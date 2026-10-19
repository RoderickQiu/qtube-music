import Foundation
import QTCore

// Owner: builder "lyrics-live". The InnerTube side of the YouTube Music lyrics provider (QTLyrics ›
// `QTYouTubeMusicLyricsProvider`, which parses the responses). See docs/architecture.md › QTInnerTube.

/// YouTube Music lyrics requests. Timed (line-synced) lyrics are only served to the Android app, so these calls use
/// an **ANDROID_MUSIC** context instead of WEB_REMIX: `next` (videoId) → the Lyrics tab's `MPLY…` browseId →
/// `browse` → `timedLyricsModel` (line cues) or a description shelf (plain text).
///
/// Always anonymous — no cookies, no SAPISIDHASH (using the user's session for lyrics would need their go-ahead).
/// When built over a `QTInnerTubeClient` it follows that client's `hl`/`gl` and reuses its visitor id, so lyrics come
/// back for the same region as the catalog.
public actor QTInnerTubeLyricsClient {
    public static let clientName = "ANDROID_MUSIC"
    /// `X-YouTube-Client-Name` for ANDROID_MUSIC.
    public static let clientNameID = "21"
    /// Verified anonymously 2026-10-18 (HANDOFF §6).
    public static let clientVersion = "7.21.50"
    public static let androidSDKVersion = 34
    public static let userAgent = "com.google.android.apps.youtube.music/\(clientVersion) (Linux; U; Android 14) gzip"

    private let client: QTInnerTubeClient?
    private let transport: any QTHTTPTransport
    private let baseURL: URL
    private var hl: String
    private var gl: String

    /// - Parameters:
    ///   - client: the app's catalog client, if any (language/region/visitor id follow it).
    ///   - hl/gl: used when there is no client.
    public init(client: QTInnerTubeClient? = nil, transport: any QTHTTPTransport = QTURLSessionTransport(),
                baseURL: URL = URL(string: "https://music.youtube.com/youtubei/v1/")!, hl: String = "en", gl: String = "US") {
        self.client = client
        self.transport = transport
        self.baseURL = baseURL
        self.hl = hl
        self.gl = gl
    }

    /// Interface language changed (only used without a client).
    public func setLanguage(hl: String) { self.hl = hl }
    public func setRegion(gl: String) { self.gl = gl }

    /// POSTs `youtubei/v1/{endpoint}` with `payload` merged into the body and an ANDROID_MUSIC context; returns the
    /// raw JSON (the lyrics parser walks it loosely). Throws `QTInnerTubeError` (`.network`, `.rateLimited`, `.http`).
    public func post(_ endpoint: String, payload: [String: String]) async throws -> Data {
        var (hl, gl, visitor) = (self.hl, self.gl, String?.none)
        if let client {
            let configuration = await client.configuration
            (hl, gl) = (configuration.hl, configuration.gl)
            visitor = await client.clientConfig().visitorData
        }
        let request = try Self.makeRequest(baseURL: baseURL, endpoint: endpoint, payload: payload, hl: hl, gl: gl,
                                           visitorData: visitor)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError {
            throw QTInnerTubeError.network(code: error.errorCode)
        } catch let error as QTInnerTubeError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw QTInnerTubeError.network(code: URLError.Code.unknown.rawValue)
        }
        switch response.statusCode {
        case 200..<300: return data
        case 429, 503:
            throw QTInnerTubeError.rateLimited(retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        default: throw QTInnerTubeError.http(status: response.statusCode)
        }
    }

    static func makeRequest(baseURL: URL, endpoint: String, payload: [String: String], hl: String, gl: String,
                            visitorData: String?) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)
        else { throw QTInnerTubeError.invalidResponse }
        components.queryItems = [URLQueryItem(name: "prettyPrint", value: "false")]
        guard let url = components.url else { throw QTInnerTubeError.invalidResponse }
        var client: [String: QTJSON] = [
            "clientName": .string(clientName), "clientVersion": .string(clientVersion),
            "androidSdkVersion": .number(Double(androidSDKVersion)), "hl": .string(hl), "gl": .string(gl),
        ]
        if let visitorData { client["visitorData"] = .string(visitorData) }
        var body = payload.mapValues { QTJSON.string($0) }
        body["context"] = ["client": .object(client)]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 12
        request.httpBody = try QTJSON.object(body).data()
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(QTInnerTubeConfiguration.origin, forHTTPHeaderField: "Origin")
        request.setValue(hl, forHTTPHeaderField: "Accept-Language")
        request.setValue(clientNameID, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let visitorData { request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        return request
    }
}
