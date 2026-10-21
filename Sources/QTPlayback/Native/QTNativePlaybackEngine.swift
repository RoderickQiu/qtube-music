import Foundation
import Observation
import QTCore
import QTInnerTube

// Native Premium engine (docs/native-engine-spike.md, option B — approved 2026-10-19: opt-in, Premium only, falls
// back to YouTube's player). Songs play from YouTube's AAC renditions in memory through AVAudioEngine (gapless,
// crossfade, EQ, visualizer data); music videos and every fallback play through the web engine it wraps. The queue,
// Now Playing and the remote commands stay the app's (QTQueueController / QTNowPlayingController): this engine only
// plays what it is told, plus the next item the queue says is coming (`prepareNext`).
//
// Routing per load:
//  - a Song item → native (resolve + download into memory, or from memory when prefetched);
//  - a Video item → the web engine (the page has the picture);
//  - after a systemic native failure (403, bot check, solver, SABR-only) → the web engine for the rest of the session,
//    without a word to the listener (Settings says so); an item-level failure → the web engine for that item only.
// Song⇄Video hands over without a gap: going to Video, the song keeps playing natively while the video page loads
// muted, the page is lined up with the native clock and the audio swaps; going back to Song, the page keeps playing
// while the native audio is fetched, then native starts at the page's position and the page stops.
// Plays here are not reported to YouTube (no playback-tracking pings): they don't reach the account's history.

/// Gapless, crossfade and EQ as the engine applies them (Settings › Premium engine).
public struct QTNativeEffects: Sendable, Hashable {
    public var gapless: Bool
    /// Seconds; 0 = off.
    public var crossfadeSeconds: Double
    public var equalizer: QTEqualizerPreset

    public init(gapless: Bool = true, crossfadeSeconds: Double = 0, equalizer: QTEqualizerPreset = .off) {
        self.gapless = gapless
        self.crossfadeSeconds = crossfadeSeconds
        self.equalizer = equalizer
    }
}

public extension QTEqualizerPreset {
    /// Band gains in dB at 32, 64, 125, 250, 500 Hz, 1, 2, 4, 8, 16 kHz.
    var gains: [Float] {
        switch self {
        case .off: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .acoustic: [5, 5, 4, 1, 2, 2, 3.5, 4, 3.5, 2]
        case .bassBooster: [5.5, 4.5, 3.5, 2.5, 1, 0, 0, 0, 0, 0]
        case .electronic: [4.5, 4, 1, 0, -2, 2, 1, 1.5, 4, 5]
        case .loudness: [6, 4, 0, 0, -2, 0, -1, -5, 5, 1]
        case .lounge: [-3, -1.5, -0.5, 1.5, 4, 2.5, 0, -1.5, 2, 1]
        case .piano: [3, 2, 0, 2.5, 3, 1.5, 3.5, 4.5, 3, 3.5]
        case .rnb: [2.5, 7, 5.5, 1.5, -2.5, -1.5, 2.5, 2.5, 3, 4]
        case .spokenWord: [-3.5, -0.5, 0, 0.5, 3.5, 4.5, 5, 4.5, 2.5, 0]
        case .trebleBooster: [0, 0, 0, 0, 0, 1, 2.5, 3.5, 4.5, 5.5]
        case .vocalBooster: [-1.5, -3, -3, 1.5, 3.5, 3.5, 3, 1.5, 0, -1.5]
        }
    }
}

/// What the native engine has done this session (DEBUG status file, acceptance).
public struct QTNativeStats: Sendable, Hashable {
    public var nativeLoads = 0
    public var webLoads = 0
    /// Load request → first rendered frame, seconds (last 50 native starts).
    public var startSeconds: [Double] = []
    /// Resolve + download, seconds (0 = from memory), last 50.
    public var fetchSeconds: [Double] = []
    public var gaplessSeams = 0
    /// Position of the new track when the engine reported the seam (output latency; ~0 = sample-exact join).
    public var lastSeamPosition: Double?
    public var crossfades = 0
    /// Items that went to the web engine after an item-level native failure.
    public var itemFallbacks: [String] = []
    public var handovers: [String] = []
    public var lastItag: Int?
}

