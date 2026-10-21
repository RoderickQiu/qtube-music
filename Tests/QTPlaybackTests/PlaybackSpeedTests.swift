@preconcurrency import AVFoundation
import Foundation
import MediaPlayer
import QTCore
import Testing
@testable import QTPlayback

/// Playback speed (docs/prelaunch-implementation.md §9) on every engine and around them: the queue's rate reaching each
/// engine (and again on every load and engine swap), timelines at the speed, ads at 1×, Now Playing and the remote
/// rate command, the web engine's page protocol and line-up math, and the native graph's time pitch.
@MainActor
@Suite struct PlaybackSpeedTests {
    // MARK: The speed values

    @Test func speedsAreNormalizedAndStepped() {
        #expect(QTPlaybackSpeed.normalized(1.5) == 1.5)
        #expect(QTPlaybackSpeed.normalized(3) == 2 && QTPlaybackSpeed.normalized(0.1) == 0.5)
        #expect(QTPlaybackSpeed.normalized(.nan) == 1 && QTPlaybackSpeed.normalized(-1) == 1)
        #expect(QTPlaybackSpeed.normalized(1.2345) == 1.25)
        #expect(QTPlaybackSpeed.faster(than: 1) == 1.25 && QTPlaybackSpeed.faster(than: 2) == nil)
        #expect(QTPlaybackSpeed.slower(than: 1) == 0.75 && QTPlaybackSpeed.slower(than: 0.5) == nil)
        // Off the grid (a remote's 1.1×): the next choice either way.
        #expect(QTPlaybackSpeed.faster(than: 1.1) == 1.25 && QTPlaybackSpeed.slower(than: 1.1) == 1)
        #expect(QTPlaybackSpeed.label(1.5, locale: Locale(identifier: "en_US")) == "1.5×")
        #expect(QTPlaybackSpeed.label(2, locale: Locale(identifier: "en_US")) == "2×")
        #expect(QTPlaybackSpeed.label(0.75, locale: Locale(identifier: "de_DE")) == "0,75×")
    }

