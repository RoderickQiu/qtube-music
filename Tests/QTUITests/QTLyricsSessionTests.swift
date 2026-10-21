import Foundation
import QTCore
import QTInnerTube
import QTLyrics
import Testing
@testable import QTUI

// Owner: builder "lyrics-live". `QTLyricsSession` (the app's one lyrics source of truth) and the InnerTube lyrics
// path (`QTInnerTubeLyricsClient` → `QTInnerTubeLyricsBridge` → `QTYouTubeMusicLyricsProvider`), offline.

/// A lyrics source whose answers a test controls.
struct QTSessionStubProvider: QTLyricsSourceProvider {
    enum Mode: Sendable { case found, unreachable }
    let source: QTLyricsSource
    let mode: @Sendable () -> Mode
    var ids = ["1"]

    func search(_ query: QTLyricsQuery) async throws -> [QTLyricsCandidate] {
        guard mode() == .found else { throw QTLyricsError.transport("offline") }
        return ids.map { QTLyricsCandidate(source: source, remoteID: $0, title: query.title, artists: query.artists, duration: query.duration) }
    }

    func lyrics(for candidate: QTLyricsCandidate) async throws -> QTParsedLyrics? {
        guard mode() == .found else { throw QTLyricsError.transport("offline") }
        let texts = ["Gió cứ rít réo rắc trong đêm", "Bao đêm qua em vẫn thế", "Em không còn cảm giác"]
        let lines = texts.enumerated().map { QTParsedLyricsLine(start: Double($0.offset * 3 + 1), end: Double($0.offset * 3 + 3), text: $0.element) }
        let lane = QTLyricsLane(kind: .translation, language: "zh-Hans",
                                entries: ["午夜的风你尽管呼啸", "多少个夜晚", "我已没有感觉"].map { QTLyricsLane.Entry(start: nil, text: $0) },
                                isIndexAligned: true)
        return QTParsedLyrics(lines: lines, lanes: candidate.remoteID == "1" ? [lane] : [])
    }
}

final class QTSessionStubMode: @unchecked Sendable {
    private let lock = NSLock()
    private var value: QTSessionStubProvider.Mode
    init(_ value: QTSessionStubProvider.Mode) { self.value = value }
    func get() -> QTSessionStubProvider.Mode { lock.withLock { value } }
    func set(_ v: QTSessionStubProvider.Mode) { lock.withLock { value = v } }
}

/// Serves the recorded (trimmed) YouTube Music responses from QTLyricsTests/Fixtures and records requests.
final class QTRecordedInnerTubeTransport: QTHTTPTransport, @unchecked Sendable {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../QTLyricsTests/Fixtures/songs/perfect").standardized
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { recorded } }
    let offline: Bool

    init(offline: Bool = false) { self.offline = offline }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        if offline { throw URLError(.notConnectedToInternet) }
        let file = request.url!.path.hasSuffix("/next") ? "ytm_next.json" : "ytm_browse.json"
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(file))
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite struct QTInnerTubeLyricsTests {
    @Test func androidMusicRequestsParseIntoTimedLyrics() async throws {
        let transport = QTRecordedInnerTubeTransport()
        let provider = QTYouTubeMusicLyricsProvider(
            requester: QTInnerTubeLyricsBridge(client: QTInnerTubeLyricsClient(transport: transport, hl: "zh-CN", gl: "US")))
        let query = QTLyricsQuery(videoId: "ORrFJ63nlcA", title: "Perfect", artists: ["Ed Sheeran"], duration: 263)
        let candidate = try #require(try await provider.search(query).first)
        let parsed = try #require(try await provider.lyrics(for: candidate))
        #expect(parsed.syncKind == .line)
        #expect(parsed.metadata.attribution == "Source: LyricFind")

        let requests = transport.requests
        #expect(requests.map { $0.url!.lastPathComponent } == ["next", "browse"])
        for r in requests {
            #expect(r.value(forHTTPHeaderField: "X-YouTube-Client-Name") == "21")
            // Anonymous: no cookies, no SAPISIDHASH.
            #expect(r.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(r.value(forHTTPHeaderField: "Authorization") == nil)
            let body = try #require(try JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any])
            let client = try #require((body["context"] as? [String: Any])?["client"] as? [String: Any])
            #expect(client["clientName"] as? String == "ANDROID_MUSIC")
            #expect(client["hl"] as? String == "zh-CN")
        }
        let next = try JSONSerialization.jsonObject(with: requests[0].httpBody!) as? [String: Any]
        #expect(next?["videoId"] as? String == "ORrFJ63nlcA")
        let browse = try JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: Any]
        #expect((browse?["browseId"] as? String)?.hasPrefix("MPLY") == true)
    }

    /// Offline InnerTube errors reach the resolver as "unreachable", so they are retried instead of cached.
    @Test func offlineIsUnreachable() async throws {
        let provider = QTYouTubeMusicLyricsProvider(
            requester: QTInnerTubeLyricsBridge(client: QTInnerTubeLyricsClient(transport: QTRecordedInnerTubeTransport(offline: true))))
        let resolver = QTLyricsResolver(providers: [provider], cache: try QTLyricsCache(url: nil))
        let r = await resolver.resolve(QTLyricsQuery(videoId: "ORrFJ63nlcA", title: "Perfect", artists: ["Ed Sheeran"], duration: 263))
        #expect(r.document == nil)
        #expect(r.unreachableSources == [.youtubeMusic])
        #expect(QTInnerTubeLyricsBridge.lyricsError(.rateLimited(retryAfter: nil)) == .rateLimited(retryAfter: 30))
    }
}

