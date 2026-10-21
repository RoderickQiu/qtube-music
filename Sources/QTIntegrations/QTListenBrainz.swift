import Foundation

// ListenBrainz API (https://listenbrainz.readthedocs.io/en/latest/users/api/core.html): submit-listens (`single`,
// `playing_now`, `import` of up to 1,000) and validate-token, authorized with the user's own token
// (`Authorization: Token …`, from https://listenbrainz.org/settings/). Any ListenBrainz-compatible server (Maloja,
// a self-hosted ListenBrainz) works by its API root. Calls are spaced at least 1 s apart and honour the server's
// rate limit (`X-RateLimit-Remaining` / `X-RateLimit-Reset-In`).

public enum QTListenType: String, Sendable {
    /// One finished listen.
    case single
    /// The song just started (no timestamp; not stored as a listen).
    case playingNow = "playing_now"
    /// Several listens at once (the offline queue).
    case `import`
}

public enum QTListenBrainzError: Error, Sendable, Equatable {
    /// Connection failure: keep queued, try later.
    case network
    /// 429, or the rate-limit window is used up: wait `resetIn` seconds.
    case rateLimited(resetIn: TimeInterval?)
    /// Any other non-2xx answer (`message` = the server's `error` text). 400 = a listen it won't take, 401 = bad token.
    case http(status: Int, message: String)
    /// A 2xx answer that isn't the API's JSON (a wrong server URL showing a web page).
    case malformed
}

public enum QTListenBrainzRequest {
    public static let defaultServer = URL(string: "https://api.listenbrainz.org/")!
    /// Where users find their token.
    public static let tokenPage = URL(string: "https://listenbrainz.org/settings/")!
    /// ListenBrainz accepts up to 1,000 listens per `import`.
    public static let maxBatch = 1_000

    public static let playerName = "QTube Music"
    public static let musicService = "music.youtube.com"
    public static let musicServiceName = "YouTube Music"

