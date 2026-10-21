import Foundation
import QTCore
import Testing
@testable import QTPlayback

/// The gaps of docs/prelaunch-implementation.md §3, one test each, on a `ChaosEngine` and a manual clock: radio that
/// fails or hangs, skip storms, network errors, pauses nobody asked for, crashes, offline loads, queue/engine
/// disagreements, missed ends, sleep. `PlaybackSoakTests` throws all of them at the queue at random.
@MainActor
@Suite struct PlaybackReliabilityTests {
    let album = QTQueueSource(kind: .album, id: "MPREb_album", title: .verbatim("Album"))

    // MARK: Autoplay radio

    @Test func anAlbumRunsIntoRadioAfterFailedAttempts() async {
        let rig = ChaosRig(continuation: false)
        var calls = 0
        rig.controller.autoplayContinuation = { _ in
            calls += 1
            if calls < 3 { throw URLError(.timedOut) }
            return [PB.track("radio1"), PB.track("radio2")]
        }
        await rig.controller.play(PB.tracks(2), source: album)
        await rig.run(10)
        #expect(calls == 3, "two retries, then an answer")
        #expect(rig.controller.queue.autoplay.map(\.track.videoId) == ["t2", "radio1", "radio2"])
        await rig.run(195)
        #expect(rig.nowID == "radio1")
        #expect(rig.engine.state.status == .playing)
        #expect(rig.notices.isEmpty, "recovered silently")
        rig.teardown()
    }

    @Test func radioThatKeepsFailingStopsOnceWithANoticeAndRetryPlaysOn() async {
        let rig = ChaosRig()
        rig.radio = .fails
        await rig.controller.play(PB.tracks(1), source: album)
        await rig.run(20)
        #expect(rig.radioCalls == 3 && rig.notices.isEmpty, "the prefetch failing early is silent")
        await rig.run(110)
        #expect(rig.notices == [.autoplayUnavailable], "one notice, not a stream")
        #expect(rig.radioCalls == 6, "asked again at the end, with its retries")
        #expect(rig.nowID == "t1" && rig.engine.state.status == .ended)
        #expect(!rig.controller.wantsPlayback)
        #expect(!rig.controller.isFetchingAutoplay)

        rig.radio = .answers
        await rig.controller.retryAutoplay()
        #expect(rig.nowID == "radio1-1")
        #expect(rig.engine.state.status == .playing)
        rig.teardown()
    }

    @Test func radioThatHangsTimesOut() async {
        let rig = ChaosRig()
        rig.radio = .hangs
        await rig.controller.play(PB.tracks(1, prefix: "h"), source: album)
        await rig.run(101)
        #expect(rig.notices.isEmpty)
        await rig.run(60)
        #expect(rig.radioCalls == 6, "each attempt timed out, then retried")
        #expect(rig.notices == [.autoplayUnavailable])
        rig.teardown()
    }

    @Test func emptyRadioEndsTheQueueQuietly() async {
        let rig = ChaosRig()
        rig.radio = .empty
        await rig.controller.play(PB.tracks(1))
        await rig.run(110)
        #expect(rig.notices.isEmpty && rig.failures.isEmpty)
        #expect(rig.engine.state.status == .ended && !rig.controller.wantsPlayback)
        rig.teardown()
    }

    // MARK: Skips and failures

    @Test func aSkipStormEndsOnOneItemTheEngineAgreesWith() async {
        let rig = ChaosRig()
        rig.engine.loadFaults = Array(repeating: .delay(1), count: 40)
        let start = Task { await rig.controller.play(PB.tracks(40), source: album) }
        await rig.run(2)
        await start.value
        let storm = (0..<25).map { _ in Task { await rig.controller.next() } }
        await rig.run(3)
        for task in storm { await task.value }
        await rig.run(3)
        let current = rig.controller.queue.nowPlaying
        #expect(rig.engine.state.item?.queueID == current?.id)
        #expect(rig.engine.state.status == .playing)
        let ids = [current?.id].compactMap { $0 } + rig.controller.queue.autoplay.map(\.id)
        #expect(Set(ids).count == ids.count)
        rig.teardown()
    }

