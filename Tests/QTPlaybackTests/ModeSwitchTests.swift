import Foundation
import QTCore
import Testing
import WebKit
@testable import QTPlayback

/// Behaviour of the seamless Song⇄Video switch (`QTWebPlaybackEngine+ModeSwitch`) and the queue around it, with
/// fake player pages behind `QTWebPageIO`: nothing is loaded from the network, but the engine's own state machine
/// (standby page, line-up, crossfade, hand-over, cancellation, fallback) runs unchanged.
@MainActor
@Suite(.serialized) struct QTModeSwitchBehaviourTests {
    static let songID = "SONGsong001"
    static let videoID = "VIDEOvid001"
    static let nextID = "NEXTnext001"

    static var song: QTTrack {
        QTTrack(videoId: songID, title: "Song", artists: [QTArtistRef(name: "Artist")], duration: 200,
                musicVideoType: .atv, counterpart: QTCounterpart(videoId: videoID, musicVideoType: .omv))
    }

    static var next: QTTrack {
        QTTrack(videoId: nextID, title: "Next", artists: [QTArtistRef(name: "Artist")], duration: 180, musicVideoType: .atv)
    }

    /// Starts the song at 30 s on the fake main page and waits until the engine knows the page's account.
    func startSong(_ pages: QTFakePlayerPages) async throws {
        try await pages.engine.load(QTPlaybackItem(track: Self.song, mode: .song, startTime: 30), autoplay: true)
        try await pages.until { pages.engine.pageAccount != nil && pages.engine.state.status == .playing }
    }

    func videoItem(_ engine: QTWebPlaybackEngine) -> QTPlaybackItem {
        QTPlaybackItem(track: Self.song, mode: .video, startTime: engine.state.timeline.currentTime)
    }

    // MARK: The switch itself

    @Test func aSeamlessSwitchHandsTheStandbyPageOverWithoutReloading() async throws {
        let pages = QTFakePlayerPages()
        try await startSong(pages)
        let oldPage = try #require(pages.engine.webView)
        try await pages.engine.load(videoItem(pages.engine), autoplay: true)

        let engine = pages.engine
        #expect(engine.webView !== oldPage, "the standby page became the engine's page")
        #expect(engine.standby == nil)
        #expect(engine.state.item?.mode == .video && engine.requestedVideoID == Self.videoID)
        let report = try #require(engine.lastModeSwitch)
        #expect(report.isSeamless && report.gap == 0 && report.to == .video)
        #expect(engine.lastSeamlessFallback == nil)
        #expect(pages.mainLoads.isEmpty, "no in-page reload")
        #expect(pages.standbyURLs.count == 1 && pages.standbyURLs[0].absoluteString.contains("v=\(Self.videoID)"))
        #expect(pages.calls(on: .standby, "fade").first?.args[2] as? String == "in")
        #expect(pages.calls(on: .main, "fade").first?.args[2] as? String == "out")
    }

    @Test func pausingDuringTheSwitchReloadsPausedAtTheCurrentPosition() async throws {
        let pages = QTFakePlayerPages()
        pages.standby = .neverReady
        try await startSong(pages)
        let switching = Task { try await pages.engine.load(videoItem(pages.engine), autoplay: true) }
        try await pages.until { !pages.standbyURLs.isEmpty }
        let pausedAt = pages.engine.state.timeline.currentTime
        pages.engine.pause()
        try await switching.value

        let load = try #require(pages.mainLoads.last)
        #expect(load.videoID == Self.videoID)
        #expect(abs(load.start - pausedAt) < 0.3)
        #expect(load.autoplay == false)
        #expect(pages.engine.standby == nil && pages.engine.state.item?.mode == .video)
        #expect(pages.engine.state.status == .paused)
    }

    @Test func seekingDuringTheSwitchReloadsAtTheSeekTarget() async throws {
        let pages = QTFakePlayerPages()
        pages.standby = .neverReady
        try await startSong(pages)
        let switching = Task { try await pages.engine.load(videoItem(pages.engine), autoplay: true) }
        try await pages.until { !pages.standbyURLs.isEmpty }
        pages.engine.seek(to: 80)
        try await switching.value

        let load = try #require(pages.mainLoads.last)
        #expect(load.videoID == Self.videoID && abs(load.start - 80) < 0.3 && load.autoplay == true)
        #expect(pages.engine.state.status == .playing)
    }