    @Test func theSpeedIsSavedWithThePlaybackSettings() throws {
        var prefs = QTPlaybackEffectsPrefs()
        #expect(prefs.playbackRate == 1)
        prefs.playbackRate = 1.75
        let decoded = try JSONDecoder().decode(QTPlaybackEffectsPrefs.self, from: JSONEncoder().encode(prefs))
        #expect(decoded.playbackRate == 1.75)
        // Settings saved before speeds existed, and a speed out of range, still load.
        let old = try JSONDecoder().decode(QTPlaybackEffectsPrefs.self, from: Data(#"{"gapless":false}"#.utf8))
        #expect(old.playbackRate == 1 && !old.gapless)
        let wild = try JSONDecoder().decode(QTPlaybackEffectsPrefs.self, from: Data(#"{"playbackRate":9}"#.utf8))
        #expect(wild.playbackRate == 2)
    }

    // MARK: Simulated engine

    @Test func theSimulatedClockRunsAtTheSpeed() async {
        let rig = Rig()
        rig.controller.setRate(1.5)
        await rig.controller.play(PB.tracks(2))
        await rig.settle()
        #expect(rig.engine.rate == 1.5 && rig.engine.state.timeline.rate == 1.5)
        rig.advanceClock(10)
        #expect(abs(rig.controller.currentTime - 15) < 0.001)
        rig.controller.pause()
        #expect(rig.engine.state.timeline.rate == 0)
        rig.controller.play()
        #expect(rig.engine.state.timeline.rate == 1.5)
        // Changing speed mid-track re-anchors: no jump in position.
        rig.controller.setRate(2)
        #expect(abs(rig.controller.currentTime - 15) < 0.001 && rig.engine.state.timeline.rate == 2)
        // The 100 s track ends 42.5 s of wall time later at 2×, and the next one plays at 2× too.
        rig.advanceClock(42.4)
        rig.engine.tick()
        await rig.settle()
        #expect(rig.nowID == "t1")
        await rig.finishTrack()
        #expect(rig.nowID == "t2" && rig.engine.state.timeline.rate == 2)
    }

    @Test func adsAlwaysPlayAtNormalSpeed() async {
        let rig = Rig()
        rig.engine.account = .free
        rig.controller.setRate(2)
        await rig.controller.play(PB.tracks(1))
        await rig.settle()
        #expect(rig.engine.state.ad != nil && rig.engine.state.timeline.rate == 0)
        // The ad counts down in real seconds.
        rig.advanceClock(4)
        rig.engine.tick()
        #expect(abs((rig.engine.state.ad?.remaining ?? 0) - (QTSimulatedPlaybackEngine.adDuration - 4)) < 0.001)
        rig.advanceClock(QTSimulatedPlaybackEngine.adDuration)
        rig.engine.tick()
        #expect(rig.engine.state.ad == nil && rig.engine.state.timeline.rate == 2)
    }

    // MARK: The queue carries the speed

    @Test func theRateIsReappliedOnEveryLoadAndEngineSwap() async {
        let clock = ManualClock()
        let first = ChaosEngine(clock: clock)
        let controller = QTQueueController(engine: first, uptime: { clock.now }, supervision: nil)
        var saved: [Double] = []
        controller.onRateChange = { saved.append($0) }
        controller.setRate(1.25)
        controller.setRate(1.25)
        #expect(saved == [1.25], "one change, one save")
        await controller.play(PB.tracks(3))
        #expect(first.rate == 1.25 && first.state.timeline.rate == 1.25)

        // Something reset the engine's speed (a fresh page, a crash): the next load puts it back.
        first.setRate(1)
        await controller.next()
        #expect(first.rate == 1.25 && first.state.timeline.rate == 1.25)

        // A new engine (sign-in, native on/off) starts at the listener's speed, at the same position.
        let second = ChaosEngine(clock: clock)
        await controller.replaceEngine(second)
        #expect(second.rate == 1.25 && second.state.timeline.rate == 1.25)
        #expect(second.loads.last?.track.videoId == "t2")

        // Song⇄Video keeps it.
        await controller.setMode(.video)
        #expect(second.rate == 1.25)
        // Out of range from anywhere: clamped.
        controller.setRate(5)
        #expect(controller.rate == 2 && second.rate == 2 && saved.last == 2)
        first.finish()
        second.finish()
    }

    @Test func nearTheEndMeansSecondsOfListening() async {
        // A stale next found in the current track's last seconds moves on instead of replaying them: at 2× "the last
        // 3 s" are 6 s of the track.
        let rig = ChaosRig(continuation: false)
        rig.controller.setRate(2)
        await rig.controller.play(PB.tracks(3).map { var t = $0; t.duration = 100; return t })
        await rig.settle()
        rig.controller.seek(to: 94.5)
        rig.engine.reportStaleItem()
        await rig.run(3)
        #expect(rig.nowID == "t2", "moved on to what's queued")
        rig.teardown()
    }

    // MARK: Now Playing and the remote rate command

    @Test func nowPlayingReportsTheSpeed() {
        let track = PB.track("np")
        var state = QTPlaybackState(item: QTPlaybackItem(track: track), status: .playing,
                                    timeline: QTPlaybackTimeline(time: 30, rate: 1.5, anchorUptime: 100, duration: 100),
                                    duration: 100)
        let s = QTNowPlayingSnapshot(track: track, state: state, isLiked: false, adLabel: "Ad", uptime: 102)
        #expect(s.rate == 1.5 && abs(s.elapsed - 33) < 0.001)
        #expect(s.info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.5)
        #expect(s.info[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double == 1)
        state.status = .paused
        state.timeline.rate = 0
        #expect(QTNowPlayingSnapshot(track: track, state: state, isLiked: false, adLabel: "Ad").rate == 0)
        // An ad counts down at 1× whatever the speed.
        state.status = .playing
        state.ad = QTAdState(duration: 15, remaining: 10, skippableIn: nil)
        #expect(QTNowPlayingSnapshot(track: track, state: state, isLiked: false, adLabel: "Ad").rate == 1)
    }

    @Test func theRemoteRateCommandSetsTheSpeed() async {
        let center = RecordingInfoCenter()
        let np = QTNowPlayingController(center: center, commandCenter: nil, artworkLoader: { _ in nil })
        let rig = Rig(nowPlaying: np)
        var saved: [Double] = []
        rig.controller.onRateChange = { saved.append($0) }
        await rig.controller.play(PB.tracks(2))
        await rig.settle()
        #expect(np.handle(.setRate(1.5)))
        await rig.settle()
        #expect(rig.controller.rate == 1.5 && rig.engine.rate == 1.5 && saved == [1.5])
        #expect(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.5)
        #expect(np.handle(.setRate(0.1)))
        #expect(rig.controller.rate == 0.5)
    }

    // MARK: Web engine

    @Test func bridgeSamplesCarryTheMediaRate() throws {
        let s = try #require(QTWebPlaybackSample(["gen": 1, "t": 10.0, "rate": 1.5]))
        #expect(s.rate == 1.5)
        #expect(try #require(QTWebPlaybackSample(["gen": 1])).rate == 0, "not reported")
        let boot = QTWebPlaybackBridgeScript.bootstrap(generation: 1, videoID: "x", hold: false, volume: 1, muted: false,
                                                       silent: true, rate: 1.75)
        #expect(boot.contains("\"rate\":1.75"))
    }

    @Test func aStallNearTheEndCountsSecondsOfListening() {
        #expect(QTWebPlaybackEngine.stallAction(position: 195, duration: 200, didRetry: false) == .reload)
        #expect(QTWebPlaybackEngine.stallAction(position: 195, duration: 200, didRetry: false, rate: 2) == .finish)
        #expect(QTWebPlaybackEngine.stallAction(position: 198, duration: 200, didRetry: true, rate: 0.5) == .fail)
    }

    @Test func theWebEngineAsksThePageAndFollowsItsReports() async throws {
        let pages = QTFakePlayerPages()
        let engine = pages.engine
        try await engine.load(QTPlaybackItem(track: QTModeSwitchBehaviourTests.song, startTime: 30), autoplay: true)
        try await pages.until { engine.state.status == .playing }
        engine.setRate(1.5)
        #expect(engine.state.timeline.rate == 1.5, "the timeline moves at once")
        #expect(engine.audio.rate == 1.5)
        try await pages.until { !pages.calls(on: .main, "rate").isEmpty }
        #expect(pages.calls(on: .main, "rate").last?.args.first as? Double == 1.5)

        // The page reports what its media really does (YouTube put 1× back for a moment): the clock follows.
        let gen = engine.generation
        func sample(rate: Double?, ad: Bool = false) -> [String: Any] {
            var s: [String: Any] = ["type": "state", "gen": gen, "vid": QTModeSwitchBehaviourTests.songID, "match": true,
                                    "t": 40.0, "d": 200.0, "paused": false, "ps": 1, "buffering": false, "rs": 4,
                                    "ad": ad ? ["duration": 15.0, "remaining": 9.0] as [String: Any] : NSNull()]
            if let rate { s["rate"] = rate }
            return s
        }
        engine.receive(sample(rate: 1))
        #expect(engine.state.timeline.rate == 1)
        engine.receive(sample(rate: 1.5))
        #expect(engine.state.timeline.rate == 1.5)
        // A page without the rate script: the asked rate.
        engine.receive(sample(rate: nil))
        #expect(engine.state.timeline.rate == 1.5)
        // An ad: the content clock stands still (the ad plays at 1× in the page).
        engine.receive(sample(rate: 1, ad: true))
        #expect(engine.state.timeline.rate == 0 && engine.state.ad != nil)
        engine.stop()
    }

    @Test func modeSwitchLineUpWaitsInWallClockTime() {
        // At 1× (unchanged): the standby starts the learnt ready time ahead, less 0.3 s.
        #expect(QTWebPlaybackEngine.standbyStart(clock: 60, shift: 0, readyEstimate: 2.5, rate: 1) == 62.2)
        // At 2× the old page moves twice as far meanwhile.
        #expect(QTWebPlaybackEngine.standbyStart(clock: 60, shift: 0, readyEstimate: 2.5, rate: 2) == 64.4)
        #expect(QTWebPlaybackEngine.standbyStart(clock: 60, shift: 5, readyEstimate: 0.5, rate: 1.5) == 65.75)
        // A standby held 0.6 s of media ahead: 0.6 s to wait at 1×, 0.4 s at 1.5×, less the resume latency.
        #expect(abs(QTWebPlaybackEngine.lineUpWait(standby: 70.6, clock: 70, shift: 0, playLatency: 0.04, rate: 1) - 0.56) < 1e-9)
        #expect(abs(QTWebPlaybackEngine.lineUpWait(standby: 70.6, clock: 70, shift: 0, playLatency: 0.04, rate: 1.5) - 0.36) < 1e-9)
        #expect(abs(QTWebPlaybackEngine.lineUpWait(standby: 80.6, clock: 70, shift: 10, playLatency: 0, rate: 0.5) - 1.2) < 1e-9)
    }

    @Test func theSpectrumTapStepsThroughTheStreamAtTheSpeed() async throws {
        let tap = QTWebAudioTap()
        let steps = StepLog()
        tap.fetchFrames = { _, _, step in steps.add(step); return "pending" }
        tap.rate = 2
        _ = tap.spectrum(bandCount: 8, now: 10)
        for _ in 0..<20 where steps.values.isEmpty { await Task.yield() }
        #expect(abs((steps.values.first ?? 0) - QTWebAudioTap.frameStep * 2) < 1e-12)
    }

    // MARK: Native engine

    @Test func nativeHandOverLinesUpAtTheSpeed() {
        #expect(QTNativePlaybackEngine.handOverStart(clock: 50, shift: 0, startEstimate: 2, rate: 1) == 52)
        #expect(QTNativePlaybackEngine.handOverStart(clock: 50, shift: 0, startEstimate: 2, rate: 1.5) == 53)
        // The page 0.9 s of media ahead: held 0.86 s at 1×, 0.56 s at 1.5×.
        guard case .hold(let h1) = QTNativePlaybackEngine.lineUp(page: 60.9, song: 60, shift: 0, rate: 1, firstAttempt: true),
              case .hold(let h15) = QTNativePlaybackEngine.lineUp(page: 60.9, song: 60, shift: 0, rate: 1.5, firstAttempt: true)
        else { Issue.record("expected holds"); return }
        #expect(abs(h1 - 0.86) < 1e-9 && abs(h15 - 0.56) < 1e-9)
        // Behind: seek ahead by what a seek takes, in media time.
        #expect(QTNativePlaybackEngine.lineUp(page: 59, song: 60, shift: 0, rate: 2, firstAttempt: true) == .seekAhead(62.4))
        #expect(QTNativePlaybackEngine.lineUp(page: 59, song: 60, shift: 0, rate: 2, firstAttempt: false) == .none)
        // 10 s of media ahead is 5 s at 2×: still worth holding (under 8 s), but not at 1×.
        #expect(QTNativePlaybackEngine.lineUp(page: 70, song: 60, shift: 0, rate: 1, firstAttempt: true) == .none)
        if case .hold = QTNativePlaybackEngine.lineUp(page: 70, song: 60, shift: 0, rate: 2, firstAttempt: true) {} else {
            Issue.record("expected a hold at 2×")
        }
    }
}

/// The native graph's time pitch, rendered offline: out of the chain at 1× (bit-exact with the graph before speeds
/// existed — a merely bypassed unit still rounds by an ulp), and positions in source frames at 1.5×.
@Suite struct NativeTimePitchTests {
    private struct Render {
        var out: [Float]
        var position: TimeInterval?
        var unit: AVAudioUnitTimePitch?
        var inChain: Bool
    }

    private static func render(rate: Double?, frames total: Int) async throws -> Render {
        let data = try NativeEngineTests.encodedSweep(seconds: 2)
        let file = try QTNativeMemoryAudioFile(bytes: QTNativeAudioBytes(data))
        let engine = AVAudioEngine()
        let format = file.format
        let queue = DispatchQueue(label: "test.timepitch")
        let deck = QTNativeDeck(name: "T", queue: queue, format: format)
        // The player's chain: deck → mixer → (time pitch) → EQ (flat: bypassed) → main mixer.
        let mixer = AVAudioMixerNode()
        let eq = AVAudioUnitEQ(numberOfBands: 10)
        eq.bypass = true
        for node in [deck.node, mixer, eq] as [AVAudioNode] { engine.attach(node) }
        engine.connect(deck.node, to: mixer, fromBus: 0, toBus: 0, format: format)
        var unit: AVAudioUnitTimePitch?
        if let rate {
            // As QTNativeAudioPlayer builds it.
            let pitch = AVAudioUnitTimePitch()
            QTNativeAudioPlayer.configure(pitch, rate: rate)
            engine.attach(pitch)
            QTNativeAudioPlayer.connectSpeedStage(in: engine, from: mixer, through: pitch, to: eq, format: format, rate: rate)
            unit = pitch
        } else {
            // The graph before playback speed existed.
            engine.connect(mixer, to: eq, format: format)
        }
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        let inChain = unit.map { !engine.outputConnectionPoints(for: $0, outputBus: 0).isEmpty } ?? false
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        try queue.sync { try deck.start(file, token: 1, atFrame: 0, gain: 1) }
        deck.node.play()
        var rendered: [Float] = []
        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        while rendered.count < total {
            let n = AVAudioFrameCount(min(1024, total - rendered.count))
            guard try engine.renderOffline(n, to: out) == .success else { break }
            rendered.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
            try await Task.sleep(for: .milliseconds(2))  // the deck refills on its queue
        }
        let position = queue.sync { deck.position(of: 1) }
        engine.stop()
        return Render(out: rendered, position: position, unit: unit, inChain: inChain)
    }

    @Test func normalSpeedIsBitExact() async throws {
        let before = try await Self.render(rate: nil, frames: 44_100)
        let normal = try await Self.render(rate: 1, frames: 44_100)
        #expect(!normal.inChain && normal.unit?.bypass == true)
        #expect(before.out.count == 44_100 && normal.out == before.out, "identical samples at 1×")
        #expect(abs((normal.position ?? 0) - 1) < 0.05)
    }

    @Test func atOneAndAHalfPositionsStayInSourceFrames() async throws {
        let rendered = try await Self.render(rate: 1.5, frames: 44_100)
        #expect(rendered.inChain && rendered.unit?.bypass == false && rendered.unit?.rate == 1.5)
        // One second of output took 1.5 s of the track (the unit reads a little ahead for its window).
        let position = try #require(rendered.position)
        #expect(position > 1.4 && position < 1.75, "position \(position)")
        // Pitch kept, not silence.
        #expect(rendered.out.contains { abs($0) > 0.05 })
    }
}

private final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [TimeInterval] = []
    var values: [TimeInterval] { lock.withLock { steps } }
    func add(_ step: TimeInterval) { lock.withLock { steps.append(step) } }
}
