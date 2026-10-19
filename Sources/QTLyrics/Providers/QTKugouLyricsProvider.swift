import Foundation
import QTCore

/// Kugou (opt-in, unofficial): word-synced KRC, strong on Vietnamese. Search needs the diacritics, so the
/// original spelling is sent. `krcs.kugou.com/search` → `lyrics.kugou.com/download` (base64 → KRC decrypt).
public struct QTKugouLyricsProvider: QTLyricsSourceProvider {
    public let source = QTLyricsSource.kugou
    public var http: any QTLyricsHTTPClient

    public init(http: any QTLyricsHTTPClient = QTURLSessionLyricsHTTPClient()) {
        self.http = http
    }

    struct SearchResponse: Decodable {
        struct Candidate: Decodable {
            var id: QTFlexibleString
            var accesskey: String
            var singer: String?
            var song: String?
            var duration: Double?
            var krctype: Int?
        }
        var candidates: [Candidate]?
    }

    struct DownloadResponse: Decodable {
        var status: Int?
        var content: String?
    }

    public func search(_ query: QTLyricsQuery) async throws -> [QTLyricsCandidate] {
        let keyword = [query.primaryArtist, query.cleanTitle.core].filter { !$0.isEmpty }.joined(separator: " - ")
        let ms = query.duration > 0 ? String(Int(query.duration * 1000)) : ""
        let data = try await QTLyricsRequest.send(
            QTLyricsRequest.get("https://krcs.kugou.com/search",
                                query: [("ver", "1"), ("man", "yes"), ("client", "mobi"), ("keyword", keyword),
                                        ("duration", ms), ("hash", "")],
                                headers: ["User-Agent": QTLyricsRequest.browserUserAgent]), with: http)
        return try Self.parseSearch(data, source: source)
    }

    static func parseSearch(_ data: Data, source: QTLyricsSource) throws -> [QTLyricsCandidate] {
        let response: SearchResponse
        do { response = try JSONDecoder().decode(SearchResponse.self, from: data) }
        catch { throw QTLyricsError.decoding("kugou search") }
        return (response.candidates ?? []).map { c in
            // Kugou mixes milliseconds and seconds in `duration`.
            let d = c.duration.map { $0 > 10_000 ? $0 / 1000 : $0 }
            return QTLyricsCandidate(source: source, remoteID: c.id.value, title: c.song ?? "",
                                     artists: (c.singer ?? "").isEmpty ? [] : QTTitleCleaner.splitArtists(c.singer!),
                                     duration: d, syncHint: .word, extra: ["accesskey": c.accesskey])
        }
    }

    public func lyrics(for candidate: QTLyricsCandidate) async throws -> QTParsedLyrics? {
        guard let key = candidate.extra["accesskey"] else { return nil }
        let data = try await QTLyricsRequest.send(
            QTLyricsRequest.get("https://lyrics.kugou.com/download",
                                query: [("ver", "1"), ("client", "pc"), ("id", candidate.remoteID), ("accesskey", key),
                                        ("fmt", "krc"), ("charset", "utf8")],
                                headers: ["User-Agent": QTLyricsRequest.browserUserAgent]), with: http)
        return try Self.parseDownload(data)
    }

    static func parseDownload(_ data: Data) throws -> QTParsedLyrics? {
        guard let r = try? JSONDecoder().decode(DownloadResponse.self, from: data), let content = r.content, !content.isEmpty
        else { return nil }
        let text = try QTKRCCodec.decrypt(base64: content)
        let parsed = QTKRCParser.parse(text)
        return parsed.isEmpty ? nil : parsed
    }
}

/// Decodes a JSON string or number as a string (Kugou ids come both ways).
struct QTFlexibleString: Decodable, Hashable {
    var value: String
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int64.self) { value = String(i) }
        else { value = String(try c.decode(Double.self)) }
    }
}
