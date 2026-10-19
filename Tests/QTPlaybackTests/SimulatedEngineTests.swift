import Foundation
import QTCore
import Testing
@testable import QTPlayback

@MainActor
final class ManualClock {
    var now: TimeInterval = 1000
}

@MainActor
@Suite struct SimulatedEngineTests {
    let clock = ManualClock()
    let track = QTTrack(videoId: "t", title: "T", artists: [QTArtistRef(name: "A")], duration: 100)

    func engine(_ account: QTSimulatedPlaybackEngine.Account = .premium) -> QTSimulatedPlaybackEngine {
        let c = clock
        return QTSimulatedPlaybackEngine(account: account, clock: { c.now }, tickInterval: nil)
    }

    @Test func playPauseSeekFollowTheClock() async throws {
        let e = engine()
        try await e.load(QTPlaybackItem(track: track, startTime: 10), autoplay: true)
        #expect(e.state.status == .playing)
        clock.now += 5
        #expect(abs(e.state.timeline.time(atUptime: clock.now) - 15) < 1e-9)
        e.pause()
        clock.now += 30
        #expect(abs(e.state.timeline.time(atUptime: clock.now) - 15) < 1e-9)
        e.seek(to: 50)
        #expect(e.state.timeline.time == 50 && e.state.status == .paused)
        e.play()
        clock.now += 1
        #expect(abs(e.state.timeline.time(atUptime: clock.now) - 51) < 1e-9)
        #expect(e.capabilities == .premium)
    }

    @Test func reachesEnded() async throws {
        let e = engine()
        try await e.load(QTPlaybackItem(track: track, startTime: 95), autoplay: true)
        clock.now += 6
        e.tick()
        #expect(e.state.status == .ended)
        #expect(e.state.timeline.time == 100)
    }

    @Test func freeAccountPlaysASkippableAdFirst() async throws {
        let e = engine(.free)
        #expect(e.capabilities == .free)
        try await e.load(QTPlaybackItem(track: track), autoplay: true)
        #expect(e.state.ad?.remaining == 12)
        #expect(e.state.ad?.canSkip == false)
        e.seek(to: 40) // ignored during ads
        #expect(e.state.timeline.time == 0)
        clock.now += 3
        e.tick()
        #expect(e.state.ad?.skippableIn == 2)
        e.skipAd()
        #expect(e.state.ad != nil)
        clock.now += 2
        e.tick()
        #expect(e.state.ad?.canSkip == true)
        e.skipAd()
        #expect(e.state.ad == nil)
        #expect(e.state.timeline.rate == 1)
    }

    @Test func adPausesWithPlaybackAndEndsByItself() async throws {
        let e = engine(.free)
        try await e.load(QTPlaybackItem(track: track), autoplay: true)
        clock.now += 4
        e.pause()
        clock.now += 100
        e.tick()
        #expect(e.state.ad?.remaining == 8)
        e.play()
        clock.now += 8
        e.tick()
        #expect(e.state.ad == nil)
        #expect(e.state.status == .playing)
    }

    @Test func unavailableTracksFail() async {
        let e = engine()
        var locked = track
        locked.availability = .regionLocked
        await #expect(throws: QTPlaybackError.self) { try await e.load(QTPlaybackItem(track: locked), autoplay: true) }
        #expect(e.state.status == .failed(.unavailable(.regionLocked)))
    }

    @Test func stateStreamYieldsCurrentStateThenChanges() async throws {
        let e = engine()
        var it = e.stateUpdates().makeAsyncIterator()
        let first = await it.next()
        #expect(first?.status == .idle)
        try await e.load(QTPlaybackItem(track: track), autoplay: false)
        let second = await it.next()
        #expect(second?.status == .paused)
        #expect(second?.duration == 100)
    }

    @Test func timelineInterpolatesAndClamps() {
        let t = QTPlaybackTimeline(time: 10, rate: 1, anchorUptime: 0, duration: 12)
        #expect(t.time(atUptime: 1) == 11)
        #expect(t.time(atUptime: 50) == 12)
        #expect(QTPlaybackTimeline(time: 10, rate: 0, anchorUptime: 0).time(atUptime: 50) == 10)
    }
}
