import Foundation
import QTCore

/// What an engine can do. Web engine (every account today): video, AirPlay and visualizer data. The native engine
/// adds gapless, crossfade and EQ.
/// Free users see the missing features greyed out with a one-line reason, never an upsell.
public struct QTPlaybackCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let gapless = QTPlaybackCapabilities(rawValue: 1 << 0)
    public static let crossfade = QTPlaybackCapabilities(rawValue: 1 << 1)
    public static let equalizer = QTPlaybackCapabilities(rawValue: 1 << 2)
    /// Spectrum data for the Stage visualizer (`spectrum(bandCount:)`).
    public static let visualizerData = QTPlaybackCapabilities(rawValue: 1 << 3)
    public static let video = QTPlaybackCapabilities(rawValue: 1 << 4)
    public static let airPlay = QTPlaybackCapabilities(rawValue: 1 << 5)

    public static let premium: QTPlaybackCapabilities = [.gapless, .crossfade, .equalizer, .visualizerData, .video, .airPlay]
    public static let free: QTPlaybackCapabilities = [.video, .airPlay]
    /// The web engine (free and Premium accounts): YouTube's player plus the spectrum tap for the visualizer.
    public static let web: QTPlaybackCapabilities = [.video, .airPlay, .visualizerData]
}

/// Song or Video rendition of a track (Song⇄Video).
public enum QTPlaybackMode: String, Sendable, Hashable, Codable {
    case song, video
}

public struct QTPlaybackItem: Sendable, Hashable {
    public var track: QTTrack
    public var mode: QTPlaybackMode
    /// Seconds; Song⇄Video switches pass the current position so playback keeps its place.
    public var startTime: TimeInterval
    /// The queue entry this item plays (`QTQueueItem.id`). An engine that moves on to the prepared next item by itself
    /// (gapless, crossfade) reports it with this id, and the queue advances to that entry.
    public var queueID: UUID?

    public init(track: QTTrack, mode: QTPlaybackMode = .song, startTime: TimeInterval = 0, queueID: UUID? = nil) {
        self.track = track
        self.mode = mode
        self.startTime = startTime
        self.queueID = queueID
    }
}

/// A YouTube ad playing before the track (free engine). UI: art dimmed, "Ad · 0:11", lyrics paused,
/// scrubber disabled, Skip only when allowed.
public struct QTAdState: Sendable, Hashable {
    public var duration: TimeInterval
    public var remaining: TimeInterval
    /// Seconds until Skip is allowed; 0 = skippable now; nil = this ad can't be skipped.
    public var skippableIn: TimeInterval?

    public init(duration: TimeInterval, remaining: TimeInterval, skippableIn: TimeInterval?) {
        self.duration = duration
        self.remaining = remaining
        self.skippableIn = skippableIn
    }

    public var canSkip: Bool { skippableIn.map { $0 <= 0 } ?? false }
    /// 0…1 for the scrubber while the ad plays.
    public var progress: Double { duration > 0 ? 1 - remaining / duration : 0 }
}

public enum QTPlaybackError: Error, Sendable, Hashable {
    case unavailable(QTAvailability)
    /// Age-gated (or behind a content warning) — needs a signed-in, verified account.
    case ageRestricted
    case network(String)
    case engine(String)
    /// The player page landed on Google's bot check (www.google.com/sorry) instead of YouTube Music. Every item would
    /// hit it, so the queue stops instead of skipping; signing in usually clears it.
    case botCheck

    /// Network trouble rather than a problem with the item: retry later instead of skipping for good.
    public var isNetwork: Bool {
        if case .network = self { return true }
        return false
    }
}

public enum QTPlaybackStatus: Sendable, Hashable {
    case idle
    case loading
    case playing
    case paused
    /// Reached the end of the item; the queue controller decides what's next.
    case ended
    case failed(QTPlaybackError)
}

/// Playback position as an anchor + rate, so renderers interpolate at display rate without the engine
/// publishing 60 updates a second. Changes only on play/pause/seek/track change.
public struct QTPlaybackTimeline: Sendable, Hashable {
    /// Position (seconds) at `anchorUptime`.
    public var time: TimeInterval
    /// 1 while playing, 0 while paused/buffering/ad.
    public var rate: Double
    /// `ProcessInfo.systemUptime` when `time` was sampled.
    public var anchorUptime: TimeInterval
    /// Clamp for interpolation (track duration).
    public var duration: TimeInterval

    public init(time: TimeInterval, rate: Double, anchorUptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
                duration: TimeInterval = .infinity) {
        self.time = time
        self.rate = rate
        self.anchorUptime = anchorUptime
        self.duration = duration
    }