    @Test func stoppingDuringTheSwitchCancelsItWithoutAReload() async throws {
        let pages = QTFakePlayerPages()
        pages.standby = .neverReady
        try await startSong(pages)
        let switching = Task { try await pages.engine.load(videoItem(pages.engine), autoplay: true) }
        try await pages.until { !pages.standbyURLs.isEmpty }
        pages.engine.stop()
        await #expect(throws: CancellationError.self) { try await switching.value }
        #expect(pages.mainLoads.isEmpty)
        #expect(pages.engine.standby == nil && pages.engine.state.status == .idle)
    }

    @Test func anotherLoadSupersedesTheSwitch() async throws {
        let pages = QTFakePlayerPages()
        pages.standby = .neverReady
        try await startSong(pages)
        let switching = Task { try await pages.engine.load(videoItem(pages.engine), autoplay: true) }
        try await pages.until { !pages.standbyURLs.isEmpty }
        try await pages.engine.load(QTPlaybackItem(track: Self.next), autoplay: true)
        await #expect(throws: CancellationError.self) { try await switching.value }
        #expect(pages.mainLoads.map(\.videoID) == [Self.nextID])
        #expect(pages.engine.state.item?.track.videoId == Self.nextID && pages.engine.standby == nil)
    }

    @Test func aSessionChangeDuringTheSwitchReloadsTheNewRenditionOnAFreshPage() async throws {
        let pages = QTFakePlayerPages()
        pages.standby = .neverReady
        try await startSong(pages)
        let switching = Task { try await pages.engine.load(videoItem(pages.engine), autoplay: true) }
        try await pages.until { !pages.standbyURLs.isEmpty }
        pages.engine.sessionDidChange()
        await #expect(throws: CancellationError.self) { try await switching.value }
        // The current item (the video, as asked) reloads by navigating a fresh page that boots with the new login.
        try await pages.until { pages.navigations.count == 2 }
        #expect(pages.navigations.last?.absoluteString.contains("v=\(Self.videoID)") == true)
        #expect(pages.engine.standby == nil)
    }

    @Test func aStandbyAdFallsBackToTheInPageReload() async throws {
        let pages = QTFakePlayerPages()
        pages.standby = .rollsAnAd
        try await startSong(pages)
        try await pages.engine.load(videoItem(pages.engine), autoplay: true)
        #expect(pages.engine.lastSeamlessFallback == "standby ad")
        let load = try #require(pages.mainLoads.last)
        #expect(load.videoID == Self.videoID && load.autoplay)
        #expect(pages.engine.standby == nil)
    }

    @Test func cancellingMidCrossfadeGivesTheOldPageItsVolumeBack() async throws {
        let pages = QTFakePlayerPages()
        try await startSong(pages)
        let engine = pages.engine
        engine.setVolume(0.6)
        // The listener pauses the moment the old page starts fading out.
        pages.onCall = { page, name, _ in
            if page == .main, name == "fade" { Task { @MainActor in engine.pause() } }
        }
        try await engine.load(videoItem(engine), autoplay: true)
        let fadeIndex = try #require(pages.log.firstIndex { $0.page == .main && $0.name == "fade" })
        let restore = try #require(pages.log[fadeIndex...].first { $0.page == .main && $0.name == "volume" })
        #expect(restore.args.first as? Double == 0.6)
        #expect(engine.lastModeSwitch == nil, "no hand-over")
        let load = try #require(pages.mainLoads.last)
        #expect(load.videoID == Self.videoID && load.autoplay == false)
    }

    @Test func aSignedInFreeAccountNeverUsesAStandbyPage() async throws {
        let pages = QTFakePlayerPages()
        pages.account = ["loggedIn": true, "premium": false]
        try await startSong(pages)
        #expect(pages.engine.pageAccount == .free)
        try await pages.engine.load(videoItem(pages.engine), autoplay: true)
        #expect(pages.standbyURLs.isEmpty)
        #expect(pages.mainLoads.last?.videoID == Self.videoID)
    }

    @Test func tooCloseToTheEndSwitchesInThePage() async throws {
        let pages = QTFakePlayerPages()
        try await pages.engine.load(QTPlaybackItem(track: Self.song, mode: .song, startTime: 190), autoplay: true)
        try await pages.until { pages.engine.pageAccount != nil && pages.engine.state.status == .playing }
        try await pages.engine.load(videoItem(pages.engine), autoplay: true)
        #expect(pages.standbyURLs.isEmpty && pages.mainLoads.last?.videoID == Self.videoID)
    }

    // MARK: The queue around a switch