@MainActor
@Observable
public final class QTNativePlaybackEngine: QTPlaybackEngine {
    /// This build has a native engine. Whether it is used is the app's call (opt-in setting, Premium, signed in).
    public nonisolated static let isAvailable = true

    /// The web engine: music videos, fallbacks, and the video surface / PiP for the rest of the app.
    public let web: QTWebPlaybackEngine
    /// Why the native path is off for the rest of the session (nil = working).
    public private(set) var fallbackReason: String?
    /// The current item plays natively.
    public internal(set) var isNativeActive = false
    @ObservationIgnored public private(set) var stats = QTNativeStats()
    public var effects = QTNativeEffects() {
        didSet { if effects != oldValue { applyEffects(oldValue) } }
    }

    @ObservationIgnored public private(set) var state = QTPlaybackState()
    /// Playback speed: the graph's time pitch, and the wrapped web engine's (videos, fallbacks) — always the same.
    @ObservationIgnored public private(set) var rate: Double = 1

    private let player = QTNativeAudioPlayer()
    private let resolver: QTNativeStreamResolver
    private let fetcher: QTNativeAudioFetcher
    @ObservationIgnored private var continuations: [UUID: AsyncStream<QTPlaybackState>.Continuation] = [:]
    @ObservationIgnored private var webTask: Task<Void, Never>?
    /// Bumped by every load and stop; an older load that wakes up finds itself superseded.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var nextToken = 0
    @ObservationIgnored private var current: Playing?
    /// The next item, as the queue last described it.
    @ObservationIgnored private var nextItem: QTPlaybackItem?
    /// The next item's audio, once it is in memory and opened.
    @ObservationIgnored private var prepared: Playing?
    @ObservationIgnored private var prepareTask: Task<Void, Never>?
    @ObservationIgnored private var transitionTask: Task<Void, Never>?
    /// Web states aren't forwarded while a handover runs (the native clock is what plays).
    @ObservationIgnored private var isHandingOver = false
    /// Seconds from asking the web engine for the video to it playing (learned).
    @ObservationIgnored private var webStartEstimate: TimeInterval = 2.5
    /// Watches the native clock while it should be moving (`checkProgress`).
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var progress = QTProgressWatch(limit: QTNativePlaybackEngine.stallLimit)
    /// The current track's graph was restarted after a stall (a second stall falls back).
    @ObservationIgnored private var restartedAfterStall = false
    /// The native clock may stand still this long while playing before the graph is restarted (then: fallback).
    static let stallLimit: TimeInterval = 6

    private struct Playing {
        let token: Int
        var item: QTPlaybackItem
        let file: QTNativeMemoryAudioFile
        let gain: Float
        let itag: Int
        var duration: TimeInterval { file.duration }
    }

    /// - Parameter credentials: the signed-in session, read for every resolve (cookies rotate).
    public init(web: QTWebPlaybackEngine, credentials: @escaping @Sendable () async -> QTInnerTubeCredentials?) {
        self.web = web
        resolver = QTNativeStreamResolver(credentialsProvider: credentials)
        fetcher = QTNativeAudioFetcher(resolver: resolver)
        state.volume = web.state.volume
        state.isMuted = web.state.isMuted
        player.outputVolume = outputVolume
        player.onPlayedOut = { [weak self] deck, token in self?.playedOut(deck: deck, token: token) }
        player.onDecodeError = { [weak self] token, error in self?.decodeFailed(token: token, error: error) }
        player.onRouteChange = { [weak self] in self?.reanchor() }
        player.onOutputFailure = { [weak self] error in self?.fallBackNow("output restart: \(error)") }
        let stream = web.stateUpdates()
        webTask = Task { @MainActor [weak self] in
            for await s in stream {
                guard let self, !Task.isCancelled else { return }
                self.webStateChanged(s)
            }
        }
    }

    // MARK: QTPlaybackEngine

    public var capabilities: QTPlaybackCapabilities { fallbackReason == nil ? .premium : .web }

