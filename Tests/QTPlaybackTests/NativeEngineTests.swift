@preconcurrency import AVFoundation
import Foundation
import QTCore
import Testing
@testable import QTPlayback

/// The native Premium engine's offline parts: in-memory decoding, gapless chaining on a deck (rendered offline), the
/// queue following an engine that moves on by itself, failure classification, the player cache, the vendored solver.
/// The live path runs in `Scripts/native-acceptance.py`.
@Suite struct NativeEngineTests {
    // MARK: Fixtures

    /// A 440 Hz → 880 Hz sweep, AAC-encoded into an .m4a (what YouTube serves is fragmented MP4 AAC; AudioToolbox
    /// reads both through the same parser).
    static func encodedSweep(seconds: Double = 3, sampleRate: Double = 44_100) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appending(path: "qt-native-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                                       AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000]
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        var phase = 0.0
        for i in 0..<Int(frames) {
            let f = 440 + 440 * Double(i) / Double(frames)
            phase += 2 * .pi * f / sampleRate
            let v = Float(sin(phase) * 0.5)
            buffer.floatChannelData![0][i] = v
            buffer.floatChannelData![1][i] = v
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }

    static func decodeAll(_ file: QTNativeMemoryAudioFile) throws -> [Float] {
        var out: [Float] = []
        let buffer = AVAudioPCMBuffer(pcmFormat: file.format, frameCapacity: 4096)!
        while try file.read(into: buffer) > 0 {
            out.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        return out
    }

    // MARK: In-memory decoding

    @Test func decodesFromMemoryLikeAVAudioFileDoes() throws {
        let data = try Self.encodedSweep()
        let memory = try QTNativeMemoryAudioFile(bytes: QTNativeAudioBytes(data))
        // The same bytes through AVAudioFile (on disk, test only) — the reference, priming trimmed.
        let url = FileManager.default.temporaryDirectory.appending(path: "qt-native-ref-\(UUID().uuidString).m4a")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let reference = try AVAudioFile(forReading: url)
        #expect(memory.length == reference.length)
        #expect(abs(memory.duration - 3) < 0.05)

        let ours = try Self.decodeAll(memory)
        let refBuffer = AVAudioPCMBuffer(pcmFormat: reference.processingFormat, frameCapacity: AVAudioFrameCount(reference.length))!
        try reference.read(into: refBuffer)
        let theirs = Array(UnsafeBufferPointer(start: refBuffer.floatChannelData![0], count: Int(refBuffer.frameLength)))
        #expect(ours.count == theirs.count)
        let maxDiff = zip(ours, theirs).map { abs($0 - $1) }.max() ?? 1
        #expect(maxDiff < 1e-5)
    }

    @Test func seeksByFrame() throws {
        let memory = try QTNativeMemoryAudioFile(bytes: QTNativeAudioBytes(try Self.encodedSweep()))
        let all = try Self.decodeAll(memory)
        try memory.seek(to: 44_100)
        #expect(memory.position == 44_100)
        let rest = try Self.decodeAll(memory)
        #expect(rest.count == all.count - 44_100)
        // AAC frames decode independently enough that a seek lands on the same samples (after decoder warm-up).
        let probe = 4096
        let diff = zip(rest[probe..<probe + 1024], all[44_100 + probe..<44_100 + probe + 1024]).map { abs($0 - $1) }.max() ?? 1
        #expect(diff < 0.01)
    }

    @Test func refusesBytesThatArentAudio() {
        #expect(throws: (any Error).self) { try QTNativeMemoryAudioFile(bytes: QTNativeAudioBytes(Data(repeating: 7, count: 4096))) }
    }

    // MARK: Gapless chaining (offline render of a deck)

    @Test func chainedTracksJoinSampleExactly() async throws {
        let data = try Self.encodedSweep(seconds: 2)
        let first = try QTNativeMemoryAudioFile(bytes: QTNativeAudioBytes(data))
        let second = try QTNativeMemoryAudioFile(bytes: QTNativeAudioBytes(data))
        let expected = try Self.decodeAll(try QTNativeMemoryAudioFile(bytes: QTNativeAudioBytes(data)))

        let engine = AVAudioEngine()
        let format = first.format
        let queue = DispatchQueue(label: "test.deck")
        let deck = QTNativeDeck(name: "T", queue: queue, format: format)
        engine.attach(deck.node)
        engine.connect(deck.node, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        let playedOut = PlayedOut()
        deck.onPlayedOut = { _, token in playedOut.add(token) }
        try queue.sync {
            try deck.start(first, token: 1, atFrame: 0, gain: 1)
            try deck.append(second, token: 2, gain: 1)
        }
        deck.node.play()

        let total = expected.count * 2
        var rendered: [Float] = []
        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        while rendered.count < total {
            let n = AVAudioFrameCount(min(2048, total - rendered.count))
            guard try engine.renderOffline(n, to: out) == .success else { break }
            rendered.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
            try await Task.sleep(for: .milliseconds(2))  // the deck refills on its queue
        }
        engine.stop()
        #expect(rendered.count == total)
        // Track 2's first sample follows track 1's last one: the render equals the two decodes back to back.
        let reference = expected + expected
        let maxDiff = zip(rendered, reference).map { abs($0 - $1) }.max() ?? 1
        #expect(maxDiff < 1e-5)
        // No silence at the seam.
        let seam = expected.count
        let window = rendered[(seam - 64)..<(seam + 64)]
        #expect(window.contains { abs($0) > 1e-3 })
        // "Played out" reports need an output device's clock (`.dataPlayedBack`); offline rendering has none, so the
        // seam report is checked live (Scripts/native-acceptance.py: gapless seams counted per advance).
        _ = playedOut
    }

    @Test func positionsFollowTheChain() async throws {
        let data = try Self.encodedSweep(seconds: 1)
        let file = try QTNativeMemoryAudioFile(bytes: QTNativeAudioBytes(data))
        let queue = DispatchQueue(label: "test.deck.pos")
        let deck = QTNativeDeck(name: "P", queue: queue, format: file.format)
        // Connected but never rendered: positions come from the schedule, not a render clock.
        let engine = AVAudioEngine()
        engine.attach(deck.node)
        engine.connect(deck.node, to: engine.mainMixerNode, format: file.format)
        try queue.sync { try deck.start(file, token: 7, atFrame: 22_050, gain: 1) }
        let p = queue.sync { deck.position(of: 7) }
        #expect(abs((p ?? 0) - 0.5) < 0.001)
        #expect(queue.sync { deck.position(of: 8) } == nil)
        #expect(queue.sync { deck.dropQueued(after: 7) })
    }

    // MARK: The queue follows an engine that moves on by itself

    @MainActor
    @Test func queueAdvancesWhenTheEngineJoinsTheNextTrack() async throws {
        let engine = AdvancingEngine()
        let controller = QTQueueController(engine: engine)
        await controller.play(PB.tracks(3))
        #expect(engine.prepared?.track.videoId == "t2")
        #expect(engine.prepared?.queueID == controller.queue.autoplay.first?.id)
        #expect(engine.loads == ["t1"])

        // Up Next changes what is next: the engine hears it.
        controller.playNext([PB.track("x")])
        #expect(engine.prepared?.track.videoId == "x")

        // The engine joins "x" gaplessly: the queue moves on, without loading anything.
        engine.advanceToPrepared()
        for _ in 0..<40 { await Task.yield() }
        #expect(controller.nowPlayingTrack?.videoId == "x")
        #expect(controller.queue.history.map(\.track.videoId) == ["t1"])
        #expect(engine.loads == ["t1"])
        #expect(engine.prepared?.track.videoId == "t2")

        // Repeat One replays on its own: nothing prepared.
        controller.repeatMode = .one
        #expect(engine.prepared == nil)
    }

    @MainActor
    @Test func aStaleAdvanceIsIgnored() async throws {
        let engine = AdvancingEngine()
        let controller = QTQueueController(engine: engine)
        await controller.play(PB.tracks(3))
        let stale = engine.prepared
        controller.playNext([PB.track("y")])
        // An engine reporting the old "next" (it changed meanwhile) doesn't move the queue.
        engine.report(stale)
        for _ in 0..<40 { await Task.yield() }
        #expect(controller.nowPlayingTrack?.videoId == "t1")
    }

    // MARK: Failures, cache, solver

    @Test func classifiesFailures() {
        #expect(QTNativeFailure.playability(.loginRequired("Sign in to confirm you’re not a bot")).isSystemic)
        #expect(!QTNativeFailure.playability(.loginRequired("This video may be inappropriate for some users.")).isSystemic)
        #expect(!QTNativeFailure.playability(.unplayable("Video unavailable")).isSystemic)
        #expect(QTNativeFailure.playability(.unplayable("The page needs to be reloaded.")).isSystemic)
        #expect(QTNativeFailure.from(QTNativeStreamError.http(403)).isSystemic)
        #expect(QTNativeFailure.from(QTNativeStreamError.cipherUnsolved("x")).isSystemic)
        #expect(QTNativeFailure.from(QTNativeStreamError.noPlayableAudio("SABR only")).isSystemic)
        #expect(!QTNativeFailure.from(QTNativeStreamError.noPlayableAudio("no AAC")).isSystemic)
        #expect(!QTNativeFailure.from(URLError(.timedOut)).isSystemic)
        #expect(QTNativeAudioFetcher.isRetryable(QTNativeStreamError.http(403)))
        #expect(QTNativeAudioFetcher.isRetryable(QTNativeFailure.systemic("solver: x")))
        #expect(!QTNativeAudioFetcher.isRetryable(QTNativeFailure.systemic("bot check")))
    }

    @Test func resolvedStreamsKnowWhenTheyExpire() {
        let format = QTNativeAudioFormat(itag: 141, mimeType: "audio/mp4", bitrate: 1, contentLength: 1, url: nil,
                                         signatureCipher: nil, loudnessDb: 3.5, isDrc: false, audioTrackName: nil)
        let soon = Int(Date().timeIntervalSince1970) + 60
        let later = Int(Date().timeIntervalSince1970) + 6 * 3600
        func stream(_ expire: Int) -> QTNativeResolvedStream {
            QTNativeResolvedStream(videoId: "v", client: .webRemix, format: format,
                                   url: URL(string: "https://example.invalid/videoplayback?expire=\(expire)&dur=213.461")!,
                                   userAgent: "ua", durationSeconds: 213, resolveSeconds: 0, fallbacks: [])
        }
        #expect(!stream(soon).isFresh())
        #expect(stream(later).isFresh())
        #expect(stream(later).exactDuration == 213.461)
        #expect(stream(later).loudnessDb == 3.5)
    }

    @Test func playerCacheKeepsTheNewestFew() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "qt-player-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = QTNativePlayerCache(directory: dir, keep: 2)
        for (i, hash) in ["aaaa1111", "bbbb2222", "cccc3333"].enumerated() {
            cache.store(hash: hash, signatureTimestamp: 20_000 + i, preprocessed: "var x = \(i);")
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(cache.entry(for: "aaaa1111") == nil)
        #expect(cache.entry(for: "cccc3333")?.signatureTimestamp == 20_002)
        #expect(cache.entry(for: "cccc3333")?.solverVersion == QTNativeSolverSource.version)
    }

    @Test func solverIsVendoredAndPinned() throws {
        #expect(QTNativeSolverSource.version.split(separator: ".").count == 3)
        let sources = try QTNativeSolverSource.load()
        #expect(sources.lib.hasPrefix("/*!\n * SPDX-License-Identifier: Unlicense"))
        #expect(sources.core.contains("var jsc"))
    }

    @Test func equalizerPresetsHaveTenBands() {
        for preset in QTEqualizerPreset.allCases {
            #expect(preset.gains.count == 10)
            #expect(preset.gains.allSatisfy { abs($0) <= 12 })
        }
        #expect(QTEqualizerPreset.off.gains.allSatisfy { $0 == 0 })
    }
}

/// Collects played-out tokens from the deck's queue.
final class PlayedOut: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Int] = []
    func add(_ t: Int) { lock.withLock { list.append(t) } }
    var tokens: [Int] { lock.withLock { list } }
}

/// An engine that loads instantly and can move on to the prepared item by itself, like a gapless join.
@MainActor
final class AdvancingEngine: QTPlaybackEngine {
    var capabilities: QTPlaybackCapabilities { .premium }
    private(set) var state = QTPlaybackState()
    private(set) var prepared: QTPlaybackItem?
    private(set) var loads: [String] = []
    private var continuations: [UUID: AsyncStream<QTPlaybackState>.Continuation] = [:]

