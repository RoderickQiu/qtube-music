import Accelerate
@preconcurrency import AVFoundation
import Foundation
import os

// Native engine — the audio graph and its two decks.
//
//   deck A (AVAudioPlayerNode) ─┐
//                               ├─ mixer ─ time pitch ─ 10-band EQ ─ main mixer (volume) ─ output
//   deck B (AVAudioPlayerNode) ─┘                           └ tap → vDSP FFT → visualizer bands (only while asked)
//
// The time pitch is the playback speed (pitch kept). At exactly 1× it isn't in the chain at all (mixer → EQ), so normal
// speed is bit-exact — a bypassed time pitch still rounds by an ulp. The decks upstream render source frames however fast
// it pulls them, so positions stay in source frames and gapless chains are untouched.
//
// A deck plays a chain of segments (one segment = one track from some frame on). It decodes ~1 s ahead in 8,192-frame
// buffers on the player's serial queue and refills as the node consumes them, so memory holds compressed tracks plus
// a second of PCM — never decoded whole tracks.
//  - Gapless: the next track is appended to the active deck's chain; its first frame follows the last frame of the
//    current one on the node's own timeline. The last buffer of every segment reports when it has *played out*, which
//    is when the engine moves Now Playing on.
//  - Crossfade: the next track starts on the other deck and the two node volumes ramp (equal power), following the
//    incoming deck's clock, so a pause mid-fade holds the fade.
// Positions come from the node's render timeline (`playerTime(forNodeTime:)`), not from wall time.

/// One player node fed from a chain of in-memory tracks. All mutable state lives on `queue`.
final class QTNativeDeck: @unchecked Sendable {
    static let bufferFrames: AVAudioFrameCount = 8192
    /// Buffers kept scheduled ahead (~1.1 s at 44.1 kHz).
    static let buffersAhead = 6

    struct Segment {
        let token: Int
        let file: QTNativeMemoryAudioFile
        var gain: Float
        /// File frame of the segment's first scheduled frame.
        var fileStart: AVAudioFramePosition
        /// Node-timeline frame where that first frame plays (set when its first buffer is scheduled).
        var nodeStart: AVAudioFramePosition?
        /// Every frame is scheduled.
        var isScheduled = false
        /// Its last frame has played out.
        var isPlayedOut = false
    }

    let node = AVAudioPlayerNode()
    let name: String
    private let queue: DispatchQueue
    private let format: AVAudioFormat
    private var segments: [Segment] = []
    private var scheduledEnd: AVAudioFramePosition = 0
    private var inFlight = 0
    private var epoch = 0
    /// Last position read per token (while the node isn't rendering, `lastRenderTime` is nil).
    private var lastPositions: [Int: TimeInterval] = [:]
    /// Called on `queue` when a segment's last frame has played out.
    var onPlayedOut: (@Sendable (_ deck: QTNativeDeck, _ token: Int) -> Void)?
    /// Called on `queue` when decoding fails (a corrupt file): the token that failed.
    var onDecodeError: (@Sendable (_ deck: QTNativeDeck, _ token: Int, _ error: any Error) -> Void)?

    init(name: String, queue: DispatchQueue, format: AVAudioFormat) {
        self.name = name
        self.queue = queue
        self.format = format
    }

    // MARK: Called on `queue`

