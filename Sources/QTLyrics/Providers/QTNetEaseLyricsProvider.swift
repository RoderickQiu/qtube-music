import Foundation
import QTCore

/// NetEase Cloud Music (opt-in, unofficial). Search via `cloudsearch/pc`; lyrics via `song/lyric/v1`:
/// `yrc` = word timing, `lrc` = line timing, `tlyric` + `ytlrc` = Chinese translation (merged; timestamps can
/// differ from the lyric lines by up to ~1.5 s), `romalrc`/`yromalrc` = romanization. Song and artist
/// `tns`/`alia`/`alias` feed alias learning (Hạ Phỏm = 出牌).
public struct QTNetEaseLyricsProvider: QTLyricsSourceProvider {
    public let source = QTLyricsSource.netease
    public var http: any QTLyricsHTTPClient
    public var baseURL: String

    public init(http: any QTLyricsHTTPClient = QTURLSessionLyricsHTTPClient(), baseURL: String = "https://music.163.com") {
        self.http = http
        self.baseURL = baseURL
    }

    private var headers: [String: String] {
        ["Referer": "https://music.163.com/", "User-Agent": QTLyricsRequest.browserUserAgent]
    }

    public func search(_ query: QTLyricsQuery) async throws -> [QTLyricsCandidate] {
        let keyword = [query.primaryArtist, query.cleanTitle.core].filter { !$0.isEmpty }.joined(separator: " ")
        let data = try await QTLyricsRequest.send(
            QTLyricsRequest.get(baseURL + "/api/cloudsearch/pc", query: [("s", keyword), ("type", "1"), ("limit", "10")],
                                headers: headers), with: http)
        return try Self.parseSearch(data, source: source)
    }

    static func parseSearch(_ data: Data, source: QTLyricsSource) throws -> [QTLyricsCandidate] {
        let json = try QTJSON.object(data)
        let songs = ((json as? [String: Any])?["result"] as? [String: Any])?["songs"] as? [[String: Any]] ?? []
        return songs.compactMap { song in
            guard let id = QTJSON.string(song["id"]), let name = song["name"] as? String else { return nil }
            let ar = song["ar"] as? [[String: Any]] ?? []
            let artists = ar.compactMap { $0["name"] as? String }
            // Artist aliases: only short, plausible lists (spam accounts list a dozen famous names).
            let artistAliases = ar.flatMap { a -> [String] in
                let list = QTJSON.strings(a["tns"]) + QTJSON.strings(a["alias"])
                return list.count <= 2 ? list : []
            }
            let titleAliases = QTJSON.strings(song["tns"]) + QTJSON.strings(song["alia"]).filter { !$0.contains(":") && !$0.contains("：") }
            let duration = QTJSON.double(song["dt"]).map { $0 / 1000 }
            let album = (song["al"] as? [String: Any])?["name"] as? String
            return QTLyricsCandidate(source: source, remoteID: id, title: name, titleAliases: titleAliases,
                                     artists: artists, artistAliases: artistAliases, album: album, duration: duration)
        }
    }

    public func lyrics(for candidate: QTLyricsCandidate) async throws -> QTParsedLyrics? {
        let data = try await QTLyricsRequest.send(
            QTLyricsRequest.get(baseURL + "/api/song/lyric/v1",
                                query: [("id", candidate.remoteID), ("lv", "-1"), ("tv", "-1"), ("rv", "-1"),
                                        ("yv", "-1"), ("ytv", "-1"), ("yrv", "-1")],
                                headers: headers), with: http)
        return try Self.parseLyrics(data)
    }

    static func parseLyrics(_ data: Data) throws -> QTParsedLyrics? {
        guard let json = try QTJSON.object(data) as? [String: Any] else { return nil }
        if json["pureMusic"] as? Bool == true || json["nolyric"] as? Bool == true { return nil }
        func lyric(_ key: String) -> String? {
            ((json[key] as? [String: Any])?["lyric"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        var parsed: QTParsedLyrics
        if let yrc = lyric("yrc"), case let y = QTYRCParser.parse(yrc), !y.isEmpty {
            parsed = y
            if let lrc = lyric("lrc") { parsed.metadata = QTLRCParser.parse(lrc).metadata }
        } else if let lrc = lyric("lrc") {
            parsed = QTLRCParser.parse(lrc)
        } else {
            return nil
        }
        // Word-timed main text pairs best with the yrc-timed translation (`ytlrc`); line text with `tlyric`.
        let translationKeys = parsed.syncKind == .word ? ["ytlrc", "tlyric"] : ["tlyric", "ytlrc"]
        for key in translationKeys {
            if let t = lyric(key) { parsed.lanes.append(lane(from: t, kind: .translation, language: "zh-Hans")) }
        }
        for key in parsed.syncKind == .word ? ["yromalrc", "romalrc"] : ["romalrc", "yromalrc"] {
            if let r = lyric(key) { parsed.lanes.append(lane(from: r, kind: .romanization, language: nil)) }
        }
        parsed.lanes.removeAll { $0.entries.isEmpty }
        return parsed
    }

    static func lane(from lrc: String, kind: QTLyricsLane.Kind, language: String?) -> QTLyricsLane {
        let p = QTLRCParser.parse(lrc)
        let entries = p.lines.compactMap { line -> QTLyricsLane.Entry? in
            let t = line.text.trimmingCharacters(in: .whitespaces)
            guard let s = line.start, !t.isEmpty, t != "//" else { return nil }
            return .init(start: s, text: t)
        }
        return QTLyricsLane(kind: kind, language: language, entries: entries)
    }
}
