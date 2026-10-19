import Foundation
import Observation
import QTCore
import QTLyrics
import QTPlayback

/// The UI's façade over playback: engine state mirror, queue, likes, shuffle/repeat, current lyrics.
/// Views read it from the environment (`@Environment(QTPlayerModel.self)`).
///
/// Ownership: shared (scaffold). The playback builder may move the queue/advance logic into
/// `QTQueueController` and Now Playing into `QTNowPlayingController`, keeping this public API stable.
@MainActor
@Observable
public final class QTPlayerModel {
    @ObservationIgnored public let engine: any QTPlaybackEngine
    @ObservationIgnored private let lyricsProvider: any QTLyricsProviding
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?

    public private(set) var state = QTPlaybackState()
    public private(set) var queue = QTQueue()
    public var likedTrackIDs: Set<String>
    public var isShuffleOn = false
    public var repeatMode: QTRepeatMode = .off
    /// Lyrics for `nowPlaying` (nil while loading or when there are none).
    public private(set) var lyrics: QTLyricsDocument?
    public private(set) var isLoadingLyrics = false
    /// Song or Video rendition currently loaded.
    public private(set) var mode: QTPlaybackMode = .song

    public init(engine: any QTPlaybackEngine, lyricsProvider: any QTLyricsProviding, likedTrackIDs: Set<String> = []) {
        self.engine = engine
        self.lyricsProvider = lyricsProvider
        self.likedTrackIDs = likedTrackIDs
        state = engine.state
        let stream = engine.stateUpdates()
        stateTask = Task { @MainActor [weak self] in
            for await s in stream {
                guard let self else { return }
                self.apply(s)
            }
        }
    }

    // MARK: Derived

    public var nowPlaying: QTTrack? { queue.nowPlaying?.track }
    public var timeline: QTPlaybackTimeline { state.timeline }
    public var isPlaying: Bool { state.isPlaying }
    public var ad: QTAdState? { state.ad }
    public var duration: TimeInterval { state.duration }
    public var capabilities: QTPlaybackCapabilities { engine.capabilities }

    public func isLiked(_ track: QTTrack) -> Bool { likedTrackIDs.contains(track.videoId) }

    // MARK: Starting playback

    /// Plays `tracks[index]`; the rest of the list continues as Autoplay from `source`.
    public func play(_ tracks: [QTTrack], startingAt index: Int = 0, source: QTQueueSource? = nil,
                     startTime: TimeInterval = 0, autoplay: Bool = true, mode: QTPlaybackMode? = nil) async {
        guard tracks.indices.contains(index), tracks[index].availability.isPlayable else { return }
        queue.play(tracks, startingAt: index, source: source)
        await loadCurrent(startTime: startTime, autoplay: autoplay, mode: mode ?? .song)
    }

    public func togglePlayPause() { engine.togglePlayPause() }
    public func play() { engine.play() }
    public func pause() { engine.pause() }
    public func seek(to time: TimeInterval) { engine.seek(to: time) }
    public func setVolume(_ volume: Double) { engine.setVolume(volume) }
    public func skipAd() { engine.skipAd() }

    public func next() async {
        guard queue.advance() != nil else { return }
        await loadCurrent(startTime: 0, autoplay: true, mode: .song)
    }

    /// Restarts the track if past 3 s, else goes to the previous track (prototype behaviour).
    public func previous() async {
        if state.time > 3 || queue.history.isEmpty {
            engine.seek(to: 0)
            return
        }
        guard queue.goBack() != nil else { return }
        await loadCurrent(startTime: 0, autoplay: true, mode: .song)
    }

    /// Song⇄Video at the same position.
    public func setMode(_ newMode: QTPlaybackMode) async {
        guard newMode != mode, nowPlaying?.hasVideo == true || newMode == .song else { return }
        await loadCurrent(startTime: state.time, autoplay: state.isPlaying, mode: newMode)
    }

    // MARK: Queue edits

    public func playNext(_ tracks: [QTTrack]) { queue.playNext(tracks) }
    public func addToQueue(_ tracks: [QTTrack]) { queue.addToQueue(tracks) }
    public func removeFromQueue(_ ids: Set<UUID>) { queue.remove(ids: ids) }
    public func moveInQueue(fromOffsets: IndexSet, toOffset: Int, in section: QTQueueSection) {
        queue.move(fromOffsets: fromOffsets, toOffset: toOffset, in: section)
    }
    public func clearUpNext() -> QTQueueUndoToken { queue.clearUpNext() }
    public func undoClearUpNext(_ token: QTQueueUndoToken) { queue.undoClearUpNext(token) }

    /// Jumps to a queue item (double-click in the queue list).
    public func jump(to item: QTQueueItem) async {
        if let i = queue.upNext.firstIndex(of: item) {
            queue.upNext.removeSubrange(0..<i)
        } else if let i = queue.autoplay.firstIndex(of: item) {
            queue.autoplay.removeSubrange(0..<i)
            queue.upNext = []
        } else {
            return
        }
        await next()
    }

    // MARK: Likes and lyrics

    public func toggleLike(_ track: QTTrack) {
        if likedTrackIDs.contains(track.videoId) { likedTrackIDs.remove(track.videoId) } else { likedTrackIDs.insert(track.videoId) }
    }

    /// ⌥↑ (+0.1, earlier) / ⌥↓ (-0.1, later).
    public func nudgeLyricsOffset(by delta: TimeInterval) {
        lyrics = lyrics?.withOffset(nudgedBy: delta)
    }

    // MARK: Engine plumbing

    private func loadCurrent(startTime: TimeInterval, autoplay: Bool, mode newMode: QTPlaybackMode) async {
        guard let track = nowPlaying else { return }
        let trackChanged = state.item?.track.videoId != track.videoId
        mode = track.hasVideo ? newMode : .song
        if trackChanged { fetchLyrics(for: track) }
        try? await engine.load(QTPlaybackItem(track: track, mode: mode, startTime: startTime), autoplay: autoplay)
    }

    private func fetchLyrics(for track: QTTrack) {
        lyricsTask?.cancel()
        lyrics = nil
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

    private func apply(_ s: QTPlaybackState) {
        let ended = s.status == .ended && state.status != .ended
        state = s
        guard ended else { return }
        Task { @MainActor in
            if self.repeatMode == .one {
                self.engine.seek(to: 0)
                self.engine.play()
            } else {
                await self.next()
            }
        }
    }
}
