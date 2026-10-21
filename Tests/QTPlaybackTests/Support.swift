import Foundation
import MediaPlayer
import QTCore
import Testing
@testable import QTPlayback

/// Deterministic generator for shuffle tests.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum PB {
    static func track(_ id: String, duration: TimeInterval = 100, playable: Bool = true) -> QTTrack {
        QTTrack(videoId: id, title: "Title \(id)", artists: [QTArtistRef(name: "Artist \(id)")],
                album: QTAlbumRef(title: "Album"), duration: duration,
                availability: playable ? .playable : .regionLocked)
    }

    static func tracks(_ n: Int, prefix: String = "t") -> [QTTrack] {
        (1...n).map { track("\(prefix)\($0)") }
    }
}

/// A simulated engine + controller on a manual clock, with helpers to let the state stream settle.
@MainActor
final class Rig {
    let clock = ManualClock()
    let engine: QTSimulatedPlaybackEngine
    let controller: QTQueueController

    init(nowPlaying: QTNowPlayingController? = nil, store: QTQueueStore? = nil, seed: UInt64 = 42) {
        let c = clock
        engine = QTSimulatedPlaybackEngine(account: .premium, clock: { c.now }, tickInterval: nil)
        controller = QTQueueController(engine: engine, nowPlaying: nowPlaying, store: store, random: SplitMix64(seed: seed),
                                       uptime: { c.now }, supervision: nil)
    }

    var nowID: String? { controller.nowPlayingTrack?.videoId }
    var upNextIDs: [String] { controller.queue.upNext.map(\.track.videoId) }
    var autoplayIDs: [String] { controller.queue.autoplay.map(\.track.videoId) }
    var historyIDs: [String] { controller.queue.history.map(\.track.videoId) }

    /// Lets the engine → controller stream and any spawned tasks run.
    func settle() async {
        for _ in 0..<40 { await Task.yield() }
    }

    /// Plays the current item to its natural end and lets the controller react.
    func finishTrack() async {
        await settle()
        let remaining = engine.state.duration - engine.state.timeline.time(atUptime: clock.now)
        clock.now += max(0, remaining) + 0.01
        engine.tick()
        await settle()
    }

    func advanceClock(_ seconds: TimeInterval) {
        clock.now += seconds
    }
}

/// Engine double that fails loading chosen ids.
@MainActor
final class FailingEngine: QTPlaybackEngine {
    var failing: Set<String>
    /// What a failing item fails with.
    var error: QTPlaybackError = .unavailable(.removed)
    var loads: [String] = []
    var capabilities: QTPlaybackCapabilities { .free }
    private(set) var state = QTPlaybackState()
    private var continuations: [UUID: AsyncStream<QTPlaybackState>.Continuation] = [:]

    init(failing: Set<String>) { self.failing = failing }

    func stateUpdates() -> AsyncStream<QTPlaybackState> {
        let (stream, c) = AsyncStream<QTPlaybackState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        c.yield(state)
        continuations[UUID()] = c
        return stream
    }

    func load(_ item: QTPlaybackItem, autoplay: Bool) async throws {
        loads.append(item.track.videoId)
        if failing.contains(item.track.videoId) {
            state = QTPlaybackState(item: item, status: .failed(error))
            for c in continuations.values { c.yield(state) }
            throw error
        }
        state = QTPlaybackState(item: item, status: autoplay ? .playing : .paused, duration: item.track.duration)
        for c in continuations.values { c.yield(state) }
    }

    func play() {}
    func pause() {}
    func seek(to time: TimeInterval) {}
    func setVolume(_ volume: Double) {}
    func setMuted(_ muted: Bool) {}
    private(set) var rate: Double = 1
    func setRate(_ rate: Double) { self.rate = rate }
    func skipAd() {}
    func stop() {}
}

/// Records what would go to MPNowPlayingInfoCenter.
@MainActor
final class RecordingInfoCenter: QTNowPlayingInfoPublishing {
    var nowPlayingInfo: [String: Any]? {
        didSet { writes += 1 }
    }
    var playbackState: MPNowPlayingPlaybackState = .unknown
    var writes = 0
}

