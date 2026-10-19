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
// - Cookies live in the Keychain (service `com.roderickqiu.qtube`) and in `WKWebsiteDataStore.default()` (shared
//   with the web playback engine). Never in files, logs or fixtures.
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

    /// - Parameters:
    ///   - client: gets this controller's session store as its credentials provider.
    public init(sessionStore: QTSessionStore = QTSessionStore(),
                cookieStore: (any QTWebCookieStore)? = nil,
                client: QTInnerTubeClient? = nil) {
        self.sessionStore = sessionStore
        self.cookieStore = cookieStore ?? QTWebKitCookieStore()
        self.client = client
        observeSessionEvents()
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
        var dataStore = (cookieStore as? QTWebKitCookieStore)?.dataStore ?? .default()
        var windowCookies: any QTWebCookieStore = cookieStore
        if isEphemeral {
            dataStore = .nonPersistent()
            windowCookies = QTWebKitCookieStore(dataStore: dataStore)
        }
        let controller = QTSignInWindowController(dataStore: dataStore, cookieStore: windowCookies, hl: hl) {
            [weak self] result in
            guard let self else { return }
            self.signInWindow = nil
            switch result {
            case .success(let cookies):
                if isEphemeral {
                    self.state = previous == .signingIn ? .signedOut : previous
                } else {
                    Task { await self.completeSignIn(cookies: cookies) }
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

    public func cancelSignIn() {
        signInWindow?.close()
    }

    private func completeSignIn(cookies: [QTCookie]) async {
        do {
            try await sessionStore.save(QTAuthSession(cookies: cookies))
            await client?.setCredentialsProvider(sessionStore)
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
        }
    }

    // MARK: WebKit sync

    /// Puts the Keychain cookies into WebKit when WebKit lost them (e.g. website data cleared), so the web
    /// playback engine is signed in too.
    private func syncWebCookies(from session: QTAuthSession) async {
        let web = QTAuthSession(cookies: QTAuthSession.filtered(await cookieStore.allCookies()))
        if web.sapisid != session.sapisid {
            await cookieStore.set(session.cookies)
        } else {
            // WebKit has the same login, possibly with fresher rotated cookies: fold those back in.
            await sessionStore.merge(web.cookies)
        }
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
        await cookieStore.set(session.cookies)
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