    /// Replaces whatever the deck plays with `file` from `frame` (the node stops; `play` starts it again).
    func start(_ file: QTNativeMemoryAudioFile, token: Int, atFrame frame: AVAudioFramePosition, gain: Float) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        reset()
        try file.seek(to: frame)
        segments = [Segment(token: token, file: file, gain: gain, fileStart: file.position)]
        fill()
    }

    /// Appends a track behind the chain (gapless).
    func append(_ file: QTNativeMemoryAudioFile, token: Int, gain: Float) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        try file.seek(to: 0)
        segments.append(Segment(token: token, file: file, gain: gain, fileStart: 0))
        fill()
    }

    /// Drops appended tracks that haven't started scheduling. Returns false when one already has (it would have to
    /// be cut out of the scheduled audio: the caller restarts the deck instead).
    func dropQueued(after token: Int) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let i = segments.firstIndex(where: { $0.token == token }) else { return true }
        let tail = segments[(i + 1)...]
        if tail.contains(where: { $0.nodeStart != nil }) { return false }
        segments.removeSubrange((i + 1)...)
        return true
    }

    /// Tokens chained after `token` on this deck.
    func tokens(after token: Int) -> [Int] {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let i = segments.firstIndex(where: { $0.token == token }) else { return [] }
        return segments[(i + 1)...].map(\.token)
    }

    func contains(_ token: Int) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return segments.contains { $0.token == token }
    }

    /// The track playing now: the first segment that hasn't played out (else the last one).
    var firstToken: Int? {
        dispatchPrecondition(condition: .onQueue(queue))
        return (segments.first { !$0.isPlayedOut } ?? segments.last)?.token
    }

    /// Restarts at `frame` of `token`'s track, keeping the tracks chained after it (seek, device change) unless
    /// `keepChain` is false.
    func restart(token: Int, atFrame frame: AVAudioFramePosition, keepChain: Bool = true) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let i = segments.firstIndex(where: { $0.token == token }) else { return }
        var kept = keepChain ? Array(segments[i...]) : [segments[i]]
        reset()
        try kept[0].file.seek(to: frame)
        kept[0].fileStart = kept[0].file.position
        kept[0].nodeStart = nil
        kept[0].isScheduled = false
        kept[0].isPlayedOut = false
        for j in kept.indices.dropFirst() {
            try kept[j].file.seek(to: 0)
            kept[j].fileStart = 0
            kept[j].nodeStart = nil
            kept[j].isScheduled = false
            kept[j].isPlayedOut = false
        }
        segments = kept
        fill()
    }

    /// Stops the node and forgets everything.
    func clear() {
        dispatchPrecondition(condition: .onQueue(queue))
        reset()
        segments = []
        lastPositions = [:]
    }

    private func reset() {
        epoch += 1
        node.stop()
        scheduledEnd = 0
        inFlight = 0
    }

    /// Position of `token`'s track in seconds (nil when the deck doesn't have it).
    func position(of token: Int) -> TimeInterval? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let seg = segments.first(where: { $0.token == token }) else { return nil }
        let rate = format.sampleRate
        guard let start = seg.nodeStart else { return Double(seg.fileStart) / rate }
        guard let renderTime = node.lastRenderTime, let playerTime = node.playerTime(forNodeTime: renderTime) else {
            return lastPositions[token] ?? Double(seg.fileStart) / rate
        }
        let frames = seg.fileStart + max(0, playerTime.sampleTime - start)
        let t = min(Double(frames), Double(seg.file.length)) / rate
        lastPositions[token] = t
        return t
    }

    /// Schedules buffers until `buffersAhead` are in flight or the chain is fully scheduled.
    private func fill() {
        while inFlight < Self.buffersAhead, let i = segments.firstIndex(where: { !$0.isScheduled }) {
            let file = segments[i].file
            let token = segments[i].token
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.bufferFrames) else { return }
            let frames: AVAudioFrameCount
            do {
                frames = try file.read(into: buffer)
            } catch {
                segments[i].isScheduled = true
                onDecodeError?(self, token, error)
                return
            }
            if segments[i].nodeStart == nil { segments[i].nodeStart = scheduledEnd }
            let isLast = frames < Self.bufferFrames || file.position >= file.length
            if frames == 0 {
                // End of file exactly on a buffer boundary: one silent frame carries the "played out" report.
                buffer.frameLength = 1
                for c in 0..<Int(format.channelCount) { buffer.floatChannelData![c][0] = 0 }
            } else if segments[i].gain != 1 {
                var gain = segments[i].gain
                for c in 0..<Int(format.channelCount) {
                    let ch = buffer.floatChannelData![c]
                    vDSP_vsmul(ch, 1, &gain, ch, 1, vDSP_Length(buffer.frameLength))
                }
            }
            if isLast { segments[i].isScheduled = true }
            scheduledEnd += AVAudioFramePosition(buffer.frameLength)
            inFlight += 1
            let epoch = epoch
            if isLast {
                node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    guard let self else { return }
                    self.queue.async { self.bufferDone(epoch: epoch, playedOut: token) }
                }
            } else {
                node.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
                    guard let self else { return }
                    self.queue.async { self.bufferDone(epoch: epoch, playedOut: nil) }
                }
            }
        }
    }

    private func bufferDone(epoch: Int, playedOut token: Int?) {
        guard epoch == self.epoch else { return }
        inFlight = max(0, inFlight - 1)
        if let token, let i = segments.firstIndex(where: { $0.token == token }) {
            segments[i].isPlayedOut = true
            // Keep the last played-out segment (its position stays readable at the end); drop older ones.
            if i + 1 < segments.count { segments.removeSubrange(...i) } else if i > 0 { segments.removeSubrange(..<i) }
            onPlayedOut?(self, token)
        }
        fill()
    }
}

