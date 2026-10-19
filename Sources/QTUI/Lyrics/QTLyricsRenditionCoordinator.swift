import Foundation
import Observation
import OSLog
import QTCore
import QTLyrics
import QTPlayback

// Owner: lyrics. Keeps the lyrics in step with the rendition that plays (Song⇄Video). A track's music video is often
// another cut than the song (intro, outro): the lyrics session then shows lyrics timed for that cut, or unsynced
// lyrics (`QTLyricsRenditionTiming`). When both timings line up at one shift, Song⇄Video switches pick up at the same
// moment of the song (`QTQueueController.modeSwitchTime`); a first switch made before the shift was known is put
// right once it is, if that is still within a few seconds of the switch.

@MainActor
final class QTLyricsRenditionCoordinator {
    static let shared = QTLyricsRenditionCoordinator()

    /// A switch to the counterpart that went unmapped (the shift wasn't known yet).
    private struct UnmappedSwitch {
        var trackID: String
        var mode: QTPlaybackMode
        var at: TimeInterval
    }

    /// How long after an unmapped switch the position may still be corrected.
    static let correctionWindow: TimeInterval = 12

    private weak var player: QTPlayerModel?
    private var unmapped: UnmappedSwitch?
    private var lastShiftGeneration = 0
    private let log = Logger(subsystem: "com.roderickqiu.qtube", category: "lyrics-rendition")

    func install(player: QTPlayerModel) {
        self.player = player
        player.playback.modeSwitchTime = { [weak self] track, mode, time in
            self?.switchTime(track: track, to: mode, at: time)
        }
        observe()
    }

    /// The rendition a track plays in `mode`, and whether it is the counterpart of what the lyrics were found for.
    nonisolated static func rendition(track: QTTrack, mode: QTPlaybackMode, duration: TimeInterval) -> QTLyricsRendition? {
        guard duration > 0, duration.isFinite else { return nil }
        let ownMode: QTPlaybackMode = track.musicVideoType.isVideo ? .video : .song
        guard mode != ownMode, let counterpart = track.counterpart, counterpart.videoId != track.videoId else {
            return QTLyricsRendition(videoId: track.videoId, duration: duration, isCounterpart: false)
        }
        return QTLyricsRendition(videoId: counterpart.videoId, duration: duration, isCounterpart: true)
    }

    private func switchTime(track: QTTrack, to mode: QTPlaybackMode, at time: TimeInterval) -> TimeInterval? {
        guard let session = player?.lyricsSession else { return nil }
        let ownMode: QTPlaybackMode = track.musicVideoType.isVideo ? .video : .song
        let toCounterpart = mode != ownMode
        if let mapped = session.switchTime(time, track: track, toCounterpart: toCounterpart) {
            unmapped = nil
            log.info("Song⇄Video at \(time, format: .fixed(precision: 2)) s → \(mapped, format: .fixed(precision: 2)) s (lyrics shift)")
            return mapped
        }
        unmapped = toCounterpart ? UnmappedSwitch(trackID: track.videoId, mode: mode, at: ProcessInfo.processInfo.systemUptime) : nil
        return nil
    }

    private func observe() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    /// Tells the session what plays; corrects a recent unmapped switch once the shift is known.
    private func update() {
        guard let player, let session = player.lyricsSession else { return }
        let state = player.state
        guard let track = player.nowPlaying, let item = state.item, item.track.videoId == track.videoId,
              state.ad == nil, state.status == .playing || state.status == .paused else {
            _ = session.shiftGeneration
            return
        }
        session.setRendition(Self.rendition(track: track, mode: item.mode, duration: state.duration))
        let generation = session.shiftGeneration
        guard generation != lastShiftGeneration else { return }
        lastShiftGeneration = generation
        guard let u = unmapped, u.trackID == track.videoId, u.mode == item.mode, state.status == .playing,
              ProcessInfo.processInfo.systemUptime - u.at < Self.correctionWindow else { return }
        unmapped = nil
        // The counterpart started where the song was (unmapped); it should have started at the mapped position.
        let now = state.timeline.currentTime
        let elapsed = ProcessInfo.processInfo.systemUptime - u.at
        let switchedFrom = max(0, now - elapsed)
        guard let target = session.switchTime(switchedFrom, track: track, toCounterpart: true) else { return }
        let corrected = target + elapsed
        guard abs(corrected - now) > 0.75 else { return }
        log.info("Song⇄Video: correcting \(now, format: .fixed(precision: 2)) s → \(corrected, format: .fixed(precision: 2)) s once the lyrics knew the shift")
        player.seek(to: corrected)
    }
}
