import Foundation
import QTCore

/// QQ Music (opt-in, unofficial): word-synced QRC with translation and romanization lanes. Full search is
/// geo-blocked outside China, so candidates come from `smartbox_new.fcg`; lyrics from `musicu.fcg`
/// `GetPlayLyricInfo` (hex → QQ triple-DES → zlib).
public struct QTQQMusicLyricsProvider: QTLyricsSourceProvider {
    public let source = QTLyricsSource.qq
    public var http: any QTLyricsHTTPClient

    public init(http: any QTLyricsHTTPClient = QTURLSessionLyricsHTTPClient()) {
        self.http = http
    }

    private var headers: [String: String] { ["Referer": "https://y.qq.com/", "User-Agent": QTLyricsRequest.browserUserAgent] }

    public func search(_ query: QTLyricsQuery) async throws -> [QTLyricsCandidate] {
        let title = query.cleanTitle.core
        var found = try await smartbox([query.primaryArtist, title].filter { !$0.isEmpty }.joined(separator: " "))
        if found.isEmpty { found = try await smartbox(title) }
        return found
    }

    private func smartbox(_ key: String) async throws -> [QTLyricsCandidate] {
        let data = try await QTLyricsRequest.send(
            QTLyricsRequest.get("https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg",
                                query: [("format", "json"), ("key", key)], headers: headers), with: http)
        return try Self.parseSmartbox(data, source: source)
    }

    static func parseSmartbox(_ data: Data, source: QTLyricsSource) throws -> [QTLyricsCandidate] {
        let json = try QTJSON.object(data)
        let items = (((json as? [String: Any])?["data"] as? [String: Any])?["song"] as? [String: Any])?["itemlist"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let id = QTJSON.string(item["id"]), let mid = item["mid"] as? String, let name = item["name"] as? String
            else { return nil }
            let singer = item["singer"] as? String ?? ""
            return QTLyricsCandidate(source: source, remoteID: id, title: name,
                                     artists: singer.isEmpty ? [] : QTTitleCleaner.splitArtists(singer),
                                     syncHint: .word, extra: ["mid": mid])
        }
    }

    public func lyrics(for candidate: QTLyricsCandidate) async throws -> QTParsedLyrics? {
        let body: [String: Any] = [
            "comm": ["ct": "19", "cv": "1859", "uin": "0"],
            "req": ["module": "music.musichallSong.PlayLyricInfo", "method": "GetPlayLyricInfo",
                    "param": ["songID": Int(candidate.remoteID) ?? 0, "songMID": candidate.extra["mid"] ?? "",
                              "qrc": 1, "trans": 1, "roma": 1, "crypt": 1, "type": 0]],
        ]
        let json = try JSONSerialization.data(withJSONObject: body)
        let data = try await QTLyricsRequest.send(
            QTLyricsRequest.post("https://u.y.qq.com/cgi-bin/musicu.fcg", json: json, headers: headers), with: http)
        return try Self.parseLyrics(data)
    }

    static func parseLyrics(_ data: Data) throws -> QTParsedLyrics? {
        let json = try QTJSON.object(data)
        guard let d = ((json as? [String: Any])?["req"] as? [String: Any])?["data"] as? [String: Any] else { return nil }
        func decrypt(_ key: String) throws -> String? {
            guard let hex = d[key] as? String, !hex.isEmpty else { return nil }
            return try QTQRCCodec.decrypt(hex: hex)
        }
        guard let lyric = try decrypt("lyric") else { return nil }
        var parsed = QTQRCParser.parse(lyric)
        guard !parsed.isEmpty else { return nil }
        if let trans = try? decrypt("trans") {
            parsed.lanes.append(QTNetEaseLyricsProvider.lane(from: trans, kind: .translation, language: "zh-Hans"))
        }
        if let roma = try? decrypt("roma") {
            let r = QTQRCParser.parse(roma)
            let entries = r.lines.compactMap { l in l.start.map { QTLyricsLane.Entry(start: $0, text: l.text) } }
            parsed.lanes.append(QTLyricsLane(kind: .romanization, language: nil, entries: entries))
        }
        parsed.lanes.removeAll { $0.entries.isEmpty }
        return parsed
    }
}
