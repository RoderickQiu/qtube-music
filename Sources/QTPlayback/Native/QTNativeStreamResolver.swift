import Foundation
import QTInnerTube

// Native engine — stream resolution (docs/native-engine-spike.md). The app's native Premium engine resolves with
// WEB_REMIX and the signed-in session (`resolvePremium`); the other clients stay for the QTNativeSpike harness.
//
// Asks the InnerTube `player` endpoint for a track's streams with one of several client profiles, the way yt-dlp,
// NewPipe and YouTube.js do (their public source was the reference; nothing is copied or linked). Mobile clients
// return plain googlevideo URLs; web/TV clients return `signatureCipher` + an `n` parameter that only the
// current player JavaScript can transform (see `QTNativePlayerScript`).

/// One InnerTube client identity for the `player` request.
public struct QTNativeStreamClient: Sendable, Hashable, CustomStringConvertible {
    public var name: String
    public var version: String
    /// `X-YouTube-Client-Name` numeric id.
    public var headerID: Int
    public var host: String
    public var userAgent: String
    /// Extra `context.client` fields (device/OS) the server checks.
    public var extraContext: [String: String]
    public var androidSdkVersion: Int?
    /// Whether the server honours web cookies (SAPISIDHASH) for this client. Mobile/VR clients ignore them.
    public var supportsCookies: Bool
    /// Whether responses carry `signatureCipher`/`n` that need the player script (and a `signatureTimestamp`).
    public var needsPlayerScript: Bool

    public var description: String { name }

    // Client identities as yt-dlp's public client table listed them in its 2026.08 release (yt_dlp/extractor/
    // youtube/_base.py). YouTube retires versions and changes which clients get plain URLs every few weeks; keeping
    // this table current is most of the maintenance burden (docs/native-engine-spike.md).
    public static let androidVR = QTNativeStreamClient(
        name: "ANDROID_VR", version: "1.65.10", headerID: 28, host: "www.youtube.com",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
        extraContext: ["deviceMake": "Oculus", "deviceModel": "Quest 3", "osName": "Android", "osVersion": "12L"],
        androidSdkVersion: 32, supportsCookies: false, needsPlayerScript: false)
    public static let iOS = QTNativeStreamClient(
        name: "IOS", version: "21.26.4", headerID: 5, host: "www.youtube.com",
        userAgent: "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
        extraContext: ["deviceMake": "Apple", "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": "18.3.2.22D82"],
        androidSdkVersion: nil, supportsCookies: false, needsPlayerScript: false)
    public static let android = QTNativeStreamClient(
        name: "ANDROID", version: "21.26.364", headerID: 3, host: "www.youtube.com",
        userAgent: "com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip",
        extraContext: ["osName": "Android", "osVersion": "11"],
        androidSdkVersion: 30, supportsCookies: false, needsPlayerScript: false)
    /// yt-dlp's default JS-less client since 2026.08.
    public static let visionOS = QTNativeStreamClient(
        name: "VISIONOS", version: "1.02", headerID: 101, host: "www.youtube.com",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        extraContext: ["deviceMake": "Apple", "deviceModel": "RealityDevice17,1", "osName": "visionOS",
                       "osVersion": "26.5.23O471"],
        androidSdkVersion: nil, supportsCookies: false, needsPlayerScript: false)
    public static let tvSamsung = QTNativeStreamClient(
        name: "TVHTML5", version: "5.20260707", headerID: 7, host: "www.youtube.com",
        userAgent: "Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/2.4.0 TV Safari/538.1",
        extraContext: ["deviceMake": "Samsung", "deviceModel": "UKS9800", "osName": "Tizen", "osVersion": "2.4.0"],
        androidSdkVersion: nil, supportsCookies: true, needsPlayerScript: true)
    public static let tvSimply = QTNativeStreamClient(
        name: "TVHTML5_SIMPLY", version: "1.0", headerID: 75, host: "www.youtube.com",
        userAgent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version",
        extraContext: [:], androidSdkVersion: nil, supportsCookies: false, needsPlayerScript: true)
    /// The YouTube Music web client — the only one that returns the Premium 256 kbps formats (AAC 141, Opus 774) for a
    /// Premium session, and whose media URLs need no PO token for Premium accounts.
    public static let webRemix = QTNativeStreamClient(
        name: "WEB_REMIX", version: "1.20260707.12.00", headerID: 67, host: "music.youtube.com",
        userAgent: QTInnerTubeConfiguration.defaultUserAgent,
        extraContext: [:], androidSdkVersion: nil, supportsCookies: true, needsPlayerScript: true)