    @Test func theSongEndingDuringASlowSwitchStillAdvancesTheQueue() async throws {
        let pages = QTFakePlayerPages()
        pages.standby = .neverReady
        let queue = QTQueueController(engine: pages.engine)
        await queue.play([Self.song, Self.next], startTime: 30)
        try await pages.until { pages.engine.pageAccount != nil && pages.engine.state.status == .playing }

        let switching = Task { await queue.setMode(.video) }
        try await pages.until { !pages.standbyURLs.isEmpty }
        // The old page plays the song to its end while the standby is still loading.
        pages.engine.receive(["type": "ended", "gen": pages.engine.generation])
        await switching.value
        try await pages.until { queue.nowPlayingTrack?.videoId == Self.nextID && pages.engine.state.status == .playing }
        #expect(pages.mainLoads.last?.videoID == Self.nextID)
        #expect(queue.queue.history.map(\.track.videoId) == [Self.songID])
        #expect(pages.engine.standby == nil)
    }

    @Test func theSongEndingDuringASwitchUnderRepeatOneReplaysTheSong() async throws {
        let pages = QTFakePlayerPages()
        pages.standby = .neverReady
        let queue = QTQueueController(engine: pages.engine)
        queue.repeatMode = .one
        await queue.play([Self.song, Self.next], startTime: 30)
        try await pages.until { pages.engine.pageAccount != nil && pages.engine.state.status == .playing }

        let switching = Task { await queue.setMode(.video) }
        try await pages.until { !pages.standbyURLs.isEmpty }
        pages.engine.receive(["type": "ended", "gen": pages.engine.generation])
        await switching.value
        try await pages.until { pages.calls(on: .main, "seek").contains { ($0.args.first as? Double) == 0 } }
        // The page that ended plays the song: the engine and the queue are back on the song, not the video.
        #expect(queue.nowPlayingTrack?.videoId == Self.songID)
        #expect(pages.engine.state.item?.mode == .song && queue.mode == .song)
    }

    @Test func thePageFailingDuringASwitchSkipsToTheNextTrack() async throws {
        let pages = QTFakePlayerPages()
        pages.standby = .neverReady
        let queue = QTQueueController(engine: pages.engine)
        var failures: [QTPlaybackFailureEvent] = []
        queue.onFailure = { failures.append($0) }
        await queue.play([Self.song, Self.next], startTime: 30)
        try await pages.until { pages.engine.pageAccount != nil && pages.engine.state.status == .playing }

        let switching = Task { await queue.setMode(.video) }
        try await pages.until { !pages.standbyURLs.isEmpty }
        pages.engine.receive(["type": "error", "gen": pages.engine.generation, "code": 5])
        await switching.value
        try await pages.until { queue.nowPlayingTrack?.videoId == Self.nextID }
        #expect(failures.count == 1 && failures.first?.track.videoId == Self.songID && failures.first?.skipped == true)
    }
}

/// Fake YouTube Music player pages: the engine's main page and a Song⇄Video standby page.
@MainActor
final class QTFakePlayerPages {
    enum Page: Equatable { case main, standby, other }
    enum Standby { case readyQuickly, neverReady, rollsAnAd }
    struct Call {
        var page: Page
        var name: String
        var args: [Any]
    }
    struct Load {
        var videoID: String
        var start: TimeInterval
        var autoplay: Bool
    }

    let engine: QTWebPlaybackEngine
    var standby = Standby.readyQuickly
    var account: [String: Any] = ["loggedIn": true, "premium": true]
    var onCall: ((Page, String, [Any]) -> Void)?
    /// Commands the main page doesn't take (a dead page answers nothing).
    var refuses: Set<String> = []
    private(set) var log: [Call] = []
    /// In-page loads (`__qtBridge.load`) on the main page.
    private(set) var mainLoads: [Load] = []
    /// Main-page navigations (first load, fresh pages).
    private(set) var navigations: [URL] = []
    private(set) var standbyURLs: [URL] = []

    private var main = Clock()
    private var standbyClock = Clock()

    struct Clock {
        var time: TimeInterval = 0
        var anchor: TimeInterval = ProcessInfo.processInfo.systemUptime
        var playing = false
        var now: TimeInterval { time + (playing ? ProcessInfo.processInfo.systemUptime - anchor : 0) }
        mutating func set(time t: TimeInterval? = nil, playing p: Bool? = nil) {
            time = t ?? now
            anchor = ProcessInfo.processInfo.systemUptime
            if let p { playing = p }
        }
    }

