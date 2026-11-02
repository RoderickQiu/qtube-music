import Foundation
import QTCore
import Testing
@testable import QTPlayback

/// The sleep timer (`QTSleepTimer`) on the simulated engine and a manual clock: the countdown, the fade through the
/// engine's volume, the pause that lets go of the idle-sleep assertion, the volume coming back, End of Song, and the
/// listener taking over (Turn Off, a pause or a volume change during the fade).
@MainActor
@Suite struct SleepTimerTests {
    private func rig(volume: Double = 0.8) async -> (Rig, QTSleepTimer) {
        let rig = Rig()
        let c = rig.clock
        let timer = QTSleepTimer(playback: rig.controller, now: { c.now }, schedulesTicks: false)
        await rig.controller.play(PB.tracks(3).map { PB.track($0.videoId, duration: 4000) })
        rig.controller.setVolume(volume)
        await rig.settle()
        return (rig, timer)
    }

    /// Moves the clock on and lets the timer and the state stream catch up.
    private func advance(_ rig: Rig, _ timer: QTSleepTimer, by seconds: TimeInterval) async {
        rig.advanceClock(seconds)
        timer.tick()
        await rig.settle()
    }

    // MARK: Countdown

    @Test func aLengthCountsDownWithoutTouchingTheVolume() async {
        let (rig, timer) = await rig()
        timer.start(.minutes(15))
        #expect(timer.isActive && timer.choice == .minutes(15))
        #expect(timer.remaining == 900)
        await advance(rig, timer, by: 300)
        #expect(timer.remaining == 600)
        await advance(rig, timer, by: 569)
        #expect(timer.remaining == 31 && !timer.isFading)
        #expect(rig.engine.state.volume == 0.8 && rig.engine.state.isPlaying)
    }

    @Test func choosingAgainStartsOverFromNow() async {
        let (rig, timer) = await rig()
        timer.start(.minutes(30))
        await advance(rig, timer, by: 600)
        timer.start(.minutes(30))
        #expect(timer.remaining == 1800)
        timer.start(.minutes(15))
        #expect(timer.choice == .minutes(15) && timer.remaining == 900)
    }

    @Test func aCustomRemainingTimeChecksTheLengthThatCoversIt() {
        #expect(QTSleepTimerChoice.preset(covering: 754) == .minutes(15))
        #expect(QTSleepTimerChoice.preset(covering: 900) == .minutes(15))
        #expect(QTSleepTimerChoice.preset(covering: 901) == .minutes(30))
        #expect(QTSleepTimerChoice.preset(covering: 3 * 3600) == .minutes(90))
    }

    // MARK: Fade, pause, volume back

    @Test func theLastThirtySecondsFadeThroughTheEngineVolume() async {
        let (rig, timer) = await rig()
        timer.start(.minutes(15), remaining: 40)
        await advance(rig, timer, by: 10)
        #expect(timer.isFading && rig.engine.state.volume == 0.8, "the fade starts at full volume")
        var volumes = [rig.engine.state.volume]
        for _ in 0..<59 {
            await advance(rig, timer, by: QTSleepTimer.fadeStep)
            volumes.append(rig.engine.state.volume)
        }
        #expect(zip(volumes, volumes.dropFirst()).allSatisfy { $0 > $1 }, "every step is quieter")
        #expect(abs(volumes[30] - 0.8 * QTSleepTimer.fadeGain(remaining: 15)) < 1e-9)
        #expect(abs(QTSleepTimer.fadeGain(remaining: 15) - 0.25) < 1e-9)
        #expect(volumes.last! < 0.01 && rig.engine.state.isPlaying)
    }