    public static let all: [QTNativeStreamClient] = [.androidVR, .iOS, .android, .visionOS, .tvSamsung, .tvSimply, .webRemix]

    /// Short names for `--clients` (TVHTML5 is ambiguous, so the Samsung profile is `TV`).
    public var shortName: String { self == .tvSamsung ? "TV" : name }

    public static func named(_ name: String) -> QTNativeStreamClient? {
        all.first { $0.shortName.caseInsensitiveCompare(name) == .orderedSame || $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// One audio rendition from `streamingData.adaptiveFormats`.
public struct QTNativeAudioFormat: Sendable, Hashable {
    public var itag: Int
    public var mimeType: String
    public var bitrate: Int
    public var contentLength: Int?
    /// Plain URL (mobile clients) — nil when the format is ciphered.
    public var url: URL?
    /// `signatureCipher` query string (`s=…&sp=sig&url=…`) for web/TV clients.
    public var signatureCipher: String?
    public var loudnessDb: Double?
    public var isDrc: Bool
    public var audioTrackName: String?

    /// AAC in MP4 — the only YouTube audio AVFoundation decodes. Opus arrives in WebM, which AVFoundation can't
    /// demux (it decodes Opus only from CAF/MP4/Ogg containers).
    public var isAVFoundationPlayable: Bool { mimeType.hasPrefix("audio/mp4") }
    public var codec: String {
        guard let r = mimeType.range(of: "codecs=\"") else { return mimeType }
        return String(mimeType[r.upperBound...].prefix { $0 != "\"" })
    }
    public var urlHasNParameter: Bool {
        let s = url?.query ?? signatureCipher.flatMap { $0.removingPercentEncoding } ?? ""
        return s.contains("&n=") || s.hasPrefix("n=")
    }
}

public enum QTNativePlayability: Sendable, Hashable {
    case ok
    case loginRequired(String)
    case unplayable(String)
    case error(String)
}

/// The parsed `player` response for one client.
public struct QTNativePlayerResponse: Sendable {
    public var client: QTNativeStreamClient
    public var playability: QTNativePlayability
    public var audioFormats: [QTNativeAudioFormat]
    public var hlsManifestURL: URL?
    /// Present when the server only wants SABR (UMP) streaming for this client.
    public var hasServerABR: Bool
    public var expiresInSeconds: Int?
    public var durationSeconds: Double?
    public var signedIn: Bool
    /// `playerConfig.audioConfig.loudnessDb` (formats usually carry their own).
    public var loudnessDb: Double?

    /// Best AVFoundation-playable audio: AAC 256 (Premium, itag 141) > AAC 128 (140) > HE-AAC 48 (139).
    public var bestPlayableAudio: QTNativeAudioFormat? {
        audioFormats.filter { $0.isAVFoundationPlayable && !$0.isDrc }
            .max { $0.bitrate < $1.bitrate }
    }

    public var bestAudioAnyCodec: QTNativeAudioFormat? {
        audioFormats.filter { !$0.isDrc }.max { $0.bitrate < $1.bitrate }
    }

    /// Parses a `player` response. Pure — unit-tested with a fixture-shaped JSON.
    public static func parse(_ json: QTJSON, client: QTNativeStreamClient, signedIn: Bool) -> QTNativePlayerResponse {
        let status = json["playabilityStatus"]["status"].string ?? "ERROR"
        let reason = json["playabilityStatus"]["reason"].string
            ?? json["playabilityStatus"]["messages"][0].string ?? ""
        let playability: QTNativePlayability = switch status {
        case "OK": .ok
        case "LOGIN_REQUIRED", "AGE_CHECK_REQUIRED", "CONTENT_CHECK_REQUIRED": .loginRequired(reason)
        case "UNPLAYABLE": .unplayable(reason)
        default: .error("\(status): \(reason)")
        }
        let streaming = json["streamingData"]
        let formats: [QTNativeAudioFormat] = streaming["adaptiveFormats"].array.compactMap { f in
            guard let mime = f["mimeType"].string, mime.hasPrefix("audio/"), let itag = f["itag"].int else { return nil }
            return QTNativeAudioFormat(
                itag: itag, mimeType: mime, bitrate: f["bitrate"].int ?? 0,
                contentLength: f["contentLength"].string.flatMap(Int.init),
                url: f["url"].string.flatMap(URL.init(string:)),
                signatureCipher: f["signatureCipher"].string ?? f["cipher"].string,
                loudnessDb: f["loudnessDb"].double, isDrc: f["isDrc"].bool ?? false,
                audioTrackName: f["audioTrack"]["displayName"].string)
        }
        return QTNativePlayerResponse(
            client: client, playability: playability, audioFormats: formats,
            hlsManifestURL: streaming["hlsManifestUrl"].string.flatMap(URL.init(string:)),
            hasServerABR: streaming["serverAbrStreamingUrl"].string != nil,
            expiresInSeconds: streaming["expiresInSeconds"].string.flatMap(Int.init),
            durationSeconds: json["videoDetails"]["lengthSeconds"].string.flatMap(Double.init),
            signedIn: signedIn,
            loudnessDb: json["playerConfig"]["audioConfig"]["loudnessDb"].double)
    }
}

/// A playable audio URL ready for AVFoundation.
public struct QTNativeResolvedStream: Sendable {
    public var videoId: String
    public var client: QTNativeStreamClient
    public var format: QTNativeAudioFormat
    public var url: URL
    /// The User-Agent googlevideo expects on media requests (must match the client that asked).
    public var userAgent: String
    public var durationSeconds: Double?
    /// Seconds spent in `player` requests (all attempts).
    public var resolveSeconds: Double
    /// Clients tried before this one succeeded, with why they failed.
    public var fallbacks: [(client: String, reason: String)]
    /// When googlevideo stops honouring `url` (its `expire` parameter; about 6 h after resolving).
    public var expires: Date?
    /// The track's loudness relative to YouTube's target (dB; positive = louder). YouTube's own player turns loud
    /// tracks down by this much, and so does the native engine, so both engines sound equally loud.
    public var loudnessDb: Double?

    public init(videoId: String, client: QTNativeStreamClient, format: QTNativeAudioFormat, url: URL, userAgent: String,
                durationSeconds: Double?, resolveSeconds: Double, fallbacks: [(client: String, reason: String)],
                loudnessDb: Double? = nil) {
        self.videoId = videoId
        self.client = client
        self.format = format
        self.url = url
        self.userAgent = userAgent
        self.durationSeconds = durationSeconds
        self.resolveSeconds = resolveSeconds
        self.fallbacks = fallbacks
        self.expires = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "expire" }?.value.flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
        self.loudnessDb = loudnessDb ?? format.loudnessDb
    }

    /// The `dur` parameter: the rendition's exact length in seconds (ms precision).
    public var exactDuration: Double? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "dur" }?.value
            .flatMap(Double.init)
    }

