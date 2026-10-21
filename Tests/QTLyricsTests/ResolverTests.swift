import Foundation
import QTCore
import Testing
@testable import QTLyrics

@Suite struct ResolverTests {
    static let allUnofficial = QTUnofficialLyricsSources(netease: true, kugou: true, qq: true)

    func makeResolver(unofficial: QTUnofficialLyricsSources = .init(), target: String? = "zh-Hans",
                      http: QTFixtureHTTPClient = QTFixtureHTTPClient(),
                      cache: QTLyricsCache? = nil) throws -> QTLyricsResolver {
        let cache = try cache ?? QTLyricsCache(url: nil)
        return QTLyricsResolver.standard(configuration: .init(unofficialSources: unofficial, translationLanguage: target),
                                         cache: cache, http: http)
    }

    /// M2 acceptance: the hero track resolves to word-synced Vietnamese + Chinese translation through NetEase.
    @Test func heroTrackWithUnofficialSources() async throws {
        let resolver = try makeResolver(unofficial: Self.allUnofficial)
        let r = await resolver.resolve(QTFixtureSong.named("doivoianh").query)
        let doc = try #require(r.document)
        #expect(doc.source == .netease)
        #expect(doc.syncKind == .word)
        #expect(doc.language == "vi")
        #expect(doc.translationLanguage == "zh-Hans")
        #expect(doc.translationSource == .netease)
        #expect(doc.confidence >= 0.8)
        let first = doc.lines[0]
        #expect(first.text == "Gió cứ rít réo rắc trong đêm")
        #expect(first.words?.count == 7)
        #expect(first.translation == "午夜的风你尽管呼啸")
        #expect(doc.lines.filter { $0.translation != nil }.count == doc.lines.count)
        // Vietnamese is Latin script: no romanization lane.
        #expect(doc.romanizationSource == nil)
        // Never mixes lines: every line is NetEase's.
        #expect(r.chosenID == "netease:34516548")
    }

    /// What the safe chain (default settings) returns for the hero: nothing (YouTube Music has no lyrics for it,
    /// LRCLIB and AMLL don't know it).
    @Test func heroTrackWithSafeChainOnly() async throws {
        let http = QTFixtureHTTPClient()
        let resolver = try makeResolver(http: http)
        let r = await resolver.resolve(QTFixtureSong.named("doivoianh").query)
        #expect(r.document == nil)
        let hosts = await http.log.hosts()
        #expect(!hosts.contains("music.163.com"))
        #expect(!hosts.contains("krcs.kugou.com"))
        #expect(!hosts.contains("c.y.qq.com"))
        #expect(hosts.contains("music.youtube.com"))
        #expect(hosts.contains("lrclib.net"))
    }

    @Test func heroTranslationFollowsTarget() async throws {
        // English target: the Chinese provider lane is not shown (machine translation would fill it in M6).
        let en = try makeResolver(unofficial: Self.allUnofficial, target: "en")
        let doc = try #require(await en.resolve(QTFixtureSong.named("doivoianh").query).document)
        #expect(doc.syncKind == .word)
        #expect(!doc.hasTranslation)
        // Off.
        let off = try makeResolver(unofficial: Self.allUnofficial, target: nil)
        #expect(await off.resolve(QTFixtureSong.named("doivoianh").query).document?.hasTranslation == false)
    }

    @Test func safeChainPrefersYouTubeMusicOverLRCLIB() async throws {
        let resolver = try makeResolver()
        let r = await resolver.resolve(QTFixtureSong.named("perfect").query)
        let doc = try #require(r.document)
        #expect(doc.source == .youtubeMusic)
        #expect(doc.syncKind == .line)
        #expect(r.attribution == "Source: LyricFind")
        #expect(r.versions.contains { $0.source == .lrclib })
        #expect(doc.language == "en")
    }

