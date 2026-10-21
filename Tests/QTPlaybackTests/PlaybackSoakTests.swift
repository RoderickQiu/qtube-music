import Foundation
import QTCore
import Testing
@testable import QTPlayback

/// A seeded random soak of the queue on a `ChaosEngine` (docs/prelaunch-implementation.md §3): 1,000 steps of listener
/// actions (speed changes from the menu and from remotes among them), virtual time and faults — failed, hung and offline
/// loads, pauses the page makes, stalls, crashes, missed ends, stale items, gapless moves, radio that fails or hangs,
/// sleep — with the invariants checked after every step and every virtual second:
/// 1. Listening, something to play and online: the engine is playing or loading within 60 s, or the listener was told.
/// 2. No load in flight: the queue's current item is the engine's (within a few seconds of grace).
/// 3. No queue id appears twice (Now Playing, Up Next, Autoplay).
/// 4. Now Playing shows the queue's current track, playing exactly when the engine plays (or loads for a listener who
///    wants it).
/// 5. The sleep assertion is held exactly while something plays.
/// 6. No load stays in flight (or the engine loading) for more than 2 min online.
/// 7. The engine plays at the listener's speed, its clock moves at it while playing, and Now Playing says so.
/// 8. Once the listener or the app paused (a pause, a remote or Picture in Picture pause, sleep, the queue giving up or
///    reaching its end), nothing plays until the listener asks for music again (Play, Next, a track, PiP's Play).
/// 9. App Nap is held off (busy) only while the listener wants music.
/// Deterministic: the seed picks every step; nothing sleeps in real time.
@MainActor
@Suite struct PlaybackSoakTests {
    @Test(arguments: [UInt64(20_261_020), 7, 424_242])
    func aThousandRandomStepsKeepTheInvariants(seed: UInt64) async {
        let soak = Soak(seed: seed)
        await soak.run(steps: 1000)
        #expect(soak.violations.isEmpty, "seed \(seed): \(soak.violations.first ?? "")")
        // The soak did exercise the queue: tracks played, faults landed, recoveries happened.
        #expect(soak.rig.controller.playSerial > 50, "seed \(seed): only \(soak.rig.controller.playSerial) listens")
        #expect(soak.faults > 100)
        #expect(soak.rig.engine.rateChanges > 10, "seed \(seed): the speed changed along the way")
        soak.rig.teardown()
    }
}

@MainActor
private final class Soak {
    let rig: ChaosRig
    private var rng: SplitMix64
    private(set) var violations: [String] = []
    private(set) var faults = 0
    private var trace: [String] = []
    private var trackCounter = 0
    private var listeningIdleSince: TimeInterval?
    private var mismatchSince: TimeInterval?
    private var nowPlayingMismatchSince: TimeInterval?
    private var nowPlayingRateSince: TimeInterval?
    private var loadWatch: (token: Int, online: TimeInterval)?
    private var engineLoadingOnline: TimeInterval = 0
    private var engineLoadingToken = 0
    /// Invariant 8: the listener or the app paused, and nobody has asked for music since.
    private var held = false
    private var lastWants = false

    init(seed: UInt64) {
        rig = ChaosRig(seed: seed)
        rng = SplitMix64(seed: seed &* 31 &+ 1)
    }

    private func roll(_ n: Int) -> Int { Int(rng.next() % UInt64(n)) }
    private func chance(_ percent: Int) -> Bool { roll(100) < percent }

    private func newTracks(_ n: Int) -> [QTTrack] {
        (0..<n).map { _ in
            trackCounter += 1
            var t = PB.track("s\(trackCounter)", duration: TimeInterval(30 + roll(60)), playable: !chance(5))
            if chance(30) { t.counterpart = QTCounterpart(videoId: "s\(trackCounter)-mv", musicVideoType: .omv) }
            return t
        }
    }

    // MARK: Steps

    private enum Step: CaseIterable {
        // The listener
        case playList, next, previous, pause, play, remotePause, remotePlay, seek, seekNearEnd, jump, addToQueue,
             playNext, remove, clearUpNext, shuffle, cycleRepeat, setMode, toggleAutoplay, clearAll, setRate, remoteRate
        // Time
        case wait, longWait
        // Faults
        case pageCausesPause, pictureInPicturePause, pictureInPicturePlay, stall, crash, missEnd, staleItem, gaplessJoin, offline, online,
             loadFault, radioMode, sleepWake

