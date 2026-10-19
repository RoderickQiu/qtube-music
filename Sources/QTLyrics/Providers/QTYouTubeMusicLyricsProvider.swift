import Foundation
import QTCore

/// Sends InnerTube requests for the lyrics provider. QTInnerTube (M3) can inject its own client (shared
/// visitor data, `hl`/`gl`); until then `QTAnonymousInnerTubeLyricsRequester` makes anonymous calls.
public protocol QTInnerTubeLyricsRequesting: Sendable {
    /// POST `youtubei/v1/{endpoint}` as the ANDROID_MUSIC client with `payload` merged into the body
    /// (`["videoId": …]` for `next`, `["browseId": …]` for `browse`). Returns the raw JSON.
    func post(endpoint: String, payload: [String: String]) async throws -> Data
}

/// Anonymous ANDROID_MUSIC InnerTube requests (HANDOFF §6: `next` → `MPLY…` browseId → `browse` → `timedLyricsData`).
public struct QTAnonymousInnerTubeLyricsRequester: QTInnerTubeLyricsRequesting {
    public static let clientVersion = "7.21.50"
    public var http: any QTLyricsHTTPClient
    public var hl: String
    public var gl: String

    public init(http: any QTLyricsHTTPClient = QTURLSessionLyricsHTTPClient(), hl: String = "en", gl: String = "US") {
        self.http = http
        self.hl = hl
        self.gl = gl
    }

    public func post(endpoint: String, payload: [String: String]) async throws -> Data {
        var body: [String: Any] = payload
        body["context"] = ["client": ["clientName": "ANDROID_MUSIC", "clientVersion": Self.clientVersion,
                                      "androidSdkVersion": 34, "hl": hl, "gl": gl]]
        let json = try JSONSerialization.data(withJSONObject: body)
        let request = QTLyricsRequest.post(
            "https://music.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false", json: json,
            headers: ["X-YouTube-Client-Name": "21", "X-YouTube-Client-Version": Self.clientVersion,
                      "User-Agent": "com.google.android.apps.youtube.music/\(Self.clientVersion) (Linux; U; Android 14) gzip",
                      "Origin": "https://music.youtube.com"])
        return try await QTLyricsRequest.send(request, with: http)
    }
}

/// YouTube Music's own lyrics, keyed by videoId (exact match, no fuzzy scoring). Line-synced when YouTube has
/// timed lyrics (LyricFind/Musixmatch), plain otherwise.
public struct QTYouTubeMusicLyricsProvider: QTLyricsSourceProvider {
    public let source = QTLyricsSource.youtubeMusic
    public var requester: any QTInnerTubeLyricsRequesting

    public init(requester: any QTInnerTubeLyricsRequesting = QTAnonymousInnerTubeLyricsRequester()) {
        self.requester = requester
    }

    public func search(_ query: QTLyricsQuery) async throws -> [QTLyricsCandidate] {
        [QTLyricsCandidate(source: source, remoteID: query.lyricsVideoId, title: query.title, artists: query.artists,
                           album: query.album, duration: query.duration > 0 ? query.duration : nil, isExactMatch: true)]
    }

    public func lyrics(for candidate: QTLyricsCandidate) async throws -> QTParsedLyrics? {
        let next = try QTJSON.object(try await requester.post(endpoint: "next", payload: ["videoId": candidate.remoteID]))
        guard let browseId = Self.lyricsBrowseId(inNext: next) else { return nil }
        let browse = try QTJSON.object(try await requester.post(endpoint: "browse", payload: ["browseId": browseId]))
        return Self.parseBrowse(browse)
    }

    /// The `MPLY…` browse id of the Lyrics tab (absent for OMVs and tracks without lyrics).
    static func lyricsBrowseId(inNext json: Any) -> String? {
        for endpoint in QTJSON.find("browseEndpoint", in: json) {
            if let id = (endpoint as? [String: Any])?["browseId"] as? String, id.hasPrefix("MPLY") { return id }
        }
        return nil
    }

    /// `timedLyricsModel.lyricsData.timedLyricsData[]` (line cues) or a description shelf (plain text).
    static func parseBrowse(_ json: Any) -> QTParsedLyrics? {
        if let model = QTJSON.find("timedLyricsData", in: json, limit: 1).first as? [[String: Any]], !model.isEmpty {
            var lines: [QTParsedLyricsLine] = []
            for cue in model {
                guard let text = cue["lyricLine"] as? String, let range = cue["cueRange"] as? [String: Any],
                      let start = QTJSON.double(range["startTimeMilliseconds"]) else { continue }
                let end = QTJSON.double(range["endTimeMilliseconds"])
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !QTLyricsCleanup.isMusicNoteOnly(trimmed) else { continue }
                lines.append(QTParsedLyricsLine(start: start / 1000, end: end.map { $0 / 1000 }, text: trimmed))
            }
            let attribution = QTJSON.find("sourceMessage", in: json, limit: 1).first.flatMap(QTJSON.string)
            return lines.isEmpty ? nil : QTParsedLyrics(lines: lines, metadata: .init(attribution: attribution))
        }
        if let shelf = QTJSON.find("musicDescriptionShelfRenderer", in: json, limit: 1).first as? [String: Any] {
            let runs = (shelf["description"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
            let text = runs.compactMap { $0["text"] as? String }.joined()
            let footer = ((shelf["footer"] as? [String: Any])?["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            guard lines.contains(where: { !$0.isEmpty }) else { return nil }
            return QTParsedLyrics(lines: lines.map { QTParsedLyricsLine(start: nil, text: $0) },
                                  metadata: .init(attribution: footer))
        }
        return nil
    }
}
