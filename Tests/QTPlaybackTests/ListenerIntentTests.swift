import Foundation
import QTCore
import Testing
@testable import QTPlayback

/// Music does what the listener intends (`QTQueueController.wantsPlayback`): Play/Pause toggles that intent, nothing
/// starts by itself after the listener or the app paused, the Picture in Picture window's controls are the listener's,
/// and the intent survives engine swaps, Song⇄Video and gapless joins. On a `ChaosEngine` and a manual clock, and on
/// the web engine with fake player pages (`QTFakePlayerPages`).
@MainActor
@Suite(.serialized) struct ListenerIntentTests {
    static let song = QTModeSwitchBehaviourTests.song
    static let songID = QTModeSwitchBehaviourTests.songID

    /// Lets the state stream catch up (bounded: a busy test run may need more turns than `settle`).
    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<2000 where !condition() { await Task.yield() }
    }

    // MARK: Play/Pause follows the intent

    @Test func pauseWorksWhileATrackIsLoading() async {
        let rig = ChaosRig()
        rig.engine.loadFaults = [.delay(20)]
        Task { await rig.controller.play(PB.tracks(3)) }
        await rig.settle()
        #expect(rig.engine.state.status == .loading && rig.controller.isPlaybackRequested, "shows Pause")
        rig.controller.togglePlayPause()
        #expect(!rig.controller.wantsPlayback && !rig.controller.isPlaybackRequested)
        await rig.run(40)
        #expect(rig.engine.state.status == .paused && rig.engine.plays == 0, "the load finished held")
        rig.controller.togglePlayPause()
        await rig.run(1)
        #expect(rig.engine.state.status == .playing)
        rig.teardown()
    }

    @Test func pauseWorksWhileATrackWaitsToBeRetried() async {
        let rig = ChaosRig()
        rig.engine.loadFaults = [.fail(.network("timeout"))]
        await rig.controller.play(PB.tracks(3))
        #expect(rig.engine.state.status == .failed(.network("timeout")) && rig.controller.isPlaybackRequested)
        rig.controller.togglePlayPause()
        await rig.run(30)
        #expect(rig.engine.loads.count == 1, "no retry after the pause")
        #expect(rig.engine.state.status != .playing && rig.failures.isEmpty)
        rig.teardown()
    }

    @Test func nowPlayingShowsPauseWhileATrackLoadsForTheListener() async {
        let rig = ChaosRig()
        await rig.controller.play(PB.tracks(3))
        await eventually { rig.nowPlaying.isActive }
        rig.engine.loadFaults = [.delay(20)]
        Task { await rig.controller.next() }
        await eventually { rig.nowPlaying.snapshot?.videoID == "t2" }
        #expect(rig.engine.state.status == .loading)
        #expect(rig.nowPlaying.snapshot?.playbackState == .playing && rig.nowPlaying.snapshot?.rate == 0)
        rig.controller.pause()
        await eventually { rig.nowPlaying.snapshot?.playbackState == .paused }
        #expect(rig.nowPlaying.snapshot?.playbackState == .paused)
        rig.teardown()
    }

    @Test func aLoadingSnapshotFollowsTheIntent() {
        let track = PB.track("np")
        let loading = QTPlaybackState(item: QTPlaybackItem(track: track), status: .loading, isBuffering: true)
        let wanted = QTNowPlayingSnapshot(track: track, state: loading, isLiked: false, adLabel: "Ad", wantsPlayback: true)
        #expect(wanted.playbackState == .playing && wanted.rate == 0)
        #expect(QTNowPlayingSnapshot(track: track, state: loading, isLiked: false, adLabel: "Ad").playbackState == .paused)
    }

    // MARK: Nothing starts by itself

    @Test func whenTheLastTrackFailsTheEngineIsToldTheQueueStopped() async {
        let rig = ChaosRig(continuation: false)
        rig.engine.failing["t1"] = .network("timeout")
        await rig.controller.play(PB.tracks(1))
        await rig.run(30)
        #expect(rig.failures.last?.skipped == false && !rig.controller.wantsPlayback)
        #expect(rig.engine.pauses >= 1, "the engine holds the failed track instead of bringing it back online")
        rig.teardown()
    }

    @Test func aFailedTrackThatWasPausedStaysHeldWhenTheNetworkReturns() async throws {
        let pages = QTFakePlayerPages()
        try await pages.engine.load(QTPlaybackItem(track: Self.song, mode: .song, startTime: 30), autoplay: true)
        try await pages.until { pages.engine.state.status == .playing }
        // The queue gave up (or the listener paused, or the Mac slept), then the item failed offline.
        pages.engine.pause()
        pages.engine.state.status = .failed(.network("stalled"))
        pages.engine.networkChanged(available: false)
        pages.engine.networkChanged(available: true)
        try await Task.sleep(for: .milliseconds(150))
        #expect(pages.mainLoads.isEmpty && pages.navigations.count == 1, "nothing reloads by itself")
        #expect(pages.engine.state.status == .failed(.network("stalled")))
    }

    @Test func aFailedTrackTheAppStillWantsReloadsWhenTheNetworkReturns() async throws {
        let pages = QTFakePlayerPages()
        try await pages.engine.load(QTPlaybackItem(track: Self.song, mode: .song, startTime: 30), autoplay: true)
        try await pages.until { pages.engine.state.status == .playing }
        pages.engine.state.status = .failed(.network("stalled"))
        pages.engine.networkChanged(available: false)
        pages.engine.networkChanged(available: true)
        try await pages.until { pages.mainLoads.count == 1 }
        #expect(pages.mainLoads.first?.autoplay == true)
    }

    @Test func aPauseWhileTheRadioAnswersHolds() async {
        let rig = ChaosRig(continuation: false)
        var answer: CheckedContinuation<[QTTrack], any Error>?
        rig.controller.autoplayContinuation = { _ in try await withCheckedThrowingContinuation { answer = $0 } }
        await rig.controller.play(PB.tracks(1))
        await rig.run(101)   // the song ends; the queue waits for more from the radio
        #expect(rig.controller.isFetchingAutoplay)
        rig.controller.pause()
        answer?.resume(returning: [PB.track("radio1"), PB.track("radio2")])
        await rig.run(10)
        #expect(rig.nowID == "radio1", "the queue moves on")
        #expect(rig.engine.state.status == .paused && !rig.controller.wantsPlayback, "but waits for Play")
        rig.teardown()
    }

    @Test func aPauseAsAGaplessJoinLandsHolds() async {
        let rig = ChaosRig()
        await rig.controller.play(PB.tracks(3))
        await rig.run(5)
        rig.controller.pause()
        // A crossfade under way: the engine moves on to the next item, paused.
        rig.engine.joinPrepared(evenIfPaused: true)
        await rig.settle()
        #expect(rig.nowID == "t2" && !rig.controller.wantsPlayback)
        let plays = rig.engine.plays
        await rig.run(20)
        #expect(rig.engine.state.status == .paused && rig.engine.plays == plays && rig.notices.isEmpty)
        rig.teardown()
    }

    // MARK: Picture in Picture

    @Test func pictureInPicturePauseAndPlayAreAdoptedWithoutFightingTheMedia() async {
        let rig = ChaosRig()
        await rig.controller.play(PB.tracks(3))
        await rig.run(5)
        let pauses = rig.engine.pauses
        rig.engine.isPausedByListener = true
        rig.engine.pauseByItself()
        await rig.settle()
        #expect(!rig.controller.wantsPlayback && rig.engine.pauses == pauses, "taken at once; the media is left alone")
        rig.engine.isPausedByListener = false
        await rig.run(10)
        #expect(rig.engine.state.status == .paused && rig.notices.isEmpty)

        rig.engine.isResumedByListener = true
        rig.engine.resumeByItself()
        await rig.settle()
        rig.engine.isResumedByListener = false
        #expect(rig.controller.wantsPlayback && rig.controller.isPlaybackRequested)
        await rig.run(110)
        #expect(rig.nowID == "t2" && rig.engine.state.status == .playing, "the queue plays on after their Play")
        rig.teardown()
    }

    @Test func theWebEngineTakesPictureInPictureControlsAsTheListeners() async throws {
        let pages = QTFakePlayerPages(freezeAfterPause: .milliseconds(30))
        let queue = QTQueueController(engine: pages.engine, supervision: nil)
        await queue.play([Self.song, QTModeSwitchBehaviourTests.next], startTime: 30)
        try await pages.until { pages.engine.state.status == .playing }
        let gen = pages.engine.generation
        func sample(paused: Bool) -> [String: Any] {
            ["type": "state", "gen": gen, "vid": Self.songID, "match": true, "t": 31.0, "d": 200.0, "paused": paused,
             "ps": paused ? 2 : 1, "buffering": false, "ad": NSNull(), "rs": 4, "pip": true]
        }
        let pauses = pages.calls(on: .main, "pause").count

        // Pause in the PiP window: the bridge says so before the state it changes.
        pages.engine.receive(["type": "pip", "gen": gen, "playing": false])
        pages.engine.receive(sample(paused: true))
        try await pages.until { !queue.wantsPlayback }
        #expect(pages.engine.isPausedByListener && !pages.engine.intendsPlayback)
        queue.superviseTick()
        #expect(pages.calls(on: .main, "pause").count == pauses, "the media is paused already: no hold sent back")

        // Play in the PiP window, after the page froze.
        try await pages.until { !pages.calls(on: .main, "freeze").isEmpty }
        pages.engine.receive(["type": "pip", "gen": gen, "playing": true])
        pages.engine.receive(sample(paused: false))
        try await pages.until { queue.wantsPlayback }
        #expect(pages.engine.isResumedByListener && pages.engine.intendsPlayback && !pages.engine.isPageFrozen)
        queue.superviseTick()
        #expect(pages.engine.state.status == .playing && pages.calls(on: .main, "pause").count == pauses)
    }

    // MARK: The intent survives

    @Test func anEngineSwapWhileLoadingKeepsPlaying() async {
        let rig = ChaosRig()
        rig.engine.loadFaults = [.delay(30)]
        Task { await rig.controller.play(PB.tracks(2)) }
        await rig.settle()
        #expect(rig.engine.state.status == .loading)
        let other = ChaosEngine(clock: rig.clock)
        await rig.controller.replaceEngine(other)
        await rig.settle()
        #expect(other.state.status == .playing && rig.controller.wantsPlayback)
        // Paused, a swap stays paused.
        rig.controller.pause()
        await rig.controller.replaceEngine(ChaosEngine(clock: rig.clock))
        #expect(rig.controller.engine.state.status == .paused)
        rig.teardown()
    }

    @Test func songVideoWhileLoadingKeepsPlaying() async {
        let rig = ChaosRig()
        var track = PB.track("mv")
        track.counterpart = QTCounterpart(videoId: "mv-video", musicVideoType: .omv)
        rig.engine.loadFaults = [.delay(30)]
        Task { await rig.controller.play([track]) }
        await rig.settle()
        await rig.controller.setMode(.video)
        await rig.settle()
        #expect(rig.controller.mode == .video && rig.engine.state.status == .playing)
        rig.teardown()
    }

    // MARK: Keeping quiet while idle

    @Test func aCuedLoadOfflineHoldsNothingUntilTheListenerWaits() async {
        let rig = ChaosRig()
        rig.engine.isNetworkAvailable = false
        // A queue restored at launch: cued, not playing.
        Task { await rig.controller.play(PB.tracks(2), autoplay: false) }
        await rig.settle()
        #expect(rig.controller.loadInFlight != nil && rig.engine.state.status == .loading)
        #expect(!rig.controller.needsSupervision && rig.controller.activityLevel == .none, "no 1 Hz watch, App Nap allowed")
        rig.controller.play()
        await rig.settle()
        #expect(rig.controller.needsSupervision && rig.controller.activityLevel == .busy)
        rig.engine.isNetworkAvailable = true
        await rig.run(1)
        #expect(rig.engine.state.status == .playing)
        rig.teardown()
    }

    // MARK: Listens

    @Test func replayingTheLastSongAfterTheQueueEndedIsANewListen() async {
        let rig = ChaosRig(continuation: false)
        await rig.controller.play(PB.tracks(1))
        await rig.run(101)
        #expect(rig.engine.state.status == .ended && !rig.controller.wantsPlayback)
        let serial = rig.controller.playSerial
        rig.controller.play()
        await rig.run(1)
        #expect(rig.controller.playSerial == serial + 1 && rig.engine.state.status == .playing)
        rig.controller.pause()
        rig.controller.play()
        #expect(rig.controller.playSerial == serial + 1, "pause and play is the same listen")
        // Repeat One counts each wrap once.
        rig.controller.repeatMode = .one
        await rig.run(101)
        #expect(rig.controller.playSerial == serial + 2 && rig.engine.state.status == .playing)
        rig.teardown()
    }
}
