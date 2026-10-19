import CryptoKit
import Foundation

// Transport, credentials, errors, cache and retry policy for `QTInnerTubeClient`.
// SAPISIDHASH, context and API-key handling informed by Kaset (MIT, github.com/sozercan/kaset —
// Services/API/YTMusicClient.swift), re-implemented.

// MARK: Transport

/// The HTTP layer, injectable for tests (fixtures) and for a future proxy/offline mode.
public protocol QTHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession` transport. Cookies are never handled by the session: the client sets the `Cookie` header itself
/// from the Keychain-backed session, so anonymous requests can't pick up a stale jar.
public struct QTURLSessionTransport: QTHTTPTransport {
    public let session: URLSession

    public init(session: URLSession = QTURLSessionTransport.makeSession()) {
        self.session = session
    }

    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        config.urlCache = nil
        return URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw QTInnerTubeError.invalidResponse }
        return (data, http)
    }
}

// MARK: Credentials

/// What an authenticated request needs. Produced by QTAuth from the Keychain session.
public struct QTInnerTubeCredentials: Sendable, Hashable {
    /// `Cookie` header value for `.youtube.com` (name=value; …).
    public var cookieHeader: String
    /// `SAPISID` (or `__Secure-3PAPISID`) value used for the SAPISIDHASH.
    public var sapisid: String
    /// `X-Goog-AuthUser` — index of the signed-in Google account (0 for the first).
    public var authUser: Int
    /// Brand account / channel to act as (`context.user.onBehalfOfUser`).
    public var onBehalfOfUser: String?

    public init(cookieHeader: String, sapisid: String, authUser: Int = 0, onBehalfOfUser: String? = nil) {
        self.cookieHeader = cookieHeader
        self.sapisid = sapisid
        self.authUser = authUser
        self.onBehalfOfUser = onBehalfOfUser
    }

    /// A short, non-secret fingerprint used to partition the response cache per account.
    public var cacheScope: String {
        let digest = SHA256.hash(data: Data("\(sapisid)|\(authUser)|\(onBehalfOfUser ?? "")".utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

/// Supplies credentials and learns about session loss. QTAuth implements it; nil credentials = anonymous.
public protocol QTInnerTubeCredentialsProvider: Sendable {
    func credentials() async -> QTInnerTubeCredentials?
    /// Called when an authenticated request came back signed out (HTTP 401/403 or `logged_in = 0`).
    func sessionDidExpire() async
    /// Cookies Google rotated via `Set-Cookie` on an authenticated response (`__Secure-*PSIDTS`, `SIDCC`…).
    func didReceive(cookies: [HTTPCookie]) async
}

public extension QTInnerTubeCredentialsProvider {
    func didReceive(cookies: [HTTPCookie]) async {}
}

/// `Authorization: SAPISIDHASH <ts>_<sha1("<ts> <SAPISID> <origin>")>`.
public enum QTSAPISIDHash {
    public static func header(sapisid: String, origin: String = QTInnerTubeConfiguration.origin,
                              timestamp: Int = Int(Date().timeIntervalSince1970)) -> String {
        let digest = Insecure.SHA1.hash(data: Data("\(timestamp) \(sapisid) \(origin)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(timestamp)_\(hex)"
    }
}

// MARK: Errors

public enum QTInnerTubeError: Error, Sendable, Equatable, LocalizedError {
    /// No network / timed out / connection lost (URLError code).
    case network(code: Int)
    /// Non-2xx response that isn't an auth problem.
    case http(status: Int)
    /// 429 or 503 after retries; `retryAfter` in seconds if the server said.
    case rateLimited(retryAfter: TimeInterval?)
    /// The endpoint needs a signed-in session and there is none.
    case notSignedIn
    /// We sent credentials and YouTube treated the request as signed out (cookies expired or revoked).
    case sessionExpired
    /// The response wasn't JSON or lacked the expected structure.
    case invalidResponse
    case parse(String)
    /// Account writes are disabled in this build (ask-before rule); see `QTInnerTubeClient.allowsAccountWrites`.
    case writesDisabled
    /// YouTube refused the request with an error payload.
    case api(status: Int, message: String)
    /// The request landed on Google's "unusual traffic" check (`www.google.com/sorry/…`, a captcha page) instead of
    /// YouTube Music. Not retried: the check doesn't clear by itself in seconds, and the app never opens or solves it.
    case botCheck

    /// Whether a response is Google's bot check rather than YouTube's answer: a redirect to `google.*/sorry/…`, or a
    /// captcha / "unusual traffic" HTML page.
    public static func isBotCheck(url: URL?, body: Data? = nil) -> Bool {
        if let url, let host = url.host?.lowercased(),
           host == "google.com" || host.hasSuffix(".google.com") || host.hasPrefix("google.") || host.contains(".google."),
           url.path.lowercased().hasPrefix("/sorry") {
            return true
        }
        guard let body, !body.isEmpty, body.first != UInt8(ascii: "{") else { return false }
        let text = String(decoding: body.prefix(64 * 1024), as: UTF8.self).lowercased()
        return text.contains("/sorry/index") || text.contains("unusual traffic from your computer network")
            || (text.contains("g-recaptcha") && text.contains("sorry"))
    }

    public var errorDescription: String? {
        switch self {
        case .botCheck: "YouTube asked to verify this connection"
        case .network(let code): "Network error (\(code))"
        case .http(let status): "HTTP \(status)"
        case .rateLimited: "Rate limited"
        case .notSignedIn: "Not signed in"
        case .sessionExpired: "Session expired"
        case .invalidResponse: "Invalid response"
        case .parse(let what): "Could not read \(what)"
        case .writesDisabled: "Account changes are disabled"
        case .api(let status, let message): "YouTube Music error \(status): \(message)"
        }
    }

    /// Whether retrying the same request may succeed.
    /// URL errors that mean "no usable connection" (the app's offline state). TLS and server errors aren't.
    public static let connectivityCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost,
        .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed, .callIsActive,
    ]

    /// The device is offline or can't reach YouTube.
    public var isConnectivity: Bool {
        if case .network(let code) = self { return Self.connectivityCodes.contains(URLError.Code(rawValue: code)) }
        return false
    }

    /// The request was cancelled (`NSURLErrorCancelled`, e.g. a page task cancelled on an account switch).
    public var isCancellation: Bool {
        if case .network(let code) = self { return code == URLError.Code.cancelled.rawValue }
        return false
    }

    public var isTransient: Bool {
        switch self {
        case .network(let code):
            let transient: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                                                  .dnsLookupFailed, .cannotFindHost, .notConnectedToInternet,
                                                  .secureConnectionFailed]
            return transient.contains(URLError.Code(rawValue: code))
        case .http(let status): return status >= 500
        case .rateLimited: return true
        default: return false
        }
    }
}

// MARK: Retry

/// Exponential backoff with jitter; honours `Retry-After` for 429/503.
public struct QTRetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval

    public init(maxAttempts: Int = 3, baseDelay: TimeInterval = 0.5, maxDelay: TimeInterval = 8) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public static let `default` = QTRetryPolicy()
    public static let none = QTRetryPolicy(maxAttempts: 1)

    /// Delay before attempt `attempt + 1` (attempt counts from 1).
    public func delay(afterAttempt attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter { return min(max(retryAfter, 0), maxDelay) }
        let exp = baseDelay * pow(2, Double(attempt - 1))
        return min(exp * Double.random(in: 0.8...1.2), maxDelay)
    }
}

// MARK: Cache

/// A small TTL + LRU cache of parsed responses, keyed by endpoint + body + account scope.
struct QTResponseCache: Sendable {
    struct Entry: Sendable {
        var value: QTJSON
        var expires: Date
        var lastUse: UInt64
    }

    var capacity: Int
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0

    init(capacity: Int = 48) { self.capacity = capacity }

    mutating func value(for key: String, now: Date) -> QTJSON? {
        guard var e = entries[key] else { return nil }
        if e.expires <= now {
            entries[key] = nil
            return nil
        }
        clock += 1
        e.lastUse = clock
        entries[key] = e
        return e.value
    }

    mutating func store(_ value: QTJSON, for key: String, ttl: TimeInterval, now: Date) {
        clock += 1
        entries[key] = Entry(value: value, expires: now.addingTimeInterval(ttl), lastUse: clock)
        if entries.count > capacity, let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            entries[oldest] = nil
        }
    }

    mutating func removeAll() { entries.removeAll() }

    var count: Int { entries.count }
}

/// Cache lifetimes per surface.
public enum QTCacheTTL {
    public static let home: TimeInterval = 5 * 60
    public static let explore: TimeInterval = 30 * 60
    public static let search: TimeInterval = 10 * 60
    public static let album: TimeInterval = 60 * 60
    public static let artist: TimeInterval = 30 * 60
    public static let playlist: TimeInterval = 5 * 60
    public static let library: TimeInterval = 60
    public static let lyrics: TimeInterval = 24 * 60 * 60
}
