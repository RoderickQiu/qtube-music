import CryptoKit
import Foundation

// Last.fm API 2.0 (https://www.last.fm/api): request building + signing, web authorization, now playing,
// scrobble batches, and `QTLastFMScrobbleService` (what its error codes mean for the queue). The user supplies the
// API key + shared secret (no app-wide key is registered yet).

public struct QTLastFMCredentials: Sendable, Hashable {
    public var apiKey: String
    public var apiSecret: String
    public init(apiKey: String, apiSecret: String) {
        self.apiKey = apiKey
        self.apiSecret = apiSecret
    }
}

/// A Last.fm web-service session (`auth.getSession`): `key` never expires unless the user revokes it.
public struct QTLastFMSession: Sendable, Hashable {
    public var name: String
    public var key: String
    public init(name: String, key: String) {
        self.name = name
        self.key = key
    }
}

/// One play to scrobble (`track.scrobble` item, a ListenBrainz listen) or announce (now playing). Saved in the offline
/// queues: fields added later are optional and decoded with `decodeIfPresent`, so queues written by older versions
/// still load.
public struct QTScrobble: Codable, Sendable, Hashable {
    public var artist: String
    public var track: String
    public var album: String?
    /// Seconds.
    public var duration: Int?
    /// Unix time (UTC) the track started playing.
    public var timestamp: Int
    /// The YouTube video id (ListenBrainz `origin_url`).
    public var videoId: String?
    /// A song the user uploaded to their own library: its link is private, so it is never sent.
    public var isPrivatelyOwned: Bool
    /// Exact length in milliseconds (ListenBrainz `duration_ms`).
    public var durationMs: Int?
    /// The account (and server) a queued play belongs to; it is only ever sent there (`QTScrobbleQueue`). nil =
    /// not yet queued, or queued before plays were keyed (adopted by the next account that connects).
    public var account: String?

    public init(artist: String, track: String, album: String? = nil, duration: Int? = nil, timestamp: Int,
                videoId: String? = nil, isPrivatelyOwned: Bool = false, durationMs: Int? = nil, account: String? = nil) {
        self.artist = artist
        self.track = track
        self.album = album
        self.duration = duration
        self.timestamp = timestamp
        self.videoId = videoId
        self.isPrivatelyOwned = isPrivatelyOwned
        self.durationMs = durationMs
        self.account = account
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        artist = try c.decode(String.self, forKey: .artist)
        track = try c.decode(String.self, forKey: .track)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        duration = try c.decodeIfPresent(Int.self, forKey: .duration)
        timestamp = try c.decode(Int.self, forKey: .timestamp)
        videoId = try c.decodeIfPresent(String.self, forKey: .videoId)
        isPrivatelyOwned = try c.decodeIfPresent(Bool.self, forKey: .isPrivatelyOwned) ?? false
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs)
        account = try c.decodeIfPresent(String.self, forKey: .account)
    }
}

public enum QTLastFMError: Error, Sendable, Equatable {
    /// HTTP / connection failure: keep queued, try later.
    case network
    /// Last.fm error code + message. 9 = invalid session (reconnect), 11/16 = temporarily unavailable,
    /// 29 = rate limited, 4/14/15 = authorization not (yet) granted.
    case api(code: Int, message: String)
    case malformed

    /// Worth retrying later without user action.
    public var isTemporary: Bool {
        switch self {
        case .network: true
        case .api(let code, _): [8, 11, 16, 29].contains(code)
        case .malformed: false
        }
    }

    /// The session key no longer works; the user has to connect again.
    public var isInvalidSession: Bool {
        if case .api(9, _) = self { return true }
        return false
    }

    /// Last.fm refused what was sent, not who sent it (6 invalid parameters, 7 invalid resource): the plays
    /// themselves are bad and retrying won't help.
    public var isRejectedPlay: Bool {
        if case .api(let code, _) = self { return [6, 7].contains(code) }
        return false
    }
}

public enum QTLastFMRequest {
    public static let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    public static let authorizePage = URL(string: "https://www.last.fm/api/auth/")!
    /// Last.fm accepts up to 50 scrobbles per request.
    public static let maxBatch = 50

