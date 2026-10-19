import Foundation
import QTCore

/// Clock-driven fake engine (port of the prototype's player.jsx) so every surface runs on mock data.
/// Account `.free` plays a 12 s ad before each track (skippable after 5 s), like the prototype.
/// No audio. Ticks only while playing (idle CPU stays ~0).
@MainActor
public final class QTSimulatedPlaybackEngine: QTPlaybackEngine {
    public enum Account: String, Sendable { case premium, free }

    public static let adDuration: TimeInterval = 12
    public static let adSkippableAfter: TimeInterval = 5

    public var account: Account {
        didSet {
            if account == .premium, state.ad != nil { endAd() }
        }
    }

    /// Mirrors what the account really gets: Premium the native set, free the web engine's (visualizer included).
    public var capabilities: QTPlaybackCapabilities { account == .premium ? .premium : .web }
    public private(set) var state = QTPlaybackState()

    private let clock: @MainActor () -> TimeInterval
    private let tickInterval: Duration
    private var continuations: [UUID: AsyncStream<QTPlaybackState>.Continuation] = [:]
    private var ticker: Task<Void, Never>?
    /// Ad clock: elapsed seconds at `adAnchor` (uptime), advancing while playing.
    private var adElapsed: TimeInterval = 0
    private var adAnchor: TimeInterval = 0

    /// - Parameters:
    ///   - clock: uptime source; tests inject a manual clock and call `tick()`.
    ///   - tickInterval: how often state is re-published while playing (ad countdown, end detection).
    ///     Pass `nil` to disable the internal ticker (tests).
    public init(account: Account = .premium,
                clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                tickInterval: Duration? = .milliseconds(250)) {
        self.account = account
        self.clock = clock
        self.tickInterval = tickInterval ?? .zero
    }

    // MARK: Stream

    public func stateUpdates() -> AsyncStream<QTPlaybackState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<QTPlaybackState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(state)
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations[id] = nil }
        }
        return stream
    }

    private func publish() {
        for c in continuations.values { c.yield(state) }
    }

    // MARK: Transport

    public func load(_ item: QTPlaybackItem, autoplay: Bool = true) async throws {
        guard item.track.availability.isPlayable else {
            state.status = .failed(.unavailable(item.track.availability))
            publish()
            throw QTPlaybackError.unavailable(item.track.availability)
        }
        let now = clock()
        let duration = item.track.duration
        state.item = item
        state.duration = duration
        state.isBuffering = false
        state.timeline = QTPlaybackTimeline(time: min(item.startTime, duration), rate: 0, anchorUptime: now, duration: duration)
        state.ad = nil
        state.status = autoplay ? .playing : .paused
        if account == .free {
            beginAd(at: now)
        } else if autoplay {
            state.timeline.rate = 1
        }
        publish()
        updateTicker()
    }

    public func play() {
        guard state.item != nil else { return }
        let now = clock()
        if state.status == .ended {
            state.timeline = QTPlaybackTimeline(time: 0, rate: 0, anchorUptime: now, duration: state.duration)
        }
        state.status = .playing
        if state.ad != nil {
            adAnchor = now
        } else {
            state.timeline = QTPlaybackTimeline(time: state.timeline.time(atUptime: now), rate: 1, anchorUptime: now, duration: state.duration)
        }
        publish()
        updateTicker()
    }

    public func pause() {
        guard state.status == .playing else { return }
        let now = clock()
        if state.ad != nil {
            adElapsed += now - adAnchor
            adAnchor = now
            refreshAd(at: now)
        }
        state.timeline = QTPlaybackTimeline(time: state.timeline.time(atUptime: now), rate: 0, anchorUptime: now, duration: state.duration)
        state.status = .paused
        publish()
        updateTicker()
    }

    public func seek(to time: TimeInterval) {
        guard state.item != nil, state.ad == nil else { return }
        let now = clock()
        let t = min(max(0, time), max(0, state.duration - 0.5))
        if state.status == .ended { state.status = .paused }
        state.timeline = QTPlaybackTimeline(time: t, rate: state.status == .playing ? 1 : 0, anchorUptime: now, duration: state.duration)
        publish()
    }

    public func setVolume(_ volume: Double) {
        state.volume = min(1, max(0, volume))
        publish()
    }

    public func setMuted(_ muted: Bool) {
        state.isMuted = muted
        publish()
    }

    public func skipAd() {
        guard let ad = state.ad, ad.canSkip else { return }
        endAd()
        publish()
    }

    public func stop() {
        state = QTPlaybackState(volume: state.volume, isMuted: state.isMuted)
        publish()
        updateTicker()
    }

    // MARK: Simulation hooks

    /// Starts an ad now (prototype "Play an ad now"; launch arg `-qt.ad YES`).
    public func playAd() {
        guard state.item != nil else { return }
        let now = clock()
        state.timeline = QTPlaybackTimeline(time: 0, rate: 0, anchorUptime: now, duration: state.duration)
        state.status = .playing
        beginAd(at: now)
        publish()
        updateTicker()
    }

    /// Re-evaluates the clock: ad countdown, ad end, track end. Called by the internal ticker; tests call it directly.
    public func tick() {
        let now = clock()
        if state.ad != nil {
            refreshAd(at: now)
            if let ad = state.ad, ad.remaining <= 0 { endAd() }
            publish()
        } else if state.status == .playing, state.timeline.time(atUptime: now) >= state.duration {
            state.timeline = QTPlaybackTimeline(time: state.duration, rate: 0, anchorUptime: now, duration: state.duration)
            state.status = .ended
            publish()
            updateTicker()
        }
    }

    private func beginAd(at now: TimeInterval) {
        adElapsed = 0
        adAnchor = now
        state.timeline.rate = 0
        state.ad = QTAdState(duration: Self.adDuration, remaining: Self.adDuration, skippableIn: Self.adSkippableAfter)
    }

    private func refreshAd(at now: TimeInterval) {
        guard var ad = state.ad else { return }
        let elapsed = adElapsed + (state.status == .playing ? now - adAnchor : 0)
        ad.remaining = max(0, ad.duration - elapsed)
        ad.skippableIn = max(0, Self.adSkippableAfter - elapsed)
        state.ad = ad
    }

    private func endAd() {
        let now = clock()
        state.ad = nil
        state.timeline = QTPlaybackTimeline(time: 0, rate: state.status == .playing ? 1 : 0, anchorUptime: now, duration: state.duration)
    }

    private func updateTicker() {
        let shouldTick = state.status == .playing && tickInterval > .zero
        if shouldTick, ticker == nil {
            let interval = tickInterval
            ticker = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard let self, !Task.isCancelled else { return }
                    self.tick()
                }
            }
        } else if !shouldTick {
            ticker?.cancel()
            ticker = nil
        }
    }
}