/// The native engine's audio graph. Main-actor API; decoding and scheduling run on `queue`.
@MainActor
final class QTNativeAudioPlayer {
    static let log = Logger(subsystem: "com.roderickqiu.qtube", category: "native")
    static let sampleRate: Double = 44_100
    static let eqFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    let engine = AVAudioEngine()
    let format = QTNativeMemoryAudioFile.processingFormat(sampleRate: QTNativeAudioPlayer.sampleRate)
    private let mixer = AVAudioMixerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let eq = AVAudioUnitEQ(numberOfBands: 10)
    let queue = DispatchQueue(label: "com.roderickqiu.qtube.native-audio", qos: .userInitiated)
    let deckA: QTNativeDeck
    let deckB: QTNativeDeck
    private(set) var active: QTNativeDeck
    private let sink = QTNativeTapSink()
    private var isTapInstalled = false
    private var lastSpectrumPull: TimeInterval = 0
    private var tapCleanup: Task<Void, Never>?
    private var crossfadeTask: Task<Void, Never>?
    nonisolated(unsafe) private var configObserver: NSObjectProtocol?
    private var isConnected = false
    /// The listener wants sound (play) — survives device changes.
    private(set) var isPlaying = false

    /// Linear 0…1 (the main mixer's output volume; 0 when muted or silent).
    var outputVolume: Float = 0.7 { didSet { engine.mainMixerNode.outputVolume = outputVolume } }
    /// A deck's segment played out (main actor).
    var onPlayedOut: ((QTNativeDeck, Int) -> Void)?
    var onDecodeError: ((Int, any Error) -> Void)?
    /// The output device changed and the graph restarted (the engine re-anchors its clock).
    var onRouteChange: (() -> Void)?
    /// The graph couldn't be started again after the output changed (the engine falls back to the web engine).
    var onOutputFailure: ((any Error) -> Void)?