    init(freezeAfterPause: Duration? = nil) {
        var configuration = QTWebPlaybackEngine.Configuration(isSilent: true, freezeAfterPause: freezeAfterPause)
        configuration.seamlessModeSwitch = true
        engine = QTWebPlaybackEngine(configuration: configuration, dataStore: .nonPersistent())
        engine.modeSwitchStandbyTimeout = 4
        engine.pageIO = QTWebPageIO(
            load: { [weak self] view, request in self?.load(view, request) },
            call: { [weak self] view, name, args in self?.call(view, name, args) },
            evaluate: { [weak self] _, body in body.contains("LOGGED_IN") ? self?.account : nil })
    }

    func calls(on page: Page, _ name: String) -> [Call] { log.filter { $0.page == page && $0.name == name } }

    /// Polls `condition` (the engine works through real short sleeps).
    func until(_ condition: () -> Bool, timeout: TimeInterval = 5, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let end = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < end else {
                Issue.record("timed out waiting", sourceLocation: sourceLocation)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func page(of view: WKWebView) -> Page {
        if view === engine.webView { return .main }
        if let s = engine.standby, view === s.webView { return .standby }
        return .other
    }

    private func load(_ view: WKWebView, _ request: URLRequest) {
        guard let url = request.url else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let videoID = items.first { $0.name == "v" }?.value ?? ""
        let start = items.first { $0.name == "t" }?.value.flatMap { Double($0.dropLast()) } ?? 0
        switch page(of: view) {
        case .main:
            navigations.append(url)
            let gen = engine.generation
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(20))
                self.engine.receive(["type": "ready"])
                self.main.set(time: start, playing: true)
                self.engine.receive(self.sample(gen: gen, videoID: videoID, time: start, paused: false))
            }
        case .standby:
            standbyURLs.append(url)
            guard let s = engine.standby else { return }
            let gen = s.generation
            switch standby {
            case .neverReady:
                break
            case .readyQuickly, .rollsAnAd:
                let ad = standby == .rollsAnAd
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(30))
                    s.receive(["type": "ready"])
                    self.standbyClock.set(time: start, playing: true)
                    var sample = self.sample(gen: gen, videoID: videoID, time: ad ? 0 : start, paused: false)
                    if ad { sample["ad"] = ["duration": 15.0, "remaining": 15.0] as [String: Any] }
                    s.receive(sample)
                }
            }
        case .other:
            break
        }
    }

    private func call(_ view: WKWebView, _ name: String, _ args: [Any]) -> Any? {
        let page = page(of: view)
        log.append(Call(page: page, name: name, args: args))
        onCall?(page, name, args)
        if page == .main, refuses.contains(name) { return nil }
        switch (page, name) {
        case (.main, "load"):
            let videoID = args[0] as? String ?? ""
            let start = args[1] as? Double ?? 0
            let autoplay = args[2] as? Bool ?? true
            let gen = args[3] as? Int ?? engine.generation
            mainLoads.append(Load(videoID: videoID, start: start, autoplay: autoplay))
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(20))
                self.main.set(time: start, playing: autoplay)
                self.engine.receive(self.sample(gen: gen, videoID: videoID, time: start, paused: !autoplay))
            }
            return true
        case (.main, "sample"):
            return ["t": main.now, "rs": 4, "paused": !main.playing] as [String: Any]
        case (.main, "play"):
            main.set(playing: true)
            return true
        case (.main, "pause"):
            main.set(playing: false)
            return true
        case (.main, "seek"):
            main.set(time: args.first as? Double ?? 0)
            return true
        case (.standby, "pause"):
            // Held where it has buffered — a little ahead of the old page, so the line-up wait is short.
            standbyClock.set(time: main.now + 0.15, playing: false)
            return true
        case (.standby, "play"):
            standbyClock.set(playing: true)
            return true
        case (.standby, "seek"):
            standbyClock.set(time: args.first as? Double ?? 0)
            return true
        case (.standby, "sample"):
            return ["t": standbyClock.now, "rs": 4, "paused": !standbyClock.playing] as [String: Any]
        default:
            return true
        }
    }

    private func sample(gen: Int, videoID: String, time: TimeInterval, paused: Bool) -> [String: Any] {
        ["type": "state", "gen": gen, "vid": videoID, "match": true, "t": time, "d": 200.0, "paused": paused,
         "ps": paused ? 2 : 1, "buffering": false, "ad": NSNull(), "rs": 4]
    }
}