/// An engine that misbehaves on request, on a manual clock (the reliability soak and its targeted tests). It plays
/// like the simulated engine (`tick()` moves time on and ends items); faults: loads that fail, hang, take a while or
/// wait for the network; pauses, stalls, crashes, missed ends, stale items and gapless moves it makes by itself.
@MainActor
final class ChaosEngine: QTPlaybackEngine {
    enum LoadFault: Equatable {
        /// Plays (a placeholder between faults).
        case ok
        case fail(QTPlaybackError)
        /// Never answers until superseded or stopped.
        case hang
        /// Answers after this many seconds (online).
        case delay(TimeInterval)
        /// Answers paused at its start though asked to play, and Play doesn't move it (YouTube's page on a new track);
        /// the next load is fine unless another fault says otherwise.
        case refusesStart
    }

    let clock: ManualClock
    var capabilities: QTPlaybackCapabilities { .web }
    private(set) var state = QTPlaybackState()
    var isNetworkAvailable = true {
        didSet { if isNetworkAvailable, !oldValue { resolvePending() } }
    }
    var isPausedByListener = false
    var isResumedByListener = false
    /// What the next loads do, in order (none left: they play, once online).
    var loadFaults: [LoadFault] = []
    /// Ids that always fail with this error.
    var failing: [String: QTPlaybackError] = [:]
    private(set) var loads: [QTPlaybackItem] = []
    private(set) var plays = 0
    private(set) var pauses = 0
    private(set) var wakes: [TimeInterval] = []
    private(set) var prepared: QTPlaybackItem?
    /// The current item is one it won't start (`LoadFault.refusesStart`).
    private(set) var isRefusingStart = false
    /// Loads the queue asked to start afresh (`startNextLoadAfresh` before them).
    private(set) var afreshLoads: [QTPlaybackItem] = []
    private var nextLoadAfresh = false
    /// The next end happens without a word (state changes, nothing is published).
    var missesNextEnd = false
    private var continuations: [UUID: AsyncStream<QTPlaybackState>.Continuation] = [:]
    private var pending: (item: QTPlaybackItem, autoplay: Bool, due: TimeInterval?, c: CheckedContinuation<Void, any Error>)?
    private var stalledSince: TimeInterval?

    init(clock: ManualClock) { self.clock = clock }

    func stateUpdates() -> AsyncStream<QTPlaybackState> {
        let (stream, c) = AsyncStream<QTPlaybackState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        c.yield(state)
        continuations[UUID()] = c
        return stream
    }

    private func publish() { for c in continuations.values { c.yield(state) } }

    var isLoadPending: Bool { pending != nil }