    init() {
        deckA = QTNativeDeck(name: "A", queue: queue, format: format)
        deckB = QTNativeDeck(name: "B", queue: queue, format: format)
        active = deckA
        for (i, band) in eq.bands.enumerated() {
            band.filterType = i == 0 ? .lowShelf : (i == 9 ? .highShelf : .parametric)
            band.frequency = Self.eqFrequencies[i]
            band.bandwidth = 1
            band.gain = 0
            band.bypass = false
        }
        Self.configure(timePitch, rate: 1)
        engine.attach(deckA.node)
        engine.attach(deckB.node)
        engine.attach(mixer)
        engine.attach(timePitch)
        engine.attach(eq)
        for deck in [deckA, deckB] {
            deck.onPlayedOut = { [weak self] deck, token in
                Task { @MainActor in self?.onPlayedOut?(deck, token) }
            }
            deck.onDecodeError = { [weak self] _, token, error in
                Task { @MainActor in self?.onDecodeError?(token, error) }
            }
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged() }
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    var other: QTNativeDeck { active === deckA ? deckB : deckA }

    private func connect() {
        guard !isConnected else { return }
        engine.connect(deckA.node, to: mixer, fromBus: 0, toBus: 0, format: format)
        engine.connect(deckB.node, to: mixer, fromBus: 0, toBus: 1, format: format)
        Self.connectSpeedStage(in: engine, from: mixer, through: timePitch, to: eq, format: format, rate: rate)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = outputVolume
        engine.prepare()
        isConnected = true
    }

    private func startEngine() throws {
        connect()
        if !engine.isRunning { try engine.start() }
    }

    // MARK: Transport

    /// Plays `file` (token) from `time` on the active deck; anything else stops (a crossfade too).
    func start(_ file: QTNativeMemoryAudioFile, token: Int, at time: TimeInterval, gain: Float, autoplay: Bool) throws {
        cancelCrossfade(keepIncoming: false)
        connect()
        let frame = AVAudioFramePosition(max(0, time) * format.sampleRate)
        let deck = active, idle = other
        try queue.sync {
            idle.clear()
            try deck.start(file, token: token, atFrame: frame, gain: gain)
        }
        deck.node.volume = 1
        idle.node.volume = 0
        if autoplay { try play() } else { isPlaying = false }
    }

    func play() throws {
        try startEngine()
        isPlaying = true
        if !active.node.isPlaying { active.node.play() }
        if crossfadeTask != nil, !other.node.isPlaying { other.node.play() }
    }

    func pause() {
        isPlaying = false
        // The nodes hold their timelines (and a running fade) where they are — pausing only the engine would let the
        // node clock run on through the pause — and the device idles.
        active.node.pause()
        if crossfadeTask != nil { other.node.pause() }
        engine.pause()
    }

    /// Moves `token` to `time` (it must be the active deck's current track). A crossfade in progress completes at once.
    func seek(token: Int, to time: TimeInterval) throws {
        cancelCrossfade(keepIncoming: true)
        let deck = active
        let frame = AVAudioFramePosition(max(0, time) * format.sampleRate)
        try queue.sync { try deck.restart(token: token, atFrame: frame) }
        if isPlaying {
            try startEngine()
            deck.node.play()
        }
    }

    func stop() {
        cancelCrossfade(keepIncoming: false)
        isPlaying = false
        let a = deckA, b = deckB
        queue.sync {
            a.clear()
            b.clear()
        }
        removeTap()
        engine.stop()
    }

    /// Appends `file` behind `after` on the active deck (gapless).
    func appendGapless(_ file: QTNativeMemoryAudioFile, token: Int, after: Int, gain: Float) throws -> Bool {
        let deck = active
        return try queue.sync {
            guard deck.contains(after), deck.tokens(after: after).isEmpty else { return false }
            try deck.append(file, token: token, gain: gain)
            return true
        }
    }

    /// Removes tracks chained after `token`. If one is already being scheduled (within the last second of the
    /// current track), restarts the deck at the current position without it.
    func dropQueued(after token: Int) {
        let deck = active
        let dropped = queue.sync { deck.dropQueued(after: token) }
        guard !dropped, let t = position(of: token) else { return }
        let frame = AVAudioFramePosition(t * format.sampleRate)
        try? queue.sync { try deck.restart(token: token, atFrame: frame, keepChain: false) }
        if isPlaying { deck.node.play() }
    }

    func tokens(after token: Int) -> [Int] {
        let deck = active
        return queue.sync { deck.tokens(after: token) }
    }

    func position(of token: Int) -> TimeInterval? {
        let a = deckA, b = deckB
        return queue.sync { a.position(of: token) ?? b.position(of: token) }
    }

    // MARK: Crossfade

    var isCrossfading: Bool { crossfadeTask != nil }

    /// Starts `file` on the idle deck and fades across `duration` seconds; the idle deck becomes the active one at
    /// once (the engine reports the new track from here). `onDone` runs when the old deck has stopped.
    func crossfade(to file: QTNativeMemoryAudioFile, token: Int, gain: Float, duration: TimeInterval) throws {
        cancelCrossfade(keepIncoming: true)
        let incoming = other, outgoing = active
        try queue.sync { try incoming.start(file, token: token, atFrame: 0, gain: gain) }
        incoming.node.volume = 0
        active = incoming
        if isPlaying {
            try startEngine()
            incoming.node.play()
        }
        crossfadeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let t = self.queue.sync { incoming.position(of: token) } ?? 0
                let p = Float(min(1, max(0, t / max(0.05, duration))))
                incoming.node.volume = sin(p * .pi / 2)
                outgoing.node.volume = cos(p * .pi / 2)
                if p >= 1 { break }
                try? await Task.sleep(for: .milliseconds(33))
            }
            guard let self, !Task.isCancelled else { return }
            self.queue.sync { outgoing.clear() }
            outgoing.node.volume = 0
            incoming.node.volume = 1
            self.crossfadeTask = nil
        }
    }

    /// Ends a fade now: the incoming deck at full volume (or, `keepIncoming: false`, both stopped by the caller).
    private func cancelCrossfade(keepIncoming: Bool) {
        guard let task = crossfadeTask else { return }
        task.cancel()
        crossfadeTask = nil
        let outgoing = other
        queue.sync { outgoing.clear() }
        outgoing.node.volume = 0
        if keepIncoming { active.node.volume = 1 }
    }

    // MARK: Speed

    /// Playback speed (source seconds per second), pitch kept. Positions are unaffected: they count source frames.
    private(set) var rate: Double = 1

    /// From one off-normal speed to another the time pitch just changes (seamless). To or from 1× it joins or leaves
    /// the chain, which restarts the graph where the track is (a moment's gap, like an output change). Throws when the
    /// graph won't start again (the engine falls back).
    func setRate(_ newRate: Double) throws {
        let old = rate
        rate = newRate
        Self.configure(timePitch, rate: newRate)
        guard (old == 1) != (newRate == 1), isConnected else { return }
        try restartGraph()
    }

    /// Speed on a time pitch unit (bypassed at 1×, when it is also out of the chain).
    nonisolated static func configure(_ unit: AVAudioUnitTimePitch, rate: Double) {
        unit.rate = Float(rate)
        unit.pitch = 0
        unit.bypass = rate == 1
    }

    /// The deck mixer to the EQ: directly at 1× (bit-exact), else through the time pitch.
    nonisolated static func connectSpeedStage(in engine: AVAudioEngine, from mixer: AVAudioNode, through timePitch: AVAudioUnitTimePitch,
                                              to next: AVAudioNode, format: AVAudioFormat, rate: Double) {
        if rate == 1 {
            engine.connect(mixer, to: next, format: format)
        } else {
            engine.connect(mixer, to: timePitch, format: format)
            engine.connect(timePitch, to: next, format: format)
        }
    }

    // MARK: EQ and spectrum

    /// Gains in dB for the 10 bands (±12), with headroom so boosts don't clip.
    func setEQ(gains: [Float]) {
        for (band, gain) in zip(eq.bands, gains) { band.gain = max(-12, min(12, gain)) }
        let peak = gains.max() ?? 0
        eq.globalGain = peak > 0 ? -peak * 0.6 : 0
        eq.bypass = gains.allSatisfy { $0 == 0 }
    }

    /// `bandCount` log-spaced bands 0…1. The FFT tap runs only while someone keeps asking (the Stage visualizer).
    func spectrum(bandCount: Int) -> [Float] {
        lastSpectrumPull = ProcessInfo.processInfo.systemUptime
        if !isTapInstalled, isConnected {
            eq.installTap(onBus: 0, bufferSize: 2048, format: nil, block: Self.tapBlock(sink))
            isTapInstalled = true
            tapCleanup = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard let self else { return }
                    if ProcessInfo.processInfo.systemUptime - self.lastSpectrumPull > 2 { self.removeTap(); return }
                }
            }
        }
        return sink.bands(bandCount, sampleRate: format.sampleRate)
    }

    var tapFrames: Int { sink.frames }

    /// Built outside the main actor: the tap runs on the render thread.
    private nonisolated static func tapBlock(_ sink: QTNativeTapSink) -> AVAudioNodeTapBlock {
        { buffer, _ in sink.consume(buffer) }
    }

    private func removeTap() {
        tapCleanup?.cancel()
        tapCleanup = nil
        guard isTapInstalled else { return }
        eq.removeTap(onBus: 0)
        isTapInstalled = false
    }

    // MARK: Output device changes

    /// The output device changed (headphones, AirPlay, sample rate): AVAudioEngine has stopped. Restart where the
    /// active track is, as it was (playing or paused). If the graph won't start again, the engine falls back.
    private func configurationChanged() {
        Self.log.info("native: output configuration changed")
        do {
            try restartGraph(afterConfigurationChange: true)
            onRouteChange?()
        } catch {
            Self.log.error("native: the graph didn't restart after a configuration change: \(error, privacy: .public)")
            onOutputFailure?(error)
        }
    }

    /// Rebuilds the connections and restarts the active deck at its position (a configuration change, a stalled clock,
    /// waking from sleep). Throws when the engine won't start.
    func restartGraph(afterConfigurationChange: Bool = false) throws {
        let wasPlaying = isPlaying
        let deck = active
        cancelCrossfade(keepIncoming: true)
        if afterConfigurationChange {
            // The engine stopped by itself and dropped the tap with its configuration.
            isTapInstalled = false
            tapCleanup?.cancel()
        } else {
            engine.stop()
            removeTap()
        }
        isConnected = false
        connect()
        if let token = queue.sync(execute: { deck.firstToken }), let t = position(of: token) {
            try queue.sync { try deck.restart(token: token, atFrame: AVAudioFramePosition(t * format.sampleRate)) }
        }
        if wasPlaying {
            try startEngine()
            deck.node.play()
        }
    }

    /// The graph should be producing sound and is: the engine runs and the active node plays.
    var isRunning: Bool { engine.isRunning && active.node.isPlaying }
}
