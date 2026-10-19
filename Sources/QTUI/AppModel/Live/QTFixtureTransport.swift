#if DEBUG
import Foundation
import QTInnerTube

// Owner: builder "guest-mode". DEBUG only: YouTube Music answered from the recorded, anonymous InnerTube responses in
// Tests/QTInnerTubeTests/Fixtures (`-qt.live.fixtures YES`), so guest-mode pages can be shown and screenshotted
// with no network at all. Anything without a recording fails as offline. Artwork stays offline too
// (`QTImageLoader.allowsNetwork`), so cards show their placeholders.

struct QTFixtureTransport: QTHTTPTransport {
    /// `Tests/QTInnerTubeTests/Fixtures` in this checkout.
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/QTInnerTubeTests/Fixtures")

    /// Recorded browse pages by browse id.
    static let browse: [String: String] = [
        "FEmusic_explore": "explore-en",
        "FEmusic_new_releases": "new-releases-en",
        "FEmusic_charts": "charts-en",
        "FEmusic_moods_and_genres": "moods-en",
        "MPREb_ScDJHCiomAo": "album-qilixiang-zh",
        "MPREb_JR856gupBGZ": "album-hkt-en",
        "UCjF7hNeaqArVJmijVgz-bjg": "artist-hkt-en",
        "UCL2MDNdwEtV6aYUgNjFQGZA": "artist-jay-zh",
        "VLRDCLAK5uy_l12ynH8dyLsBmE11ToAHLm9P04NS2i9ME": "playlist-jay-zh",
        "VLPL0GvsLQil0MmYC96KEs_7dTNsLm1PS6JX": "playlist-classic-rock-en",
    ]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, let name = Self.fixture(for: request),
              let data = try? Data(contentsOf: Self.folder.appendingPathComponent(name + ".json")) else {
            throw URLError(.notConnectedToInternet)
        }
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }

    /// Which recording answers a request (nil = none: offline).
    static func fixture(for request: URLRequest) -> String? {
        guard let url = request.url, let body = request.httpBody,
              let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        let hl = ((json["context"] as? [String: Any])?["client"] as? [String: Any])?["hl"] as? String ?? "en"
        if json["continuation"] != nil { return nil }
        switch url.lastPathComponent {
        case "browse":
            guard let id = json["browseId"] as? String else { return nil }
            if id == "FEmusic_home" { return hl.hasPrefix("zh") ? "home-zh" : "home-en" }
            return browse[id]
        case "search":
            let query = json["query"] as? String ?? ""
            if query.contains("晴天") { return json["params"] == nil ? "search-qingtian-zh" : "search-qingtian-albums-zh" }
            return json["params"] == nil ? "search-trumua-en" : "search-trumua-songs-en"
        case "next":
            return "next-trumua-en"
        default:
            return nil
        }
    }
}
#endif
