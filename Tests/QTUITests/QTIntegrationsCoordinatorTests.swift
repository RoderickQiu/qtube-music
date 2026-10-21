import Foundation
import QTCore
import QTIntegrations
import QTLyrics
import QTPlayback
import Testing
@testable import QTUI

/// Records Last.fm calls (method + track) without the network.
final class QTUIRecordingLastFM: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(method: String, track: String)] = []
    var methods: [String] { lock.withLock { calls.map(\.method) } }
    var scrobbledTracks: [String] { lock.withLock { calls.filter { $0.method == "track.scrobble" }.map(\.track) } }

    var transport: QTLastFMClient.Transport {
        { [self] request in
            let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self).split(separator: "&").reduce(into: [String: String]()) {
                let kv = $1.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                if kv.count == 2 { $0[kv[0]] = kv[1].replacingOccurrences(of: "+", with: " ") }
            }
            lock.withLock { calls.append((form["method"] ?? "?", form["track[0]"] ?? form["track"] ?? "")) }
            return (Data(#"{"scrobbles":{"@attr":{"accepted":1,"ignored":0}}}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
}

/// Records ListenBrainz submissions (listen type + first track) without the network.
final class QTUIRecordingListenBrainz: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(type: String, track: String)] = []
    var types: [String] { lock.withLock { calls.map(\.type) } }
    var listenedTracks: [String] { lock.withLock { calls.filter { $0.type != "playing_now" }.map(\.track) } }

    var transport: QTListenBrainzClient.Transport {
        { [self] request in
            let json = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let first = (json?["payload"] as? [[String: Any]])?.first?["track_metadata"] as? [String: Any]
            lock.withLock { calls.append((json?["listen_type"] as? String ?? "?", first?["track_name"] as? String ?? "")) }
            return (Data(#"{"status":"ok"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
}

final class QTUITestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_760_000_000)
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
}

/// An engine that is neither simulated nor the web engine (for `reportsPlays`).
@MainActor
final class QTUIStubEngine: QTPlaybackEngine {
    var capabilities: QTPlaybackCapabilities { .free }
    var state = QTPlaybackState()
    func stateUpdates() -> AsyncStream<QTPlaybackState> { AsyncStream { $0.yield(state) } }
    func load(_ item: QTPlaybackItem, autoplay: Bool) async throws {}
    func play() {}
    func pause() {}
    func seek(to time: TimeInterval) {}
    func setVolume(_ volume: Double) {}
    func setMuted(_ muted: Bool) {}
    var rate: Double = 1
    func setRate(_ rate: Double) { self.rate = rate }
    func skipAd() {}
    func stop() {}
}

@MainActor
@Suite struct QTIntegrationsCoordinatorTests {
    let lastfm = QTUIRecordingLastFM()
    let listenBrainz = QTUIRecordingListenBrainz()
    let clock = QTUITestClock()
    var notified: [String] { notifications.values }
    let notifications = QTUINotificationLog()

    static func song(_ id: String, duration: TimeInterval = 200) -> QTTrack {
        QTTrack(videoId: id, title: "Song \(id)", artists: [QTArtistRef(name: "Artist")], duration: duration)
    }

    func makeCoordinator(lastFM: Bool = true, listenBrainz: Bool = false, notify: Bool = true,
                         launchTrack: QTTrack? = nil) -> QTIntegrationsCoordinator {
        let defaults = UserDefaults(suiteName: "qt.tests.integrations.\(UUID().uuidString)")!
        let store = QTIntegrationsStore(defaults: defaults, secrets: QTMemorySecretStore([.lastFMSecret: "secret",
                                                                                          .lastFMSessionKey: "SK",
                                                                                          .listenBrainzToken: "TOKEN"]))
        store.update {
            $0.lastFM.apiKey = "key"
            $0.lastFM.hasSecret = true
            $0.lastFM.username = "listener"
            $0.lastFM.isEnabled = lastFM
            $0.listenBrainz.username = "listener"
            $0.listenBrainz.isEnabled = listenBrainz
            $0.notifiesTrackChanges = notify
        }
        let clock = clock
        let c = QTIntegrationsCoordinator(store: store, scrobbler: QTScrobbler(queueFolder: nil, now: { clock.now }),
                                          discord: QTDiscordPresence(paths: []))
        let transport = lastfm.transport
        c.makeLastFMClient = { QTLastFMClient(credentials: $0, transport: transport) }
        let lbTransport = self.listenBrainz.transport
        c.makeListenBrainzClient = { QTListenBrainzClient(token: $0, server: $1, pacer: QTRequestPacer(interval: 0), transport: lbTransport) }
        let log = notifications
        c.postNotification = { log.append($0.videoId) }
        c.startForTesting(launchTrack: launchTrack)
        return c
    }

    func apply(_ c: QTIntegrationsCoordinator, _ s: QTIntegrationsSnapshot) async {
        c.apply(s)
        await c.drain()
    }

    // MARK: Demo / simulated playback

    @Test func demoPlaysNeverReachLastFMDiscordOrNotifications() async {
        let c = makeCoordinator()
        var s = QTIntegrationsSnapshot(track: Self.song("demo1"), playSerial: 1, isPlaying: true, reportsPlays: false)
        await apply(c, s)
        clock.advance(300)
        s.track = Self.song("demo2")
        s.playSerial = 2
        await apply(c, s)
        clock.advance(300)
        s.track = nil
        await apply(c, s)
        #expect(lastfm.methods.isEmpty)
        #expect(notified.isEmpty)
    }

    @Test func onlyAudibleLibraryPlaybackIsReported() {
        let live = QTPlaybackSetup(source: .live, engine: .web, isSilent: false, isAnonymous: false,
                                   publishesNowPlaying: true, persistsQueue: true)
        var silent = live
        silent.isSilent = true
        var demo = live
        demo.source = .mock
        let real = QTUIStubEngine()
        #expect(QTIntegrationsCoordinator.reportsPlays(setup: live, engine: real, catalogMode: .live))
        #expect(QTIntegrationsCoordinator.reportsPlays(setup: live, engine: real, catalogMode: .guest))
        #expect(!QTIntegrationsCoordinator.reportsPlays(setup: live, engine: real, catalogMode: .mock))
        #expect(!QTIntegrationsCoordinator.reportsPlays(setup: demo, engine: real, catalogMode: .live))
        #expect(!QTIntegrationsCoordinator.reportsPlays(setup: silent, engine: real, catalogMode: .live))
        #expect(!QTIntegrationsCoordinator.reportsPlays(setup: live, engine: QTSimulatedPlaybackEngine(account: .premium),
                                                        catalogMode: .live))
        #expect(!QTIntegrationsCoordinator.reportsPlays(setup: nil, engine: real, catalogMode: .live))
    }

    /// "Use Demo Library" (`switchSource(to: .mock)`) swaps in the simulated engine, after which nothing is reported.
    @Test func switchingToTheDemoLibraryStopsReporting() async {
        let defaults = UserDefaults(suiteName: "qt.tests.switch.\(UUID().uuidString)")!
        let tracks = [Self.song("a")]
        let catalog = QTMockCatalog(tracks: tracks, liked: QTPlaylist(id: "LM", title: .localized("Liked Songs"), kind: .liked,
                                                                      tracks: tracks))
        let player = QTPlayerModel(engine: QTUIStubEngine(), lyricsProvider: QTMockLyricsProvider(catalog: catalog))
        let model = QTAppModel(settings: QTSettingsStore(defaults: defaults), player: player, catalog: catalog,
                               launch: QTLaunchOptions(arguments: [:]))
        let services = QTPlaybackServices()
        services.install(model: model, setup: QTPlaybackSetup(source: .live, engine: .web, isSilent: false, isAnonymous: false,
                                                              publishesNowPlaying: false, persistsQueue: false))
        #expect(QTIntegrationsCoordinator.reportsPlays(setup: services.setup, engine: player.engine, catalogMode: .live))
        await services.switchSource(to: .mock)
        #expect(player.engine is QTSimulatedPlaybackEngine)
        #expect(services.setup?.source == .mock)
        #expect(services.setup?.persistsQueue == false, "the demo never overwrites the saved queue")
        #expect(!QTIntegrationsCoordinator.reportsPlays(setup: services.setup, engine: player.engine, catalogMode: .mock))
    }

    // MARK: Listens

    @Test func repeatOneAndReplaysScrobbleEveryListen() async {
        let c = makeCoordinator()
        var s = QTIntegrationsSnapshot(track: Self.song("a"), playSerial: 1, isPlaying: true)
        await apply(c, s)
        #expect(lastfm.methods == ["track.updateNowPlaying"])
        for serial in 2...3 { // Repeat One wraps twice
            clock.advance(201)
            s.playSerial = serial
            await apply(c, s)
        }
        #expect(lastfm.scrobbledTracks == ["Song a", "Song a"])
        #expect(lastfm.methods.filter { $0 == "track.updateNowPlaying" }.count == 3, "a fresh now-playing per listen")
        #expect(notified == ["a"], "the same song again isn't a song change")
    }

    @Test func theLaunchTrackScrobblesOnceItPlaysButIsNotAnnounced() async {
        let launch = Self.song("launch")
        let c = makeCoordinator(launchTrack: launch)
        var s = QTIntegrationsSnapshot(track: launch, playSerial: 0, isPlaying: false)
        await apply(c, s)
        #expect(lastfm.methods.isEmpty, "cued and paused: nothing to say yet")
        s.isPlaying = true
        await apply(c, s)
        #expect(lastfm.methods == ["track.updateNowPlaying"])
        clock.advance(120)
        s.track = Self.song("next")
        s.playSerial = 1
        await apply(c, s)
        #expect(lastfm.scrobbledTracks == ["Song launch"])
        #expect(notified == ["next"])
    }

    @Test func adsAreNeitherScrobbledNorAnnounced() async {
        let c = makeCoordinator()
        var s = QTIntegrationsSnapshot(track: Self.song("a"), playSerial: 1, isPlaying: true, isAd: true)
        await apply(c, s)
        clock.advance(200)
        await apply(c, s)
        #expect(lastfm.methods.isEmpty)
        #expect(notified.isEmpty)
        s.isAd = false
        await apply(c, s)
        #expect(lastfm.methods == ["track.updateNowPlaying"])
        #expect(notified == ["a"])
        // A mid-roll pauses the listen; the ad's time doesn't count towards the threshold.
        clock.advance(60)
        s.isAd = true
        await apply(c, s)
        clock.advance(300)
        s.isAd = false
        await apply(c, s)
        clock.advance(20)
        s.track = nil
        await apply(c, s)
        #expect(lastfm.scrobbledTracks.isEmpty, "80 s listened of a 200 s song")
    }

    @Test func turningLastFMOnMidSongTracksItFromThen() async {
        let c = makeCoordinator(lastFM: false)
        let s = QTIntegrationsSnapshot(track: Self.song("a"), playSerial: 1, isPlaying: true)
        await apply(c, s)
        #expect(lastfm.methods.isEmpty)
        c.store.update { $0.lastFM.isEnabled = true }
        await apply(c, s)
        #expect(lastfm.methods == ["track.updateNowPlaying"])
        clock.advance(150)
        c.store.update { $0.lastFM.isEnabled = false }
        await apply(c, s)
        #expect(lastfm.scrobbledTracks.isEmpty, "turned off: the listen is forgotten, not sent")
    }

    // MARK: ListenBrainz, media time

    @Test func oneListenReachesLastFMAndListenBrainz() async {
        let c = makeCoordinator(listenBrainz: true)
        var s = QTIntegrationsSnapshot(track: Self.song("a"), playSerial: 1, isPlaying: true)
        await apply(c, s)
        #expect(lastfm.methods == ["track.updateNowPlaying"])
        #expect(listenBrainz.types == ["playing_now"])
        clock.advance(120)
        s.track = Self.song("b")
        s.playSerial = 2
        await apply(c, s)
        #expect(lastfm.scrobbledTracks == ["Song a"])
        #expect(listenBrainz.listenedTracks == ["Song a"])
        #expect(listenBrainz.types == ["playing_now", "playing_now", "single"])
    }

    @Test func listenBrainzAloneScrobblesAndTurningItOffForgetsTheListen() async {
        let c = makeCoordinator(lastFM: false, listenBrainz: true)
        let s = QTIntegrationsSnapshot(track: Self.song("a"), playSerial: 1, isPlaying: true)
        await apply(c, s)
        #expect(listenBrainz.types == ["playing_now"])
        clock.advance(150)
        c.store.update { $0.listenBrainz.isEnabled = false }
        await apply(c, s)
        #expect(listenBrainz.listenedTracks.isEmpty)
        #expect(lastfm.methods.isEmpty)
    }

    /// At 2× a 200 s song has had half its length after 50 s; while buffering (rate 0) nothing counts.
    @Test func listensCountMediaTime() async {
        let c = makeCoordinator()
        var s = QTIntegrationsSnapshot(track: Self.song("a"), playSerial: 1, isPlaying: true, rate: 2)
        await apply(c, s)
        clock.advance(30)          // 60 s of music
        s.rate = 0                 // buffering
        await apply(c, s)
        clock.advance(60)
        s.rate = 2
        await apply(c, s)
        clock.advance(19)          // + 38 → 98
        s.track = Self.song("b")
        s.playSerial = 2
        await apply(c, s)
        #expect(lastfm.scrobbledTracks.isEmpty)

        clock.advance(50)          // b: 100 s of music at 2×
        s.track = Self.song("c")
        s.playSerial = 3
        await apply(c, s)
        #expect(lastfm.scrobbledTracks == ["Song b"])
    }

    @Test func notificationsOnlyWhenInactive() async {
        let c = makeCoordinator()
        await apply(c, QTIntegrationsSnapshot(track: Self.song("a"), playSerial: 1, isPlaying: true, isAppActive: true))
        await apply(c, QTIntegrationsSnapshot(track: Self.song("b"), playSerial: 2, isPlaying: true))
        #expect(notified == ["b"])
    }

    @Test func serialQueueRunsOperationsInOrder() async {
        let queue = QTSerialTaskQueue()
        var order: [Int] = []
        for i in 0..<20 {
            queue.enqueue {
                if i % 3 == 0 { await Task.yield() }
                order.append(i)
            }
        }
        await queue.drain()
        #expect(order == Array(0..<20))
    }
}