    @Test func alternatingNetworkErrorsNeverStopPlayback() async {
        let rig = ChaosRig(continuation: false)
        rig.engine.loadFaults = (0..<8).flatMap { _ in [ChaosEngine.LoadFault.fail(.network("timeout")), .ok] }
        await rig.controller.play(PB.tracks(6))
        var played: [String] = []
        for _ in 0..<6 {
            await rig.run(4)
            if let id = rig.nowID, rig.engine.state.status == .playing { played.append(id) }
            rig.engine.seek(to: 99)
            await rig.run(2)
        }
        #expect(played == ["t1", "t2", "t3", "t4", "t5", "t6"], "every track played after one retry, none skipped")
        #expect(rig.failures.isEmpty && rig.notices.isEmpty)
        rig.teardown()
    }

    @Test func aTrackThatKeepsFailingOnlineIsSkippedWithoutCountingTowardsTheLimit() async {
        let rig = ChaosRig(continuation: false)
        for id in ["t2", "t3", "t4"] { rig.engine.failing[id] = .network("timeout") }
        await rig.controller.play(PB.tracks(5))
        rig.engine.seek(to: 99)
        await rig.run(3)
        #expect(rig.nowID == "t2" && rig.failures.isEmpty, "retried first")
        await rig.run(80)
        #expect(rig.nowID == "t5", "three network failures in a row don't stop the queue")
        #expect(rig.failures.count == 3 && rig.failures.allSatisfy { $0.skipped && $0.consecutive == 0 })
        #expect(rig.engine.loads.filter { $0.track.videoId == "t2" }.count == 3, "tried twice more before the skip")
        #expect(rig.engine.state.status == .playing)
        rig.teardown()
    }

    @Test func playAfterTheQueueGaveUpLoadsTheItemAgain() async {
        let rig = ChaosRig(continuation: false)
        rig.engine.failing["t1"] = .engine("decoder")
        await rig.controller.play(PB.tracks(1))
        #expect(rig.failures.count == 1 && !rig.controller.wantsPlayback)
        rig.engine.failing = [:]
        rig.controller.play()
        await rig.run(1)
        #expect(rig.engine.state.status == .playing && rig.engine.loads.count == 2)
        rig.teardown()
    }

    // MARK: Pauses nobody asked for

    @Test func anUnrequestedPauseIsUndoneOnceThenReported() async {
        let rig = ChaosRig()
        await rig.controller.play(PB.tracks(3))
        await rig.run(10)
        rig.engine.pauseByItself()
        await rig.run(3)
        #expect(rig.engine.state.status == .playing, "resumed silently")
        #expect(rig.notices.isEmpty)
        await rig.run(20)
        rig.engine.pauseByItself()
        await rig.run(5)
        #expect(rig.engine.state.status == .paused, "a second one soon after isn't fought")
        #expect(rig.notices == [.interrupted])
        #expect(!rig.controller.wantsPlayback)
        await rig.run(30)
        #expect(rig.engine.state.status == .paused && rig.notices.count == 1)
        // The listener presses Play: the next interruption is undone silently again.
        rig.controller.play()
        await rig.run(5)
        rig.engine.pauseByItself()
        await rig.run(3)
        #expect(rig.engine.state.status == .playing && rig.notices.count == 1)
        rig.teardown()
    }

    @Test func remoteAndPictureInPicturePausesAreTheListeners() async {
        let rig = ChaosRig()
        await rig.controller.play(PB.tracks(3))
        await rig.run(5)
        // AirPods out, Control Center: they arrive as remote commands.
        #expect(rig.controller.handleRemote(.pause))
        let plays = rig.engine.plays
        await rig.run(20)
        #expect(rig.engine.state.status == .paused && rig.engine.plays == plays && rig.notices.isEmpty)

        rig.controller.play()
        await rig.run(2)
        // The Picture in Picture window's own pause button.
        rig.engine.isPausedByListener = true
        rig.engine.pauseByItself()
        await rig.run(10)
        #expect(rig.engine.state.status == .paused && !rig.controller.wantsPlayback && rig.notices.isEmpty)
        rig.teardown()
    }