        var weight: Int {
            switch self {
            case .playList: 3
            case .next: 6
            case .previous: 3
            case .pause: 3
            case .play: 6
            case .remotePause, .remotePlay: 2
            case .seek: 3
            case .seekNearEnd: 5
            case .jump: 2
            case .addToQueue, .playNext: 3
            case .remove: 2
            case .clearUpNext, .shuffle, .cycleRepeat, .setMode, .toggleAutoplay: 1
            case .clearAll: 1
            case .setRate: 3
            case .remoteRate: 1
            case .wait: 22
            case .longWait: 4
            case .pageCausesPause: 4
            case .pictureInPicturePause, .pictureInPicturePlay: 1
            case .stall, .crash, .missEnd, .staleItem, .gaplessJoin: 2
            case .offline: 2
            case .online: 3
            case .loadFault: 5
            case .radioMode: 2
            case .sleepWake: 1
            }
        }

        var isFault: Bool {
            switch self {
            case .pageCausesPause, .pictureInPicturePause, .pictureInPicturePlay, .stall, .crash, .missEnd, .staleItem, .gaplessJoin, .offline,
                 .loadFault, .radioMode, .sleepWake: true
            default: false
            }
        }
    }

    private func pick() -> Step {
        let total = Step.allCases.reduce(0) { $0 + $1.weight }
        var r = roll(total)
        for step in Step.allCases {
            if r < step.weight { return step }
            r -= step.weight
        }
        return .wait
    }

    func run(steps: Int) async {
        let c = rig.controller
        Task { await c.play(self.newTracks(8)) }
        await rig.run(1)
        for i in 0..<steps {
            let step = pick()
            if step.isFault { faults += 1 }
            note("\(i) t=\(Int(rig.clock.now)) \(step) now=\(rig.nowID ?? "-") engine=\(describe(rig.engine.state)) wants=\(c.wantsPlayback)")
            await perform(step)
            await rig.settle()
            check()
            if !violations.isEmpty { return }
        }
        // Let whatever is pending play out, then check once more.
        rig.engine.isNetworkAvailable = true
        await advance(30)
    }

    private func perform(_ step: Step) async {
        let c = rig.controller, e = rig.engine
        switch step {
        case .playList, .next, .previous, .play, .remotePlay, .jump, .clearAll:
            held = false   // the listener asks for music (invariant 8)
        case .pause, .remotePause, .sleepWake:
            held = true
        default:
            break
        }
        switch step {
        case .playList:
            let tracks = newTracks(2 + roll(8))
            let start = roll(tracks.count)
            Task { await c.play(tracks, startingAt: start) }
        case .next: Task { await c.next() }
        case .previous: Task { await c.previous() }
        case .pause: c.pause()
        case .play: c.play()
        case .remotePause: c.handleRemote(.pause)
        case .remotePlay: c.handleRemote(.play)
        case .seek: c.seek(to: Double(roll(80)))
        case .seekNearEnd: c.seek(to: max(0, e.state.duration - Double(1 + roll(4))))
        case .jump:
            let items = c.queue.upNext + c.queue.autoplay
            if !items.isEmpty { let item = items[roll(items.count)]; Task { await c.jump(to: item) } }
        case .addToQueue: c.addToQueue(newTracks(1 + roll(3)))
        case .playNext: c.playNext(newTracks(1 + roll(2)))
        case .remove:
            let items = c.queue.upNext + c.queue.autoplay
            if !items.isEmpty { c.remove([items[roll(items.count)].id]) }
        case .clearUpNext: c.clearUpNext()
        case .shuffle: c.setShuffle(!c.isShuffleOn)
        case .cycleRepeat: c.cycleRepeatMode()
        case .setMode: Task { await c.setMode(c.mode == .song ? .video : .song) }
        case .toggleAutoplay: c.setAutoplayEnabled(!c.queue.isAutoplayEnabled)
        case .clearAll:
            c.clearAll()
            await rig.settle()
            Task { await c.play(self.newTracks(3 + roll(6))) }
        case .setRate: c.setRate(QTPlaybackSpeed.choices[roll(QTPlaybackSpeed.choices.count)])
        case .remoteRate: c.handleRemote(.setRate(0.5 + Double(roll(16)) / 10))
        case .wait: await advance(1 + roll(20))
        case .longWait: await advance(60 + roll(120))
        case .pageCausesPause: e.pauseByItself()
        case .pictureInPicturePause:
            e.isPausedByListener = true
            e.pauseByItself()
            await advance(3)
            e.isPausedByListener = false
        case .pictureInPicturePlay:
            // Play in the PiP window after a pause there (or in the app): the listener's own.
            guard e.state.status == .paused, !c.wantsPlayback, let current = c.queue.nowPlaying,
                  c.agrees(e.state.item, with: current) else { break }
            held = false
            e.isResumedByListener = true
            e.resumeByItself()
            await rig.settle()
            e.isResumedByListener = false
        case .stall: e.stall()
        case .crash: e.crash()
        case .missEnd: e.missesNextEnd = true
        case .staleItem: e.reportStaleItem()
        case .gaplessJoin: e.joinPrepared(evenIfPaused: chance(30))
        case .offline: e.isNetworkAvailable = false
        case .online: e.isNetworkAvailable = true
        case .loadFault:
            let faults: [ChaosEngine.LoadFault] = [.fail(.unavailable(.removed)), .fail(.network("timeout")), .hang,
                                                   .delay(Double(1 + roll(10))), .fail(.engine("decoder")), .ok]
            e.loadFaults.append(faults[roll(faults.count)])
        case .radioMode:
            let modes: [ChaosRig.Radio] = [.answers, .answers, .fails, .hangs, .empty]
            rig.radio = modes[roll(modes.count)]
        case .sleepWake:
            c.systemWillSleep()
            await rig.settle()
            c.systemDidWake(after: Double(roll(2) == 0 ? 60 : 7200))
        }
    }