    func load(_ item: QTPlaybackItem, autoplay: Bool) async throws {
        cancelPending()
        stalledSince = nil
        loads.append(item)
        if nextLoadAfresh { afreshLoads.append(item) }
        nextLoadAfresh = false
        var fault = failing[item.track.videoId].map { LoadFault.fail($0) } ?? (loadFaults.isEmpty ? nil : loadFaults.removeFirst())
        if fault == .ok { fault = nil }
        isRefusingStart = fault == .refusesStart
        if isRefusingStart { fault = nil }
        let duration = item.track.duration
        state = QTPlaybackState(item: item, status: .loading,
                                timeline: QTPlaybackTimeline(time: item.startTime, rate: 0, anchorUptime: clock.now, duration: duration),
                                duration: duration, isBuffering: true, volume: state.volume, isMuted: state.isMuted)
        publish()
        switch fault {
        case .fail(let error)?:
            state.status = .failed(error)
            state.isBuffering = false
            publish()
            throw error
        case nil where isNetworkAvailable:
            start(item, autoplay: autoplay)
        default:
            let due: TimeInterval?
            switch fault {
            case .delay(let d)?: due = clock.now + d
            case .hang?: due = nil
            default: due = clock.now
            }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                pending = (item, autoplay, due, c)
            }
        }
    }

    private func start(_ item: QTPlaybackItem, autoplay: Bool) {
        let plays = autoplay && !isRefusingStart
        state.item = item
        state.status = plays ? .playing : .paused
        state.isBuffering = false
        state.timeline = QTPlaybackTimeline(time: min(item.startTime, item.track.duration), rate: plays ? rate : 0,
                                            anchorUptime: clock.now, duration: item.track.duration)
        publish()
    }

    private func resolvePending() {
        guard let p = pending, let due = p.due, clock.now >= due, isNetworkAvailable else { return }
        pending = nil
        start(p.item, autoplay: p.autoplay)
        p.c.resume()
    }

    private func cancelPending() {
        guard let p = pending else { return }
        pending = nil
        p.c.resume(throwing: CancellationError())
    }

    var position: TimeInterval { state.timeline.time(atUptime: clock.now) }

    func play() {
        plays += 1
        guard state.item != nil else { return }
        if pending != nil {
            // Paused while loading, wanted again: loading (as the web engine shows it).
            pending?.autoplay = true
            if state.status == .paused {
                state.status = .loading
                state.isBuffering = true
                publish()
            }
            return
        }
        // Taken, but a track the page won't start stays paused at its start.
        if isRefusingStart, state.status == .paused { return }
        let t = state.status == .ended ? 0 : position
        state.status = .playing
        state.timeline = QTPlaybackTimeline(time: t, rate: stalledSince == nil ? rate : 0, anchorUptime: clock.now, duration: state.duration)
        publish()
    }

    func pause() {
        pauses += 1
        guard state.item != nil else { return }
        if pending != nil { pending?.autoplay = false }
        guard state.status == .playing || state.status == .loading else { return }
        state.timeline = QTPlaybackTimeline(time: position, rate: 0, anchorUptime: clock.now, duration: state.duration)
        state.status = .paused
        state.isBuffering = false
        publish()
    }

    func seek(to time: TimeInterval) {
        guard state.item != nil, pending == nil else { return }
        let t = min(max(0, time), max(0, state.duration - 0.5))
        if state.status == .ended { state.status = .paused }
        state.timeline = QTPlaybackTimeline(time: t, rate: state.status == .playing && stalledSince == nil ? rate : 0,
                                            anchorUptime: clock.now, duration: state.duration)
        publish()
    }

    /// Plays at this speed from now on (the clock re-anchors where it is).
    private(set) var rate: Double = 1
    private(set) var rateChanges = 0
    func setRate(_ rate: Double) {
        guard rate != self.rate else { return }
        self.rate = rate
        rateChanges += 1
        guard state.timeline.rate > 0 else { return }
        state.timeline = QTPlaybackTimeline(time: position, rate: rate, anchorUptime: clock.now, duration: state.duration)
        publish()
    }

    func setVolume(_ volume: Double) { state.volume = volume; publish() }
    func setMuted(_ muted: Bool) { state.isMuted = muted; publish() }
    func skipAd() {}

    func stop() {
        cancelPending()
        stalledSince = nil
        state = QTPlaybackState(volume: state.volume, isMuted: state.isMuted)
        publish()
    }

    func prepareNext(_ item: QTPlaybackItem?) { prepared = item }

    func systemDidWake(after sleep: TimeInterval) { wakes.append(sleep) }

    func startNextLoadAfresh() { nextLoadAfresh = true }

    /// Moves the clock-driven parts on: delayed loads answer, stalls fail after 20 s, items end.
    func tick() {
        resolvePending()
        if let since = stalledSince, state.status == .playing, clock.now - since >= 20 {
            stalledSince = nil
            state.status = .failed(.network("stalled"))
            state.isBuffering = false
            publish()
            return
        }
        guard state.status == .playing, stalledSince == nil, state.duration > 0, position >= state.duration else { return }
        state.timeline = QTPlaybackTimeline(time: state.duration, rate: 0, anchorUptime: clock.now, duration: state.duration)
        state.status = .ended
        if missesNextEnd { missesNextEnd = false } else { publish() }
    }

    // MARK: Faults

    /// The page pauses on its own ("Still listening?", WebKit).
    func pauseByItself() {
        guard state.status == .playing, pending == nil else { return }
        state.timeline = QTPlaybackTimeline(time: position, rate: 0, anchorUptime: clock.now, duration: state.duration)
        state.status = .paused
        publish()
    }

    /// The media plays again without the app asking (Play in the Picture in Picture window).
    func resumeByItself() {
        guard state.status == .paused, state.item != nil, pending == nil else { return }
        state.status = .playing
        state.timeline = QTPlaybackTimeline(time: position, rate: rate, anchorUptime: clock.now, duration: state.duration)
        publish()
    }

    /// Playing, but the clock stands still (buffering that never ends); fails as a network stall after 20 s.
    func stall() {
        guard state.status == .playing, stalledSince == nil, pending == nil else { return }
        stalledSince = clock.now
        state.timeline = QTPlaybackTimeline(time: position, rate: 0, anchorUptime: clock.now, duration: state.duration)
        state.isBuffering = true
        publish()
    }

    /// The engine loses its item (a crashed page that comes back empty).
    func crash() {
        stop()
    }

    /// Reports an item the queue didn't ask for (a stale gapless chain).
    func reportStaleItem() {
        guard let item = state.item, pending == nil else { return }
        var stale = item
        stale.queueID = UUID()
        stale.track.videoId = "stale-\(stale.track.videoId)"
        state.item = stale
        state.timeline = QTPlaybackTimeline(time: 0, rate: state.status == .playing ? rate : 0, anchorUptime: clock.now, duration: state.duration)
        publish()
    }

    /// Moves on to the prepared next item by itself (gapless join), as the native engine does. `evenIfPaused`: the join
    /// lands just as the listener pauses (a crossfade under way), so the next item reports paused.
    func joinPrepared(evenIfPaused: Bool = false) {
        guard let next = prepared, state.status == .playing || (evenIfPaused && state.status == .paused), pending == nil else { return }
        prepared = nil
        state.item = next
        state.duration = next.track.duration
        state.timeline = QTPlaybackTimeline(time: 0, rate: state.status == .playing ? rate : 0, anchorUptime: clock.now,
                                            duration: next.track.duration)
        publish()
    }

    /// Ends whatever is pending (test teardown).
    func finish() { cancelPending() }
}

