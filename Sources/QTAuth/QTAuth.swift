import AppKit
import Foundation
import Observation
import QTInnerTube
import WebKit

// QTAuth — Google sign-in for YouTube Music. See docs/architecture.md › QTAuth.
//
// - `QTAuthController` (@MainActor, @Observable): state for the UI, sign-in window, sign-out (also at Google), session
//   restore, session-loss handling, session import (Firefox / cookies.txt; CDP JSON in DEBUG only).
// - `QTSessionStore` (actor): Keychain persistence + `QTInnerTubeCredentialsProvider` for `QTInnerTubeClient`.
// - Cookies live in the Keychain (service `com.roderickqiu.qtube`) and, in memory only, in the non-persistent WebKit
//   jar `QTWebKitCookieStore.session` that the web playback engine plays in. Never in a persistent WebKit store (WebKit
//   saves those as plain-text `.binarycookies`), files, logs or fixtures. Sign-in runs in a throwaway non-persistent
//   store; its cookies move to the Keychain and the throwaway is cleared.
// Account writes go through QTUI's `QTAccountWriter`, which turns `QTInnerTubeClient.setAllowsAccountWrites` on only
// while signed in with Settings › Account › Sync on. Brand accounts: `switchIdentity(to:)` (QTIdentitySwitcher.swift).

/// Signed-in state as the UI sees it.
public enum QTAuthState: Sendable, Hashable {
    case signedOut
    case signingIn
    case signedIn(accountName: String, isPremium: Bool)
    case sessionExpired
}

@MainActor
@Observable
public final class QTAuthController {
    public private(set) var state: QTAuthState = .signedOut
    public private(set) var account: QTAccountInfo?
    /// Last sign-in/restore failure, for diagnostics (never contains cookie values).
    public private(set) var lastError: QTAuthError?
    /// The brand account the session acts as (`onBehalfOfUser`), nil for the Google account itself.
    public private(set) var brandAccountId: String?
    /// Moves the player page's web session to another identity (`switchIdentity(to:)`); tests inject a fake.
    @ObservationIgnored public var identitySwitcher: any QTSessionIdentitySwitching = QTWebIdentitySwitcher()

    public let sessionStore: QTSessionStore
    @ObservationIgnored private let cookieStore: any QTWebCookieStore
    @ObservationIgnored private let client: QTInnerTubeClient?
    @ObservationIgnored private var signInWindow: QTSignInWindowController?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var foldTask: Task<Void, Never>?
    /// How long cookie changes in the web jar settle before they're folded into the Keychain session.
    @ObservationIgnored var foldDelay: Duration = .seconds(2)
    /// Ends the session at Google on sign-out (`QTGoogleSignOut`), given the session's cookies; nil signs out of the
    /// app only. Set for the app's WebKit jar in release builds; tests and in-memory jars get nil. DEBUG builds leave
    /// it off unless `-qt.auth.revoke YES`: the shared dev session is the owner's browser login, and revoking it would
    /// sign that browser out.
    @ObservationIgnored var revokeAtGoogle: (@MainActor ([QTCookie]) -> Void)?

    /// - Parameters:
    ///   - client: gets this controller's session store as its credentials provider.
    public init(sessionStore: QTSessionStore = QTSessionStore(),
                cookieStore: (any QTWebCookieStore)? = nil,
                client: QTInnerTubeClient? = nil) {
        self.sessionStore = sessionStore
        self.cookieStore = cookieStore ?? QTWebKitCookieStore.session
        self.client = client
        if self.cookieStore is QTWebKitCookieStore, Self.revokesAtGoogle {
            revokeAtGoogle = { QTGoogleSignOut.revoke($0) }
        }
        observeSessionEvents()
        self.cookieStore.onChange = { [weak self] in self?.webCookiesChanged() }
    }

