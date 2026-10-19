import Foundation
import QTInnerTube

// M5 SPIKE — native stream resolution (docs/native-engine-spike.md). Not wired into the app:
// `QTNativePlaybackEngine.isAvailable` stays false until the user decides on the build-out.
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
            signedIn: signedIn)
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

    public init(videoId: String, client: QTNativeStreamClient, format: QTNativeAudioFormat, url: URL, userAgent: String,
                durationSeconds: Double?, resolveSeconds: Double, fallbacks: [(client: String, reason: String)]) {
        self.videoId = videoId
        self.client = client
        self.format = format
        self.url = url
        self.userAgent = userAgent
        self.durationSeconds = durationSeconds
        self.resolveSeconds = resolveSeconds
        self.fallbacks = fallbacks
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

/// Resolves stream URLs. Anonymous by default; with credentials, cookie-capable clients send the signed-in session
/// (read-only: the `player` call alone records nothing — history is written by the playback-tracking pings, which
/// the spike never sends).
public actor QTNativeStreamResolver {
    private let session: URLSession
    private let credentials: QTInnerTubeCredentials?
    private var playerScript: QTNativePlayerScript?
    private var visitorDataValue: String?

    public init(credentials: QTInnerTubeCredentials? = nil, session: URLSession = QTURLSessionTransport.makeSession()) {
        self.credentials = credentials
        self.session = session
    }

    public var isSignedIn: Bool { credentials != nil }

    /// Hash of the player script, if one was needed so far.
    public var loadedPlayerHash: String? { playerScript?.playerHash }

    /// Player script (cached per resolver) — needed for web/TV clients' `signatureTimestamp` and cipher.
    public func script() async throws -> QTNativePlayerScript {
        if let playerScript { return playerScript }
        let s = try await QTNativePlayerScript.fetchCurrent(session: session)
        playerScript = s
        return s
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
