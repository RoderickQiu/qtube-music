import Foundation
import QTCore
import Testing
@testable import QTLyrics

/// Every provider against the recorded (trimmed) responses of the 7-song set. Offline.
@Suite struct ProviderFixtureTests {
    let http = QTFixtureHTTPClient()

    @Test(arguments: QTFixtureSong.all.map(\.slug))
    func youTubeMusic(slug: String) async throws {
        let song = QTFixtureSong.named(slug)
        let provider = QTYouTubeMusicLyricsProvider(requester: QTAnonymousInnerTubeLyricsRequester(http: http))
        let candidates = try await provider.search(song.query)
        #expect(candidates.count == 1 && candidates[0].isExactMatch)
        let parsed = try await provider.lyrics(for: candidates[0])
        switch slug {
        case "haphom", "doivoianh":
            // "Lyrics not available at this time."
            #expect(parsed == nil)
        default:
            let p = try #require(parsed)
            #expect(p.syncKind == .line)
            #expect((1...8).contains(p.lines.count))
            #expect(p.metadata.attribution?.hasPrefix("Source:") == true)
        }
    }

    @Test func youTubeMusicMapsVideosToTheirAudioCounterpart() {
        let track = QTTrack(videoId: "wYBeTZb2a0A", title: "Đối Với Anh Em Không Còn Cảm Giác", artists: [.init(name: "Kim Ny Ngọc")],
                            duration: 257, musicVideoType: .omv,
                            counterpart: QTCounterpart(videoId: "0sDXWfkljn4", musicVideoType: .atv))
        let q = QTLyricsQuery(track: track)
        #expect(q.videoId == "wYBeTZb2a0A")
        #expect(q.lyricsVideoId == "0sDXWfkljn4")
    }

    @Test(arguments: QTFixtureSong.all.map(\.slug))
    func lrclib(slug: String) async throws {
        let provider = QTLRCLIBProvider(http: http)
        let candidates = try await provider.search(QTFixtureSong.named(slug).query)
        if slug == "doivoianh" {
            #expect(candidates.isEmpty)   // LRCLIB has nothing for the hero track
            return
        }
        let first = try #require(candidates.first)
        let p = try #require(try await provider.lyrics(for: first))
        #expect(p.lines.count <= 8)
        #expect(!p.isEmpty)
    }

    @Test func lrclibSendsDescriptiveUserAgent() async throws {
        let recorder = QTHeaderRecorder()
        _ = try? await QTLRCLIBProvider(http: recorder).search(QTFixtureSong.named("perfect").query)
        let ua = await recorder.lastUserAgent
        #expect(ua?.hasPrefix("QTube Music/") == true)
    }

    @Test func lrclibHonoursRetryAfter() async throws {
        var limited = QTFixtureHTTPClient()
        limited.rateLimited = ["lrclib.net": "120"]
        let provider = QTLRCLIBProvider(http: limited)
        await #expect(throws: QTLyricsError.rateLimited(retryAfter: 120)) {
            try await provider.search(QTFixtureSong.named("perfect").query)
        }
        // The gate stays closed: the next call doesn't hit the network.
        let before = await limited.log.urls.count
        await #expect(throws: QTLyricsError.self) { try await provider.search(QTFixtureSong.named("perfect").query) }
        #expect(await limited.log.urls.count == before)
        #expect(QTLyricsRequest.retryAfterSeconds("Wed, 21 Oct 2015 07:28:00 GMT",
                                                  now: Date(timeIntervalSince1970: 1_445_412_420)) == 60)
    }

    @Test(arguments: QTFixtureSong.all.map(\.slug))
    func netEase(slug: String) async throws {
        let song = QTFixtureSong.named(slug)
        let provider = QTNetEaseLyricsProvider(http: http)
        let candidates = try await provider.search(song.query)
        #expect(!candidates.isEmpty)
        let p = try #require(try await provider.lyrics(for: QTLyricsCandidate(source: .netease, remoteID: song.neteaseId,
                                                                               title: song.title, artists: [song.artist])))
        #expect(!p.isEmpty)
        // 晴天's tlyric is all empty timestamps: no lane.
        if slug == "qingtian" { #expect(p.lanes.isEmpty) }
        if ["perfect", "doivoianh"].contains(slug) { #expect(p.syncKind == .word) }
        if ["perfect", "haphom", "doivoianh", "chungta", "yoruni"].contains(slug) {
            #expect(p.lanes.contains { $0.kind == .translation && $0.language == "zh-Hans" })
        }
    }

    @Test(arguments: ["perfect", "qingtian", "haphom", "doivoianh", "chungta", "yoruni"])
    func kugou(slug: String) async throws {
        let provider = QTKugouLyricsProvider(http: http)
        let candidates = try await provider.search(QTFixtureSong.named(slug).query)
        let first = try #require(candidates.first)
        let p = try #require(try await provider.lyrics(for: first))
        #expect(p.syncKind == .word)
        #expect(p.lines.count <= 8)
    }

    @Test(arguments: ["perfect", "qingtian", "yoruni"])
    func qqMusic(slug: String) async throws {
        let provider = QTQQMusicLyricsProvider(http: http)
        let candidates = try await provider.search(QTFixtureSong.named(slug).query)
        let first = try #require(candidates.first)
        #expect(first.extra["mid"] != nil)
        let p = try #require(try await provider.lyrics(for: first))
        #expect(p.syncKind == .word)
        if slug != "qingtian" { #expect(p.lanes.contains { $0.kind == .translation }) }
        if slug == "yoruni" { #expect(p.lanes.contains { $0.kind == .romanization }) }
    }

    @Test func qqSearchIsEmptyForVietnamese() async throws {
        let provider = QTQQMusicLyricsProvider(http: http)
        #expect(try await provider.search(QTFixtureSong.named("haphom").query).isEmpty)
    }

    @Test func amllFindsCJKSongsThroughTheIndex() async throws {
        let provider = QTAMLLLyricsProvider(http: http)
        let qingtian = try await provider.search(QTFixtureSong.named("qingtian").query)
        let c = try #require(qingtian.first)
        #expect(c.remoteID == "186016")
        #expect(c.extra["folder"] == "ncm-lyrics")
        let p = try #require(try await provider.lyrics(for: c))
        #expect(p.syncKind == .word)
        #expect(try await provider.search(QTFixtureSong.named("doivoianh").query).isEmpty)
        // The index is fetched once per process.
        _ = try await provider.search(QTFixtureSong.named("yoruni").query)
        #expect(await http.log.urls.filter { $0.path.hasSuffix("raw-lyrics-index.jsonl") }.count == 1)
    }
}

/// Records the User-Agent of the last request and answers 200 [].
struct QTHeaderRecorder: QTLyricsHTTPClient {
    private let box = Box()
    actor Box {
        var ua: String?
        func set(_ v: String?) { ua = v }
    }

    var lastUserAgent: String? { get async { await box.ua } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await box.set(request.value(forHTTPHeaderField: "User-Agent"))
        return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