    private static var revokesAtGoogle: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "qt.auth.revoke")
        #else
        true
        #endif
    }

    /// The WebKit data store signed-in playback uses (the session jar), nil when the jar isn't WebKit's (tests).
    public var webDataStore: WKWebsiteDataStore? {
        (cookieStore as? QTWebKitCookieStore)?.dataStore
    }

    public var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    // MARK: Restore

    /// Launch: load the Keychain session, hand it to the client, and make sure WebKit has the same cookies.
    public func restore() async {
        await client?.setCredentialsProvider(sessionStore)
        do {
            guard let session = try await sessionStore.restore() else {
                state = .signedOut
                return
            }
            await syncWebCookies(from: session)
            account = session.account
            brandAccountId = session.brandAccountId
            state = .signedIn(accountName: session.account?.name ?? "", isPremium: session.account?.isPremium ?? false)
        } catch let error as QTAuthError {
            lastError = error
            state = .signedOut
        } catch {
            state = .signedOut
        }
    }

    // MARK: Sign in / out

    /// Opens the Google sign-in window. `hl` = interface language for Google's pages.
    /// - Parameter isEphemeral: DEBUG screenshots only — a private, throwaway WebKit store, so the window shows
    ///   Google's sign-in page even when this app is already signed in (a finished login there isn't kept).
    public func beginSignIn(hl: String, over parent: NSWindow? = nil, isEphemeral: Bool = false) {
        if let signInWindow {
            signInWindow.present(over: parent)
            return
        }
        let previous = state
        state = .signingIn
        // Always a throwaway, memory-only store: the login is harvested into the Keychain (and the session jar)
        // and the throwaway cleared, so Google's cookies never reach a persistent WebKit store.
        let windowCookies = Self.makeSignInCookieStore()
        let controller = QTSignInWindowController(dataStore: windowCookies.dataStore, cookieStore: windowCookies, hl: hl) {
            [weak self] result in
            guard let self else { return }
            self.signInWindow = nil
            switch result {
            case .success(let cookies):
                if isEphemeral {
                    self.state = previous == .signingIn ? .signedOut : previous
                    Task { await windowCookies.removeGoogleCookies() }
                } else {
                    Task {
                        await self.completeSignIn(cookies: cookies)
                        await windowCookies.removeGoogleCookies()
                    }
                }
            case .failure(let error):
                self.lastError = error
                self.state = previous == .signingIn ? .signedOut : previous
            }
        }
        signInWindow = controller
        controller.present(over: parent, quietly: isEphemeral)
    }

    #if DEBUG
    /// DEBUG screenshots (`-qt.auth.signInPreview`): the sign-in window's own chrome around a local placeholder page,
    /// showing `address` in the strip. No network, no Google; the window is never a real sign-in.
    public func showSignInPreview(address: QTSignInAddress, showsHelp: Bool = false, over parent: NSWindow?) {
        guard signInWindow == nil else { return }
        let controller = QTSignInWindowController(dataStore: .nonPersistent(), cookieStore: QTMemoryWebCookieStore(),
                                                  hl: "en", previewAddress: address) { [weak self] _ in
            self?.signInWindow = nil
        }
        signInWindow = controller
        controller.present(over: parent, quietly: true)
        guard showsHelp else { return }
        Task { @MainActor [weak controller] in
            for await _ in NotificationCenter.default.notifications(named: QTSignInWindowController.didShowQuietly) {
                controller?.showHelpForScreenshot()
                break
            }
        }
    }
    #endif

    /// Posted when an ephemeral (screenshot) sign-in window has loaded Google's page and appeared.
    public static let ephemeralSignInDidShow = QTSignInWindowController.didShowQuietly

    /// The sign-in window's jar: a fresh non-persistent store per attempt.
    static func makeSignInCookieStore() -> QTWebKitCookieStore {
        QTWebKitCookieStore(dataStore: .nonPersistent())
    }

    public func cancelSignIn() {
        signInWindow?.close()
    }

    private func completeSignIn(cookies: [QTCookie]) async {
        do {
            try await sessionStore.save(QTAuthSession(cookies: cookies))
            await client?.setCredentialsProvider(sessionStore)
            if let saved = await sessionStore.current { await seedWebCookies(saved.cookies) }
            state = .signedIn(accountName: "", isPremium: false)
            await refreshAccount()
        } catch let error as QTAuthError {
            lastError = error
            state = .signedOut
        } catch {
            state = .signedOut
        }
    }

    /// Account facts from the signed-in web client (Premium, region); nil until `refreshAccount()` read them.
    public private(set) var accountContext: QTAccountContext?

    /// Reads the account name/photo (read-only `account/account_menu`) and Premium + region from the signed-in web
    /// client's `ytcfg` (`IS_SUBSCRIBER`, `INNERTUBE_CONTEXT_GL`). The client's `gl` follows the account region.
    public func refreshAccount() async {
        guard client != nil, isSignedIn else { return }
        let facts = await fetchAccountFacts()
        guard isSignedIn else { return }
        await apply(facts)
    }

    /// The two read-only account requests, side by side; nil for whichever failed.
    private func fetchAccountFacts() async -> (info: QTAccountInfo?, context: QTAccountContext?) {
        guard let client else { return (nil, nil) }
        async let infoResult = try? client.account()
        async let contextResult = try? client.accountContext()
        return await (infoResult, contextResult)
    }

    private func apply(_ facts: (info: QTAccountInfo?, context: QTAccountContext?)) async {
        if let context = facts.context {
            accountContext = context
            if let gl = context.gl { await client?.setRegion(gl: gl) }
        }
        guard var info = facts.info ?? account else { return }
        if let premium = facts.context?.isSubscriber { info.isPremium = premium }
        account = info
        try? await sessionStore.setAccount(info)
        state = .signedIn(accountName: info.name, isPremium: info.isPremium ?? false)
    }

    /// Signs out: Keychain item, WebKit Google/YouTube cookies and the response cache are all cleared, and the session
    /// is ended at Google too (`revokeAtGoogle`), so it leaves the account's device list instead of lingering there.
    public func signOut() async {
        signInWindow?.close()
        foldTask?.cancel()
        if let revokeAtGoogle, let saved = await sessionStore.current {
            // The jar's rotated cookies are the newest; the Keychain's fill in the rest.
            let cookies = QTAuthSession.filtered(saved.cookies + (await cookieStore.allCookies()))
            revokeAtGoogle(cookies)
        }
        try? await sessionStore.clear()
        await cookieStore.removeGoogleCookies()
        await client?.clearCache()
        account = nil
        brandAccountId = nil
        state = .signedOut
    }

    // MARK: Brand accounts

    /// Acts as another identity of the signed-in Google account (a brand account / channel, or the account itself).
    /// The player page moves first and must confirm the new identity (`QTSessionIdentitySwitching`); only then do
    /// the API requests follow (`onBehalfOfUser`, cache cleared). If the page can't confirm it, nothing changes and
    /// this throws — plays never go to one identity while the library shows another.
    public func switchIdentity(to identity: QTAccountIdentity) async throws {
        guard isSignedIn else { throw QTIdentitySwitchError.noWebSession }
        guard let url = identity.signinURL else { throw QTIdentitySwitchError.invalidLink }
        try await identitySwitcher.switchIdentity(to: url, brandId: identity.brandId, dataStore: webDataStore)
        try await sessionStore.setBrandAccount(identity.brandId)
        brandAccountId = identity.brandId
        await client?.setCredentialsProvider(sessionStore)
        let premium: Bool
        if case .signedIn(_, let p) = state { premium = p } else { premium = false }
        account = QTAccountInfo(name: identity.name, handle: identity.handle, photo: identity.photo)
        state = .signedIn(accountName: identity.name, isPremium: premium)
        await refreshAccount()
    }

    /// Back to the Google account itself for the API, without touching the web session (a launch whose saved brand
    /// account couldn't be confirmed in the player page).
    public func useMainIdentity() async {
        guard brandAccountId != nil else { return }
        try? await sessionStore.setBrandAccount(nil)
        brandAccountId = nil
        await client?.setCredentialsProvider(sessionStore)
        await refreshAccount()
    }

    // MARK: Session loss

    private func observeSessionEvents() {
        let store = sessionStore
        eventsTask = Task { [weak self] in
            for await event in await store.events() {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: QTSessionEvent) {
        switch event {
        case .expired:
            // Nothing to expire when signed out (an import that YouTube refused has already rolled back).
            guard state != .signedOut else { return }
            state = .sessionExpired
            Task { await client?.clearCache() }
        case .signedOut:
            if state != .signingIn { state = .signedOut }
        case .signedIn:
            break
        case .cookiesRotated(let cookies):
            // API responses rotated the session: the player page must present the same cookies.
            Task { await seedWebCookies(cookies) }
        }
    }

    // MARK: WebKit sync

    /// Puts the Keychain cookies into the session jar (empty at launch: it lives in memory only), so the web
    /// playback engine is signed in too. When the jar already holds the same login (a second restore), its rotated
    /// cookies are folded back into the Keychain instead.
    private func syncWebCookies(from session: QTAuthSession) async {
        let web = QTAuthSession(cookies: QTAuthSession.filtered(await cookieStore.allCookies()))
        if web.sapisid != session.sapisid {
            await seedWebCookies(session.cookies)
        } else {
            await sessionStore.merge(web.cookies)
        }
    }

    /// The only way session cookies enter WebKit. Refuses a persistent jar: WebKit would save them in plain text.
    private func seedWebCookies(_ cookies: [QTCookie]) async {
        guard !cookieStore.isPersistent else { return }
        await cookieStore.set(cookies)
    }

    /// The player page rotated cookies (Google's `RotateCookies`, `SIDCC` on every response): after they settle,
    /// fold the auth cookies of the same login back into the Keychain session.
    private func webCookiesChanged() {
        guard isSignedIn else { return }
        foldTask?.cancel()
        foldTask = Task { @MainActor [weak self, foldDelay] in
            try? await Task.sleep(for: foldDelay)
            guard let self, !Task.isCancelled, self.isSignedIn else { return }
            await self.foldWebCookies()
        }
    }

    /// Exposed for tests (skips the settle delay).
    func foldWebCookies() async {
        let web = QTAuthSession(cookies: QTAuthSession.filtered(await cookieStore.allCookies()))
        guard let current = await sessionStore.current, web.sapisid != nil, web.sapisid == current.sapisid else { return }
        await sessionStore.merge(web.cookies)
    }

    // MARK: Session import

    /// Imports a session the user brought from their own browser (Settings › Account › Import Session: a Firefox
    /// profile or a cookies.txt file) — the way in for passkey-only and Advanced Protection accounts, which can't
    /// finish Google's sign-in inside an app. Keeps only the allow-listed Google/YouTube auth cookies and needs a
    /// complete login (`.incompleteSession` otherwise). While it's checked the state is `.signingIn`: it's saved to
    /// the Keychain and the account is read as after a sign-in. When YouTube answers that read signed out, the login
    /// behind the cookies is gone: nothing is kept (signed out) and it throws `.sessionRejected`. Network errors keep
    /// the session, as at launch. Then the session jar gets the cookies and the state is `.signedIn`.
    /// Callers delete any temporary cookie copy right after this returns.
    public func importSession(cookies: [QTCookie], authUser: Int = 0, brandAccountId: String? = nil) async throws {
        let session = QTAuthSession(cookies: QTAuthSession.filtered(cookies), authUser: authUser,
                                    brandAccountId: brandAccountId)
        guard session.isComplete else { throw QTAuthError.incompleteSession }
        let previous = state
        state = .signingIn
        do {
            try await sessionStore.save(session)
        } catch {
            state = previous
            throw error
        }
        await client?.setCredentialsProvider(sessionStore)
        let facts = await fetchAccountFacts()
        if await sessionStore.expired {
            // Local only: there's no live session left to end at Google. The Keychain item was replaced, so this
            // is signed out whatever came before.
            try? await sessionStore.clear()
            await client?.clearCache()
            account = nil
            accountContext = nil
            state = .signedOut
            lastError = .sessionRejected
            throw QTAuthError.sessionRejected
        }
        await seedWebCookies(session.cookies)
        account = nil
        state = .signedIn(accountName: "", isPremium: false)
        await apply(facts)
    }

    #if DEBUG
    /// DEBUG ONLY. Same as `importSession(cookies:)` for the JSON that Chrome DevTools Protocol's
    /// `Network.getCookies` / `Storage.getCookies` return (`{"cookies": [...]}` or a bare array).
    public func importSession(cdpCookiesJSON data: Data, authUser: Int = 0, brandAccountId: String? = nil) async throws {
        try await importSession(cookies: QTCookie.decodeCDP(data), authUser: authUser, brandAccountId: brandAccountId)
    }
    #endif
}

#if DEBUG
/// DEBUG ONLY (the dev cookie import): not in the shipping binary.
extension QTCookie {
    /// Cookies in Chrome DevTools Protocol form: `name`, `value`, `domain`, `path`, `expires` (Unix seconds, -1 for
    /// session cookies), `secure`, `httpOnly`, `sameSite`.
    public static func decodeCDP(_ data: Data) throws -> [QTCookie] {
        struct CDPCookie: Decodable {
            var name: String
            var value: String
            var domain: String
            var path: String?
            var expires: Double?
            var secure: Bool?
            var httpOnly: Bool?
            var sameSite: String?
        }
        struct Wrapper: Decodable { var cookies: [CDPCookie] }
        let decoder = JSONDecoder()
        let list: [CDPCookie]
        if let wrapped = try? decoder.decode(Wrapper.self, from: data) {
            list = wrapped.cookies
        } else {
            list = try decoder.decode([CDPCookie].self, from: data)
        }
        return list.map { c in
            let expires = c.expires.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            return QTCookie(name: c.name, value: c.value, domain: c.domain, path: c.path ?? "/", expires: expires,
                            isSecure: c.secure ?? false, isHTTPOnly: c.httpOnly ?? false, sameSite: c.sameSite)
        }
    }
}
#endif
