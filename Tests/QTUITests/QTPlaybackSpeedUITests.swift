import AppKit
import Foundation
import QTCore
import QTLyrics
import QTPlayback
import Testing
@testable import QTUI

/// Playback speed in the app: the saved setting reaches the queue at launch, every change is saved, a catalog switch
/// (new engine) keeps it, and the speed menu offers the choices with Speed Up / Slow Down.
@MainActor
@Suite struct QTPlaybackSpeedUITests {
    private func makeModel(defaults: UserDefaults) -> (QTAppModel, QTPlaybackServices) {
        let tracks = [QTTrack(videoId: "a", title: "A", artists: [QTArtistRef(name: "Artist")], duration: 200)]
        let catalog = QTMockCatalog(tracks: tracks, liked: QTPlaylist(id: "LM", title: .localized("Liked Songs"), kind: .liked,
                                                                      tracks: tracks))
        let player = QTPlayerModel(engine: QTUIStubEngine(), lyricsProvider: QTMockLyricsProvider(catalog: catalog))
        let model = QTAppModel(settings: QTSettingsStore(defaults: defaults), player: player, catalog: catalog,
                               launch: QTLaunchOptions(arguments: [:]))
        let services = QTPlaybackServices()
        services.install(model: model, setup: QTPlaybackSetup(source: .live, engine: .web, isSilent: true, isAnonymous: true,
                                                              publishesNowPlaying: false, persistsQueue: false))
        return (model, services)
    }

    @Test func theSavedSpeedIsAppliedAndEveryChangeSaved() async throws {
        let defaults = try #require(UserDefaults(suiteName: "qt.tests.speed.\(UUID().uuidString)"))
        QTSettingsStore(defaults: defaults).update { $0.playbackEffects.playbackRate = 1.5 }

        let (model, services) = makeModel(defaults: defaults)
        let player = model.player
        #expect(player.rate == 1.5 && player.engine.rate == 1.5)

        player.setRate(0.75)
        #expect(player.engine.rate == 0.75)
        #expect(model.settings.settings.playbackEffects.playbackRate == 0.75)
        #expect(QTSettingsStore(defaults: defaults).settings.playbackEffects.playbackRate == 0.75, "saved")

        // Another engine (here: the demo library's) plays at the same speed.
        await services.switchSource(to: .mock)
        #expect(player.engine is QTSimulatedPlaybackEngine && player.engine.rate == 0.75)
    }

    @Test func theSpeedMenuOffersTheChoicesAndSteps() throws {
        let defaults = try #require(UserDefaults(suiteName: "qt.tests.speed.\(UUID().uuidString)"))
        let (model, _) = makeModel(defaults: defaults)
        let player = model.player
        player.setRate(1.25)
        let menu = QTPlaybackSpeedMenu.menu(for: player)
        let titles = menu.items.map(\.title)
        let label = { (r: Double) in QTPlaybackSpeed.label(r) }
        #expect(titles.prefix(7) == [label(0.5), label(0.75), QTLoc.tr("Normal", table: .player), label(1.25), label(1.5),
                                     label(1.75), label(2)])
        #expect(menu.items.filter { $0.state == .on }.map(\.title) == [label(1.25)])
        let up = try #require(menu.items.first { $0.keyEquivalent == "." })
        #expect(up.keyEquivalentModifierMask == [.command, .option] && up.isEnabled)

        // Choosing from the menu sets it; Speed Up / Slow Down step through the choices and stop at the ends.
        let choice = try #require(menu.items.first { $0.title == label(1.75) })
        _ = (choice.target as? NSObject)?.perform(try #require(choice.action), with: choice)
        #expect(player.rate == 1.75)
        QTPlaybackSpeedMenu.speedUp(player)
        #expect(player.rate == 2)
        #expect(QTPlaybackSpeedMenu.menu(for: player).items.first { $0.keyEquivalent == "." }?.isEnabled == false)
        QTPlaybackSpeedMenu.slowDown(player)
        #expect(player.rate == 1.75)
        #expect(QTPlaybackSpeedMenu.title(for: 1) == QTLoc.tr("Normal", table: .player))
    }
}
