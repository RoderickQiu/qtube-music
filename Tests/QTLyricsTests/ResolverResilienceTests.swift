import Foundation
import QTCore
import Testing
@testable import QTLyrics

/// A provider whose answers a test controls: lyrics, "not found", or unreachable.
struct QTStubLyricsProvider: QTLyricsSourceProvider {
    enum Behaviour: Sendable { case lyrics(QTParsedLyrics), notFound, unreachable }
    let source: QTLyricsSource
    let behaviour: @Sendable () -> Behaviour
    var candidates = 1

    func search(_ query: QTLyricsQuery) async throws -> [QTLyricsCandidate] {
        switch behaviour() {
        case .unreachable: throw QTLyricsError.transport("offline")
        case .notFound: return []
        case .lyrics:
            return (0..<candidates).map {
                QTLyricsCandidate(source: source, remoteID: "\($0)", title: query.title, artists: query.artists,
                                  duration: query.duration)
            }
        }
    }

    func lyrics(for candidate: QTLyricsCandidate) async throws -> QTParsedLyrics? {
        if case .lyrics(let parsed) = behaviour() { return parsed }
        throw QTLyricsError.transport("offline")
    }
}

/// Mutable switch shared with a stub's closure.
final class QTStubSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: QTStubLyricsProvider.Behaviour
    init(_ value: QTStubLyricsProvider.Behaviour) { self.value = value }
    func get() -> QTStubLyricsProvider.Behaviour { lock.withLock { value } }
    func set(_ v: QTStubLyricsProvider.Behaviour) { lock.withLock { value = v } }
}

@Suite struct ResolverResilienceTests {
    static let query = QTLyricsQuery(videoId: "vid00000001", title: "Đối Với Anh Em Không Còn Cảm Giác",
                                     artists: ["Kim Ny Ngọc"], duration: 60)

    static let parsed = QTParsedLyrics(lines: [
        QTParsedLyricsLine(start: 1, end: 3, text: "Gió cứ rít réo rắc trong đêm"),
        QTParsedLyricsLine(start: 4, end: 6, text: "Bao đêm qua em vẫn thế"),
        QTParsedLyricsLine(start: 7, end: 9, text: "Em không còn cảm giác"),
    ])

    /// Offline is not "no lyrics": nothing is cached, and the next online lookup finds them.
    @Test func unreachableSourcesAreNotCachedAsNoLyrics() async throws {
        let toggle = QTStubSwitch(.unreachable)
        let resolver = QTLyricsResolver(providers: [QTStubLyricsProvider(source: .lrclib, behaviour: toggle.get)],
                                        cache: try QTLyricsCache(url: nil))
        let offline = await resolver.resolve(Self.query)
        #expect(offline.document == nil)
        #expect(offline.unreachableSources == [.lrclib])
        #expect(!offline.isComplete)

        toggle.set(.lyrics(Self.parsed))
        let online = await resolver.resolve(Self.query)
        #expect(!online.fromCache)
        #expect(online.document?.source == .lrclib)
        #expect(online.isComplete)

        // Back offline: the cached document is served without asking.
        toggle.set(.unreachable)
        let cached = await resolver.resolve(Self.query)
        #expect(cached.fromCache)
        #expect(cached.document?.lines.count == 3)
    }

    /// A genuine "not found" from every source is remembered (negative cache).
    @Test func notFoundIsCached() async throws {
        let toggle = QTStubSwitch(.notFound)
        let resolver = QTLyricsResolver(providers: [QTStubLyricsProvider(source: .lrclib, behaviour: toggle.get)],
                                        cache: try QTLyricsCache(url: nil))
        let first = await resolver.resolve(Self.query)
        #expect(first.document == nil)
        #expect(first.isComplete)
        toggle.set(.lyrics(Self.parsed))
        #expect(await resolver.resolve(Self.query).fromCache)
        #expect(await resolver.resolve(Self.query, forceRefresh: true).document != nil)
    }

    /// When one source is down but another answers, the pick is kept only briefly (a better version may exist).
    @Test func partialLookupsExpireSooner() async throws {
        let clock = QTStubClock()
        let resolver = QTLyricsResolver(
            providers: [QTStubLyricsProvider(source: .lrclib, behaviour: { .lyrics(Self.parsed) }),
                        QTStubLyricsProvider(source: .amll, behaviour: { .unreachable })],
            cache: try QTLyricsCache(url: nil), now: clock.now)
        let first = await resolver.resolve(Self.query)
        #expect(first.unreachableSources == [.amll])
        clock.advance(600)
        #expect(await resolver.resolve(Self.query).fromCache)
        clock.advance(3_600)
        #expect(await !resolver.resolve(Self.query).fromCache)
    }

    /// The configuration travels with the call (settings can change while another lookup is in flight).
    @Test func perCallConfiguration() async throws {
        let resolver = QTLyricsResolver(
            providers: [QTStubLyricsProvider(source: .netease, behaviour: { .lyrics(Self.parsed) })],
            cache: try QTLyricsCache(url: nil))
        #expect(await resolver.resolve(Self.query).document == nil)
        let on = QTLyricsResolverConfiguration(unofficialSources: .init(netease: true))
        #expect(await resolver.resolve(Self.query, configuration: on).document?.source == .netease)
        // The resolver's own configuration is untouched.
        #expect(await resolver.configuration.unofficialSources.netease == false)
    }

