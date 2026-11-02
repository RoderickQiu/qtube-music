import AppKit
import Foundation
import QTCore
import QTLyrics
import QTPlayback
import Testing
@testable import QTUI

/// The sleep timer in the app: the menu's choices (checked = active, Turn Off only while one runs, End of Song only
/// with a song), the Dock's submenu, the listener's volume ending a fade, and the DEBUG launch argument.
@MainActor
@Suite struct QTSleepTimerUITests {
    private func makeModel(launch: [String: String] = ["qt.catalog": "mock"]) -> QTAppModel {
        let tracks = [QTTrack(videoId: "sleep-a", title: "A", artists: [QTArtistRef(name: "Artist")], duration: 200)]
        let catalog = QTMockCatalog(tracks: tracks, liked: QTPlaylist(id: "LM", title: .localized("Liked Songs"), kind: .liked,
                                                                      tracks: tracks))
        let player = QTPlayerModel(engine: QTSimulatedPlaybackEngine(account: .premium, tickInterval: nil),
                                   lyricsProvider: QTMockLyricsProvider(catalog: catalog))
        let defaults = UserDefaults(suiteName: "qt.tests.sleep.\(UUID().uuidString)")!
        return QTAppModel(settings: QTSettingsStore(defaults: defaults), player: player, catalog: catalog,
                          launch: QTLaunchOptions(arguments: launch))
    }

    private func choose(_ title: String, in menu: NSMenu) throws {
        let item = try #require(menu.items.first { $0.title == title })
        _ = (item.target as? NSObject)?.perform(try #require(item.action), with: item)
    }

    @Test func theMenuOffersTheLengthsEndOfSongAndTurnOff() async throws {
        let model = makeModel()
        let player = model.player
        let idle = QTSleepTimerMenu.menu(for: player)
        let titles = idle.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles == [15, 30, 45, 60, 90].map { QTLoc.tr("%lld Minutes", table: .player, $0) }
            + [QTLoc.tr("End of Song", table: .player), QTLoc.tr("Turn Off", table: .player)])
        #expect(idle.items.filter(\.isSeparatorItem).count == 2)
        #expect(idle.items.allSatisfy { $0.state == .off })
        #expect(idle.items.first { $0.title == QTLoc.tr("End of Song", table: .player) }?.isEnabled == false, "needs a song")
        #expect(idle.items.last?.isEnabled == false, "nothing to turn off")

        try choose(QTLoc.tr("%lld Minutes", table: .player, 30), in: idle)
        #expect(player.sleepTimer.choice == .minutes(30))
        let running = QTSleepTimerMenu.menu(for: player)
        #expect(running.items.filter { $0.state == .on }.map(\.title) == [QTLoc.tr("%lld Minutes", table: .player, 30)])
        #expect(running.items.last?.isEnabled == true)
        try choose(QTLoc.tr("Turn Off", table: .player), in: running)
        #expect(!player.sleepTimer.isActive)

        await player.play(model.catalog.tracks, autoplay: false)
        let loaded = QTSleepTimerMenu.menu(for: player)
        #expect(loaded.items.first { $0.title == QTLoc.tr("End of Song", table: .player) }?.isEnabled == true)
    }

    @Test func theDockMenuHasTheSleepTimerSubmenu() {
        let model = makeModel()
        model.player.sleepTimer.start(.minutes(45))
        let item = QTDockMenuBuilder.menu(model: model).items.first { $0.title == QTLoc.tr("Sleep Timer", table: .player) }
        #expect(item?.submenu?.items.filter { $0.state == .on }.map(\.title) == [QTLoc.tr("%lld Minutes", table: .player, 45)])
        model.player.sleepTimer.turnOff()
    }

    @Test func theCountdownReadsLikeAClock() {
        let model = makeModel()
        let timer = model.player.sleepTimer
        #expect(QTSleepTimerMenu.countdown(timer) == nil)
        timer.start(.minutes(15), remaining: 754)
        let shown = QTSleepTimerMenu.countdown(timer)
        #expect(shown == QTFormat.duration(754) || shown == QTFormat.duration(753), "\(shown ?? "nil")")
        timer.start(.minutes(90))
        #expect(QTSleepTimerMenu.countdown(timer)?.split(separator: ":").count == 3, "an hour or more shows hours")
        timer.start(.endOfSong)
        #expect(QTSleepTimerMenu.countdown(timer) == nil)
        timer.turnOff()
    }

    @Test func theListenersVolumeDuringTheFadeTurnsTheTimerOff() async {
        let model = makeModel()
        let player = model.player
        await player.play(model.catalog.tracks)
        player.setVolume(0.8)
        player.sleepTimer.start(.minutes(15), remaining: 10)
        #expect(player.sleepTimer.isFading && player.engine.state.volume < 0.8)
        player.setVolume(0.4)
        #expect(!player.sleepTimer.isActive && player.engine.state.volume == 0.4)
    }

    #if DEBUG
    @Test func theLaunchArgumentStartsATimer() {
        let model = makeModel(launch: ["qt.catalog": "mock", "qt.player.sleepTimer": "754"])
        QTPlayerLaunch.applySleepTimer(model.launch, to: model.player)
        let timer = model.player.sleepTimer
        #expect(timer.choice == .minutes(15) && (timer.remaining ?? 0) > 750 && (timer.remaining ?? 0) <= 754)
        timer.turnOff()

        let end = makeModel(launch: ["qt.catalog": "mock", "qt.player.sleepTimer": "end"])
        QTPlayerLaunch.applySleepTimer(end.launch, to: end.player)
        #expect(end.player.sleepTimer.choice == .endOfSong)
        end.player.sleepTimer.turnOff()
    }
    #endif
}
