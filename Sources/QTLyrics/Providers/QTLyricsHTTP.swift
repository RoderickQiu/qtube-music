import Foundation

public enum QTLyricsError: Error, Sendable, Equatable {
    case http(status: Int)
    /// The service asked us to slow down; don't call again before `retryAfter` seconds.
    case rateLimited(retryAfter: TimeInterval)
    case decoding(String)
    case transport(String)

    /// The source didn't answer (offline, timeout, rate limit, server error) — as opposed to answering "not found".
    /// Errors from other layers (an injected InnerTube client) count as unreachable unless they are lyrics errors
    /// that say otherwise.
    public static func isUnreachable(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        guard let e = error as? QTLyricsError else { return !(error is DecodingError) }
        switch e {
        case .transport, .rateLimited: return true
        case .http(let status): return status >= 500
        case .decoding: return false
        }
    }
}

/// The only way providers touch the network, so tests can serve recorded fixtures and the app can share
/// sessions. Requests are anonymous: no cookies, no user data.
public protocol QTLyricsHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Ephemeral `URLSession` (no cookie jar, no URL cache on disk).
public final class QTURLSessionLyricsHTTPClient: QTLyricsHTTPClient {
    private let session: URLSession

    public init(timeout: TimeInterval = 12) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw QTLyricsError.transport("not HTTP") }
            return (data, http)
        } catch let error as QTLyricsError {
            throw error
        } catch {
            throw QTLyricsError.transport(String(describing: error))
        }
    }
}

/// Shared request helpers.
enum QTLyricsRequest {
    /// Descriptive User-Agent for services that ask for one (LRCLIB).
    static let descriptiveUserAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        return "QTube Music/\(version) (macOS; native YouTube Music client; lyrics lookup)"
    }()

    static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

    static func get(_ base: String, query: [(String, String)] = [], headers: [String: String] = [:]) -> URLRequest {
        var components = URLComponents(string: base)!
        if !query.isEmpty {
            components.percentEncodedQueryItems = query.map {
                URLQueryItem(name: $0.0, value: $0.1.addingPercentEncoding(withAllowedCharacters: .qtQueryValueAllowed))
            }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        return request
    }

    static func post(_ url: String, json: Data, headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.httpBody = json
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        return request
    }

    /// Sends and checks the status; 429/503 become `.rateLimited` with the server's `Retry-After`.
    static func send(_ request: URLRequest, with http: any QTLyricsHTTPClient) async throws -> Data {
        let (data, response) = try await http.data(for: request)
        switch response.statusCode {
        case 200..<300:
            return data
        case 404:
            throw QTLyricsError.http(status: 404)
        case 429, 503:
            let header = response.value(forHTTPHeaderField: "Retry-After")
            throw QTLyricsError.rateLimited(retryAfter: retryAfterSeconds(header) ?? 30)
        default:
            throw QTLyricsError.http(status: response.statusCode)
        }
    }

    /// `Retry-After` is either delta-seconds or an HTTP date.
    static func retryAfterSeconds(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        if let s = Double(header) { return max(0, s) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: header).map { max(0, $0.timeIntervalSince(now)) }
    }
}

/// Remembers a provider's `Retry-After` so we stop calling until it passes.
actor QTRetryAfterGate {
    private var blockedUntil: Date?
    private let clock: @Sendable () -> Date

    init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    /// Throws `.rateLimited` while the gate is closed.
    func check() throws {
        if let until = blockedUntil, until > clock() {
            throw QTLyricsError.rateLimited(retryAfter: until.timeIntervalSince(clock()))
        }
        blockedUntil = nil
    }

    func close(for seconds: TimeInterval) {
        let until = clock().addingTimeInterval(seconds)
        blockedUntil = max(blockedUntil ?? until, until)
    }
}

extension CharacterSet {
    /// RFC 3986 unreserved characters — everything else is escaped inside a query value (incl. `&`, `+`, `=`).
    static let qtQueryValueAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