    @Test func atTheEndPlaybackPausesTheAssertionGoesAndTheVolumeComesBack() async {
        let (rig, timer) = await rig()
        #expect(rig.controller.activityLevel == .playing, "playing keeps the Mac awake")
        timer.start(.minutes(15), remaining: 20)
        await advance(rig, timer, by: 10)
        #expect(rig.engine.state.volume < 0.8)
        await advance(rig, timer, by: 10)
        #expect(rig.engine.state.status == .paused && !rig.controller.wantsPlayback)
        #expect(rig.controller.activityLevel == .none, "the idle-sleep assertion is let go")
        #expect(rig.engine.state.volume == 0.8, "the next Play isn't silent")
        #expect(!timer.isActive && !timer.isFading && timer.remaining == nil)
        rig.controller.play()
        await rig.settle()
        #expect(rig.engine.state.isPlaying && rig.engine.state.volume == 0.8)
    }

    @Test func aTimerThatRunsOutWhilePausedJustTurnsOff() async {
        let (rig, timer) = await rig()
        timer.start(.minutes(15), remaining: 60)
        rig.controller.pause()
        await advance(rig, timer, by: 45)
        #expect(!timer.isFading && rig.engine.state.volume == 0.8, "nothing to fade while paused")
        await advance(rig, timer, by: 15)
        #expect(!timer.isActive && rig.engine.state.status == .paused && rig.engine.state.volume == 0.8)
    }

    @Test func playingAgainInsideTheFadeWindowPicksUpTheFadeWhereItIs() async {
        let (rig, timer) = await rig()
        timer.start(.minutes(15), remaining: 60)
        rig.controller.pause()
        await advance(rig, timer, by: 45)
        rig.controller.play()
        await rig.settle()
        timer.tick()
        #expect(timer.isFading && abs(rig.engine.state.volume - 0.8 * QTSleepTimer.fadeGain(remaining: 15)) < 1e-9)
    }

    @Test func nextDuringTheFadeKeepsFading() async {
        let (rig, timer) = await rig()
        timer.start(.minutes(15), remaining: 20)
        await advance(rig, timer, by: 10)
        let faded = rig.engine.state.volume
        await rig.controller.next()
        await advance(rig, timer, by: 1)
        #expect(rig.nowID == "t2" && timer.isFading && rig.engine.state.volume < faded)
        await advance(rig, timer, by: 9)
        #expect(rig.engine.state.status == .paused && rig.engine.state.volume == 0.8)
    }

    // MARK: The listener takes over

    @Test func turnOffDuringTheFadeRestoresTheVolumeAndKeepsPlaying() async {
        let (rig, timer) = await rig()
        timer.start(.minutes(15), remaining: 20)
        await advance(rig, timer, by: 10)
        #expect(rig.engine.state.volume < 0.8)
        timer.turnOff()
        await rig.settle()
        #expect(!timer.isActive && rig.engine.state.volume == 0.8 && rig.engine.state.isPlaying)
        await advance(rig, timer, by: 30)
        #expect(rig.engine.state.isPlaying && rig.engine.state.volume == 0.8, "nothing fires after Turn Off")
    }

    @Test func turnOffDuringTheCountdownChangesNothing() async {
        let (rig, timer) = await rig()
        timer.start(.minutes(45))
        timer.turnOff()
        await advance(rig, timer, by: 45 * 60)
        #expect(!timer.isActive && rig.engine.state.isPlaying && rig.engine.state.volume == 0.8)
    }

    @Test func pausingDuringTheFadeEndsTheTimerWithTheVolumeBack() async {
        let (rig, timer) = await rig()
        timer.start(.minutes(15), remaining: 20)
        await advance(rig, timer, by: 10)
        rig.controller.pause()
        await advance(rig, timer, by: QTSleepTimer.fadeStep)
        #expect(!timer.isActive && rig.engine.state.volume == 0.8 && rig.engine.state.status == .paused)
    }

    @Test func settingTheVolumeDuringTheFadeKeepsTheListenersVolume() async {
        let (rig, timer) = await rig()
        timer.start(.minutes(15), remaining: 20)
        await advance(rig, timer, by: 10)
        // QTPlayerModel.setVolume: the listener's volume.
        timer.listenerChangedVolume()
        rig.controller.setVolume(0.5)
        await advance(rig, timer, by: 20)
        #expect(!timer.isActive && rig.engine.state.volume == 0.5 && rig.engine.state.isPlaying)
    }

