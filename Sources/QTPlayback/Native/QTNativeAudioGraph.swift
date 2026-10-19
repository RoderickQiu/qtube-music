import Accelerate
@preconcurrency import AVFoundation
import Foundation

// M5 SPIKE — the native audio path: download → AVAudioFile → AVAudioEngine.
//
//   playerA ─┐
//            ├─ crossfade mixer ─ 10-band AVAudioUnitEQ ─ main mixer (output volume 0 in every test) ─ output
//   playerB ─┘                          └ tap → vDSP FFT → spectrum bands for the visualizer
//
// Gapless: the next track's file is scheduled on the same player node right behind the current one, so it starts on
// the next sample. AudioToolbox reads YouTube's fragmented MP4 (`mp4f`) and honours its AAC priming (2112 frames)
// and remainder, so no encoder padding lands at the seam.
// Crossfade: the next track starts on the other node and the two node volumes ramp in opposite directions.

/// Downloads a googlevideo URL to a local file in ≤ 10 MB range requests (larger single requests get throttled or
/// refused), with the User-Agent of the client that resolved it.
public enum QTNativeStreamDownloader {
    public struct Result: Sendable {
        public var file: URL
        public var bytes: Int
        public var firstByteSeconds: Double
        public var totalSeconds: Double
    }

    public static let chunkSize = 10 * 1024 * 1024

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "com.roderickqiu.qtube.native-spike/audio", directoryHint: .isDirectory)
    }

    /// Deletes every downloaded track (the spike never keeps audio around after a run).
    public static func purge() {
        try? FileManager.default.removeItem(at: directory)
    }

    public static func download(_ stream: QTNativeResolvedStream, session: URLSession = .shared) async throws -> Result {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appending(path: "\(stream.videoId)-\(stream.format.itag).m4a")
        let start = ProcessInfo.processInfo.systemUptime
        var firstByte: Double?
        var data = Data()
        let total = stream.format.contentLength
        var offset = 0
        repeat {
            let end = total.map { min($0, offset + chunkSize) - 1 } ?? (offset + chunkSize - 1)
            var request = URLRequest(url: stream.url)
            request.setValue(stream.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            let (chunk, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 206 || status == 200 else { throw QTNativeStreamError.http(status) }
            if firstByte == nil { firstByte = ProcessInfo.processInfo.systemUptime - start }
            data.append(chunk)
            offset += chunk.count
            if chunk.isEmpty || status == 200 { break }
        } while offset < (total ?? 0)
        try data.write(to: dest, options: .atomic)
        return Result(file: dest, bytes: data.count, firstByteSeconds: firstByte ?? 0,
                      totalSeconds: ProcessInfo.processInfo.systemUptime - start)
    }
}

/// Lock-protected sink the render-thread tap writes into.
final class QTNativeTapSink: @unchecked Sendable {
    private let lock = NSLock()
    private var magnitudes: [Float] = []
    private var firstSignalUptime: Double?
    private var renderedFrames: Int = 0
    private var silentRunFrames = 0
    private var longestSilentRunAfterSignal = 0

    let fftSize = 2048
    private let fft: vDSP.FFT<DSPSplitComplex>?
    private let window: [Float]

    init() {
        fft = vDSP.FFT(log2n: 11, radix: .radix2, ofType: DSPSplitComplex.self)
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: 2048, isHalfWindow: false)
    }

    func reset() {
        lock.withLock {
            firstSignalUptime = nil
            renderedFrames = 0
            silentRunFrames = 0
            longestSilentRunAfterSignal = 0
        }
    }

    /// Render thread. Mono-mixes, FFTs the latest 2048 frames, records first-signal time and silent runs.
    func consume(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let count = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        for c in 0..<count {
            vDSP.add(mono, UnsafeBufferPointer(start: channels[c], count: frames), result: &mono)
        }
        let peak = vDSP.maximumMagnitude(mono)
        var spectrum: [Float] = []
        if let fft, frames >= fftSize {
            let slice = Array(mono.suffix(fftSize))
            let windowed = vDSP.multiply(slice, window)
            var real = [Float](repeating: 0, count: fftSize / 2)
            var imag = [Float](repeating: 0, count: fftSize / 2)
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                        }
                    }
                    fft.forward(input: split, output: &split)
                    spectrum = [Float](repeating: 0, count: fftSize / 2)
                    vDSP.absolute(split, result: &spectrum)
                }
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            if !spectrum.isEmpty { magnitudes = spectrum }
            renderedFrames += frames
            if peak > 1e-4 {
                if firstSignalUptime == nil { firstSignalUptime = now }
                silentRunFrames = 0
            } else if firstSignalUptime != nil {
                silentRunFrames += frames
                longestSilentRunAfterSignal = max(longestSilentRunAfterSignal, silentRunFrames)
            }
        }
    }

    var firstSignal: Double? { lock.withLock { firstSignalUptime } }
    var frames: Int { lock.withLock { renderedFrames } }
    var longestSilence: Int { lock.withLock { longestSilentRunAfterSignal } }

    /// `bandCount` log-spaced bands, 0…1 (−80…0 dBFS).
    func bands(_ bandCount: Int, sampleRate: Double) -> [Float] {
        let mags = lock.withLock { magnitudes }
        guard !mags.isEmpty, bandCount > 0 else { return [] }
        let binHz = sampleRate / Double(fftSize)
        let lo = 40.0, hi = min(16_000.0, sampleRate / 2)
        return (0..<bandCount).map { i in
            let f0 = lo * pow(hi / lo, Double(i) / Double(bandCount))
            let f1 = lo * pow(hi / lo, Double(i + 1) / Double(bandCount))
            let b0 = max(1, Int(f0 / binHz)), b1 = max(b0 + 1, min(mags.count, Int(f1 / binHz)))
            let peak = mags[b0..<b1].max() ?? 0
            let db = 20 * log10(max(peak / Float(fftSize / 4), 1e-8))
            return min(1, max(0, (db + 80) / 80))
        }
    }
}

