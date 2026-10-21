import AppKit
import Foundation
import MediaPlayer
import QTCore

/// What the system Now Playing card shows, derived from a track and the engine state. Pure value so the
/// mapping is unit-tested without touching `MPNowPlayingInfoCenter`.
public struct QTNowPlayingSnapshot: Equatable, Sendable {
    public var videoID: String
    public var title: String
    public var artist: String
    public var album: String?
    /// Seconds; the ad's length while an ad plays.
    public var duration: TimeInterval
    /// Seconds at the moment the snapshot was taken.
    public var elapsed: TimeInterval
    /// The playback speed while audibly playing (1 at normal speed and during ads), 0 when paused, loading or
    /// buffering. The system moves the elapsed time on at this rate.
    public var rate: Double
    public var isAd: Bool
    public var isVideo: Bool
    public var isLiked: Bool
    public var artworkURL: URL?
    public var playbackState: QTNowPlayingPlaybackState

    /// - Parameters:
    ///   - adLabel: localized "Advertisement", shown in place of the artist while an ad plays.
    ///   - uptime: the instant to sample the timeline at (tests pass a fixed value).
    ///   - wantsPlayback: the listener's intent (`QTQueueController.wantsPlayback`). A track loading for a listener who
    ///     wants it reads as playing (rate 0), like Music while it buffers, so Control Center and the Touch Bar show
    ///     Pause — the same as the app's own controls.
    public init(track: QTTrack, state: QTPlaybackState, isLiked: Bool, adLabel: String,
                uptime: TimeInterval = ProcessInfo.processInfo.systemUptime, wantsPlayback: Bool = false) {
        videoID = track.videoId
        title = track.title
        album = track.album?.title
        isVideo = state.item?.mode == .video
        self.isLiked = isLiked
        artworkURL = (isVideo ? track.videoArtwork : track.artwork).best(forPixelWidth: 600)?.url
            ?? track.artwork.best(forPixelWidth: 600)?.url
        let playing = state.status == .playing && !state.isBuffering
        // The engine's timeline runs at the speed while content plays (and stands still when it does); an ad's
        // countdown always at 1×.
        rate = playing ? (state.ad == nil ? state.timeline.rate : 1) : 0
        if let ad = state.ad {
            isAd = true
            artist = adLabel
            duration = ad.duration
            elapsed = max(0, ad.duration - ad.remaining)
        } else {
            isAd = false
            artist = track.artistLine
            duration = state.duration > 0 ? state.duration : track.duration
            elapsed = state.timeline.time(atUptime: uptime)
        }
        switch state.status {
        case .playing: playbackState = .playing
        case .loading: playbackState = wantsPlayback ? .playing : .paused
        case .paused: playbackState = .paused
        case .ended, .idle, .failed: playbackState = .stopped
        }
    }

    /// `MPNowPlayingInfoCenter.nowPlayingInfo` without artwork (artwork is attached by the controller).
    public var info: [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: NSNumber(value: (isVideo ? MPNowPlayingInfoMediaType.video : .audio).rawValue),
            MPNowPlayingInfoPropertyExternalContentIdentifier: videoID,
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]
        if let album, !isAd { info[MPMediaItemPropertyAlbumTitle] = album }
        return info
    }

    /// True when only the clock moved (no need to push metadata/artwork again).
    func differsOnlyInTiming(from other: QTNowPlayingSnapshot) -> Bool {
        var a = self, b = other
        a.elapsed = 0
        b.elapsed = 0
        return a == b
    }
}

public enum QTNowPlayingPlaybackState: Sendable, Hashable {
    case playing, paused, stopped

    var system: MPNowPlayingPlaybackState {
        switch self {
        case .playing: .playing
        case .paused: .paused
        case .stopped: .stopped
        }
    }
}

/// Remote commands the app handles (media keys, Control Center, AirPods, Touch Bar).
public enum QTRemoteCommand: Sendable, Hashable {
    case play, pause, togglePlayPause, next, previous
    case seek(TimeInterval)
    case like(Bool)
    case setShuffle(Bool)
    case setRepeat(QTRepeatMode)
    /// Playback speed (`changePlaybackRateCommand`; 0.5–2).
    case setRate(Double)
}

/// Where Now Playing info goes. `MPNowPlayingInfoCenter.default()` in the app; a recorder in tests.
@MainActor
public protocol QTNowPlayingInfoPublishing: AnyObject {
    var nowPlayingInfo: [String: Any]? { get set }
    var playbackState: MPNowPlayingPlaybackState { get set }
}

extension MPNowPlayingInfoCenter: QTNowPlayingInfoPublishing {}

/// The single owner of Now Playing info and remote commands. Exactly one instance talks to
/// `MPNowPlayingInfoCenter.default()` / `MPRemoteCommandCenter.shared()` in a process; WebKit never does
/// (see `QTWebKitTuning`).
///
/// It stays silent until playback actually starts once (`activate`), so launching paused — screenshot runs,
/// a restored queue — never steals the media keys from whatever the user is listening to.
@MainActor
public final class QTNowPlayingController {
    public typealias CommandHandler = @MainActor (QTRemoteCommand) -> Bool
    public typealias ArtworkLoader = @Sendable (URL) async -> Data?

