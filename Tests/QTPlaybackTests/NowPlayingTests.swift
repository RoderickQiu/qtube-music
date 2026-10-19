import AppKit
import Foundation
import MediaPlayer
import QTCore
import Testing
@testable import QTPlayback

@MainActor
@Suite struct NowPlayingTests {
    let art = URL(string: "https://lh3.googleusercontent.com/a=w544-h544")!

    var track: QTTrack {
        var t = PB.track("np1", duration: 200)
        t.title = "Trú Mưa"
        t.artists = [QTArtistRef(name: "HKT")]
        t.album = QTAlbumRef(title: "Trú Mưa (Single)")
        t.artwork = [QTArtworkImage(url: URL(string: "https://example.com/s=w120")!, width: 120, height: 120),
                     QTArtworkImage(url: art, width: 544, height: 544)]
        t.counterpart = QTCounterpart(videoId: "np1-mv", musicVideoType: .omv,
                                      artwork: [QTArtworkImage(url: URL(string: "https://example.com/mv.jpg")!, width: 1280, height: 720)])
        return t
    }

    func state(_ status: QTPlaybackStatus, time: TimeInterval, rate: Double, at uptime: TimeInterval = 100,
               mode: QTPlaybackMode = .song, ad: QTAdState? = nil) -> QTPlaybackState {
        QTPlaybackState(item: QTPlaybackItem(track: track, mode: mode), status: status,
                        timeline: QTPlaybackTimeline(time: time, rate: rate, anchorUptime: uptime, duration: 200),
                        duration: 200, ad: ad)
    }

    // MARK: Mapping