    /// Virtual seconds, one at a time, checking the invariants after each.
    private func advance(_ seconds: Int) async {
        for _ in 0..<seconds {
            await rig.run(1)
            check()
            if !violations.isEmpty { return }
        }
    }

    // MARK: Invariants

    private func check() {
        let c = rig.controller, e = rig.engine, s = e.state
        let now = rig.clock.now
        let current = c.queue.nowPlaying

        // 3. Unique queue ids.
        let ids = [current?.id].compactMap { $0 } + c.queue.upNext.map(\.id) + c.queue.autoplay.map(\.id)
        if Set(ids).count != ids.count {
            fail("a queue id appears twice: now \(current?.track.videoId ?? "-")")
        }

        // 5. The sleep assertion follows actual playback.
        if (c.activityLevel == .playing) != (s.status == .playing) {
            fail("sleep assertion \(c.activityLevel) while the engine is \(describe(s))")
        }

        // 1. Listening and online: playing or loading within 60 s, unless the listener was told.
        let idle = c.wantsPlayback && current != nil && e.isNetworkAvailable && s.status != .playing && s.status != .loading
        if idle {
            var since = listeningIdleSince ?? now
            if rig.lastReport > since { since = rig.lastReport }
            listeningIdleSince = since
            if now - since > 60 { fail("listening, but the engine has been \(describe(s)) for \(Int(now - since)) s with nothing said") }
        } else {
            listeningIdleSince = nil
        }

        // 2. The queue's current item is the engine's.
        if c.loadInFlight == nil {
            let agrees = current.map { c.agrees(s.item, with: $0) } ?? (s.item == nil)
            if agrees {
                mismatchSince = nil
            } else {
                let since = mismatchSince ?? now
                mismatchSince = since
                if now - since > 8 { fail("queue on \(current?.track.videoId ?? "nothing"), engine on \(s.item?.track.videoId ?? "nothing") for \(Int(now - since)) s") }
            }
        } else {
            mismatchSince = nil
        }

        // 8. Paused by the listener or the app: nothing plays until they ask for music again.
        // (Held from the moment the intent drops — not merely while it is false: Next may still be waiting for radio.)
        if lastWants, !c.wantsPlayback { held = true }
        lastWants = c.wantsPlayback
        if held, s.status == .playing {
            fail("the engine plays \(describe(s)) though the listener or the app paused and nobody asked for music since")
        }

        // 9. App Nap is held off only for a listener waiting for music.
        if c.activityLevel == .busy, !c.wantsPlayback {
            fail("busy (App Nap held off) while nobody wants music; engine \(describe(s))")
        }

        // 4. Now Playing shows the queue's track, playing exactly when the engine plays (or loads for a listener who
        // wants it: Pause in Control Center, like the app's own controls).
        let snapshot = rig.nowPlaying.snapshot
        let npPlaying = s.status == .playing || (s.status == .loading && c.wantsPlayback)
        let npAgrees = snapshot.map { $0.videoID == current?.track.videoId && ($0.playbackState == .playing) == npPlaying } ?? true
        if npAgrees {
            nowPlayingMismatchSince = nil
        } else {
            let since = nowPlayingMismatchSince ?? now
            nowPlayingMismatchSince = since
            if now - since > 8 { fail("Now Playing shows \(snapshot?.videoID ?? "-") \(String(describing: snapshot?.playbackState)), queue \(current?.track.videoId ?? "-") engine \(describe(s))") }
        }

        // 7. The listener's speed: on the engine at once, its clock at it while content plays, Now Playing soon after.
        if e.rate != c.rate { fail("engine at \(e.rate)×, the listener's speed is \(c.rate)×") }
        // (A clock that stands still while "playing" is a stall: the watch's business, not the speed's.)
        if s.status == .playing, !s.isBuffering, s.timeline.rate > 0, s.timeline.rate != c.rate {
            fail("the engine's clock runs at \(s.timeline.rate)× while playing at \(c.rate)×")
        }
        if let snap = snapshot, snap.playbackState == .playing, s.status == .playing, !s.isBuffering, s.timeline.rate > 0,
           snap.videoID == current?.track.videoId, snap.rate != c.rate {
            let since = nowPlayingRateSince ?? now
            nowPlayingRateSince = since
            if now - since > 8 { fail("Now Playing says \(snap.rate)×, playing at \(c.rate)×") }
        } else {
            nowPlayingRateSince = nil
        }

        // 6. No load or engine stays loading for more than 2 min online.
        if let token = c.loadInFlight {
            var w: (token: Int, online: TimeInterval) = loadWatch?.token == token ? loadWatch! : (token, 0)
            if e.isNetworkAvailable, let last = lastCheck { w.online += now - last }
            loadWatch = w
            if w.online > 120 { fail("a load in flight for \(Int(w.online)) s online") }
        } else {
            loadWatch = nil
        }
        // (Per load the queue asked for: a retry of a hung load may land on another hang.)
        if s.status == .loading, e.isNetworkAvailable, let last = lastCheck, engineLoadingToken == c.loadToken {
            engineLoadingOnline += now - last
            if engineLoadingOnline > 120 { fail("the engine loading for \(Int(engineLoadingOnline)) s online") }
        } else if s.status != .loading || engineLoadingToken != c.loadToken {
            engineLoadingOnline = 0
            engineLoadingToken = c.loadToken
        }
        lastCheck = now
    }