    public private(set) var isActive = false
    public private(set) var snapshot: QTNowPlayingSnapshot?
    /// Handles remote commands; return false when the command can't apply (e.g. nothing loaded).
    public var commandHandler: CommandHandler?

    private let center: any QTNowPlayingInfoPublishing
    private let commandCenter: MPRemoteCommandCenter?
    private let artworkLoader: ArtworkLoader
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var artwork: (url: URL, value: MPMediaItemArtwork)?
    private var artworkTask: Task<Void, Never>?
    private var requestedArtworkURL: URL?
    private var publishedAt: TimeInterval = 0
    private let uptime: @MainActor () -> TimeInterval

    /// - Parameters:
    ///   - center: `MPNowPlayingInfoCenter.default()` unless testing.
    ///   - commandCenter: `MPRemoteCommandCenter.shared()`; nil in tests (commands go through `handle(_:)`).
    ///   - uptime: clock for elapsed-time sampling (tests inject a manual clock).
    public init(center: any QTNowPlayingInfoPublishing = MPNowPlayingInfoCenter.default(),
                commandCenter: MPRemoteCommandCenter? = .shared(),
                artworkLoader: @escaping ArtworkLoader = QTNowPlayingController.loadArtworkData,
                uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.center = center
        self.commandCenter = commandCenter
        self.artworkLoader = artworkLoader
        self.uptime = uptime
    }

    // MARK: Publishing

    /// Publishes the current item. Call on every engine state / like change; cheap when nothing changed.
    /// Becomes active the first time `state` is playing. `wantsPlayback`: the listener's intent (see the snapshot).
    public func update(track: QTTrack?, state: QTPlaybackState, isLiked: Bool, wantsPlayback: Bool = false) {
        guard let track, state.item != nil else {
            if isActive { clear() }
            return
        }
        if !isActive {
            guard state.status == .playing else { return }
            activate()
        }
        let now = uptime()
        let next = QTNowPlayingSnapshot(track: track, state: state, isLiked: isLiked, adLabel: QTLoc.tr("Advertisement"), uptime: now,
                                        wantsPlayback: wantsPlayback)
        if let previous = snapshot, previous.differsOnlyInTiming(from: next) {
            // The system interpolates elapsed time from the rate; only re-publish when it would drift.
            let predicted = previous.elapsed + previous.rate * (now - publishedAt)
            if abs(predicted - next.elapsed) < 0.5 { return }
        }
        snapshot = next
        publishedAt = now

        var info = next.info
        if let artwork, artwork.url == next.artworkURL { info[MPMediaItemPropertyArtwork] = artwork.value }
        center.nowPlayingInfo = info
        center.playbackState = next.playbackState.system
        updateCommandAvailability(next)

        if next.artworkURL != artwork?.url, next.artworkURL != requestedArtworkURL {
            fetchArtwork(for: next)
        }
    }

    /// Removes the entry (queue cleared, sign-out, engine switch to nothing).
    public func clear() {
        artworkTask?.cancel()
        requestedArtworkURL = nil
        snapshot = nil
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        deactivate()
    }

    // MARK: Remote commands

    /// Routes a command to `commandHandler`. Public so tests and AppleScript/Shortcuts can drive the same path.
    @discardableResult
    public func handle(_ command: QTRemoteCommand) -> Bool {
        commandHandler?(command) ?? false
    }

    private func activate() {
        guard !isActive else { return }
        isActive = true
        guard let cc = commandCenter else { return }
        func on(_ command: MPRemoteCommand, _ make: @escaping @MainActor (MPRemoteCommandEvent) -> QTRemoteCommand?) {
            command.isEnabled = true
            let target = command.addTarget(handler: Self.makeHandler { [weak self] event in
                guard let self, let mapped = make(event) else { return .commandFailed }
                return self.handle(mapped) ? .success : .noActionableNowPlayingItem
            })
            commandTargets.append((command, target))
        }
        on(cc.playCommand) { _ in .play }
        on(cc.pauseCommand) { _ in .pause }
        on(cc.stopCommand) { _ in .pause }
        on(cc.togglePlayPauseCommand) { _ in .togglePlayPause }
        on(cc.nextTrackCommand) { _ in .next }
        on(cc.previousTrackCommand) { _ in .previous }
        on(cc.changePlaybackPositionCommand) { event in
            (event as? MPChangePlaybackPositionCommandEvent).map { .seek($0.positionTime) }
        }
        on(cc.likeCommand) { event in
            (event as? MPFeedbackCommandEvent).map { .like(!$0.isNegative) }
        }
        on(cc.changeShuffleModeCommand) { event in
            (event as? MPChangeShuffleModeCommandEvent).map { .setShuffle($0.shuffleType != .off) }
        }
        on(cc.changeRepeatModeCommand) { event in
            (event as? MPChangeRepeatModeCommandEvent).map { e in
                switch e.repeatType {
                case .one: .setRepeat(.one)
                case .all: .setRepeat(.all)
                default: .setRepeat(.off)
                }
            }
        }
        on(cc.changePlaybackRateCommand) { event in
            (event as? MPChangePlaybackRateCommandEvent).map { .setRate(Double($0.playbackRate)) }
        }
        cc.changePlaybackRateCommand.supportedPlaybackRates = QTPlaybackSpeed.choices.map { NSNumber(value: $0) }
        cc.likeCommand.localizedTitle = QTLoc.tr("Like")
        for unsupported in [cc.skipForwardCommand, cc.skipBackwardCommand, cc.seekForwardCommand, cc.seekBackwardCommand,
                            cc.dislikeCommand, cc.bookmarkCommand, cc.ratingCommand] {
            unsupported.isEnabled = false
        }
    }