    @Test func playingSongMapsToNowPlayingInfo() {
        let s = QTNowPlayingSnapshot(track: track, state: state(.playing, time: 30, rate: 1), isLiked: true,
                                     adLabel: "Ad", uptime: 105)
        let info = s.info
        #expect(info[MPMediaItemPropertyTitle] as? String == "Trú Mưa")
        #expect(info[MPMediaItemPropertyArtist] as? String == "HKT")
        #expect(info[MPMediaItemPropertyAlbumTitle] as? String == "Trú Mưa (Single)")
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 200)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 35)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
        #expect(info[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double == 1)
        #expect((info[MPNowPlayingInfoPropertyMediaType] as? NSNumber)?.uintValue == MPNowPlayingInfoMediaType.audio.rawValue)
        #expect(info[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String == "np1")
        #expect(s.playbackState == .playing)
        #expect(s.artworkURL == art)
        #expect(s.isLiked)
    }

    @Test func pausedBufferingAndEndedStopTheClock() {
        let paused = QTNowPlayingSnapshot(track: track, state: state(.paused, time: 30, rate: 0), isLiked: false, adLabel: "Ad", uptime: 500)
        #expect(paused.rate == 0 && paused.elapsed == 30 && paused.playbackState == .paused)
        var buffering = state(.playing, time: 30, rate: 0)
        buffering.isBuffering = true
        #expect(QTNowPlayingSnapshot(track: track, state: buffering, isLiked: false, adLabel: "Ad").rate == 0)
        #expect(QTNowPlayingSnapshot(track: track, state: state(.ended, time: 200, rate: 0), isLiked: false, adLabel: "Ad").playbackState == .stopped)
        #expect(QTNowPlayingSnapshot(track: track, state: state(.loading, time: 0, rate: 0), isLiked: false, adLabel: "Ad").playbackState == .paused)
    }

    @Test func adsShowTheAdClockNotTheSong() {
        let ad = QTAdState(duration: 15, remaining: 11, skippableIn: nil)
        let s = QTNowPlayingSnapshot(track: track, state: state(.playing, time: 0, rate: 0, ad: ad), isLiked: false,
                                     adLabel: "Advertisement")
        #expect(s.isAd)
        #expect(s.title == "Trú Mưa")
        #expect(s.artist == "Advertisement")
        #expect(s.duration == 15 && s.elapsed == 4)
        #expect(s.info[MPMediaItemPropertyAlbumTitle] == nil)
    }

    @Test func videoModeUsesTheVideoStillAndMediaType() {
        let s = QTNowPlayingSnapshot(track: track, state: state(.playing, time: 0, rate: 1, mode: .video), isLiked: false, adLabel: "Ad")
        #expect(s.isVideo)
        #expect(s.artworkURL?.lastPathComponent == "mv.jpg")
        #expect((s.info[MPNowPlayingInfoPropertyMediaType] as? NSNumber)?.uintValue == MPNowPlayingInfoMediaType.video.rawValue)
    }

    // MARK: Controller

    final class Clock { var now: TimeInterval = 100 }

    func controller(_ center: RecordingInfoCenter, clock: Clock, artwork: Data? = nil) -> QTNowPlayingController {
        QTNowPlayingController(center: center, commandCenter: nil, artworkLoader: { _ in artwork }, uptime: { clock.now })
    }

    @Test func staysSilentUntilPlaybackStartsThenPublishesOnlyMeaningfulChanges() {
        let center = RecordingInfoCenter()
        let clock = Clock()
        let np = controller(center, clock: clock)

        np.update(track: track, state: state(.paused, time: 31.5, rate: 0), isLiked: false)
        #expect(!np.isActive && center.writes == 0, "a paused launch never claims Now Playing")

        np.update(track: track, state: state(.playing, time: 31.5, rate: 1), isLiked: false)
        #expect(np.isActive && center.writes == 1)
        #expect(center.playbackState == .playing)

        clock.now += 10  // same timeline, the system interpolates
        np.update(track: track, state: state(.playing, time: 31.5, rate: 1), isLiked: false)
        #expect(center.writes == 1)

        np.update(track: track, state: state(.playing, time: 90, rate: 1, at: clock.now), isLiked: false)  // seek
        #expect(center.writes == 2)
        #expect(center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 90)

        np.update(track: track, state: state(.playing, time: 90, rate: 1, at: clock.now), isLiked: true)
        #expect(center.writes == 3, "like state is metadata")

        np.update(track: track, state: state(.paused, time: 91, rate: 0, at: clock.now), isLiked: true)
        #expect(center.playbackState == .paused)

        np.update(track: nil, state: QTPlaybackState(), isLiked: false)
        #expect(center.nowPlayingInfo == nil && !np.isActive)
    }

    @Test func artworkIsAttachedOnceLoaded() async throws {
        let png = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }.tiffRepresentation
        let center = RecordingInfoCenter()
        let np = controller(center, clock: Clock(), artwork: png)
        np.update(track: track, state: state(.playing, time: 0, rate: 1), isLiked: false)
        for _ in 0..<50 where center.nowPlayingInfo?[MPMediaItemPropertyArtwork] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyArtwork] is MPMediaItemArtwork)
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Trú Mưa")
    }

    // MARK: Remote commands through the queue controller

    @Test func remoteCommandsDriveTheQueue() async {
        let center = RecordingInfoCenter()
        let np = QTNowPlayingController(center: center, commandCenter: nil, artworkLoader: { _ in nil })
        let rig = Rig(nowPlaying: np)
        #expect(np.handle(.play) == false, "nothing loaded")

        var liked: [(String, Bool)] = []
        rig.controller.onRemoteLike = { t, l in liked.append((t.videoId, l)) }
        await rig.controller.play(PB.tracks(3))
        await rig.settle()
        #expect(np.isActive)
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Title t1")

        #expect(np.handle(.next))
        await rig.settle()
        #expect(rig.nowID == "t2")
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Title t2")

        #expect(np.handle(.pause))
        await rig.settle()
        #expect(rig.engine.state.status == .paused)
        #expect(center.playbackState == .paused)
        #expect(np.handle(.togglePlayPause))
        #expect(rig.engine.state.status == .playing)

        #expect(np.handle(.seek(50)))
        #expect(rig.engine.state.timeline.time == 50)

        #expect(np.handle(.like(true)))
        #expect(liked.count == 1 && liked[0] == ("t2", true))

        #expect(np.handle(.setRepeat(.one)))
        #expect(rig.controller.repeatMode == .one)
        #expect(np.handle(.setShuffle(true)))
        #expect(rig.controller.isShuffleOn)

        rig.engine.playAd()
        await rig.settle()
        #expect(np.handle(.seek(10)) == false, "no seeking during ads")
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyArtist] as? String == QTLoc.tr("Advertisement"))
    }
}
