import AppKit
import Foundation
import Observation
import QTInnerTube
import WebKit

// QTAuth — Google sign-in for YouTube Music. See docs/architecture.md › QTAuth.
//
// - `QTAuthController` (@MainActor, @Observable): state for the UI, sign-in window, sign-out, session restore,
//   session-loss handling, DEBUG-only session import.
// - `QTSessionStore` (actor): Keychain persistence + `QTInnerTubeCredentialsProvider` for `QTInnerTubeClient`.
// - Cookies live in the Keychain (service `com.roderickqiu.qtube`) and, in memory only, in the non-persistent WebKit
//   jar `QTWebKitCookieStore.session` that the web playback engine plays in. Never in a persistent WebKit store (WebKit
//   saves those as plain-text `.binarycookies`), files, logs or fixtures. Sign-in runs in a throwaway non-persistent
//   store; its cookies move to the Keychain and the throwaway is cleared.
// Writing to the user's account is gated: ask the user first (`QTInnerTubeClient.setAllowsAccountWrites`).

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

    public let sessionStore: QTSessionStore
    @ObservationIgnored private let cookieStore: any QTWebCookieStore
    @ObservationIgnored private let client: QTInnerTubeClient?
    @ObservationIgnored private var signInWindow: QTSignInWindowController?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var foldTask: Task<Void, Never>?
    /// How long cookie changes in the web jar settle before they're folded into the Keychain session.
    @ObservationIgnored var foldDelay: Duration = .seconds(2)

    /// - Parameters:
    ///   - client: gets this controller's session store as its credentials provider.
    public init(sessionStore: QTSessionStore = QTSessionStore(),
                cookieStore: (any QTWebCookieStore)? = nil,
                client: QTInnerTubeClient? = nil) {
        self.sessionStore = sessionStore
        self.cookieStore = cookieStore ?? QTWebKitCookieStore.session
        self.client = client
        observeSessionEvents()
        self.cookieStore.onChange = { [weak self] in self?.webCookiesChanged() }
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
        guard let client, isSignedIn else { return }
        async let infoResult = try? client.account()
        async let contextResult = try? client.accountContext()
        let (fetched, context) = await (infoResult, contextResult)
        guard isSignedIn else { return }
        if let context {
            accountContext = context
            if let gl = context.gl { await client.setRegion(gl: gl) }
        }
        guard var info = fetched ?? account else { return }
        if let premium = context?.isSubscriber { info.isPremium = premium }
        account = info
        try? await sessionStore.setAccount(info)
        state = .signedIn(accountName: info.name, isPremium: info.isPremium ?? false)
    }

    /// Signs out: Keychain item, WebKit Google/YouTube cookies and the response cache are all cleared.
    public func signOut() async {
        signInWindow?.close()
        foldTask?.cancel()
        try? await sessionStore.clear()
        await cookieStore.removeGoogleCookies()
        await client?.clearCache()
        account = nil
        state = .signedOut
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

    // MARK: Debug import

    #if DEBUG
    /// DEBUG ONLY. Imports a session from cookies exported from a signed-in browser profile (HANDOFF §8): keeps
    /// only the Google/YouTube auth cookies, writes them to the Keychain and to WebKit, and signs in.
    /// Callers must delete any temporary cookie copy right after this returns.
    public func importSession(cookies: [QTCookie], authUser: Int = 0, brandAccountId: String? = nil) async throws {
        let session = QTAuthSession(cookies: QTAuthSession.filtered(cookies), authUser: authUser,
                                    brandAccountId: brandAccountId)
        guard session.isComplete else { throw QTAuthError.incompleteSession }
        try await sessionStore.save(session)
        await seedWebCookies(session.cookies)
        await client?.setCredentialsProvider(sessionStore)
        state = .signedIn(accountName: "", isPremium: false)
    }

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