/// The spike's audio engine. Muted by construction (`mainMixerNode.outputVolume = 0`) unless a test flips it.
@MainActor
public final class QTNativeAudioGraph {
    public static let eqFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    public let engine = AVAudioEngine()
    public let eq = AVAudioUnitEQ(numberOfBands: 10)
    private let playerA = AVAudioPlayerNode()
    private let playerB = AVAudioPlayerNode()
    private let crossfadeMixer = AVAudioMixerNode()
    let sink = QTNativeTapSink()
    private var activeIsA = true

    /// Uptime of the first non-silent buffer the tap saw since the last `play` (time-to-first-audio).
    public var firstSignalUptime: Double? { sink.firstSignal }
    /// Longest run of silent frames after the first signal (a gap at a gapless seam shows up here).
    public var longestSilentRunFrames: Int { sink.longestSilence }
    public func resetMeters() { sink.reset() }
    private var format: AVAudioFormat?

    public init() {
        for (i, band) in eq.bands.enumerated() {
            band.filterType = i == 0 ? .lowShelf : (i == 9 ? .highShelf : .parametric)
            band.frequency = Self.eqFrequencies[i]
            band.bandwidth = 1
            band.gain = 0
            band.bypass = false
        }
        engine.attach(playerA)
        engine.attach(playerB)
        engine.attach(crossfadeMixer)
        engine.attach(eq)
    }

    private var active: AVAudioPlayerNode { activeIsA ? playerA : playerB }
    private var standby: AVAudioPlayerNode { activeIsA ? playerB : playerA }

    /// Wires the graph for the file format and starts the engine (output muted).
    public func start(format: AVAudioFormat) throws {
        if engine.isRunning, self.format == format { return }
        engine.stop()
        self.format = format
        engine.connect(playerA, to: crossfadeMixer, format: format)
        engine.connect(playerB, to: crossfadeMixer, format: format)
        engine.connect(crossfadeMixer, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0
        eq.removeTap(onBus: 0)
        eq.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.tapBlock(sink))
        engine.prepare()
        try engine.start()
    }

    /// Built outside the main actor: the tap runs on the render thread, and a main-actor closure would trap there.
    private nonisolated static func tapBlock(_ sink: QTNativeTapSink) -> AVAudioNodeTapBlock {
        { buffer, _ in sink.consume(buffer) }
    }

    public var isMuted: Bool { engine.mainMixerNode.outputVolume == 0 }

    /// Plays a file now on the active node.
    public func play(_ file: AVAudioFile) throws {
        try start(format: file.processingFormat)
        sink.reset()
        active.stop()
        active.volume = 1
        active.scheduleFile(file, at: nil, completionHandler: nil)
        active.play()
    }

    /// Gapless: appends `file` behind whatever the active node is playing.
    public func enqueueGapless(_ file: AVAudioFile) {
        active.scheduleFile(file, at: nil, completionHandler: nil)
    }

    private static func schedule(_ file: AVAudioFile, on node: AVAudioPlayerNode) {
        node.scheduleFile(file, at: nil, completionHandler: nil)
    }

    /// Starts `file` on the standby node and ramps the two nodes across `duration` seconds (equal-power curve).
    public func crossfade(to file: AVAudioFile, duration: Double) async {
        let incoming = standby
        let outgoing = active
        incoming.stop()
        incoming.volume = 0
        Self.schedule(file, on: incoming) // synchronous: the async overload would wait for the file to finish
        incoming.play()
        activeIsA.toggle()
        let steps = max(1, Int(duration * 30))
        for i in 1...steps {
            let t = Float(i) / Float(steps)
            incoming.volume = sin(t * .pi / 2)
            outgoing.volume = cos(t * .pi / 2)
            try? await Task.sleep(for: .seconds(duration / Double(steps)))
        }
        outgoing.stop()
    }