    /// `api_sig`: every parameter except `format` / `callback`, sorted by name, as name+value, then the secret;
    /// MD5, lowercase hex (UTF-8 throughout).
    public static func signature(_ params: [String: String], secret: String) -> String {
        let base = params.filter { $0.key != "format" && $0.key != "callback" }
            .sorted { $0.key < $1.key }
            .map { $0.key + $0.value }
            .joined() + secret
        return Insecure.MD5.hash(data: Data(base.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A signed POST (`application/x-www-form-urlencoded`, JSON response).
    public static func signed(method: String, params: [String: String], credentials: QTLastFMCredentials,
                              sessionKey: String? = nil) -> URLRequest {
        var all = params
        all["method"] = method
        all["api_key"] = credentials.apiKey
        if let sessionKey { all["sk"] = sessionKey }
        all["api_sig"] = signature(all, secret: credentials.apiSecret)
        all["format"] = "json"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(formEncoded(all).utf8)
        request.timeoutInterval = 20
        return request
    }

    public static var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        return "QTubeMusic/\(version) (macOS)"
    }

    static func formEncoded(_ params: [String: String]) -> String {
        params.sorted { $0.key < $1.key }.map { "\(escape($0.key))=\(escape($0.value))" }.joined(separator: "&")
    }

    /// RFC 3986 unreserved characters stay; everything else is percent-encoded (spaces as %20).
    static func escape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(.init(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: Methods

    public static func getToken(_ c: QTLastFMCredentials) -> URLRequest {
        signed(method: "auth.getToken", params: [:], credentials: c)
    }

    /// The page the user approves the app on (opened in their browser).
    public static func authorizeURL(apiKey: String, token: String) -> URL {
        var comps = URLComponents(url: authorizePage, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "api_key", value: apiKey), URLQueryItem(name: "token", value: token)]
        return comps.url!
    }

    public static func getSession(token: String, _ c: QTLastFMCredentials) -> URLRequest {
        signed(method: "auth.getSession", params: ["token": token], credentials: c)
    }

    public static func updateNowPlaying(_ s: QTScrobble, _ c: QTLastFMCredentials, sessionKey: String) -> URLRequest {
        var p = ["artist": s.artist, "track": s.track]
        if let album = s.album, !album.isEmpty { p["album"] = album }
        if let d = s.duration, d > 0 { p["duration"] = String(d) }
        return signed(method: "track.updateNowPlaying", params: p, credentials: c, sessionKey: sessionKey)
    }

    /// `track.scrobble` for up to 50 plays (`artist[i]`, `track[i]`, `timestamp[i]`, …).
    public static func scrobble(_ batch: [QTScrobble], _ c: QTLastFMCredentials, sessionKey: String) -> URLRequest {
        var p: [String: String] = [:]
        for (i, s) in batch.prefix(maxBatch).enumerated() {
            p["artist[\(i)]"] = s.artist
            p["track[\(i)]"] = s.track
            p["timestamp[\(i)]"] = String(s.timestamp)
            if let album = s.album, !album.isEmpty { p["album[\(i)]"] = album }
            if let d = s.duration, d > 0 { p["duration[\(i)]"] = String(d) }
        }
        return signed(method: "track.scrobble", params: p, credentials: c, sessionKey: sessionKey)
    }

    // MARK: Responses

    /// Throws `.api` for `{"error": n, "message": …}` bodies (Last.fm also uses HTTP 4xx for them).
    public static func check(_ data: Data, _ response: HTTPURLResponse) throws -> [String: Any] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let code = json?["error"] as? Int {
            throw QTLastFMError.api(code: code, message: json?["message"] as? String ?? "")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw response.statusCode >= 500 ? QTLastFMError.network : QTLastFMError.malformed
        }
        guard let json else { throw QTLastFMError.malformed }
        return json
    }

    public static func token(from json: [String: Any]) throws -> String {
        guard let t = json["token"] as? String, !t.isEmpty else { throw QTLastFMError.malformed }
        return t
    }

    public static func session(from json: [String: Any]) throws -> QTLastFMSession {
        guard let s = json["session"] as? [String: Any], let name = s["name"] as? String, let key = s["key"] as? String
        else { throw QTLastFMError.malformed }
        return QTLastFMSession(name: name, key: key)
    }
}

/// Sends Last.fm requests through an injectable transport (tests never touch the network).
public struct QTLastFMClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public let credentials: QTLastFMCredentials
    let transport: Transport

    public init(credentials: QTLastFMCredentials, transport: Transport? = nil) {
        self.credentials = credentials
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw QTLastFMError.network }
            return (data, http)
        }
    }

    func send(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as QTLastFMError {
            throw error
        } catch {
            throw QTLastFMError.network
        }
        return try QTLastFMRequest.check(data, response)
    }

    /// Step 1 of the web flow: a request token to approve at `QTLastFMRequest.authorizeURL`.
    public func requestToken() async throws -> String {
        try QTLastFMRequest.token(from: await send(QTLastFMRequest.getToken(credentials)))
    }

    /// Step 2, after the user approved in the browser (error 14 = not yet approved, 15 = token expired).
    public func session(token: String) async throws -> QTLastFMSession {
        try QTLastFMRequest.session(from: await send(QTLastFMRequest.getSession(token: token, credentials)))
    }

    public func updateNowPlaying(_ s: QTScrobble, sessionKey: String) async throws {
        _ = try await send(QTLastFMRequest.updateNowPlaying(s, credentials, sessionKey: sessionKey))
    }

    public func scrobble(_ batch: [QTScrobble], sessionKey: String) async throws {
        _ = try await send(QTLastFMRequest.scrobble(batch, credentials, sessionKey: sessionKey))
    }
}

/// Last.fm as a scrobble service: 50 plays per request, nothing older than 14 days.
public struct QTLastFMScrobbleService: QTScrobbleService {
    public let client: QTLastFMClient
    public let sessionKey: String

    public init(client: QTLastFMClient, sessionKey: String) {
        self.client = client
        self.sessionKey = sessionKey
    }

    public var maxBatch: Int { QTLastFMRequest.maxBatch }
    public var maxAge: TimeInterval? { QTScrobbleRules.maximumAge }

    public func nowPlaying(_ play: QTScrobble) async throws {
        try await client.updateNowPlaying(play, sessionKey: sessionKey)
    }

    public func submit(_ plays: [QTScrobble]) async throws {
        try await client.scrobble(plays, sessionKey: sessionKey)
    }

    /// 9 (revoked session) disconnects; 8 / 11 / 16 / 29 and the network wait; 6 / 7 reject the plays themselves;
    /// anything that says the API account is wrong (10 invalid key, 26 suspended, 13 bad signature, an unreadable
    /// answer…) pauses sending and keeps the queue.
    public func classify(_ error: any Error) -> QTScrobbleFailure {
        guard let error = error as? QTLastFMError else { return .temporary(retryAfter: nil) }
        if error.isInvalidSession { return .invalidCredentials }
        if error.isTemporary { return .temporary(retryAfter: nil) }
        if error.isRejectedPlay { return .rejectedPlays }
        return .accountProblem
    }
}