    @Test func settingTheVolumeBeforeTheFadeKeepsTheTimer() async {
        let (rig, timer) = await rig()
        timer.start(.minutes(15), remaining: 60)
        timer.listenerChangedVolume()
        rig.controller.setVolume(0.6)
        await advance(rig, timer, by: 30)
        #expect(timer.isFading && rig.engine.state.volume == 0.6, "the fade starts from the new volume")
        await advance(rig, timer, by: 30)
        #expect(rig.engine.state.status == .paused && rig.engine.state.volume == 0.6)
    }

    // MARK: End of Song

    @Test func endOfSongCuesTheNextSongInsteadOfPlayingIt() async {
        let rig = Rig()
        let c = rig.clock
        let timer = QTSleepTimer(playback: rig.controller, now: { c.now }, schedulesTicks: false)
        await rig.controller.play(PB.tracks(3))
        rig.controller.setVolume(0.8)
        timer.start(.endOfSong)
        #expect(timer.isActive && timer.remaining == nil && rig.controller.stopsAtEndOfItem)
        await rig.finishTrack()
        #expect(rig.nowID == "t2" && rig.historyIDs == ["t1"], "the queue moved on")
        #expect(rig.engine.state.item?.track.videoId == "t2" && rig.engine.state.status == .paused, "cued, not playing")
        #expect(!rig.controller.wantsPlayback && rig.controller.activityLevel == .none)
        #expect(!timer.isActive && !rig.controller.stopsAtEndOfItem && rig.engine.state.volume == 0.8)
        rig.controller.play()
        await rig.finishTrack()
        #expect(rig.nowID == "t3" && rig.engine.state.isPlaying, "only the one song stopped")
    }

    @Test func endOfSongUnderRepeatOneStopsAtTheStart() async {
        let rig = Rig()
        let c = rig.clock
        let timer = QTSleepTimer(playback: rig.controller, now: { c.now }, schedulesTicks: false)
        await rig.controller.play(PB.tracks(2))
        rig.controller.repeatMode = .one
        timer.start(.endOfSong)
        await rig.finishTrack()
        #expect(rig.nowID == "t1" && rig.engine.state.status == .paused)
        #expect(rig.engine.state.timeline.time(atUptime: c.now) == 0 && !timer.isActive)
    }

    @Test func endOfSongFollowsNextToTheSongThatsPlaying() async {
        let rig = Rig()
        let c = rig.clock
        let timer = QTSleepTimer(playback: rig.controller, now: { c.now }, schedulesTicks: false)
        await rig.controller.play(PB.tracks(3))
        timer.start(.endOfSong)
        await rig.controller.next()
        await rig.settle()
        #expect(rig.engine.state.isPlaying && timer.isActive)
        await rig.finishTrack()
        #expect(rig.nowID == "t3" && rig.engine.state.status == .paused && !timer.isActive)
    }

    @Test func endOfSongHandsTheEngineNoNextSoGaplessCantCarryOn() async {
        let rig = ChaosRig(continuation: false)
        let c = rig.clock
        let timer = QTSleepTimer(playback: rig.controller, now: { c.now }, schedulesTicks: false)
        await rig.controller.play(PB.tracks(3))
        await rig.settle()
        #expect(rig.engine.prepared?.track.videoId == "t2")
        timer.start(.endOfSong)
        #expect(rig.engine.prepared == nil)
        timer.turnOff()
        #expect(rig.engine.prepared?.track.videoId == "t2", "Turn Off hands it back")
        rig.teardown()
    }

    @Test func switchingFromEndOfSongToALengthStopsWaitingForTheEnd() async {
        let rig = Rig()
        let c = rig.clock
        let timer = QTSleepTimer(playback: rig.controller, now: { c.now }, schedulesTicks: false)
        await rig.controller.play(PB.tracks(3))
        timer.start(.endOfSong)
        timer.start(.minutes(60))
        #expect(!rig.controller.stopsAtEndOfItem)
        await rig.finishTrack()
        #expect(rig.nowID == "t2" && rig.engine.state.isPlaying && timer.choice == .minutes(60))
    }
}