    /// Still usable for at least `margin` seconds.
    public func isFresh(margin: TimeInterval = 120) -> Bool {
        guard let expires else { return true }
        return expires.timeIntervalSinceNow > margin
    }
}

public enum QTNativeStreamError: Error, Sendable, CustomStringConvertible {
    case noPlayableAudio(String)
    case http(Int)
    case cipherUnsolved(String)

    public var description: String {
        switch self {
        case .noPlayableAudio(let s): "no playable audio: \(s)"
        case .http(let s): "HTTP \(s)"
        case .cipherUnsolved(let s): "cipher: \(s)"
        }
    }
}

/// Why the native engine couldn't play something, sorted by what the engine does about it.
public enum QTNativeFailure: Error, Sendable, Hashable, CustomStringConvertible {
    /// The native path itself is broken right now (403 on media, a bot check, the solver, SABR-only answers, no
    /// session): the engine falls back to YouTube's player for the rest of the session.
    case systemic(String)
    /// Only this item (unplayable, region, age check, no AAC rendition, a network hiccup): YouTube's player gets this
    /// item, and says why if it can't play it either.
    case item(String)

    public var description: String {
        switch self {
        case .systemic(let s): "native unavailable: \(s)"
        case .item(let s): "item: \(s)"
        }
    }