    @Test func wordSyncedAMLLBeatsLineSyncedForQingtian() async throws {
        let resolver = try makeResolver()
        let doc = try #require(await resolver.resolve(QTFixtureSong.named("qingtian").query).document)
        #expect(doc.source == .amll)
        #expect(doc.syncKind == .word)
        #expect(doc.language == "zh-Hans")
        // Chinese gets on-device pinyin; zh song + zh target → no translation line.
        #expect(doc.romanizationSource == .onDeviceRomanization)
        #expect(doc.lines.first?.romanization?.isEmpty == false)
        #expect(!doc.hasTranslation)
    }

    @Test func yoasobiUsesAMLLWithInlineTranslationAndRomaji() async throws {
        let resolver = try makeResolver(target: "zh-Hans")
        let doc = try #require(await resolver.resolve(QTFixtureSong.named("yoruni").query).document)
        #expect(doc.source == .amll)
        #expect(doc.language == "ja")
        #expect(doc.translationLanguage == "zh-Hans")
        #expect(doc.lines.first?.translation == "像是沉溺溶化一般")
        #expect(doc.romanizationSource == .amll)
    }

    @Test(arguments: QTFixtureSong.all.map(\.slug))
    func everySongResolvesWithAllSources(slug: String) async throws {
        let resolver = try makeResolver(unofficial: Self.allUnofficial)
        let r = await resolver.resolve(QTFixtureSong.named(slug).query)
        let doc = try #require(r.document, "no lyrics for \(slug)")
        #expect(doc.confidence >= 0.6)
        #expect(!doc.lines.isEmpty)
        // Credits never reach the UI.
        #expect(!doc.lines.contains { QTLyricsCleanup.isCredit($0.text) })
        if ["perfect", "qingtian", "haphom", "doivoianh", "yoruni"].contains(slug) { #expect(doc.syncKind == .word) }
    }

    @Test func cacheOffsetAndPin() async throws {
        let cache = try QTLyricsCache(url: nil)
        let http = QTFixtureHTTPClient()
        let resolver = try makeResolver(unofficial: Self.allUnofficial, http: http, cache: cache)
        let query = QTFixtureSong.named("perfect").query
        let first = await resolver.resolve(query)
        #expect(!first.fromCache)
        #expect(first.document?.syncKind == .word)
        let requests = await http.log.urls.count

        // Served from SQLite, no network.
        let second = await resolver.resolve(query)
        #expect(second.fromCache)
        #expect(second.document == first.document)
        #expect(await http.log.urls.count == requests)

        // Offset per track and version (positive = lyrics earlier), rounded to 0.1 s, applied to the document.
        let chosen = try #require(first.chosenID)
        await resolver.setOffset(0.3000001, for: query.videoId, version: chosen)
        #expect(await resolver.resolve(query).document?.offset == 0.3)

        // "Lyrics Source": pin the LRCLIB version. It is timed on its own, so it doesn't inherit the offset.
        let other = try #require(first.versions.first { $0.source == .lrclib && $0.syncKind == .line })
        let pinned = await resolver.pin(versionID: other.id, for: query)
        #expect(pinned.isPinned)
        #expect(pinned.chosenID == other.id)
        #expect(pinned.document?.source == .lrclib)
        #expect(pinned.document?.offset == 0)
        #expect(await resolver.resolve(query).fromCache)
        let unpinned = await resolver.unpin(for: query)
        #expect(unpinned.chosenID == first.chosenID)
        #expect(!unpinned.isPinned)
        #expect(unpinned.document?.offset == 0.3)
    }

    @Test func heroOffersNoBrokenAlternatives() async throws {
        let resolver = try makeResolver(unofficial: Self.allUnofficial)
        let r = await resolver.resolve(QTFixtureSong.named("doivoianh").query)
        // NetEase's duplicate entry has no lyrics: fetched, failed, not offered. Unfetched candidates stay listed
        // with their pre-fetch score (they are fetched when picked).
        #expect(!r.versions.contains { $0.id == "netease:570056840" })
        #expect(r.versions.allSatisfy { $0.score >= QTLyricsMatchThreshold.possible })
    }

    @Test func changingSourcesInvalidatesTheCache() async throws {
        let cache = try QTLyricsCache(url: nil)
        let safe = try makeResolver(cache: cache)
        #expect(await safe.resolve(QTFixtureSong.named("doivoianh").query).document == nil)
        await safe.update(configuration: .init(unofficialSources: Self.allUnofficial, translationLanguage: "zh-Hans"))
        let r = await safe.resolve(QTFixtureSong.named("doivoianh").query)
        #expect(!r.fromCache)
        #expect(r.document?.source == .netease)
    }

    @Test func aliasesAreLearnedAndPersisted() async throws {
        let cache = try QTLyricsCache(url: nil)
        let resolver = try makeResolver(unofficial: .init(netease: true), cache: cache)
        _ = await resolver.resolve(QTFixtureSong.named("haphom").query)
        let pairs = await cache.aliasPairs()
        #expect(pairs.contains { $0 == ("Hạ Phỏm", "出牌") })
        #expect(pairs.contains { $0 == ("Hoàng Thùy Linh", "黄垂玲") })
    }

    @Test func secondSourceTranslationNeedsAlignedTimestamps() {
        let lines = (0..<10).map { QTLyricsLine(start: Double($0) * 4 + 10, text: "line \($0)") }
        // Same song from another source, 0.8 s later throughout: aligned after offset estimation.
        let shifted = QTLyricsLane(kind: .translation, language: "zh-Hans",
                                   entries: (0..<10).map { .init(start: Double($0) * 4 + 10.8, text: "行 \($0)") })
        let aligned = QTLyricsAssembler.alignForeign(shifted, to: lines)
        #expect(aligned?.compactMap { $0 }.count == 10)
        #expect(aligned?[3] == "行 3")
        // A different arrangement (irregular gaps): rejected rather than mixed in.
        let unrelated = QTLyricsLane(kind: .translation, language: "zh-Hans",
                                     entries: (0..<10).map { .init(start: Double($0 * $0) * 1.7 + 3, text: "x\($0)") })
        #expect(QTLyricsAssembler.alignForeign(unrelated, to: lines) == nil)
    }

    @Test func sameSourceLaneToleratesNetEaseDrift() {
        let parsed = QTParsedLyrics(lines: [QTParsedLyricsLine(start: 10, text: "a"), QTParsedLyricsLine(start: 14, text: "b"),
                                            QTParsedLyricsLine(start: 18, text: "c")],
                                    lanes: [QTLyricsLane(kind: .translation, language: "zh-Hans",
                                                         entries: [.init(start: 10.9, text: "甲"), .init(start: 17.2, text: "丙")])])
        let doc = QTLyricsAssembler.document(from: parsed, source: .netease, confidence: 1, preferredTranslationLanguage: "zh-Hans",
                                             romanize: false)
        #expect(doc.lines.map(\.translation) == ["甲", nil, "丙"])
    }

    @Test func providerFailuresDoNotFailTheLookup() async throws {
        struct Broken: QTLyricsSourceProvider {
            let source = QTLyricsSource.lrclib
            func search(_ query: QTLyricsQuery) async throws -> [QTLyricsCandidate] { throw QTLyricsError.http(status: 500) }
            func lyrics(for candidate: QTLyricsCandidate) async throws -> QTParsedLyrics? { nil }
        }
        let resolver = QTLyricsResolver(providers: [Broken(), QTYouTubeMusicLyricsProvider(
            requester: QTAnonymousInnerTubeLyricsRequester(http: QTFixtureHTTPClient()))], cache: nil)
        #expect(await resolver.resolve(QTFixtureSong.named("perfect").query).document?.source == .youtubeMusic)
    }

    @Test func conformsToTheUIProtocol() async throws {
        let provider: any QTLyricsProviding = try makeResolver(unofficial: Self.allUnofficial)
        let track = QTTrack(videoId: "0sDXWfkljn4", title: "Đối Với Anh Em Không Còn Cảm Giác",
                            artists: [.init(name: "Kim Ny Ngọc")], duration: 257)
        #expect(try await provider.lyrics(for: track)?.syncKind == .word)
    }
}