final class QTUINotificationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    var values: [String] { lock.withLock { ids } }
    func append(_ id: String) { lock.withLock { ids.append(id) } }
}

/// Dev and scripted runs never fall back to the user's display (`QTScreenGuard`).
@MainActor
@Suite struct QTScreenGuardTests {
    #if DEBUG
    @Test func devRunsRequireTheirDisplayAndPlainLaunchesRequireNone() {
        let builtIn = ["Built-in Retina Display"]
        #expect(QTLaunchOptions(arguments: [:]).effectiveScreenName == nil, "Finder / Dock launch")
        let scripted = QTLaunchOptions(arguments: ["qt.catalog": "mock"])
        #expect(scripted.effectiveScreenName == "U270CA")
        #expect(QTScreenGuard.missingScreen(for: scripted, connected: builtIn) == "U270CA")
        #expect(QTScreenGuard.missingScreen(for: scripted, connected: builtIn + ["LG U270CA"]) == nil)
        let onBuiltIn = QTLaunchOptions(arguments: ["qt.screen": "built-in"])
        #expect(QTScreenGuard.missingScreen(for: onBuiltIn, connected: builtIn) == nil)
        #expect(QTScreenGuard.missingScreen(for: onBuiltIn, connected: ["LG U270CA"]) == "built-in")
        for any in ["main", "any", "none"] {
            let o = QTLaunchOptions(arguments: ["qt.screen": any, "qt.catalog": "mock"])
            #expect(o.effectiveScreenName == nil && o.screen == nil)
        }
    }
    #endif
}