    // MARK: Engine losing the item

    @Test func anEngineThatLostItsItemReloadsWhereItWas() async {
        let rig = ChaosRig()
        await rig.controller.play(PB.tracks(3))
        await rig.run(30)
        rig.engine.crash()
        await rig.run(4)
        #expect(rig.engine.state.item?.queueID == rig.controller.queue.nowPlaying?.id)
        #expect(rig.engine.state.status == .playing)
        #expect(abs(rig.engine.position - 33) < 2.5)
        // Paused: it comes back held, and Play plays it.
        rig.controller.pause()
        rig.engine.crash()
        await rig.run(4)
        #expect(rig.engine.state.status == .paused && rig.engine.state.item != nil)
        rig.controller.play()
        await rig.run(1)
        #expect(rig.engine.state.status == .playing)
        rig.teardown()
    }

    @Test func aQueueEngineMismatchReloadsTheQueuesTrack() async {
        let rig = ChaosRig()
        await rig.controller.play(PB.tracks(3))
        await rig.run(10)
        let loads = rig.engine.loads.count
        rig.engine.reportStaleItem()
        await rig.run(1)
        #expect(rig.engine.loads.count == loads, "not before the grace")
        await rig.run(3)
        #expect(rig.engine.loads.count == loads + 1)
        #expect(rig.engine.state.item?.queueID == rig.controller.queue.nowPlaying?.id && rig.nowID == "t1")
        #expect(abs((rig.engine.loads.last?.startTime ?? 0) - 10) < 1.5, "where it was")
        rig.teardown()
    }

    @Test func aStaleChainAfterTheEndMovesOnInsteadOfReplaying() async {
        let rig = ChaosRig()
        await rig.controller.play(PB.tracks(3))
        rig.engine.seek(to: 98.5)
        await rig.run(1)
        // The engine runs on into something the queue no longer has next.
        rig.engine.reportStaleItem()
        await rig.run(4)
        #expect(rig.nowID == "t2" && rig.engine.state.item?.queueID == rig.controller.queue.nowPlaying?.id)
        rig.teardown()
    }

    @Test func aMissedEndStillMovesOn() async {
        let rig = ChaosRig()
        await rig.controller.play(PB.tracks(3))
        rig.engine.missesNextEnd = true
        // The engine ends without a word; the watch's next look takes the end.
        await rig.run(102)
        #expect(rig.nowID == "t2" && rig.engine.state.status == .playing)
        rig.teardown()
    }

    @Test func aGaplessJoinIsFollowedWithoutALoad() async {
        let rig = ChaosRig()
        await rig.controller.play(PB.tracks(3))
        await rig.run(2)
        let loads = rig.engine.loads.count
        rig.engine.joinPrepared()
        await rig.run(3)
        #expect(rig.nowID == "t2" && rig.engine.loads.count == loads)
        rig.teardown()
    }

    // MARK: Network

    @Test func anOfflineLoadWaitsWithoutKeepingTheMacAwakeThenPauses() async {
        let rig = ChaosRig()
        rig.engine.isNetworkAvailable = false
        Task { await rig.controller.play(PB.tracks(3)) }
        await rig.run(1)
        #expect(rig.engine.state.status == .loading)
        #expect(rig.controller.activityLevel == .busy, "loading never holds the sleep assertion")
        await rig.run(300)
        #expect(rig.engine.state.status == .loading && rig.notices.isEmpty, "waits for the network")
        rig.engine.isNetworkAvailable = true
        await rig.run(1)
        #expect(rig.engine.state.status == .playing && rig.controller.activityLevel == .playing)

        rig.engine.isNetworkAvailable = false
        Task { await rig.controller.next() }
        await rig.run(590)
        #expect(rig.notices.isEmpty)
        await rig.run(15)
        #expect(rig.notices == [.networkUnavailable], "ten minutes without music: paused, said once")
        #expect(rig.engine.state.status == .paused && !rig.controller.wantsPlayback)
        #expect(rig.controller.activityLevel == .none)
        await rig.run(60)
        #expect(rig.notices.count == 1)
        rig.teardown()
    }

