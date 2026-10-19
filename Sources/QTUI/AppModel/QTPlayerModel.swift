import Foundation
import Observation
import QTCore
import QTLyrics
import QTPlayback

/// The UI's façade over playback: engine state mirror, queue, likes, shuffle/repeat, current lyrics.
/// Views read it from the environment (`@Environment(QTPlayerModel.self)`).
///
/// Ownership: shared (scaffold). Queue policy, track-end advance, shuffle/repeat, persistence and the engine live
/// in `QTQueueController` (`playback`); Now Playing + remote commands in `QTNowPlayingController`. This type keeps
/// the UI-facing API stable and adds likes and lyrics.
@MainActor
@Observable
public final class QTPlayerModel {
    /// Queue, engine and advance policy.
    public let playback: QTQueueController
    @ObservationIgnored private let lyricsProvider: any QTLyricsProviding
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?

    public var likedTrackIDs: Set<String> {
        didSet { playback.publishNowPlaying() }
    }
    /// Lyrics for `nowPlaying` (nil while loading or when there are none).
    public private(set) var lyrics: QTLyricsDocument?
    public private(set) var isLoadingLyrics = false

    /// - Parameters:
    ///   - nowPlaying: the process's Now Playing owner. Pass one for real engines; mock/screenshot runs pass nil so
    ///     a paused launch never takes the media keys.
    ///   - queueStore: persistence for the queue (survives relaunch); nil = in-memory.
    public init(engine: any QTPlaybackEngine, lyricsProvider: any QTLyricsProviding, likedTrackIDs: Set<String> = [],
                nowPlaying: QTNowPlayingController? = nil, queueStore: QTQueueStore? = nil) {
        self.lyricsProvider = lyricsProvider
        self.likedTrackIDs = likedTrackIDs
        playback = QTQueueController(engine: engine, nowPlaying: nowPlaying, store: queueStore)
        playback.isLiked = { [weak self] track in self?.likedTrackIDs.contains(track.videoId) ?? false }
        playback.onRemoteLike = { [weak self] track, liked in
            guard let self else { return }
            if liked { self.likedTrackIDs.insert(track.videoId) } else { self.likedTrackIDs.remove(track.videoId) }
        }
        playback.onTrackChange = { [weak self] track in self?.fetchLyrics(for: track) }
    }

    // MARK: Derived

    public var engine: any QTPlaybackEngine { playback.engine }
    public var state: QTPlaybackState { playback.state }
    public var queue: QTQueue { playback.queue }
    /// Song or Video rendition currently loaded.
    public var mode: QTPlaybackMode { playback.mode }
    public var isShuffleOn: Bool {
        get { playback.isShuffleOn }
        set { playback.setShuffle(newValue) }
    }
    public var repeatMode: QTRepeatMode {
        get { playback.repeatMode }
        set { playback.repeatMode = newValue }
    }
    public var nowPlaying: QTTrack? { queue.nowPlaying?.track }
    public var timeline: QTPlaybackTimeline { state.timeline }
    public var isPlaying: Bool { state.isPlaying }
    public var ad: QTAdState? { state.ad }
    public var duration: TimeInterval { state.duration }
    public var capabilities: QTPlaybackCapabilities { playback.capabilities }

    public func isLiked(_ track: QTTrack) -> Bool { likedTrackIDs.contains(track.videoId) }

    // MARK: Starting playback

    /// Plays `tracks[index]`; the rest of the list continues as Autoplay from `source`.
    public func play(_ tracks: [QTTrack], startingAt index: Int = 0, source: QTQueueSource? = nil,
                     startTime: TimeInterval = 0, autoplay: Bool = true, mode: QTPlaybackMode? = nil) async {
        await playback.play(tracks, startingAt: index, source: source, startTime: startTime, autoplay: autoplay, mode: mode ?? .song)
    }

    /// Shuffle a playlist/album/artist or the entire library: shuffle on, random first track.
    public func shuffle(_ tracks: [QTTrack], source: QTQueueSource? = nil) async {
        await playback.shuffle(tracks, source: source)
    }

    public func togglePlayPause() { playback.togglePlayPause() }
    public func play() { playback.play() }
    public func pause() { playback.pause() }
    public func seek(to time: TimeInterval) { playback.seek(to: time) }
    public func setVolume(_ volume: Double) { playback.setVolume(volume) }
    public func skipAd() { playback.skipAd() }

    public func next() async { await playback.next() }

    /// Restarts the track if past 3 s, else goes to the previous track (prototype behaviour).
    public func previous() async { await playback.previous() }

    /// Song⇄Video at the same position.
    public func setMode(_ newMode: QTPlaybackMode) async { await playback.setMode(newMode) }

    public func cycleRepeatMode() { playback.cycleRepeatMode() }

    // MARK: Queue edits

    public func playNext(_ tracks: [QTTrack]) { playback.playNext(tracks) }
    public func addToQueue(_ tracks: [QTTrack]) { playback.addToQueue(tracks) }
    public func removeFromQueue(_ ids: Set<UUID>) { playback.remove(ids) }
    public func moveInQueue(fromOffsets: IndexSet, toOffset: Int, in section: QTQueueSection) {
        playback.move(fromOffsets: fromOffsets, toOffset: toOffset, in: section)
    }
    /// Moves one item between sections ("Play Next" on an Autoplay row, drag from Autoplay into Up Next).
    public func moveInQueue(itemID: UUID, to section: QTQueueSection, at index: Int) {
        playback.move(itemID: itemID, to: section, at: index)
    }
    /// The Autoplay switch in the queue ("Autoplay · from …").
    public func setAutoplayEnabled(_ enabled: Bool) { playback.setAutoplayEnabled(enabled) }
    public func clearUpNext() -> QTQueueUndoToken { playback.clearUpNext() }
    public func undoClearUpNext(_ token: QTQueueUndoToken) { playback.undoClearUpNext(token) }

    /// Jumps to a queue item (double-click in the queue list).
    public func jump(to item: QTQueueItem) async { await playback.jump(to: item) }

    // MARK: Likes and lyrics

    /// Local only: writing likes to the YouTube Music account waits for the user's go-ahead.
    public func toggleLike(_ track: QTTrack) {
        if likedTrackIDs.contains(track.videoId) { likedTrackIDs.remove(track.videoId) } else { likedTrackIDs.insert(track.videoId) }
    }

    /// ⌥↑ (+0.1, earlier) / ⌥↓ (-0.1, later).
    public func nudgeLyricsOffset(by delta: TimeInterval) {
        lyrics = lyrics?.withOffset(nudgedBy: delta)
    }

    private func fetchLyrics(for track: QTTrack?) {
        lyricsTask?.cancel()
        lyrics = nil
        guard let track else {
            isLoadingLyrics = false
            return
        }
        isLoadingLyrics = true
        let provider = lyricsProvider
        let hold = QTReadiness.shared.hold("lyrics \(track.videoId)")
        lyricsTask = Task { @MainActor [weak self] in
            let doc = try? await provider.lyrics(for: track)
            defer { QTReadiness.shared.release(hold) }
            guard let self, !Task.isCancelled, self.nowPlaying?.videoId == track.videoId else { return }
            self.lyrics = doc
            self.isLoadingLyrics = false
        }
    }
}