    #if DEBUG
    /// DEBUG: delivers a command *through `MPRemoteCommandCenter`* exactly as a media key or Control Center would —
    /// MediaPlayer builds the event (`-[MPRemoteCommand newCommandEvent]`) and dispatches it to the registered
    /// targets (`-invokeCommandWithEvent:completion:`). Real media keys need physical input; this exercises the
    /// same handlers in-process. Returns false when the command has no target (Now Playing not active yet) or
    /// MediaPlayer's internals changed.
    @discardableResult
    public func debugSimulateSystemCommand(_ name: String) -> Bool {
        guard isActive, let cc = commandCenter else { return false }
        let command: MPRemoteCommand
        switch name {
        case "play": command = cc.playCommand
        case "pause": command = cc.pauseCommand
        case "toggle", "togglePlayPause": command = cc.togglePlayPauseCommand
        case "next": command = cc.nextTrackCommand
        case "previous": command = cc.previousTrackCommand
        default: return false
        }
        let make = NSSelectorFromString("newCommandEvent")
        let invoke = NSSelectorFromString("invokeCommandWithEvent:completion:")
        guard command.responds(to: make), command.responds(to: invoke),
              let event = command.perform(make)?.takeRetainedValue() else { return false }
        typealias Completion = @convention(block) (UnsafeRawPointer?) -> Void
        typealias Invoke = @convention(c) (AnyObject, Selector, AnyObject, Completion?) -> Void
        let imp = unsafeBitCast(command.method(for: invoke), to: Invoke.self)
        let completion: Completion = { _ in }
        imp(command, invoke, event, completion)
        return true
    }
    #endif

    private func deactivate() {
        guard isActive else { return }
        isActive = false
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets.removeAll()
    }

    private func updateCommandAvailability(_ s: QTNowPlayingSnapshot) {
        guard let cc = commandCenter else { return }
        cc.changePlaybackPositionCommand.isEnabled = !s.isAd && s.duration > 0
        cc.likeCommand.isActive = s.isLiked
    }

    /// Builds the block MediaPlayer calls. Made outside the main actor on purpose: a closure formed in a
    /// `@MainActor` method inherits that isolation and traps if MediaPlayer ever calls it from its own queue.
    nonisolated private static func makeHandler(
        _ body: @escaping @MainActor (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { event in
            nonisolated(unsafe) let event = event  // immutable once delivered
            return onMain { body(event) }
        }
    }

    /// The artwork callback runs on MediaPlayer's queue (`-jpegDataWithSize:`), so it must not be main-actor
    /// isolated — it only hands back an immutable image.
    nonisolated private static func makeArtwork(_ image: NSImage) -> MPMediaItemArtwork {
        let box = QTSendableImage(image)
        return MPMediaItemArtwork(boundsSize: image.size) { _ in box.image }
    }

    /// MediaPlayer calls handlers on the main thread on macOS; hop explicitly if that ever changes.
    nonisolated private static func onMain(_ body: @MainActor () -> MPRemoteCommandHandlerStatus) -> MPRemoteCommandHandlerStatus {
        if Thread.isMainThread {
            return QTMainActorHop.onMainThread { body() }
        }
        return DispatchQueue.main.sync { QTMainActorHop.onMainThread { body() } }
    }

    // MARK: Artwork

    private func fetchArtwork(for snapshot: QTNowPlayingSnapshot) {
        artworkTask?.cancel()
        requestedArtworkURL = snapshot.artworkURL
        guard let url = snapshot.artworkURL else { return }
        let loader = artworkLoader
        artworkTask = Task { @MainActor [weak self] in
            guard let data = await loader(url), !Task.isCancelled, let image = NSImage(data: data) else { return }
            guard let self, self.snapshot?.artworkURL == url else { return }
            let value = Self.makeArtwork(image)
            self.artwork = (url, value)
            var info = self.center.nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = value
            self.center.nowPlayingInfo = info
        }
    }

    /// Reads file URLs (mock catalog) directly and fetches http(s) with the shared URL cache.
    public static let loadArtworkData: ArtworkLoader = { url in
        if url.isFileURL { return try? Data(contentsOf: url) }
        return try? await URLSession.shared.data(from: url).0
    }
}

/// NSImage is immutable once handed to MediaPlayer; the artwork callback may run off the main thread.
private final class QTSendableImage: @unchecked Sendable {
    let image: NSImage
    init(_ image: NSImage) { self.image = image }
}