    @Test func otherVersionsAreCappedPerSource() async throws {
        var provider = QTStubLyricsProvider(source: .lrclib, behaviour: { .lyrics(Self.parsed) })
        provider.candidates = 9
        let resolver = QTLyricsResolver(providers: [provider], cache: try QTLyricsCache(url: nil))
        let r = await resolver.resolve(Self.query)
        #expect(r.versions.count == 3)
        #expect(r.versions.contains { $0.id == r.chosenID })
    }

    /// Mock-catalog tracks (no real videoId) never reach YouTube.
    @Test func youTubeMusicSkipsNonYouTubeIDs() async throws {
        #expect(QTYouTubeMusicLyricsProvider.isYouTubeVideoId("0sDXWfkljn4"))
        #expect(QTYouTubeMusicLyricsProvider.isYouTubeVideoId("-BJt4fCAtZE"))
        #expect(!QTYouTubeMusicLyricsProvider.isYouTubeVideoId("ne34516548"))
        #expect(!QTYouTubeMusicLyricsProvider.isYouTubeVideoId(""))
        #expect(!QTYouTubeMusicLyricsProvider.isYouTubeVideoId("ne46004370!"))
        let http = QTFixtureHTTPClient()
        let provider = QTYouTubeMusicLyricsProvider(requester: QTAnonymousInnerTubeLyricsRequester(http: http))
        var q = QTFixtureSong.named("perfect").query
        q.lyricsVideoId = ""
        #expect(try await provider.search(q).isEmpty)
        #expect(await http.log.urls.isEmpty)
    }

    @Test func unreachableClassification() {
        #expect(QTLyricsError.isUnreachable(QTLyricsError.transport("x")))
        #expect(QTLyricsError.isUnreachable(QTLyricsError.rateLimited(retryAfter: 3)))
        #expect(QTLyricsError.isUnreachable(QTLyricsError.http(status: 502)))
        #expect(!QTLyricsError.isUnreachable(QTLyricsError.http(status: 404)))
        #expect(!QTLyricsError.isUnreachable(QTLyricsError.decoding("x")))
        #expect(QTLyricsError.isUnreachable(URLError(.notConnectedToInternet)))
    }
}

@Suite struct TranslationPolicyTests {
    static func doc(language: String?, lane: String?) -> QTLyricsDocument {
        QTLyricsDocument(lines: [QTLyricsLine(start: 1, text: "Gió cứ rít réo rắc trong đêm", translation: lane.map { _ in "午夜的风你尽管呼啸" }),
                                 QTLyricsLine(start: 4, text: "Bao đêm qua", translation: lane.map { _ in "多少个夜晚" })],
                         syncKind: .word, source: .netease, language: language, translationLanguage: lane,
                         translationSource: lane.map { _ in .netease })
    }

    @Test func providerLaneOnlyInTheTarget() {
        let d = Self.doc(language: "vi", lane: "zh-Hans")
        #expect(QTLyricsTranslationPolicy.applyProviderLane(to: d, target: "zh-Hans").hasTranslation)
        #expect(!QTLyricsTranslationPolicy.applyProviderLane(to: d, target: "en").hasTranslation)
        #expect(!QTLyricsTranslationPolicy.applyProviderLane(to: d, target: nil).hasTranslation)
        #expect(QTLyricsTranslationPolicy.plan(for: d, target: "zh-Hans") == .provider(.netease))
        #expect(QTLyricsTranslationPolicy.plan(for: d, target: "en") == .none(.noEngine))
        #expect(QTLyricsTranslationPolicy.plan(for: d, target: nil) == .none(.off))
        #expect(QTLyricsTranslationPolicy.plan(for: nil, target: "en") == .none(.noLyrics))
    }

    /// A Simplified lane is converted for a Traditional target, so every surface shows the script picked.
    @Test func simplifiedLaneForTraditionalTarget() {
        let d = QTLyricsTranslationPolicy.applyProviderLane(to: Self.doc(language: "vi", lane: "zh-Hans"), target: "zh-Hant")
        #expect(d.translationLanguage == "zh-Hant")
        #expect(d.lines[0].translation == "午夜的風你儘管呼嘯")
        #expect(d.lines[1].translation == "多少個夜晚")
    }

    /// No pointless translation: a Chinese song with a Chinese target gets no lane.
    @Test func skipsWhenAlreadyInTargetLanguage() {
        let zh = Self.doc(language: "zh-Hans", lane: "en")
        #expect(QTLyricsTranslationPolicy.plan(for: zh, target: "zh-Hant") == .none(.alreadyInTargetLanguage))
        #expect(!QTLyricsTranslationPolicy.applyProviderLane(to: zh, target: "zh-Hans").hasTranslation)
    }
}

final class QTStubClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: @Sendable () -> Date { { [self] in lock.withLock { current } } }
    func advance(_ s: TimeInterval) { lock.withLock { current += s } }
}
