import Foundation
import os

/// Native side of the web engine's spectrum tap (`QTWebAudioScript`): spectrum data for the Stage visualizer,
/// decoded from the stream YouTube Music's own player is playing.
///
/// Pull-driven, so a hidden visualizer costs nothing: the visualizer calls `spectrum(bandCount:)` once per drawn
/// frame, only while it is on screen and playing. About ten times a second such a call pulls a batch from the page:
/// the spectra for the playhead and the next `framesAhead` display frames (`frameStep` apart), which the page can
/// compute because the samples ahead are already decoded. Each call returns the batch frame for *now* (the batch is
/// anchored at the midpoint of its round trip), so the bars follow the audio at display rate with ~10 page calls a
/// second. Nothing runs in the page between pulls; once nobody has asked for `releaseAfter` seconds the page drops
/// its decoded audio.
///
/// Degrades quietly: until data arrive the bands read 0 (the visualizer's resting shape); when the stream can't be
/// read (encrypted, undecodable) `spectrum` returns nil and the visualizer animates on its own.
@MainActor
public final class QTWebAudioTap {
    /// What the page says about the stream under the playhead.
    public enum Status: String, Sendable {
        /// Not asked yet, or released.
        case idle
        /// Bands are flowing.
        case ok
        /// Decoding the seconds under the playhead (the first frame, after a seek).
        case pending
        /// The page's media is paused.
        case paused
        /// Nothing buffered covers the playhead (start of a load, a seek).
        case noData = "nodata"
        /// Encrypted media (EME): the samples can't be read.
        case protected
        /// The page couldn't decode the stream (unknown container or codec).
        case undecodable
        /// No player page (loading, torn down).
        case noPage
    }

    static let log = Logger(subsystem: "com.roderickqiu.qtube", category: "web-audio")

    /// Bands the page computes; requests for other counts are resampled from these.
    nonisolated static let pageBandCount = 48
    /// The page drops its decoded audio this long after the last `spectrum` call.
    nonisolated static let releaseAfter: TimeInterval = 1.0
    /// Bands older than this are stale (the page stopped answering).
    nonisolated static let staleSeconds: TimeInterval = 0.5
    /// Spacing of the frames in a batch (display rate; a 30 fps visualizer takes every other one).
    nonisolated static let frameStep: TimeInterval = 1.0 / 60
    /// Frames per batch (about 170 ms, so batches overlap and a slow round trip never leaves a gap).
    nonisolated static let framesAhead = 10
    /// A new batch this often.
    nonisolated static let pullInterval: TimeInterval = 0.1

    public private(set) var status: Status = .idle
    /// Frames received (diagnostics).
    public private(set) var framesReceived = 0
    /// Batches pulled from the page (diagnostics).
    public private(set) var pulls = 0
    /// True between the first pull and the release.
    public private(set) var isActive = false
    /// Playback speed: a batch's frames are `frameStep` apart in wall time, `frameStep × rate` in the stream.
    var rate: Double = 1

    /// `window.__qtAudio.frames(bands, ahead, dt)` in the page: an array of band arrays, a status string, or nil
    /// (no page).
    var fetchFrames: (@MainActor (_ bands: Int, _ ahead: Int, _ step: TimeInterval) async -> Any?)?
    /// `window.__qtAudio.release()` in the page.
    var releasePage: (@MainActor () async -> Void)?

    /// The last batch and the uptime its first frame belongs to.
    private var batch: [[Float]] = []
    private var batchAnchor: TimeInterval = 0
    private var lastCall: TimeInterval = 0
    private var lastFetch: TimeInterval = 0
    private var isFetching = false
    private var releaseTask: Task<Void, Never>?

    init() {}

    /// Spectrum for the visualizer: `bandCount` magnitudes 0…1, low → high. Nil when the stream can't be read.
    func spectrum(bandCount: Int, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [Float]? {
        guard bandCount > 0 else { return nil }
        lastCall = now
        isActive = true
        let index = Int(((now - batchAnchor) / Self.frameStep).rounded())
        if !isFetching, now - lastFetch >= Self.pullInterval || index >= batch.count - 2 { fetch(now: now) }
        if releaseTask == nil { scheduleRelease() }
        switch status {
        case .protected, .undecodable: return nil
        default: break
        }
        guard let frame = frame(at: now) else { return Array(repeating: 0, count: bandCount) }
        return Self.resample(frame, to: bandCount)
    }

    /// The batch frame for an uptime: the last one a little past the batch's end, nothing once it's stale.
    func frame(at now: TimeInterval) -> [Float]? {
        guard !batch.isEmpty else { return nil }
        let index = Int(((now - batchAnchor) / Self.frameStep).rounded())
        if index >= batch.count {
            return now - batchAnchor < Double(batch.count) * Self.frameStep + Self.staleSeconds ? batch[batch.count - 1] : nil
        }
        return batch[max(0, index)]
    }

    private func fetch(now: TimeInterval) {
        guard let fetchFrames else { return }
        isFetching = true
        lastFetch = now
        pulls += 1
        let step = Self.frameStep * rate
        Task { @MainActor [weak self] in
            let result = await fetchFrames(Self.pageBandCount, Self.framesAhead, step)
            guard let self else { return }
            self.isFetching = false
            // The page read its playhead somewhere in the round trip: anchor the batch at its midpoint.
            self.apply(result, anchor: (now + ProcessInfo.processInfo.systemUptime) / 2)
        }
    }

    /// One page answer: a batch of band sets, or the reason there are none.
    func apply(_ result: Any?, anchor: TimeInterval) {
        let new: Status
        if let frames = result as? [Any], !frames.isEmpty {
            batch = frames.map { ($0 as? [Any] ?? []).map { Float(($0 as? NSNumber)?.doubleValue ?? 0) } }
            batchAnchor = anchor
            framesReceived += batch.count
            new = .ok
        } else if let reason = result as? String {
            new = Status(rawValue: reason) ?? .noData
            if new != .pending { batch = [] }
        } else {
            new = .noPage
            batch = []
        }
        if new != status, new != .pending, new != .paused {
            Self.log.info("spectrum tap: \(new.rawValue, privacy: .public)")
        }
        status = new
    }

    private func scheduleRelease() {
        releaseTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                guard ProcessInfo.processInfo.systemUptime - self.lastCall > Self.releaseAfter else { continue }
                self.releaseTask = nil
                self.isActive = false
                self.batch = []
                self.status = .idle
                await self.releasePage?()
                return
            }
        }
    }

    /// A new item loads (or the page is replaced): old bands and an old stream's verdict no longer apply.
    func itemDidChange() {
        batch = []
        if status == .protected || status == .undecodable { status = .idle }
    }

    /// Resampling of a low → high band set to `count` bands: the max of the covered source bands when shrinking (so
    /// peaks survive), linear interpolation when growing.
    nonisolated static func resample(_ source: [Float], to count: Int) -> [Float] {
        guard count > 0, !source.isEmpty else { return [] }
        if source.count == count { return source }
        let n = source.count
        if count < n {
            return (0..<count).map { i in
                let a = i * n / count, b = max(a + 1, (i + 1) * n / count)
                return source[a..<min(b, n)].max() ?? 0
            }
        }
        return (0..<count).map { i in
            let x = (Double(i) + 0.5) * Double(n) / Double(count) - 0.5
            let a = max(0, min(n - 1, Int(x.rounded(.down)))), b = min(n - 1, a + 1)
            let f = Float(max(0, x - Double(a)))
            return source[a] * (1 - f) + source[b] * f
        }
    }
}
