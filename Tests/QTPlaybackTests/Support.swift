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
                                       uptime: { c.now })
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
            state = QTPlaybackState(item: item, status: .failed(.unavailable(.removed)))
            for c in continuations.values { c.yield(state) }
            throw QTPlaybackError.unavailable(.removed)
        }
        state = QTPlaybackState(item: item, status: autoplay ? .playing : .paused, duration: item.track.duration)
        for c in continuations.values { c.yield(state) }
    }

    func play() {}
    func pause() {}
    func seek(to time: TimeInterval) {}
    func setVolume(_ volume: Double) {}
    func setMuted(_ muted: Bool) {}
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