/// A queue controller on a `ChaosEngine` and a manual clock, with a Now Playing controller that records instead of
/// publishing. Nothing ticks by itself: `run(_:)` advances the clock second by second and ticks engine and watch.
@MainActor
final class ChaosRig {
    let clock = ManualClock()
    let engine: ChaosEngine
    let controller: QTQueueController
    let center = RecordingInfoCenter()
    let nowPlaying: QTNowPlayingController
    private(set) var failures: [QTPlaybackFailureEvent] = []
    private(set) var notices: [QTPlaybackNotice] = []
    /// Clock time of the last failure event or notice.
    private(set) var lastReport: TimeInterval = -1
    /// Autoplay continuation calls that never answer (resumed at teardown).
    private var hanging: [CheckedContinuation<[QTTrack], any Error>] = []
    enum Radio { case answers, fails, hangs, empty }
    var radio = Radio.answers
    private(set) var radioCalls = 0
    private var radioCounter = 0

    init(seed: UInt64 = 7, continuation: Bool = true) {
        let c = clock
        engine = ChaosEngine(clock: c)
        nowPlaying = QTNowPlayingController(center: center, commandCenter: nil, artworkLoader: { _ in nil }, uptime: { c.now })
        controller = QTQueueController(engine: engine, nowPlaying: nowPlaying, random: SplitMix64(seed: seed),
                                       uptime: { c.now }, supervision: nil)
        // Weak: tasks the controller left suspended may outlive the rig.
        controller.onFailure = { [weak self] event in
            guard let self else { return }
            failures.append(event)
            lastReport = clock.now
        }
        controller.onNotice = { [weak self] notice in
            guard let self else { return }
            notices.append(notice)
            lastReport = clock.now
        }
        if continuation {
            controller.autoplayContinuation = { [weak self] _ in
                guard let self else { throw CancellationError() }
                return try await self.answerRadio()
            }
        }
    }

    private func answerRadio() async throws -> [QTTrack] {
        radioCalls += 1
        switch radio {
        case .answers:
            radioCounter += 1
            let n = radioCounter
            return (1...4).map { PB.track("radio\(n)-\($0)", duration: 60) }
        case .fails: throw URLError(.notConnectedToInternet)
        case .empty: return []
        case .hangs: return try await withCheckedThrowingContinuation { hanging.append($0) }
        }
    }

    var nowID: String? { controller.nowPlayingTrack?.videoId }

    func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }

    /// Advances `seconds` of virtual time, one second at a time: engine tick, watch tick, settle.
    func run(_ seconds: Int) async {
        await settle()
        for _ in 0..<seconds {
            clock.now += 1
            engine.tick()
            await settle()
            controller.superviseTick()
            await settle()
        }
    }

    func teardown() {
        for c in hanging { c.resume(throwing: CancellationError()) }
        hanging = []
        engine.finish()
        controller.fireAllWatchTimers()
    }
}
