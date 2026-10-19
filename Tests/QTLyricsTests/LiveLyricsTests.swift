import Foundation
import QTCore
import Testing
@testable import QTLyrics

/// Opt-in: hits the real endpoints (anonymous, read-only). Run with `QT_LIVE=1 swift test --filter LiveLyricsTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["QT_LIVE"] == "1"), .serialized)
struct LiveLyricsTests {
    @Test func heroResolvesThroughNetEase() async throws {
        let resolver = QTLyricsResolver.standard(
            configuration: .init(unofficialSources: .init(netease: true, kugou: true, qq: true), translationLanguage: "zh-Hans"),
            cache: try QTLyricsCache(url: nil))
        let r = await resolver.resolve(QTFixtureSong.named("doivoianh").query)
        let doc = try #require(r.document)
        print("[live] hero (all sources):", doc.source.id, doc.syncKind, doc.language ?? "?", doc.translationLanguage ?? "-",
              "lines \(doc.lines.count), translated \(doc.lines.filter { $0.translation != nil }.count), confidence \(doc.confidence)")
        #expect(doc.source == .netease)
        #expect(doc.syncKind == .word)
        #expect(doc.language == "vi")
        #expect(doc.translationLanguage == "zh-Hans")
    }

    @Test func safeChainForEverySong() async throws {
        let resolver = QTLyricsResolver.standard(configuration: .init(translationLanguage: "zh-Hans"), cache: try QTLyricsCache(url: nil))
        for song in QTFixtureSong.all {
            let r = await resolver.resolve(song.query)
            let summary = r.document.map { "\($0.source.id) \($0.syncKind) \($0.language ?? "?") lines \($0.lines.count) conf \($0.confidence)" } ?? "none"
            print("[live] safe \(song.slug): \(summary) · versions \(r.versions.count)")
        }
    }

    @Test func everySourceForEverySong() async throws {
        let resolver = QTLyricsResolver.standard(
            configuration: .init(unofficialSources: .init(netease: true, kugou: true, qq: true), translationLanguage: "zh-Hans"),
            cache: try QTLyricsCache(url: nil))
        var found = 0
        for song in QTFixtureSong.all {
            let r = await resolver.resolve(song.query)
            if r.document != nil { found += 1 }
            let summary = r.document.map { "\($0.source.id) \($0.syncKind) tr \($0.translationLanguage ?? "-") conf \($0.confidence)" } ?? "none"
            print("[live] all \(song.slug): \(summary) · versions \(r.versions.map { "\($0.id)@\(String(format: "%.2f", $0.score))" })")
        }
        #expect(found == QTFixtureSong.all.count)
    }

    @Test func qrcAndKrcDecryptLiveResponses() async throws {
        let http = QTURLSessionLyricsHTTPClient()
        let kugou = QTKugouLyricsProvider(http: http)
        let k = try #require(try await kugou.search(QTFixtureSong.named("haphom").query).first)
        #expect(try await kugou.lyrics(for: k)?.syncKind == .word)
        let qq = QTQQMusicLyricsProvider(http: http)
        let q = try #require(try await qq.search(QTFixtureSong.named("yoruni").query).first)
        #expect(try await qq.lyrics(for: q)?.syncKind == .word)
    }
}