    private var lastCheck: TimeInterval?

    private func fail(_ message: String) {
        guard violations.isEmpty else { return }
        let c = rig.controller
        let context = "advances=\(c.advancesInFlight) loadInFlight=\(String(describing: c.loadInFlight)) "
            + "fetching=\(c.isFetchingAutoplay) radio=\(rig.radio) repeat=\(c.repeatMode) autoplayOn=\(c.queue.isAutoplayEnabled) "
            + "upNext=\(c.queue.upNext.map(\.track.videoId)) autoplay=\(c.queue.autoplay.map(\.track.videoId)) "
            + "notices=\(rig.notices.suffix(3)) lastReport=\(Int(rig.lastReport)) online=\(rig.engine.isNetworkAvailable)"
        violations.append("\(message) at t=\(Int(rig.clock.now))\n\(context)\nlast steps:\n" + trace.suffix(30).joined(separator: "\n"))
    }

    private func note(_ line: String) {
        trace.append(line)
        if trace.count > 60 { trace.removeFirst(trace.count - 60) }
    }

    private func describe(_ s: QTPlaybackState) -> String {
        let status: String
        switch s.status {
        case .idle: status = "idle"
        case .loading: status = "loading"
        case .playing: status = s.isBuffering ? "playing(buffering)" : "playing"
        case .paused: status = "paused"
        case .ended: status = "ended"
        case .failed(let e): status = "failed(\(e))"
        }
        return "\(status) \(s.item?.track.videoId ?? "-")"
    }
}