    public static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
    }

    /// The API root from the Settings field: empty = listenbrainz.org; otherwise an http(s) URL with a host, with or
    /// without a trailing `/` or `/1` (Maloja's is `https://<host>/apis/listenbrainz`). nil = not a usable URL.
    public static func server(from text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return defaultServer }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/1") { s.removeLast(2) }
        guard let url = URL(string: s + "/"), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              url.host?.isEmpty == false else { return nil }
        return url
    }

    static func endpoint(_ server: URL, _ path: String) -> URL {
        URL(string: "1/" + path, relativeTo: server)!.absoluteURL
    }

    static func request(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(QTLastFMRequest.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        return request
    }

    public static func validateToken(_ token: String, server: URL = defaultServer) -> URLRequest {
        request(endpoint(server, "validate-token"), token: token)
    }

    public static func submit(_ type: QTListenType, _ plays: [QTScrobble], token: String, server: URL = defaultServer,
                              version: String = appVersion) -> URLRequest {
        var request = request(endpoint(server, "submit-listens"), token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body(type, plays, version: version)
        return request
    }

    /// The JSON body (keys sorted, so the same plays always give the same bytes).
    public static func body(_ type: QTListenType, _ plays: [QTScrobble], version: String = appVersion) -> Data {
        let payload: [String: Any] = [
            "listen_type": type.rawValue,
            "payload": plays.prefix(type == .import ? maxBatch : 1).map { listen($0, type: type, version: version) },
        ]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    static func listen(_ s: QTScrobble, type: QTListenType, version: String) -> [String: Any] {
        var info: [String: Any] = [
            "media_player": playerName, "media_player_version": version,
            "submission_client": playerName, "submission_client_version": version,
            "music_service": musicService, "music_service_name": musicServiceName,
        ]
        if let id = s.videoId, !id.isEmpty, !s.isPrivatelyOwned { info["origin_url"] = "https://music.youtube.com/watch?v=\(id)" }
        if let ms = s.durationMs ?? s.duration.map({ $0 * 1000 }), ms > 0 { info["duration_ms"] = ms }
        var metadata: [String: Any] = ["artist_name": s.artist, "track_name": s.track, "additional_info": info]
        if let album = s.album, !album.isEmpty { metadata["release_name"] = album }
        var listen: [String: Any] = ["track_metadata": metadata]
        if type != .playingNow { listen["listened_at"] = s.timestamp }
        return listen
    }

    // MARK: Responses

    /// The JSON of a 2xx answer; throws `QTListenBrainzError` for everything else.
    public static func check(_ data: Data, _ response: HTTPURLResponse) throws -> [String: Any] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        switch response.statusCode {
        case 200..<300:
            guard let json else { throw QTListenBrainzError.malformed }
            return json
        case 429:
            throw QTListenBrainzError.rateLimited(resetIn: resetIn(response))
        default:
            throw QTListenBrainzError.http(status: response.statusCode, message: json?["error"] as? String ?? "")
        }
    }

    static func resetIn(_ response: HTTPURLResponse) -> TimeInterval? {
        response.value(forHTTPHeaderField: "X-RateLimit-Reset-In").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// validate-token: the user name for a valid token (a compatible server may not send one: then `fallbackName`).
    /// An invalid token answers 200 with `"valid": false`, reported as a 401 like a refused submission.
    public static func userName(from json: [String: Any], fallbackName: String) throws -> String {
        guard json["valid"] as? Bool == true else {
            throw QTListenBrainzError.http(status: 401, message: json["message"] as? String ?? "")
        }
        let name = (json["user_name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? fallbackName : name
    }
}

/// Keeps one server's calls at least `interval` apart and stops them while its rate-limit window is used up.
public actor QTRequestPacer {
    private let interval: Duration
    private var next = ContinuousClock.now
    private var heldUntil: ContinuousClock.Instant?

    /// One for listenbrainz.org and whatever server the user set (requests are rare; sharing costs nothing).
    public static let listenBrainz = QTRequestPacer(interval: 1)

    public init(interval: TimeInterval) {
        self.interval = .milliseconds(Int(interval * 1000))
    }

    /// Waits for the next slot (at most `interval`). A longer hold isn't waited out here — that would hold up the
    /// caller's other work — but thrown as `rateLimited`, so the queue backs off instead.
    func reserve() async throws {
        let now = ContinuousClock.now
        if let heldUntil, heldUntil > now {
            let left = now.duration(to: heldUntil).components
            throw QTListenBrainzError.rateLimited(resetIn: TimeInterval(left.seconds) + TimeInterval(left.attoseconds) / 1e18)
        }
        let start = max(now, next)
        next = start + interval
        if start > now { try? await Task.sleep(until: start, clock: .continuous) }
    }

    /// The server said its window is used up (`X-RateLimit-Remaining: 0`) for `seconds`.
    func hold(for seconds: TimeInterval) {
        heldUntil = ContinuousClock.now + .milliseconds(Int(max(0, seconds) * 1000))
    }
}

/// Sends ListenBrainz requests through an injectable transport (tests never touch the network).
public struct QTListenBrainzClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public let token: String
    public let server: URL
    let version: String
    let pacer: QTRequestPacer
    let transport: Transport

    public init(token: String, server: URL = QTListenBrainzRequest.defaultServer, version: String = QTListenBrainzRequest.appVersion,
                pacer: QTRequestPacer = .listenBrainz, transport: Transport? = nil) {
        self.token = token
        self.server = server
        self.version = version
        self.pacer = pacer
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw QTListenBrainzError.network }
            return (data, http)
        }
    }

    func send(_ request: URLRequest) async throws -> [String: Any] {
        try await pacer.reserve()
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as QTListenBrainzError {
            throw error
        } catch {
            throw QTListenBrainzError.network
        }
        if response.value(forHTTPHeaderField: "X-RateLimit-Remaining")?.trimmingCharacters(in: .whitespaces) == "0",
           let resetIn = QTListenBrainzRequest.resetIn(response) {
            await pacer.hold(for: resetIn)
        }
        return try QTListenBrainzRequest.check(data, response)
    }

    /// The account the token belongs to (Connect). Throws `.http(401, …)` for a token the server doesn't know.
    public func validateToken() async throws -> String {
        let json = try await send(QTListenBrainzRequest.validateToken(token, server: server))
        return try QTListenBrainzRequest.userName(from: json, fallbackName: server.host ?? "ListenBrainz")
    }

    public func submit(_ type: QTListenType, _ plays: [QTScrobble]) async throws {
        guard !plays.isEmpty else { return }
        _ = try await send(QTListenBrainzRequest.submit(type, plays, token: token, server: server, version: version))
    }
}

/// ListenBrainz as a scrobble service: up to 1,000 listens per `import`, no age limit.
public struct QTListenBrainzScrobbleService: QTScrobbleService {
    public let client: QTListenBrainzClient

    public init(client: QTListenBrainzClient) {
        self.client = client
    }

    public var maxBatch: Int { QTListenBrainzRequest.maxBatch }
    public var maxAge: TimeInterval? { nil }

    public func nowPlaying(_ play: QTScrobble) async throws {
        try await client.submit(.playingNow, [play])
    }

    public func submit(_ plays: [QTScrobble]) async throws {
        try await client.submit(plays.count == 1 ? .single : .import, plays)
    }

    /// 401 disconnects; 429, 408, 5xx and the network wait (429 for as long as the server says); 400 rejects the
    /// listens themselves; anything else (403, 404 from a wrong server URL, a web page instead of JSON) pauses.
    public func classify(_ error: any Error) -> QTScrobbleFailure {
        guard let error = error as? QTListenBrainzError else { return .temporary(retryAfter: nil) }
        switch error {
        case .network: return .temporary(retryAfter: nil)
        case .rateLimited(let resetIn): return .temporary(retryAfter: resetIn)
        case .http(401, _): return .invalidCredentials
        case .http(400, _): return .rejectedPlays
        case .http(let status, _) where status == 408 || status >= 500: return .temporary(retryAfter: nil)
        case .http, .malformed: return .accountProblem
        }
    }
}