    @Test func aStallOfflineWaitsForTheNetworkThenResumesThere() async {
        let rig = ChaosRig()
        await rig.controller.play(PB.tracks(3))
        await rig.run(40)
        rig.engine.isNetworkAvailable = false
        rig.engine.stall()
        await rig.run(60)
        #expect(rig.nowID == "t1" && rig.failures.isEmpty, "no skip while offline")
        rig.engine.isNetworkAvailable = true
        await rig.run(2)
        #expect(rig.nowID == "t1" && rig.engine.state.status == .playing)
        #expect(abs((rig.engine.loads.last?.startTime ?? 0) - 40) < 1.5)
        rig.teardown()
    }

    @Test func aLoadThatHangsOnlineIsRetried() async {
        let rig = ChaosRig()
        rig.engine.loadFaults = [.hang]
        Task { await rig.controller.play(PB.tracks(3)) }
        await rig.run(80)
        #expect(rig.engine.state.status == .loading)
        await rig.run(20)
        #expect(rig.engine.state.status == .playing && rig.nowID == "t1" && rig.engine.loads.count == 2)
        rig.teardown()
    }

    // MARK: Sleep

    @Test func sleepPausesAndWakeTellsTheEngine() async {
        let rig = ChaosRig()
        await rig.controller.play(PB.tracks(3))
        await rig.run(5)
        #expect(rig.controller.activityLevel == .playing)
        rig.controller.systemWillSleep()
        await rig.settle()
        #expect(rig.engine.state.status == .paused && rig.controller.activityLevel == .none)
        rig.controller.systemDidWake(after: 3600)
        #expect(rig.engine.wakes == [3600])
        await rig.run(10)
        #expect(rig.engine.state.status == .paused, "nothing resumes by itself")
        rig.teardown()
    }

    // MARK: Native engine pieces

    @Test func theNativeWatchdogNoticesAClockThatStopped() {
        var watch = QTProgressWatch(limit: 6)
        var readings: [Bool] = []
        for (position, uptime) in [(10.0, 100.0), (12, 102), (12, 106), (12.01, 108.5)] {
            readings.append(watch.isStalled(position: position, at: uptime))
        }
        #expect(readings == [false, false, false, true])
        watch.reset()
        let afterReset = watch.isStalled(position: 12, at: 109)
        #expect(!afterReset)
    }

    @Test func onlySessionLevelErrorsTurnTheNativeEngineOff() {
        #expect(QTNativeFailure.from(QTNativeStreamError.http(403)).isSystemic)
        #expect(QTNativeFailure.from(QTNativeStreamError.http(410)).isSystemic)
        #expect(!QTNativeFailure.from(QTNativeStreamError.http(503)).isSystemic, "a passing 5xx: this item only")
        #expect(!QTNativeFailure.from(QTNativeStreamError.http(429)).isSystemic)
    }

    @Test func aWebStallInTheLastSecondsFinishesTheItem() {
        #expect(QTWebPlaybackEngine.stallAction(position: 40, duration: 200, didRetry: false) == .reload)
        #expect(QTWebPlaybackEngine.stallAction(position: 40, duration: 200, didRetry: true) == .fail)
        #expect(QTWebPlaybackEngine.stallAction(position: 198, duration: 200, didRetry: false) == .finish)
        #expect(QTWebPlaybackEngine.stallAction(position: 40, duration: 0, didRetry: false) == .reload)
    }
}