    public func stateUpdates() -> AsyncStream<QTPlaybackState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<QTPlaybackState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(state)
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.continuations[id] = nil } }
        return stream
    }

    private func publish() {
        for c in continuations.values { c.yield(state) }
    }

    public func load(_ item: QTPlaybackItem, autoplay: Bool) async throws {
        generation += 1
        let gen = generation
        transitionTask?.cancel()
        guard item.track.availability.isPlayable else {
            try await loadWeb(item, autoplay: autoplay, generation: gen)
            return
        }
        if item.mode == .video || fallbackReason != nil {
            try await loadWeb(item, autoplay: autoplay, generation: gen)
        } else {
            try await loadNative(item, autoplay: autoplay, generation: gen)
        }
    }

    public func play() {
        guard isNativeActive else { web.play(); return }
        guard current != nil else { return }
        if state.status == .ended { seek(to: 0) }
        do {
            try player.play()
        } catch {
            fallBackNow("output: \(error)")
            return
        }
        publishNative(status: .playing)
        scheduleTransition()
    }

    public func pause() {
        guard isNativeActive else { web.pause(); return }
        guard current != nil else { return }
        player.pause()
        transitionTask?.cancel()
        publishNative(status: .paused)
    }

    public func seek(to time: TimeInterval) {
        guard isNativeActive else { web.seek(to: time); return }
        guard let cur = current else { return }
        let t = min(max(0, time), max(0, cur.duration - 0.25))
        do {
            try player.seek(token: cur.token, to: t)
        } catch {
            fallBackNow("seek: \(error)")
            return
        }
        // The appended next track was re-chained by the restart; nothing else to do.
        let status: QTPlaybackStatus = player.isPlaying ? .playing : .paused
        state.timeline = QTPlaybackTimeline(time: t, rate: status == .playing ? rate : 0, duration: cur.duration)
        publishNative(status: status, time: t)
        scheduleTransition()
    }

    public func setRate(_ rate: Double) {
        let r = QTPlaybackSpeed.normalized(rate)
        guard r != self.rate else { return }
        self.rate = r
        web.setRate(r)
        do {
            try player.setRate(r)
        } catch {
            fallBackNow("speed: \(error)")
            return
        }
        guard isNativeActive, current != nil, state.status == .playing else { return }
        // The clock re-anchors where the graph is; the crossfade's start moves with the speed.
        publishNative(status: .playing)
        scheduleTransition()
    }

    public func setVolume(_ volume: Double) {
        state.volume = min(1, max(0, volume))
        player.outputVolume = outputVolume
        web.setVolume(state.volume)
        publish()
    }

    public func setMuted(_ muted: Bool) {
        state.isMuted = muted
        player.outputVolume = outputVolume
        if !isHandingOver { web.setMuted(muted) }
        publish()
    }

    public func skipAd() {
        if !isNativeActive { web.skipAd() }
    }

    public func stop() {
        generation += 1
        transitionTask?.cancel()
        prepareTask?.cancel()
        prepared = nil
        stopNative()
        web.stop()
        state = QTPlaybackState(volume: state.volume, isMuted: state.isMuted)
        publish()
    }

    public func spectrum(bandCount: Int) -> [Float]? {
        isNativeActive ? player.spectrum(bandCount: bandCount) : web.spectrum(bandCount: bandCount)
    }

    public var isNetworkAvailable: Bool { web.isNetworkAvailable }

    public var isPausedByListener: Bool { !isNativeActive && web.isPausedByListener }

    public var isListenerPauseReported: Bool { !isNativeActive && web.isListenerPauseReported }

    public var isResumedByListener: Bool { !isNativeActive && web.isResumedByListener }

    /// The web engine drops a stale page; a native track checks its graph (the output may have changed while asleep),
    /// restarting it, or falling back when it won't run.
    public func systemDidWake(after sleep: TimeInterval) {
        web.systemDidWake(after: sleep)
        guard isNativeActive, current != nil, player.isPlaying, !player.isRunning else { return }
        do {
            try player.restartGraph()
            reanchor()
        } catch {
            fallBackNow("output after wake: \(error)")
        }
    }

    /// A page that won't start the item: the web engine's next load gets a fresh one — only while the web engine plays
    /// it. A native item reloads natively anyway; a stale flag would cost the next web play a fresh page and the next
    /// Song⇄Video switch its seamlessness.
    public func startNextLoadAfresh() {
        guard !isNativeActive else { return }
        web.startNextLoadAfresh()
    }

    /// The queue's next item (nil: nothing follows in order). Prefetched, and joined gaplessly or crossfaded into.
    public func prepareNext(_ item: QTPlaybackItem?) {
        guard item != nextItem else { return }
        nextItem = item
        prepareTask?.cancel()
        // Whatever was chained for the old next goes.
        if let cur = current, let p = prepared, item?.queueID != p.item.queueID || item?.track.videoId != p.item.track.videoId {
            player.dropQueued(after: cur.token)
            prepared = nil
        }
        guard let item, item.mode == .song, item.track.availability.isPlayable, fallbackReason == nil,
              item.track.videoId.count == 11 else { scheduleTransition(); return }
        let id = item.track.videoId
        prepareTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let audio = try? await self.fetcher.audio(for: id), !Task.isCancelled, self.nextItem == item else { return }
            guard let file = try? QTNativeMemoryAudioFile(bytes: audio.bytes, sampleRate: QTNativeAudioPlayer.sampleRate) else { return }
            self.nextToken += 1
            self.prepared = Playing(token: self.nextToken, item: item, file: file, gain: Self.gain(audio.stream),
                                    itag: audio.stream.format.itag)
            self.chainPrepared()
            self.scheduleTransition()
        }
    }

    /// Turns the native path off for this engine's life and frees the audio (the app swaps engines when the setting
    /// goes off).
    public func shutdownNative() {
        transitionTask?.cancel()
        prepareTask?.cancel()
        prepared = nil
        stopNative()
        webTask?.cancel()
        Task { await fetcher.purge() }
    }

    // MARK: Native loads

    private func loadNative(_ item: QTPlaybackItem, autoplay: Bool, generation gen: Int) async throws {
        let requested = ProcessInfo.processInfo.systemUptime
        // Video → Song of the same track while the page plays: the page keeps playing until native is ready.
        let fromWeb = !isNativeActive && web.state.isPlaying && web.state.item?.track.videoId == item.track.videoId && autoplay
        let webClockAtRequest = web.state.timeline.currentTime
        if !fromWeb {
            if isNativeActive { player.pause() }
            state = QTPlaybackState(item: item, status: .loading,
                                    timeline: QTPlaybackTimeline(time: item.startTime, rate: 0,
                                                                 duration: item.track.duration > 0 ? item.track.duration : .infinity),
                                    duration: item.track.duration, isBuffering: true, volume: state.volume, isMuted: state.isMuted)
            publish()
        } else {
            isHandingOver = true
            state.item = item
            publish()
        }
        defer { if fromWeb { isHandingOver = false } }

        // The audio: the prepared next track, memory, or the network.
        let playing: Playing
        if let p = prepared, p.item.track.videoId == item.track.videoId {
            prepared = nil
            playing = Playing(token: p.token, item: item, file: p.file, gain: p.gain, itag: p.itag)
            stats.fetchSeconds.append(0)
        } else {
            do {
                let audio = try await fetcher.audio(for: item.track.videoId)
                guard gen == generation else { throw CancellationError() }
                let file = try QTNativeMemoryAudioFile(bytes: audio.bytes, sampleRate: QTNativeAudioPlayer.sampleRate)
                nextToken += 1
                playing = Playing(token: nextToken, item: item, file: file, gain: Self.gain(audio.stream), itag: audio.stream.format.itag)
                stats.fetchSeconds.append(audio.fetchSeconds)
            } catch let error as CancellationError {
                throw error
            } catch {
                guard gen == generation else { throw CancellationError() }
                let failure = QTNativeFailure.from(error)
                note(failure, item: item)
                // YouTube's player takes it (from Video, that is the page's own Song⇄Video switch).
                isHandingOver = false
                try await loadWeb(item, autoplay: autoplay, generation: gen)
                return
            }
        }
        if stats.fetchSeconds.count > 50 { stats.fetchSeconds.removeFirst() }
        guard gen == generation else { throw CancellationError() }

        var start = item.startTime
        if fromWeb {
            // Pick up where the page is now (shifted, when the two renditions are different cuts).
            let shift = abs(item.startTime - webClockAtRequest) >= 0.75 ? item.startTime - webClockAtRequest : 0
            start = web.state.timeline.currentTime + shift
        }
        start = min(max(0, start), max(0, playing.duration - 0.5))
        do {
            try player.start(playing.file, token: playing.token, at: start, gain: playing.gain, autoplay: autoplay)
        } catch {
            note(.systemic("output: \(error)"), item: item)
            try await loadWeb(item, autoplay: autoplay, generation: gen)
            return
        }
        if fromWeb {
            web.standDown()
            stats.handovers.append("video→song \(item.track.videoId) after \(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - requested)) s")
        } else if !isNativeActive {
            web.standDown()
        }
        current = playing
        restartedAfterStall = false
        isNativeActive = true
        stats.nativeLoads += 1
        stats.lastItag = playing.itag
        state.item = item
        state.duration = playing.duration
        state.isBuffering = false
        publishNative(status: autoplay ? .playing : .paused, time: start)
        if autoplay { measureStart(token: playing.token, since: requested) }
        chainPrepared()
        scheduleTransition()
    }

    /// Native gain for YouTube's loudness normalisation: loud tracks turned down to the target, quiet ones left alone.
    private static func gain(_ stream: QTNativeResolvedStream) -> Float {
        guard let db = stream.loudnessDb, db > 0 else { return 1 }
        return Float(pow(10, -db / 20))
    }

    private var outputVolume: Float {
        web.configuration.isSilent || state.isMuted ? 0 : Float(state.volume)
    }

    // MARK: Web loads

    private func loadWeb(_ item: QTPlaybackItem, autoplay: Bool, generation gen: Int) async throws {
        stats.webLoads += 1
        // Song → Video of the same track while the song plays: keep the song until the page plays, then swap.
        if isNativeActive, let cur = current, player.isPlaying, autoplay, item.mode == .video,
           cur.item.track.videoId == item.track.videoId {
            try await handOverToWeb(item, from: cur, generation: gen)
            return
        }
        stopNative()
        guard gen == generation else { throw CancellationError() }
        state.item = item
        try await web.load(item, autoplay: autoplay)
        guard gen == generation else { throw CancellationError() }
        forward(web.state)
    }

    private func handOverToWeb(_ item: QTPlaybackItem, from cur: Playing, generation gen: Int) async throws {
        let requested = ProcessInfo.processInfo.systemUptime
        let clock = player.position(of: cur.token) ?? item.startTime
        let shift = abs(item.startTime - clock) >= 0.75 ? item.startTime - clock : 0
        isHandingOver = true
        defer { isHandingOver = false }
        // The switch shows now; the song plays on.
        state.item = item
        publish()
        transitionTask?.cancel()
        web.setMuted(true)
        var target = item
        target.startTime = Self.handOverStart(clock: clock, shift: shift, startEstimate: webStartEstimate, rate: rate)
        do {
            try await web.load(target, autoplay: true)
        } catch {
            web.setMuted(state.isMuted)
            guard gen == generation else { throw CancellationError() }
            keepSong(cur, after: "the video didn't load (\(error))")
            return
        }
        guard gen == generation else { web.setMuted(state.isMuted); throw CancellationError() }
        // Until the page plays content.
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !(web.state.status == .playing && !web.state.isBuffering && web.state.ad == nil),
              ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(40))
            guard gen == generation else { web.setMuted(state.isMuted); throw CancellationError() }
        }
        guard web.state.status == .playing else {
            web.standDown()
            web.setMuted(state.isMuted)
            keepSong(cur, after: "the video didn't start")
            return
        }
        let readyAfter = ProcessInfo.processInfo.systemUptime - requested
        webStartEstimate = min(6, max(0.8, webStartEstimate * 0.5 + readyAfter * 0.5))
        // Line the page up with the song: hold it while the song catches up, or seek it ahead once.
        var attempt = 0
        lineUp: while attempt < 2, let native = player.position(of: cur.token) {
            switch Self.lineUp(page: web.state.timeline.currentTime, song: native, shift: shift, rate: rate,
                               firstAttempt: attempt == 0) {
            case .hold(let seconds):
                web.pause()
                try? await Task.sleep(for: .seconds(seconds))
                guard gen == generation else { web.setMuted(state.isMuted); throw CancellationError() }
                web.play()
                break lineUp
            case .seekAhead(let to):
                web.seek(to: to)
                let until = ProcessInfo.processInfo.systemUptime + 4
                try? await Task.sleep(for: .milliseconds(150))
                while web.state.isBuffering || web.state.status != .playing, ProcessInfo.processInfo.systemUptime < until {
                    try? await Task.sleep(for: .milliseconds(40))
                }
                guard gen == generation else { web.setMuted(state.isMuted); throw CancellationError() }
            case .none:
                break lineUp
            }
            attempt += 1
        }
        // How far apart the two clocks are at the swap (+ = the video is ahead of the song).
        let drift = web.state.timeline.currentTime - ((player.position(of: cur.token) ?? clock) + shift)
        web.setMuted(state.isMuted)
        stopNative()
        stats.handovers.append("song→video \(item.track.videoId) after \(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - requested)) s, drift \(String(format: "%.2f", drift)) s")
        if stats.handovers.count > 20 { stats.handovers.removeFirst() }
        forward(web.state)
    }

    /// Where the video page starts in a Song→Video handover: where the song will be (it plays `rate` media seconds per
    /// second) once the page plays, by the learnt wall-clock `startEstimate`.
    nonisolated static func handOverStart(clock: TimeInterval, shift: TimeInterval, startEstimate: TimeInterval,
                                          rate: Double) -> TimeInterval {
        max(0, clock + shift + startEstimate * rate)
    }

    enum HandOverLineUp: Equatable {
        /// Pause the page this many wall-clock seconds while the song catches up.
        case hold(TimeInterval)
        /// Seek the page to this position (it is behind).
        case seekAhead(TimeInterval)
        case none
    }

    /// Lines the playing video page up with the song: the gap between the two clocks is media time, waited out in
    /// wall-clock time at the playback speed.
    nonisolated static func lineUp(page: TimeInterval, song: TimeInterval, shift: TimeInterval, rate: Double,
                                   firstAttempt: Bool) -> HandOverLineUp {
        let lead = (page - (song + shift)) / rate
        if lead > 0.06, lead < 8 { return .hold(max(0, lead - 0.04)) }
        if lead <= -0.25, firstAttempt { return .seekAhead(song + shift + 1.2 * rate) }
        return .none
    }

    /// A Song→Video handover that couldn't get the video playing: the song never stopped, so it simply goes on (the
    /// queue's mode follows the item, back to Song) instead of the track being skipped as a failure.
    private func keepSong(_ cur: Playing, after reason: String) {
        QTNativeAudioPlayer.log.info("native: Song→Video for \(cur.item.track.videoId, privacy: .public) kept the song: \(reason, privacy: .public)")
        stats.handovers.append("song→video \(cur.item.track.videoId) kept the song: \(reason)")
        if stats.handovers.count > 20 { stats.handovers.removeFirst() }
        publishNative(status: player.isPlaying ? .playing : .paused)
        scheduleTransition()
    }

    // MARK: Native state

    private func publishNative(status: QTPlaybackStatus, time: TimeInterval? = nil) {
        guard let cur = current else { return }
        let t = time ?? player.position(of: cur.token) ?? state.timeline.currentTime
        state.item = cur.item
        state.status = status
        state.duration = cur.duration
        state.isBuffering = false
        state.ad = nil
        state.timeline = QTPlaybackTimeline(time: t, rate: status == .playing ? rate : 0, duration: cur.duration)
        publish()
        updateWatchdog()
    }

    // MARK: Progress watchdog

    /// While native audio should be playing, its clock is checked every 2 s.
    private func updateWatchdog() {
        progress.reset()
        guard isNativeActive, state.status == .playing else {
            watchdog?.cancel()
            watchdog = nil
            return
        }
        guard watchdog == nil else { return }
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                self.checkProgress()
            }
        }
    }

    /// A clock that stopped (a dead output, a wedged node) restarts the graph once; stopping again falls back to the
    /// web engine at the same position. Stuck at the very end it is simply over.
    private func checkProgress() {
        guard isNativeActive, state.status == .playing, let cur = current, player.isPlaying else { return }
        let position = player.position(of: cur.token) ?? state.timeline.currentTime
        guard progress.isStalled(position: position, at: ProcessInfo.processInfo.systemUptime) else { return }
        progress.reset()
        if position >= cur.duration - 0.5 {
            playedOut(deck: player.active, token: cur.token)
        } else if restartedAfterStall {
            fallBackNow("stalled at \(String(format: "%.1f", position)) s")
        } else {
            restartedAfterStall = true
            QTNativeAudioPlayer.log.error("native: the clock stalled at \(position, format: .fixed(precision: 1)) s; restarting the graph")
            do {
                try player.restartGraph()
                reanchor()
            } catch {
                fallBackNow("restart after a stall: \(error)")
            }
        }
    }

    /// Re-reads the clock after the output device changed.
    private func reanchor() {
        guard isNativeActive, current != nil else { return }
        publishNative(status: player.isPlaying ? .playing : .paused)
        scheduleTransition()
    }

    private func stopNative() {
        transitionTask?.cancel()
        if isNativeActive || current != nil { player.stop() }
        current = nil
        isNativeActive = false
        watchdog?.cancel()
        watchdog = nil
    }

    private func webStateChanged(_ s: QTPlaybackState) {
        guard !isNativeActive, !isHandingOver else { return }
        forward(s)
    }

    private func forward(_ s: QTPlaybackState) {
        var s = s
        s.volume = state.volume
        s.isMuted = state.isMuted
        state = s
        publish()
    }

    // MARK: Next track: gapless, crossfade

    /// Gapless when crossfade is off (or both tracks are from one album — albums are meant to flow), else nothing to
    /// chain: the crossfade starts on time (`scheduleTransition`).
    private var usesGapless: Bool {
        guard effects.gapless else { return false }
        return effects.crossfadeSeconds < 1 || isSameAlbum
    }

    private var isSameAlbum: Bool {
        guard let a = current?.item.track.album?.id, let b = prepared?.item.track.album?.id else { return false }
        return a == b
    }

    /// Chains the prepared track behind the current one when gapless applies.
    private func chainPrepared() {
        guard isNativeActive, let cur = current, let p = prepared, usesGapless else { return }
        guard player.tokens(after: cur.token).isEmpty else { return }
        _ = try? player.appendGapless(p.file, token: p.token, after: cur.token, gain: p.gain)
    }

    /// Sleeps until the crossfade should start, then starts it.
    private func scheduleTransition() {
        transitionTask?.cancel()
        guard isNativeActive, player.isPlaying, let cur = current, prepared != nil, effects.crossfadeSeconds >= 1,
              !usesGapless else { return }
        let fade = min(effects.crossfadeSeconds, cur.duration / 3)
        transitionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let now = self.player.position(of: cur.token) else { return }
                // Media seconds to the fade's start, slept in wall-clock seconds at the speed it plays.
                let wait = (cur.duration - fade - now) / self.rate
                if wait <= 0.02 { break }
                try? await Task.sleep(for: .seconds(min(wait, 5)))
            }
            guard let self, !Task.isCancelled else { return }
            self.startCrossfade(fade)
        }
    }

    private func startCrossfade(_ fade: TimeInterval) {
        guard isNativeActive, let p = prepared, current != nil else { return }
        do {
            try player.crossfade(to: p.file, token: p.token, gain: p.gain, duration: fade)
        } catch {
            return
        }
        prepared = nil
        current = p
        restartedAfterStall = false
        stats.crossfades += 1
        stats.lastItag = p.itag
        nextItem = nil
        publishNative(status: .playing, time: 0)
    }

    /// A segment's last frame played out on a deck.
    private func playedOut(deck: QTNativeDeck, token: Int) {
        guard isNativeActive, let cur = current, cur.token == token else { return }
        // The gapless next track is already playing on the same deck.
        if let p = prepared, deck === player.active, deck.chains(p.token, on: player) {
            prepared = nil
            current = p
            restartedAfterStall = false
            nextItem = nil
            stats.gaplessSeams += 1
            stats.lastItag = p.itag
            let t = player.position(of: p.token) ?? 0
            stats.lastSeamPosition = t
            publishNative(status: .playing, time: t)
            scheduleTransition()
            return
        }
        transitionTask?.cancel()
        state.timeline = QTPlaybackTimeline(time: cur.duration, rate: 0, duration: cur.duration)
        state.status = .ended
        publish()
        updateWatchdog()
    }

    private func decodeFailed(token: Int, error: any Error) {
        guard current?.token == token else { return }
        fallBackNow("decode: \(error)")
    }

    // MARK: Failures

    private func note(_ failure: QTNativeFailure, item: QTPlaybackItem) {
        switch failure {
        case .systemic(let reason):
            if fallbackReason == nil {
                fallbackReason = reason
                QTNativeAudioPlayer.log.error("native engine falls back to YouTube's player for this session: \(reason, privacy: .public)")
                prepared = nil
                prepareTask?.cancel()
            }
        case .item(let reason):
            stats.itemFallbacks.append("\(item.track.videoId): \(reason)")
            if stats.itemFallbacks.count > 20 { stats.itemFallbacks.removeFirst() }
            QTNativeAudioPlayer.log.info("native: \(item.track.videoId, privacy: .public) plays in YouTube's player (\(reason, privacy: .public))")
        }
    }

    /// Native broke mid-track: the web engine takes over at the same position.
    private func fallBackNow(_ reason: String) {
        guard let cur = current else { return }
        note(.systemic(reason), item: cur.item)
        let t = player.position(of: cur.token) ?? state.timeline.currentTime
        let wasPlaying = player.isPlaying
        var item = cur.item
        item.startTime = t
        generation += 1
        let gen = generation
        stopNative()
        Task { @MainActor [weak self] in
            try? await self?.loadWeb(item, autoplay: wasPlaying, generation: gen)
        }
    }

    private func measureStart(token: Int, since requested: TimeInterval) {
        Task { @MainActor [weak self] in
            let start = self?.player.position(of: token) ?? 0
            for _ in 0..<300 {
                guard let self, self.current?.token == token else { return }
                if let t = self.player.position(of: token), t > start + 0.001 {
                    self.stats.startSeconds.append(ProcessInfo.processInfo.systemUptime - requested)
                    if self.stats.startSeconds.count > 50 { self.stats.startSeconds.removeFirst() }
                    return
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    private func applyEffects(_ old: QTNativeEffects) {
        if effects.equalizer != old.equalizer { player.setEQ(gains: effects.equalizer.gains) }
        guard effects.gapless != old.gapless || effects.crossfadeSeconds != old.crossfadeSeconds else { return }
        // Re-plan the next transition under the new rules.
        if let cur = current, !usesGapless { player.dropQueued(after: cur.token) }
        chainPrepared()
        scheduleTransition()
    }

    // MARK: Debug

    /// DEBUG: every solve fails from now on (and the loaded player is dropped), to exercise the fallback.
    public func debugForceSolverFailure() async {
        QTNativePlayerScript.debugFailSolves = true
        await resolver.invalidatePlayer()
        await fetcher.purge()
    }

    /// DEBUG: frames the visualizer tap has seen.
    public var debugTapFrames: Int { player.tapFrames }

    /// DEBUG: the clock of the current native track (seconds), for seam and drift checks.
    public var debugNativePosition: TimeInterval? {
        guard let cur = current else { return nil }
        return player.position(of: cur.token)
    }
}

/// Notices a clock that stopped moving while it should play (the native engine's watchdog).
struct QTProgressWatch {
    let limit: TimeInterval
    private var last: (position: TimeInterval, uptime: TimeInterval)?

    init(limit: TimeInterval) { self.limit = limit }

    /// Forget the last reading (play, pause, seek, a new track).
    mutating func reset() { last = nil }

    /// One reading while playing: true once the position hasn't moved for `limit` seconds.
    mutating func isStalled(position: TimeInterval, at uptime: TimeInterval) -> Bool {
        guard let last, abs(position - last.position) <= 0.05 else {
            self.last = (position, uptime)
            return false
        }
        return uptime - last.uptime >= limit
    }
}

private extension QTNativeDeck {
    /// Whether `token` is chained on this deck (read through the player's queue).
    @MainActor
    func chains(_ token: Int, on player: QTNativeAudioPlayer) -> Bool {
        player.queue.sync { contains(token) }
    }
}