    public func setEQ(gains: [Float]) {
        for (band, gain) in zip(eq.bands, gains) { band.gain = max(-12, min(12, gain)) }
    }

    public func spectrum(bandCount: Int) -> [Float] {
        sink.bands(bandCount, sampleRate: format?.sampleRate ?? 44_100)
    }

    /// Current position of the active node in seconds.
    public var currentTime: Double {
        guard let nodeTime = active.lastRenderTime, let t = active.playerTime(forNodeTime: nodeTime) else { return 0 }
        return Double(t.sampleTime) / t.sampleRate
    }

    public var activeNodeVolumes: (active: Float, standby: Float) { (active.volume, standby.volume) }

    public func stop() {
        playerA.stop()
        playerB.stop()
        eq.removeTap(onBus: 0)
        engine.stop()
    }

    // MARK: Offline seam check

    /// Gapless proof without a device: renders 2 s around the middle of `file` twice, offline — once straight through,
    /// once as two segments cut at the midpoint and scheduled back to back on one node — and compares the samples.
    /// Identical output means the scheduler adds no gap, so a gapless album plays gaplessly as long as the decoder
    /// trims the encoder priming (checked separately: decoded length = `dur` − 2112 frames).
    public static func seamDifference(_ file: AVAudioFile, window: Double = 1.0) throws
        -> (maxDifference: Float, frames: Int, silentFramesAtCut: Int) {
        let rate = file.processingFormat.sampleRate
        let half = AVAudioFramePosition(window * rate)
        let mid = file.length / 2
        let straight = try renderOffline(file, segments: [(mid - half, 2 * half)])
        let cut = try renderOffline(file, segments: [(mid - half, half), (mid, half)])
        let n = min(straight.count, cut.count)
        var maxDiff: Float = 0
        for i in 0..<n { maxDiff = max(maxDiff, abs(straight[i] - cut[i])) }
        var silent = 0, run = 0
        for i in max(0, Int(half) - 2048)..<min(n, Int(half) + 2048) {
            run = abs(cut[i]) < 1e-6 ? run + 1 : 0
            silent = max(silent, run)
        }
        return (maxDiff, n, silent)
    }

    private static func renderOffline(_ file: AVAudioFile, segments: [(start: AVAudioFramePosition, count: AVAudioFramePosition)])
        throws -> [Float] {
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let format = file.processingFormat
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        for s in segments {
            node.scheduleSegment(file, startingFrame: s.start, frameCount: AVAudioFrameCount(s.count), at: nil,
                                 completionHandler: nil)
        }
        node.play()
        let total = Int(segments.reduce(0) { $0 + $1.count })
        var samples: [Float] = []
        samples.reserveCapacity(total)
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        while samples.count < total {
            let n = min(4096, total - samples.count)
            guard try engine.renderOffline(AVAudioFrameCount(n), to: buffer) == .success,
                  let ch = buffer.floatChannelData else { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(buffer.frameLength)))
        }
        engine.stop()
        return samples
    }
}

/// AVPlayer path (progressive HTTP, no download step): measures readiness and whether a format is playable at all.
@MainActor
public enum QTNativeAVPlayerProbe {
    public struct Result: Sendable {
        public var isPlayable: Bool
        public var readySeconds: Double?
        public var playingSeconds: Double?
        public var error: String?
    }

    public static func probe(url: URL, userAgent: String, timeout: Double = 15) async -> Result {
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPUserAgentKey": userAgent])
        let start = ProcessInfo.processInfo.systemUptime
        let playable = (try? await asset.load(.isPlayable)) ?? false
        guard playable else { return Result(isPlayable: false, error: "asset not playable") }
        let item = AVPlayerItem(asset: asset)
        let player = AVQueuePlayer(items: [item])
        player.volume = 0
        player.isMuted = true
        player.play()
        var ready: Double?
        var playing: Double?
        while ProcessInfo.processInfo.systemUptime - start < timeout {
            if ready == nil, item.status == .readyToPlay { ready = ProcessInfo.processInfo.systemUptime - start }
            if item.status == .failed { break }
            if player.timeControlStatus == .playing, item.currentTime().seconds > 0.05 {
                playing = ProcessInfo.processInfo.systemUptime - start
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let error = item.error.map { "\($0.localizedDescription)" }
        player.pause()
        player.removeAllItems()
        return Result(isPlayable: true, readySeconds: ready, playingSeconds: playing, error: error)
    }
}
