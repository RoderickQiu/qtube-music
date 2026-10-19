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

    /// Tables and the Queue mark the current track the same way: a speaker only while playing, a pause glyph
    /// while paused. Every glyph the transport draws exists.
    @Test func nowPlayingIndicatorAndTransportGlyphs() {
        #expect(QTNowPlayingIndicator.symbolName(isPlaying: true) == QTIcon.volume.systemName)
        #expect(QTNowPlayingIndicator.symbolName(isPlaying: false) == QTIcon.pause.systemName)
        #expect(!QTNowPlayingIndicator.symbolName(isPlaying: false).hasPrefix("speaker"))
        for name in ["play.circle.fill", "pause.circle.fill", QTNowPlayingIndicator.symbolName(isPlaying: true),
                     QTNowPlayingIndicator.symbolName(isPlaying: false)] {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
    }
}