@MainActor
@Suite struct QTLyricsSessionTests {
    static let hero = QTTrack(videoId: "ne34516548", title: "Đối Với Anh Em Không Còn Cảm Giác",
                              artists: [QTArtistRef(name: "Kim Ny Ngọc")], duration: 60)

    func makeSettings(unofficial: QTUnofficialLyricsSources = .init(), target: QTLyricsTranslationTarget = .zhHans) -> QTSettingsStore {
        let store = QTSettingsStore(defaults: UserDefaults(suiteName: "qt.lyrics-live.tests.\(UUID().uuidString)")!)
        store.override {
            $0.unofficialLyricsSources = unofficial
            $0.lyricsTranslation = target
        }
        return store
    }

    func makeSession(_ settings: QTSettingsStore, mode: QTSessionStubMode = .init(.found), ids: [String] = ["1"],
                     cache: QTLyricsCache? = nil, bundled: [String: QTLyricsDocument] = [:]) throws -> QTLyricsSession {
        var netease = QTSessionStubProvider(source: .netease, mode: mode.get)
        netease.ids = ids
        let resolver = QTLyricsResolver(providers: [netease], cache: try cache ?? QTLyricsCache(url: nil))
        return QTLyricsSession(settings: settings, resolver: resolver, bundled: bundled, isMockTrack: { $0.videoId.hasPrefix("ne") })
    }