    public static let zero = QTPlaybackTimeline(time: 0, rate: 0, anchorUptime: 0, duration: 0)

    /// Interpolated position at a given uptime.
    public func time(atUptime uptime: TimeInterval) -> TimeInterval {
        min(duration, max(0, time + (uptime - anchorUptime) * rate))
    }

    /// Interpolated position now.
    public var currentTime: TimeInterval { time(atUptime: ProcessInfo.processInfo.systemUptime) }
}

public struct QTPlaybackState: Sendable, Hashable {
    public var item: QTPlaybackItem?
    public var status: QTPlaybackStatus
    public var timeline: QTPlaybackTimeline
    public var duration: TimeInterval
    public var isBuffering: Bool
    public var ad: QTAdState?
    /// 0…1.
    public var volume: Double
    public var isMuted: Bool

    public init(item: QTPlaybackItem? = nil, status: QTPlaybackStatus = .idle, timeline: QTPlaybackTimeline = .zero,
                duration: TimeInterval = 0, isBuffering: Bool = false, ad: QTAdState? = nil, volume: Double = 0.7,
                isMuted: Bool = false) {
        self.item = item
        self.status = status
        self.timeline = timeline
        self.duration = duration
        self.isBuffering = isBuffering
        self.ad = ad
        self.volume = volume
        self.isMuted = isMuted
    }

    /// True while playing (including while an ad plays).
    public var isPlaying: Bool { status == .playing }
    public var isAd: Bool { ad != nil }
    /// Interpolated track position now.
    public var time: TimeInterval { timeline.currentTime }
}

/// One playback engine. Two implementations behind this protocol (draft §11): the free web engine
/// (`QTWebPlaybackEngine`, headless WKWebView with ads) and the Premium native engine (spike in M5).
/// `QTSimulatedPlaybackEngine` drives the UI on mock data.
///
/// Engines only play what they're given. The app owns the queue (`QTQueueController`), Now Playing and
/// remote commands (`QTNowPlayingController`) — never the web page.
@MainActor
public protocol QTPlaybackEngine: AnyObject {
    var capabilities: QTPlaybackCapabilities { get }
    /// Latest state snapshot.
    var state: QTPlaybackState { get }
    /// A new stream per subscriber; yields the current state immediately, then every change
    /// (status, seek, ad countdown ticks, buffering, volume). Not a per-frame clock — use `timeline`.
    func stateUpdates() -> AsyncStream<QTPlaybackState>

    /// Loads (and by default starts) an item. Throws if the item can't be played.
    func load(_ item: QTPlaybackItem, autoplay: Bool) async throws
    func play()
    func pause()
    /// Ignored while an ad plays.
    func seek(to time: TimeInterval)
    func setVolume(_ volume: Double)
    func setMuted(_ muted: Bool)
    /// Skips the current ad if YouTube allows it; no-op otherwise.
    func skipAd()
    func stop()
    /// Spectrum magnitudes 0…1 for the visualizer, or nil without `.visualizerData`.
    func spectrum(bandCount: Int) -> [Float]?
    /// What the queue will play next in order (nil: nothing, or the queue decides at the end — Repeat One, a
    /// Repeat All wrap). Engines with gapless/crossfade prefetch it and may move on to it by themselves: they then
    /// report a state whose item is this one (same `queueID`), and the queue advances without loading.
    func prepareNext(_ item: QTPlaybackItem?)
    /// False while the system reports no usable network path (the queue waits instead of skipping). Default true.
    var isNetworkAvailable: Bool { get }
    /// The current pause came from the listener outside the app's own commands (the Picture in Picture window's
    /// controls): the queue takes it as the listener's pause instead of resuming. Default false.
    var isPausedByListener: Bool { get }
    /// The Mac woke after sleeping `sleep` seconds (the queue paused it on the way down). Engines check their
    /// output and drop state that went stale. Default: nothing.
    func systemDidWake(after sleep: TimeInterval)
}

public extension QTPlaybackEngine {
    func togglePlayPause() {
        state.isPlaying ? pause() : play()
    }

    func spectrum(bandCount: Int) -> [Float]? { nil }

    func prepareNext(_ item: QTPlaybackItem?) {}

    var isNetworkAvailable: Bool { true }

    var isPausedByListener: Bool { false }

    func systemDidWake(after sleep: TimeInterval) {}

    /// The web engine behind this engine: itself, or the one the native engine wraps (videos, the video surface).
    var webEngine: QTWebPlaybackEngine? {
        (self as? QTWebPlaybackEngine) ?? (self as? QTNativePlaybackEngine)?.web
    }
}
