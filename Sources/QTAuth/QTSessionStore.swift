import Foundation
import QTInnerTube

/// Events the UI reacts to.
public enum QTSessionEvent: Sendable, Equatable {
    case signedIn
    case signedOut
    /// YouTube answered a signed-in request as signed out; the user needs to sign in again.
    case expired
}

/// Owns the current session: Keychain persistence, credentials for `QTInnerTubeClient`, cookie rotation and
/// session-loss detection. Never logs or exposes cookie values.
public actor QTSessionStore: QTInnerTubeCredentialsProvider {
    private let store: any QTSecureStore
    private let now: @Sendable () -> Date
    private var session: QTAuthSession?
    private var isExpired = false
    private var continuations: [UUID: AsyncStream<QTSessionEvent>.Continuation] = [:]

    public init(store: any QTSecureStore = QTKeychainStore(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    // MARK: Lifecycle

    /// Loads the session saved in the Keychain. Returns it if it's still a complete login.
    @discardableResult
    public func restore() throws -> QTAuthSession? {
        guard let data = try store.read() else {
            session = nil
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard var saved = try? decoder.decode(QTAuthSession.self, from: data) else {
            try? store.delete()
            session = nil
            return nil
        }
        saved.cookies = QTAuthSession.filtered(saved.cookies, now: now())
        guard saved.isComplete else {
            session = nil
            return nil
        }
        session = saved
        isExpired = false
        return saved
    }

    /// Saves a new login (from the sign-in window or the debug import).
    public func save(_ newSession: QTAuthSession) throws {
        var s = newSession
        s.cookies = QTAuthSession.filtered(s.cookies, now: now())
        guard s.isComplete else { throw QTAuthError.incompleteSession }
        s.savedAt = now()
        try persist(s)
        session = s
        isExpired = false
        emit(.signedIn)
    }

    /// Forgets the session (Keychain item removed). Web cookies are cleared by `QTAuthController`.
    public func clear() throws {
        session = nil
        isExpired = false
        try store.delete()
        emit(.signedOut)
    }

    public var current: QTAuthSession? { session }
    public var expired: Bool { isExpired }

    public func setAccount(_ account: QTAccountInfo?) throws {
        guard var s = session else { return }
        s.account = account
        try persist(s)
        session = s
    }

    /// Selects a brand account (`onBehalfOfUser`), nil for the main account.
    public func setBrandAccount(_ id: String?) throws {
        guard var s = session else { return }
        s.brandAccountId = id
        try persist(s)
        session = s
    }

    /// Rotated cookies (Set-Cookie on API responses, WebKit cookie changes).
    public func merge(_ cookies: [QTCookie]) {
        guard let s = session, !isExpired else { return }
        let merged = s.merging(cookies, now: now())
        guard merged.cookies != s.cookies, merged.isComplete else { return }
        session = merged
        try? persist(merged)
    }

    /// One stream per subscriber.
    public func events() -> AsyncStream<QTSessionEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<QTSessionEvent>.makeStream()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func emit(_ event: QTSessionEvent) {
        for c in continuations.values { c.yield(event) }
    }

    private func persist(_ s: QTAuthSession) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(s) else { throw QTAuthError.encoding }
        try store.write(data)
    }

    // MARK: QTInnerTubeCredentialsProvider

    public func credentials() async -> QTInnerTubeCredentials? {
        guard !isExpired else { return nil }
        return session?.credentials(now: now())
    }

    public func sessionDidExpire() async {
        guard session != nil, !isExpired else { return }
        isExpired = true
        emit(.expired)
    }

    public func didReceive(cookies: [HTTPCookie]) async {
        merge(cookies.map(QTCookie.init))
    }
}
