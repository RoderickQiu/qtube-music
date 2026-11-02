import AppKit
import Foundation
import QTCore
import QTInnerTube
import QTLyrics
import QTPlayback
import Testing
@testable import QTUI

/// "Don't Play This Artist" in the app: menus, Undo, the queue hook, search, the launch list.
@MainActor
@Suite struct QTArtistBlockingTests {
    static let velvet = QTArtistRef(id: "UCvelvet", name: "The Velvet Sundown")
    static let other = QTArtistRef(id: "UCok", name: "Real Band")

    static func model(arguments: [String: String] = [:]) -> QTAppModel {
        let tracks = [QTTrack(videoId: "a", title: "A", artists: [other], duration: 200)]
        let catalog = QTMockCatalog(tracks: tracks, liked: QTPlaylist(id: "LM", title: .localized("Liked Songs"), kind: .liked,
                                                                      tracks: tracks))
        let player = QTPlayerModel(engine: QTSimulatedPlaybackEngine(account: .premium, tickInterval: nil),
                                   lyricsProvider: QTMockLyricsProvider(catalog: catalog))
        let defaults = UserDefaults(suiteName: "qt.tests.blocking.\(UUID().uuidString)")!
        let model = QTAppModel(settings: QTSettingsStore(defaults: defaults), player: player, catalog: catalog,
                               launch: QTLaunchOptions(arguments: arguments))
        QTArtistBlocking.install(model: model)
        return model
    }

    static func track(_ id: String, _ artists: QTArtistRef...) -> QTTrack {
        QTTrack(videoId: id, title: id, artists: artists, duration: 180)
    }

    @Test func blockingSavesTheListTellsTheQueueAndUndoes() {
        let model = Self.model()
        let song = Self.track("v1", Self.velvet)
        #expect(model.player.playback.autoPickSkips?(song) == false)

        QTArtistBlocking.setBlocked(true, Self.velvet, model: model)
        #expect(model.settings.settings.blockedArtists.map(\.channelID) == ["UCvelvet"])
        #expect(model.player.playback.autoPickSkips?(song) == true)
        #expect(model.toast?.message == QTLoc.tr("Won’t play “%@”", table: .main, "The Velvet Sundown"))

        model.toast?.undo?()
        #expect(model.settings.settings.blockedArtists.isEmpty)
        #expect(model.player.playback.autoPickSkips?(song) == false)

        QTArtistBlocking.setBlocked(true, Self.velvet, model: model)
        QTArtistBlocking.setBlocked(false, QTArtistRef(name: "the velvet sundown"), model: model)
        #expect(model.settings.settings.blockedArtists.isEmpty, "allowing by name clears the id entry too")
        model.toast?.undo?()
        #expect(model.settings.settings.blockedArtists.map(\.name) == ["The Velvet Sundown"])
    }

    @Test func songMenusOfferTheArtistCheckedWhileBlocked() throws {
        let model = Self.model()
        let solo = Self.track("s", Self.velvet)
        let item = try #require(QTArtistBlocking.menuItem(for: [solo], model: model))
        #expect(item.title == QTLoc.tr("Don’t Play This Artist", table: .main))
        #expect(item.state == .off)
        #expect(item.submenu == nil)

        QTArtistBlocking.setBlocked(true, Self.velvet, model: model)
        #expect(QTArtistBlocking.menuItem(for: [solo], model: model)?.state == .on)

        // Several artists: pick which one.
        let duet = Self.track("d", Self.other, Self.velvet, QTArtistRef(name: "real band"))
        let several = try #require(QTArtistBlocking.menuItem(for: [duet], model: model))
        #expect(several.submenu?.items.map(\.title) == ["Real Band", "The Velvet Sundown"], "once per name")
        #expect(several.submenu?.items.map(\.state) == [.off, .on])

        #expect(QTArtistBlocking.menuItem(for: [solo, duet], model: model) == nil, "one song at a time")
        var upload = solo
        upload.isPrivatelyOwned = true
        #expect(QTArtistBlocking.menuItem(for: [upload], model: model) == nil, "uploads are the listener's own")
    }

    @Test func searchHidesBlockedArtistsUnlessItNamesThem() {
        let model = Self.model()
        QTArtistBlocking.setBlocked(true, Self.velvet, model: model)
        let results = QTSearchResults(topResult: .artist(QTArtist(id: "UCvelvet", name: "The Velvet Sundown")), items: [
            .track(Self.track("v1", Self.velvet)), .track(Self.track("ok", Self.other)),
            .video(Self.track("v2", Self.other, Self.velvet)),
            .album(QTAlbum(id: "MPREb_v", title: "Floating on Echoes", artists: [Self.velvet])),
            .playlist(QTPlaylist(id: "VLPL1", title: .verbatim("Velvet radio"))),
        ])
        let hidden = results.filtered(by: model.artistBlocklist, query: "velvet")
        #expect(hidden.topResult == nil)
        #expect(hidden.items.map(\.id) == ["track:ok", "playlist:VLPL1"])

        let asked = results.filtered(by: model.artistBlocklist, query: "The Velvet Sundown")
        #expect(asked == results, "they typed the name")
    }

    @Test func theDebugLaunchListIsSessionOnly() {
        #if DEBUG
        let entries = QTArtistBlocking.launchEntries(QTLaunchOptions(arguments: ["qt.blockedArtists": "李健, Ed Sheeran,,"]))
        #expect(entries?.map(\.name) == ["李健", "Ed Sheeran"])
        #expect(entries?.allSatisfy { $0.channelID == nil } == true)
        #endif
        #expect(QTArtistBlocking.launchEntries(QTLaunchOptions(arguments: [:])) == nil)
    }
}