    public var isSystemic: Bool {
        if case .systemic = self { return true }
        return false
    }

    /// Classifies a `player` answer that isn't OK.
    static func playability(_ p: QTNativePlayability) -> QTNativeFailure {
        switch p {
        case .ok: .item("ok")
        case .loginRequired(let reason):
            // "Sign in to confirm you're not a bot" — with a session, that is about us, not the song.
            reason.localizedCaseInsensitiveContains("bot") ? .systemic("bot check") : .item("login required: \(reason)")
        case .unplayable(let reason):
            // "The page needs to be reloaded" is a client problem, not the song's.
            reason.localizedCaseInsensitiveContains("reload") ? .systemic("unplayable: \(reason)") : .item("unplayable: \(reason)")
        case .error(let reason): .item(reason)
        }
    }

    /// Classifies any error from resolving or downloading.
    static func from(_ error: any Error) -> QTNativeFailure {
        if let failure = error as? QTNativeFailure { return failure }
        if let stream = error as? QTNativeStreamError {
            switch stream {
            case .cipherUnsolved(let s): return .systemic("solver: \(s)")
            // Refused (403/410/401: the session or the player): the native path is off for the session. A passing
            // server error or rate limit (5xx, 429, 408) is about this request only: the item plays in the web engine.
            case .http(let code): return Self.isTransientHTTP(code) ? .item("HTTP \(code)") : .systemic("HTTP \(code)")
            case .noPlayableAudio(let s): return s.contains("SABR") ? .systemic("SABR only") : .item(s)
            }
        }
        if let url = error as? URLError { return .item("network: \(url.code.rawValue)") }
        return .systemic(String(describing: error))
    }

    static func isTransientHTTP(_ code: Int) -> Bool {
        code >= 500 || code == 429 || code == 408
    }
}