    func stateUpdates() -> AsyncStream<QTPlaybackState> {
        let id = UUID()
        let (stream, c) = AsyncStream<QTPlaybackState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        c.yield(state)
        continuations[id] = c
        return stream
    }

    private func publish() { for c in continuations.values { c.yield(state) } }

    func load(_ item: QTPlaybackItem, autoplay: Bool) async throws {
        loads.append(item.track.videoId)
        state = QTPlaybackState(item: item, status: autoplay ? .playing : .paused,
                                timeline: QTPlaybackTimeline(time: item.startTime, rate: autoplay ? 1 : 0, duration: 100), duration: 100)
        publish()
    }

    func prepareNext(_ item: QTPlaybackItem?) { prepared = item }

    func advanceToPrepared() { report(prepared) }

    func report(_ item: QTPlaybackItem?) {
        guard let item else { return }
        state = QTPlaybackState(item: item, status: .playing, timeline: QTPlaybackTimeline(time: 0, rate: 1, duration: 100), duration: 100)
        publish()
    }

    func play() {}
    func pause() {}
    func seek(to time: TimeInterval) {}
    func setVolume(_ volume: Double) {}
    func setMuted(_ muted: Bool) {}
    func skipAd() {}
    func stop() { state = QTPlaybackState() }
}
