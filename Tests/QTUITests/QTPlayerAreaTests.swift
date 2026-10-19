import AppKit
import Foundation
import QTCore
import QTLyrics
import QTPlayback
import Testing
@testable import QTUI

/// Player area: launch seeding of the queue, Autoplay switch, moving items between sections.
@MainActor
@Suite struct QTPlayerAreaTests {
    private static func track(_ id: String) -> QTTrack {
        QTTrack(videoId: id, title: "Title \(id)", artists: [QTArtistRef(name: "A")], duration: 200)
    }

    private static func makePlayer() async -> (QTPlayerModel, QTMockCatalog) {
        let tracks = ["a", "b", "c", "d"].map(track)
        let catalog = QTMockCatalog(tracks: tracks, liked: QTPlaylist(id: "LM", title: .localized("Liked Songs"), kind: .liked, tracks: tracks))
        let engine = QTSimulatedPlaybackEngine(account: .premium, tickInterval: nil)
        let player = QTPlayerModel(engine: engine, lyricsProvider: QTMockLyricsProvider(catalog: catalog))
        await player.play(tracks, startingAt: 0, source: QTQueueSource(kind: .playlist, id: "LM", title: .localized("Liked Songs")),
                          autoplay: false)
        return (player, catalog)
    }

    @Test func launchSeedsUpNextAndRemovesThemFromAutoplay() async {
        let (player, catalog) = await Self.makePlayer()
        let launch = QTLaunchOptions(arguments: ["qt.player.upNext": "c, d", "qt.player.shuffle": "YES", "qt.player.repeat": "one"])
        QTPlayerLaunch.apply(launch, catalog: catalog, to: player)
        #expect(player.queue.upNext.map(\.track.videoId) == ["c", "d"])
        #expect(player.queue.autoplay.map(\.track.videoId) == ["b"])
        #expect(player.isShuffleOn)
        #expect(player.repeatMode == .one)
    }

    @Test func autoplaySwitchStopsAdvancingIntoAutoplay() async {
        let (player, catalog) = await Self.makePlayer()
        QTPlayerLaunch.apply(QTLaunchOptions(arguments: ["qt.player.autoplay": "NO"]), catalog: catalog, to: player)
        #expect(player.queue.isAutoplayEnabled == false)
        #expect(player.queue.nextItem == nil)
        player.setAutoplayEnabled(true)
        #expect(player.queue.nextItem?.track.videoId == "b")
    }

    @Test func playNextFromAutoplayMovesItemToFrontOfUpNext() async {
        let (player, _) = await Self.makePlayer()
        player.addToQueue([Self.track("x")])
        let d = player.queue.autoplay.first { $0.track.videoId == "d" }!
        player.moveInQueue(itemID: d.id, to: .upNext, at: 0)
        #expect(player.queue.upNext.map(\.track.videoId) == ["d", "x"])
        #expect(!player.queue.autoplay.contains(d))
    }

    /// Tables, the Queue and Home mark the current track the same way: moving level bars while playing, a still
    /// speaker while paused — never a pause glyph (beside a track it reads as "playing"). Every glyph the transport
    /// draws exists.
    @Test func nowPlayingIndicatorAndTransportGlyphs() {
        #expect(QTNowPlayingIndicator.pausedSymbolName.hasPrefix("speaker"))
        #expect(!QTNowPlayingIndicator.pausedSymbolName.contains("pause"))
        for name in ["play.circle.fill", "pause.circle.fill", QTNowPlayingIndicator.pausedSymbolName] {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
        let marker = QTNowPlayingBarsView(pointSize: 12)
        marker.show(isPlaying: true, reduceMotion: false)
        #expect(marker.accessibilityLabel() == QTNowPlayingIndicator.accessibilityLabel(isPlaying: true))
        marker.show(isPlaying: false, reduceMotion: false)
        #expect(marker.accessibilityLabel() == QTNowPlayingIndicator.accessibilityLabel(isPlaying: false))
        #expect(marker.intrinsicContentSize.width > 0)
    }

    /// The now-playing subtitle drops an album that only repeats the song's title (singles).
    @Test func nowPlayingSubtitleSkipsAlbumNamedLikeTheSong() {
        func t(_ title: String, album: String?) -> QTTrack {
            QTTrack(videoId: "s", title: title, artists: [QTArtistRef(name: "Kim Ny Ngọc")],
                    album: album.map { QTAlbumRef(title: $0) }, duration: 200)
        }
        let title = "Đối Với Anh Em Không Còn Cảm Giác"
        #expect(t(title, album: title).qtNowPlayingSubtitle(separator: " — ") == "Kim Ny Ngọc")
        // Same text in decomposed Unicode (a different byte sequence) still counts as the same name.
        #expect(t(title, album: title.decomposedStringWithCanonicalMapping).qtNowPlayingSubtitle(separator: " — ") == "Kim Ny Ngọc")
        #expect(t("Say So", album: "Say So - Single").qtNowPlayingSubtitle(separator: " · ") == "Kim Ny Ngọc")
        #expect(t("Say So", album: "Hot Pink").qtNowPlayingSubtitle(separator: " · ") == "Kim Ny Ngọc · Hot Pink")
        #expect(t("Say So", album: nil).qtNowPlayingSubtitle(separator: " · ") == "Kim Ny Ngọc")
    }
}