/// Resolves stream URLs. Anonymous by default; with credentials, cookie-capable clients send the signed-in session
/// (read-only: the `player` call alone records nothing — history is written by the playback-tracking pings, which
/// the spike never sends).
public actor QTNativeStreamResolver {
    /// How long a loaded player is trusted before its hash is checked again (YouTube ships players every few days;
    /// a stale player's signatures fail, which invalidates it at once).
    public static let playerRecheckInterval: TimeInterval = 3600

    private let session: URLSession
    private let credentialsProvider: @Sendable () async -> QTInnerTubeCredentials?
    private let playerCache: QTNativePlayerCache?
    private var playerScript: QTNativePlayerScript?
    private var playerCheckedAt: TimeInterval = 0
    private var scriptTask: Task<QTNativePlayerScript, any Error>?
    private var visitorDataValue: String?
    private var credentials: QTInnerTubeCredentials?
    private var resolved: [String: QTNativeResolvedStream] = [:]

    /// Fixed credentials (the spike harness; nil = anonymous).
    public init(credentials: QTInnerTubeCredentials? = nil, session: URLSession = QTURLSessionTransport.makeSession(),
                playerCache: QTNativePlayerCache? = nil) {
        self.credentials = credentials
        self.credentialsProvider = { credentials }
        self.session = session
        self.playerCache = playerCache
    }

    /// Credentials read for every resolve (the app: the Keychain session, whose cookies rotate).
    public init(credentialsProvider: @escaping @Sendable () async -> QTInnerTubeCredentials?,
                session: URLSession = QTURLSessionTransport.makeSession(), playerCache: QTNativePlayerCache? = .shared) {
        self.credentialsProvider = credentialsProvider
        self.session = session
        self.playerCache = playerCache
    }

    public var isSignedIn: Bool { credentials != nil }

    /// Hash of the player script, if one was needed so far.
    public var loadedPlayerHash: String? { playerScript?.playerHash }

    /// Player script — needed for web/TV clients' `signatureTimestamp` and cipher. Kept per resolver (its warm solver
    /// context with it), its hash re-checked hourly, preprocessed per hash on disk. Concurrent callers share a fetch.
    public func script() async throws -> QTNativePlayerScript {
        let now = ProcessInfo.processInfo.systemUptime
        if let playerScript, now - playerCheckedAt < Self.playerRecheckInterval { return playerScript }
        if let scriptTask { return try await scriptTask.value }
        let session = session, cache = playerCache, previous = playerScript
        let task = Task<QTNativePlayerScript, any Error> {
            // Same hash as the loaded one: keep it.
            if let previous, let hash = try? await QTNativePlayerScript.currentHash(session: session),
               hash == previous.playerHash { return previous }
            return try await QTNativePlayerScript.fetchCurrent(session: session, cache: cache)
        }
        scriptTask = task
        defer { scriptTask = nil }
        let s = try await task.value
        playerScript = s
        playerCheckedAt = ProcessInfo.processInfo.systemUptime
        return s
    }

    /// Forgets the player and every resolved URL (a signature failed or media was refused): the next request checks
    /// for a new player.
    public func invalidatePlayer() {
        playerScript = nil
        resolved.removeAll()
    }

    /// Drops one resolved URL (googlevideo refused it, or it is about to expire).
    public func forget(videoId: String) {
        resolved[videoId] = nil
    }

    /// Premium audio for the app's native engine: WEB_REMIX with the signed-in session — the only client that serves
    /// the 256 kbps renditions and needs no PO token for Premium. Errors are `QTNativeFailure`s. A resolved URL is
    /// reused until shortly before it expires. Read-only: the `player` call records nothing in the account's history.
    public func resolvePremium(videoId: String) async throws -> QTNativeResolvedStream {
        if let hit = resolved[videoId], hit.isFresh() { return hit }
        guard let creds = await credentialsProvider() else { throw QTNativeFailure.systemic("not signed in") }
        credentials = creds
        let start = ProcessInfo.processInfo.systemUptime
        let response: QTNativePlayerResponse
        do {
            response = try await player(videoId: videoId, client: .webRemix)
        } catch {
            throw QTNativeFailure.from(error)
        }
        guard response.playability == .ok else { throw QTNativeFailure.playability(response.playability) }
        guard let format = response.bestPlayableAudio else {
            let noURLs = response.audioFormats.allSatisfy { $0.url == nil && $0.signatureCipher == nil }
            throw response.hasServerABR && noURLs ? QTNativeFailure.systemic("SABR only") : QTNativeFailure.item("no AAC rendition")
        }
        let answered = ProcessInfo.processInfo.systemUptime
        let url: URL
        do {
            url = try await mediaURL(for: format)
        } catch {
            throw QTNativeFailure.from(error)
        }
        QTNativeAudioFetcher.log.debug("native resolve \(videoId, privacy: .public): player \(answered - start, format: .fixed(precision: 3)) s, signatures \(ProcessInfo.processInfo.systemUptime - answered, format: .fixed(precision: 3)) s")
        let stream = QTNativeResolvedStream(videoId: videoId, client: .webRemix, format: format, url: url,
                                            userAgent: QTNativeStreamClient.webRemix.userAgent,
                                            durationSeconds: response.durationSeconds,
                                            resolveSeconds: ProcessInfo.processInfo.systemUptime - start, fallbacks: [],
                                            loudnessDb: format.loudnessDb ?? response.loudnessDb)
        if resolved.count > 64 { resolved.removeAll() }
        resolved[videoId] = stream
        return stream
    }

    /// Anonymous visitor id (`VISITOR_DATA`) — web/TV clients refuse anonymous `player` calls without one.
    public func visitorData() async -> String? {
        if let visitorDataValue { return visitorDataValue }
        var request = URLRequest(url: URL(string: "https://www.youtube.com/sw.js_data")!)
        request.setValue(QTInnerTubeConfiguration.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await session.data(for: request) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.firstIndex(of: "["),
              let json = try? QTJSON(data: Data(text[start...].utf8)) else { return nil }
        visitorDataValue = json[0][2][0][0][13].string
        return visitorDataValue
    }

    /// One `player` request with one client.
    public func player(videoId: String, client: QTNativeStreamClient) async throws -> QTNativePlayerResponse {
        var clientContext: [String: Any] = ["clientName": client.name, "clientVersion": client.version, "hl": "en", "gl": "US"]
        for (k, v) in client.extraContext { clientContext[k] = v }
        if let sdk = client.androidSdkVersion { clientContext["androidSdkVersion"] = sdk }
        if client.supportsCookies, credentials == nil { credentials = await credentialsProvider() }
        let signedIn = client.supportsCookies && credentials != nil
        if client.needsPlayerScript, !signedIn, let visitor = await visitorData() { clientContext["visitorData"] = visitor }
        var body: [String: Any] = ["context": ["client": clientContext], "videoId": videoId,
                                   "contentCheckOk": true, "racyCheckOk": true]
        if client.needsPlayerScript, let sts = try? await script().signatureTimestamp {
            body["playbackContext"] = ["contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS",
                                                                   "signatureTimestamp": sts]]
        }
        var request = URLRequest(url: URL(string: "https://\(client.host)/youtubei/v1/player?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(String(client.headerID), forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("https://\(client.host)", forHTTPHeaderField: "Origin")
        if signedIn, let credentials {
            // Values go straight into headers; never logged.
            let origin = "https://\(client.host)"
            request.setValue(credentials.cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue(QTSAPISIDHash.header(sapisid: credentials.sapisid, origin: origin),
                             forHTTPHeaderField: "Authorization")
            request.setValue(String(credentials.authUser), forHTTPHeaderField: "X-Goog-AuthUser")
            request.setValue(origin, forHTTPHeaderField: "X-Origin")
        }
        request.httpShouldHandleCookies = false
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw QTNativeStreamError.http(status) }
        return QTNativePlayerResponse.parse(try QTJSON(data: data), client: client, signedIn: signedIn)
    }

    /// A format's final media URL: deciphered signature (web/TV) and transformed `n`, or the plain URL as is.
    public func mediaURL(for format: QTNativeAudioFormat) async throws -> URL {
        let signed: URL
        if let plain = format.url {
            signed = plain
        } else if let cipher = format.signatureCipher {
            signed = try await script().decipher(cipher)
        } else {
            throw QTNativeStreamError.noPlayableAudio("no URL (SABR only)")
        }
        let hasN = URLComponents(url: signed, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "n" } ?? false
        return hasN ? try await script().transformN(signed) : signed
    }

    /// Tries clients in order until one yields an AVFoundation-playable audio URL.
    public func resolve(videoId: String, clients: [QTNativeStreamClient]) async throws -> QTNativeResolvedStream {
        let start = ProcessInfo.processInfo.systemUptime
        var fallbacks: [(String, String)] = []
        for client in clients {
            do {
                let response = try await player(videoId: videoId, client: client)
                guard response.playability == .ok else {
                    fallbacks.append((client.name, "\(response.playability)"))
                    continue
                }
                guard let format = response.bestPlayableAudio else {
                    fallbacks.append((client.name, response.hasServerABR ? "SABR only" : "no AAC format"))
                    continue
                }
                let final = try await mediaURL(for: format)
                return QTNativeResolvedStream(videoId: videoId, client: client, format: format, url: final,
                                              userAgent: client.userAgent, durationSeconds: response.durationSeconds,
                                              resolveSeconds: ProcessInfo.processInfo.systemUptime - start,
                                              fallbacks: fallbacks)
            } catch {
                fallbacks.append((client.name, "\(error)"))
            }
        }
        throw QTNativeStreamError.noPlayableAudio(fallbacks.map { "\($0.0): \($0.1)" }.joined(separator: "; "))
    }
}
