import Foundation
import QTCore
@testable import QTLyrics

/// The 7-song test set (EN, ZH, 3×VI, JA, HI) with the ids recorded on 2026-10-18.
struct QTFixtureSong: Sendable {
    var slug: String
    var title: String
    var artist: String
    var duration: TimeInterval
    var videoId: String
    var neteaseId: String

    static let all: [QTFixtureSong] = [
        .init(slug: "perfect", title: "Perfect", artist: "Ed Sheeran", duration: 263, videoId: "ORrFJ63nlcA", neteaseId: "460043703"),
        .init(slug: "qingtian", title: "晴天", artist: "周杰伦", duration: 269, videoId: "SJKoWAd5ySo", neteaseId: "186016"),
        .init(slug: "haphom", title: "Hạ Phỏm", artist: "Hoàng Thùy Linh", duration: 196, videoId: "XesqCcJiQFY", neteaseId: "1968907343"),
        .init(slug: "doivoianh", title: "Đối Với Anh Em Không Còn Cảm Giác", artist: "Kim Ny Ngọc", duration: 257,
              videoId: "0sDXWfkljn4", neteaseId: "34516548"),
        .init(slug: "chungta", title: "Chúng Ta Của Hiện Tại", artist: "Sơn Tùng M-TP", duration: 301, videoId: "bNp9pn0ni3I", neteaseId: "1805346557"),
        .init(slug: "yoruni", title: "夜に駆ける", artist: "YOASOBI", duration: 261, videoId: "by4SYYWlhEs", neteaseId: "1409311773"),
        .init(slug: "arzkiyahai", title: "Arz Kiya Hai", artist: "Anuv Jain", duration: 294, videoId: "-BJt4fCAtZE", neteaseId: "2738094873"),
    ]

    static func named(_ slug: String) -> QTFixtureSong { all.first { $0.slug == slug }! }

    var query: QTLyricsQuery {
        QTLyricsQuery(videoId: videoId, title: title, artists: [artist], duration: duration)
    }
}

enum QTFixtures {
    static let root: URL = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!

    static func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    static func data(_ path: String) -> Data? { try? Data(contentsOf: url(path)) }

    static func text(_ path: String) -> String? { data(path).flatMap { String(data: $0, encoding: .utf8) } }

    static func song(_ slug: String, _ file: String) -> Data? { data("songs/\(slug)/\(file)") }
}

/// Serves the recorded (trimmed) responses by URL so every provider runs offline against real payload shapes.
struct QTFixtureHTTPClient: QTLyricsHTTPClient {
    /// URLs requested, for assertions (thread-safe log).
    let log = QTRequestLog()
    /// Hosts that answer 503 with this Retry-After (seconds).
    var rateLimited: [String: String] = [:]

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        await log.append(url)
        if let retry = rateLimited[url.host ?? ""] {
            return (Data(), HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: ["Retry-After": retry])!)
        }
        guard let body = route(request) else {
            return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    private func param(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    /// The song whose title appears in a free-text search keyword.
    private func song(matching keyword: String) -> QTFixtureSong? {
        let k = QTLyricsTextFolding.comparisonKey(keyword)
        return QTFixtureSong.all.first { k.contains(QTLyricsTextFolding.comparisonKey($0.title)) }
    }

    private func route(_ request: URLRequest) -> Data? {
        let url = request.url!
        let path = url.path
        switch url.host {
        case "music.youtube.com":
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
            if path.hasSuffix("/next"), let vid = body["videoId"] as? String,
               let s = QTFixtureSong.all.first(where: { $0.videoId == vid }) {
                return QTFixtures.song(s.slug, "ytm_next.json")
            }
            if path.hasSuffix("/browse"), let bid = body["browseId"] as? String {
                for s in QTFixtureSong.all {
                    if let next = QTFixtures.song(s.slug, "ytm_next.json"), String(decoding: next, as: UTF8.self).contains(bid) {
                        return QTFixtures.song(s.slug, "ytm_browse.json")
                    }
                }
            }
            return nil
        case "lrclib.net":
            guard path == "/api/search", let s = song(matching: param(url, "track_name") ?? "") else { return path == "/api/search" ? Data("[]".utf8) : nil }
            return QTFixtures.song(s.slug, "lrclib_search.json")
        case "music.163.com":
            if path == "/api/cloudsearch/pc" {
                guard let s = song(matching: param(url, "s") ?? "") else { return Data(#"{"result":{"songs":[]},"code":200}"#.utf8) }
                return QTFixtures.song(s.slug, "netease_search.json")
            }
            if path == "/api/song/lyric/v1", let id = param(url, "id") {
                if let s = QTFixtureSong.all.first(where: { $0.neteaseId == id }) { return QTFixtures.song(s.slug, "netease_lyric.json") }
                return Data(#"{"code":200,"lrc":{"version":0,"lyric":""}}"#.utf8)
            }
            return nil
        case "krcs.kugou.com":
            guard let s = song(matching: param(url, "keyword") ?? "") else { return Data(#"{"status":200,"candidates":[]}"#.utf8) }
            return QTFixtures.song(s.slug, "kugou_search.json") ?? Data(#"{"status":200,"candidates":[]}"#.utf8)
        case "lyrics.kugou.com":
            let id = param(url, "id") ?? ""
            for s in QTFixtureSong.all {
                guard let search = QTFixtures.song(s.slug, "kugou_search.json"),
                      let json = try? JSONSerialization.jsonObject(with: search) as? [String: Any],
                      let first = (json["candidates"] as? [[String: Any]])?.first,
                      "\(first["id"] ?? "")" == id else { continue }
                return QTFixtures.song(s.slug, "kugou_download.json")
            }
            return Data(#"{"status":404,"content":""}"#.utf8)
        case "c.y.qq.com":
            guard let s = song(matching: param(url, "key") ?? "") else {
                return Data(#"{"code":0,"data":{"song":{"count":0,"itemlist":[]}}}"#.utf8)
            }
            return QTFixtures.song(s.slug, "qq_smartbox.json")
        case "u.y.qq.com":
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            let param = ((body?["req"] as? [String: Any])?["param"] as? [String: Any])
            let id = "\(param?["songID"] ?? "")"
            for s in QTFixtureSong.all {
                guard let box = QTFixtures.song(s.slug, "qq_smartbox.json"), String(decoding: box, as: UTF8.self).contains("\"id\": \"\(id)\"")
                else { continue }
                return QTFixtures.song(s.slug, "qq_lyric.json")
            }
            return nil
        case "raw.githubusercontent.com":
            if path.hasSuffix("/metadata/raw-lyrics-index.jsonl") { return QTFixtures.data("amll_index_excerpt.jsonl") }
            if path.contains("/ncm-lyrics/"), let id = path.split(separator: "/").last?.replacingOccurrences(of: ".ttml", with: ""),
               let s = QTFixtureSong.all.first(where: { $0.neteaseId == id }) {
                return QTFixtures.song(s.slug, "amll.ttml")
            }
            return nil
        default:
            return nil
        }
    }
}

actor QTRequestLog {
    private(set) var urls: [URL] = []
    func append(_ url: URL) { urls.append(url) }
    func hosts() -> Set<String> { Set(urls.compactMap(\.host)) }
}