    func settle(_ session: QTLyricsSession) async {
        let start = ContinuousClock.now
        while session.phase == .loading, ContinuousClock.now - start < .seconds(5) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func heroWithUnofficialSourcesShowsTheProviderTranslation() async throws {
        let session = try makeSession(makeSettings(unofficial: .init(netease: true)))
        session.load(Self.hero)
        #expect(session.phase == .loading)
        await settle(session)
        #expect(session.phase == .loaded)
        let doc = try #require(session.document)
        #expect(doc.source == .netease)
        #expect(doc.language == "vi")
        #expect(doc.translationLanguage == "zh-Hans")
        #expect(doc.lines.first?.translation == "午夜的风你尽管呼啸")
        #expect(session.translationPlan == .provider(.netease))
        #expect(session.translationEngineName == "NetEase")
        #expect(session.sourceName == "NetEase")
        #expect(!session.isPossibleMismatch)
        // Vietnamese is Latin script: no romanization lane.
        #expect(!session.hasRomanization)
        // Mock tracks are matched by metadata; YouTube Music is never asked.
        #expect(session.query(for: Self.hero).lyricsVideoId.isEmpty)
    }

    @Test func targetChangeRepresentsInstantly() async throws {
        let settings = makeSettings(unofficial: .init(netease: true))
        let session = try makeSession(settings)
        session.load(Self.hero)
        await settle(session)
        #expect(session.document?.hasTranslation == true)

        settings.override { $0.lyricsTranslation = .en }
        session.settingsDidChange()
        // No lookup needed to drop the Chinese lane for an English target (machine translation is M6).
        #expect(session.document?.hasTranslation == false)
        #expect(session.translationTarget == "en")
        #expect(session.translationEngineName == nil)
        #expect(session.translationPlan == .none(.noEngine))

        settings.override { $0.lyricsTranslation = .zhHant }
        session.settingsDidChange()
        #expect(session.document?.lines.first?.translation == "午夜的風你儘管呼嘯")
        settings.override { $0.lyricsTranslation = .off }
        session.settingsDidChange()
        #expect(session.translationPlan == .none(.off))
        #expect(session.document?.hasTranslation == false)
    }

    @Test func unofficialSourcesOffMeansTheSafeChainOnly() async throws {
        let settings = makeSettings()
        let session = try makeSession(settings)
        session.load(Self.hero)
        await settle(session)
        #expect(session.phase == .notFound)
        #expect(session.document == nil)

        // Turning NetEase on looks up again.
        settings.override { $0.unofficialLyricsSources.netease = true }
        session.settingsDidChange()
        await settle(session)
        let start = ContinuousClock.now
        while session.document == nil, ContinuousClock.now - start < .seconds(5) { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(session.document?.source == .netease)
    }

    @Test func offlineFallsBackToBundledLyricsWhenTheirSourceIsOn() async throws {
        let bundled = QTLyricsDocument(lines: [QTLyricsLine(start: 1, text: "Gió cứ rít réo rắc trong đêm", translation: "午夜的风你尽管呼啸")],
                                       syncKind: .line, source: .netease, language: "vi", translationLanguage: "zh-Hans",
                                       translationSource: .netease)
        let on = try makeSession(makeSettings(unofficial: .init(netease: true)), mode: .init(.unreachable),
                                 bundled: [Self.hero.videoId: bundled])
        on.load(Self.hero)
        await settle(on)
        #expect(on.isShowingFallback)
        #expect(on.document?.lines.first?.translation == "午夜的风你尽管呼啸")
        #expect(on.unreachableSources == [.netease])

        let off = try makeSession(makeSettings(), mode: .init(.unreachable), bundled: [Self.hero.videoId: bundled])
        off.load(Self.hero)
        await settle(off)
        #expect(off.document == nil)
        #expect(!off.isShowingFallback)
    }

    @Test func offsetNudgesApplyLiveAndPersistPerTrack() async throws {
        let settings = makeSettings(unofficial: .init(netease: true))
        let cache = try QTLyricsCache(url: nil)
        let session = try makeSession(settings, cache: cache)
        session.load(Self.hero)
        await settle(session)
        session.nudgeOffset(by: 0.1)
        session.nudgeOffset(by: 0.1)
        #expect(session.offset == 0.2)
        #expect(session.document?.offset == 0.2)
        try await Task.sleep(for: .milliseconds(600))
        #expect(await cache.offset(for: Self.hero.videoId, version: "netease:1") == 0.2)

        let again = try makeSession(settings, cache: cache)
        again.load(Self.hero)
        await settle(again)
        #expect(again.offset == 0.2)
        session.nudgeOffset(by: -0.3)
        #expect(session.offset == -0.1)
    }

    @Test func pinningAnotherVersion() async throws {
        let session = try makeSession(makeSettings(unofficial: .init(netease: true)), ids: ["1", "2"])
        session.load(Self.hero)
        await settle(session)
        #expect(session.chosenVersionID == "netease:1")
        #expect(session.otherVersions.map(\.id) == ["netease:2"])
        session.pin(versionID: "netease:2")
        let start = ContinuousClock.now
        while session.chosenVersionID != "netease:2", ContinuousClock.now - start < .seconds(5) { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(session.isPinned)
        #expect(session.document?.hasTranslation == false)
        session.unpin()
        while session.isPinned, ContinuousClock.now - start < .seconds(5) { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(session.chosenVersionID == "netease:1")
    }

    /// Offline is not "No lyrics": the lookup runs again by itself when the network comes back.
    @Test func offlineLookupRetriesWhenTheNetworkReturns() async throws {
        let mode = QTSessionStubMode(.unreachable)
        let session = try makeSession(makeSettings(unofficial: .init(netease: true)), mode: mode)
        session.networkDidChange(available: false)
        session.load(Self.hero)
        await settle(session)
        #expect(session.phase == .unreachable)
        #expect(!session.isNetworkAvailable)
        // A re-open right after the failed lookup doesn't hammer the sources.
        session.retryIfUnreachable()
        #expect(session.phase == .unreachable)

        mode.set(.found)
        session.networkDidChange(available: true)
        #expect(session.phase == .loading)
        await settle(session)
        #expect(session.phase == .loaded)
        #expect(session.document?.lines.count == 3)
        // Nothing to retry once loaded.
        session.retryIfUnreachable(force: true)
        #expect(session.phase == .loaded)
    }

    @Test func reopeningRetriesAnUnreachableLookup() async throws {
        let mode = QTSessionStubMode(.unreachable)
        let session = try makeSession(makeSettings(unofficial: .init(netease: true)), mode: mode)
        session.load(Self.hero)
        await settle(session)
        #expect(session.phase == .unreachable)
        mode.set(.found)
        session.retryIfUnreachable(force: true)
        await settle(session)
        #expect(session.phase == .loaded)
    }

    func waitUntil(_ condition: @MainActor () -> Bool) async {
        let start = ContinuousClock.now
        while !condition(), ContinuousClock.now - start < .seconds(5) { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// "Report Wrong Lyrics" is one call: the next version shows at once, and a relaunch keeps it away.
    @Test func reportWrongShowsTheNextVersionAndSticks() async throws {
        let settings = makeSettings(unofficial: .init(netease: true))
        let cache = try QTLyricsCache(url: nil)
        let store = QTLyricsVersionStore()
        var netease = QTSessionStubProvider(source: .netease, mode: QTSessionStubMode(.found).get)
        netease.ids = ["1", "2"]
        let session = QTLyricsSession(settings: settings, resolver: QTLyricsResolver(providers: [netease], cache: cache),
                                      isMockTrack: { $0.videoId.hasPrefix("ne") }, versionStore: store)
        session.load(Self.hero)
        await settle(session)
        #expect(session.chosenVersionID == "netease:1")
        #expect(store.versions[Self.hero.videoId]?.count == 2)

        store.reportWrong(Self.hero.videoId)
        await waitUntil { session.chosenVersionID == "netease:2" }
        #expect(session.chosenVersionID == "netease:2")
        #expect(!session.versions.contains { $0.id == "netease:1" })
        #expect(store.versions[Self.hero.videoId]?.map(\.id) == ["netease:2"])
        #expect(await cache.rejectedVersionIDs(for: Self.hero.videoId) == ["netease:1"])

        let again = try makeSession(settings, ids: ["1", "2"], cache: cache)
        again.reload()
        again.load(Self.hero)
        await settle(again)
        #expect(again.chosenVersionID == "netease:2")
    }

    @Test func noLyricsForThisSong() async throws {
        let settings = makeSettings(unofficial: .init(netease: true))
        let cache = try QTLyricsCache(url: nil)
        let session = try makeSession(settings, ids: ["1", "2"], cache: cache)
        session.load(Self.hero)
        await settle(session)
        #expect(session.document != nil)
        session.turnOffLyrics()
        await waitUntil { session.isLyricsOff }
        #expect(session.document == nil)
        #expect(session.phase == .notFound)
        #expect(session.versions.count == 2)

        let again = try makeSession(settings, ids: ["1", "2"], cache: cache)
        again.load(Self.hero)
        await settle(again)
        #expect(again.isLyricsOff)
        #expect(again.document == nil)
        again.unpin()
        await waitUntil { again.document != nil }
        #expect(!again.isLyricsOff)
        #expect(again.chosenVersionID == "netease:1")
    }

    /// Each version keeps its own timing: pinning another one doesn't carry the nudge over.
    @Test func offsetFollowsTheVersion() async throws {
        let cache = try QTLyricsCache(url: nil)
        let session = try makeSession(makeSettings(unofficial: .init(netease: true)), ids: ["1", "2"], cache: cache)
        session.load(Self.hero)
        await settle(session)
        session.nudgeOffset(by: 0.3)
        try await Task.sleep(for: .milliseconds(500))
        session.pin(versionID: "netease:2")
        await waitUntil { session.chosenVersionID == "netease:2" }
        #expect(session.offset == 0)
        session.unpin()
        await waitUntil { session.chosenVersionID == "netease:1" }
        #expect(session.offset == 0.3)
    }

    @Test func launchArgumentForUnofficialSources() {
        #expect(QTLyricsSession.unofficialSources(argument: "all") == .init(netease: true, kugou: true, qq: true))
        #expect(QTLyricsSession.unofficialSources(argument: "none") == .init())
        #expect(QTLyricsSession.unofficialSources(argument: "netease,qq") == .init(netease: true, qq: true))
        #expect(QTLyricsSession.unofficialSources(argument: nil) == nil)
    }
}
