import AppKit
import OSLog
import QTCore
import QTInnerTube
import SwiftUI

/// Start Radio from any song, album, playlist or artist (every menu that offers it goes through here). The station
/// loads first, then replaces what plays the way a mix does — Up Next is kept — so a radio that fails leaves the queue
/// as it was. On the song playing now, that song plays on and the station follows it.
@MainActor
public enum QTRadioActions {
    /// Bumped by every Start Radio: a station that arrives after a newer one was asked for is dropped.
    private static var serial = 0

    public static func canStart(_ seed: QTRadioSeed, store: QTLiveCatalogStore = .shared) -> Bool {
        store.canStartRadio(seed)
    }

    /// Menus: starts the radio in the background.
    public static func startRadio(_ seed: QTRadioSeed) {
        Task { await start(seed) }
    }

    /// Fetches the station and plays it; a failure is a toast, like a song that couldn't play (Try Again when YouTube
    /// couldn't be reached). Returns whether the station started.
    @discardableResult
    public static func start(_ seed: QTRadioSeed, autoplay: Bool = true, store: QTLiveCatalogStore = .shared,
                             model: QTAppModel = .shared) async -> Bool {
        guard store.canStartRadio(seed) else { return false }
        serial += 1
        let mine = serial
        let player = model.player
        let wasPlaying = seed.song.map { $0.videoId == player.nowPlaying?.videoId } ?? false
        do {
            let station = try await store.radioStation(for: seed)
            guard mine == serial else { return false }
            if wasPlaying, let current = player.nowPlaying, current.videoId == station.tracks.first?.videoId {
                player.continueAsRadio(Array(station.tracks.dropFirst()), source: station.source)
            } else {
                await player.playRadio(station.tracks, source: station.source, autoplay: autoplay, mode: .song)
            }
            return true
        } catch {
            guard mine == serial else { return false }
            report(error, for: seed, store: store, model: model)
            return false
        }
    }

    /// The toast for a radio that didn't start. Exposed for tests.
    static func message(for error: any Error, seed: QTRadioSeed) -> (message: String, retries: Bool) {
        if (error as? QTInnerTubeError) == .botCheck {
            return (QTLoc.tr("YouTube wants to check this connection", table: .live), false)
        }
        return (QTLoc.tr("Couldn’t start a radio for “%@”", table: .live, seed.title), !(error is QTRadioUnavailable))
    }

    private static func report(_ error: any Error, for seed: QTRadioSeed, store: QTLiveCatalogStore, model: QTAppModel) {
        QTPlaybackServices.log.error("couldn't start radio for \(seed.title, privacy: .private): \(String(describing: error), privacy: .public)")
        let (message, retries) = Self.message(for: error, seed: seed)
        if (error as? QTInnerTubeError) == .botCheck, !store.auth.isSignedIn {
            // As with playback: signing in usually clears the check.
            model.showToast(message, actionTitle: QTLoc.tr("Sign In", table: .live)) { store.signIn() }
        } else if retries {
            model.showToast(message, actionTitle: QTLoc.tr("Try Again", table: .live)) { startRadio(seed) }
        } else {
            model.showToast(message)
        }
    }

    // MARK: Menu items

    /// Whether a playlist's menu offers Start Radio at all: Liked Songs and lists made on this Mac have no radio.
    static func offersRadio(playlistID id: String) -> Bool { QTRadioRequest.playlist(id) != nil }

    /// The radio of an album or playlist page (its More menu); nil for lists without one (Liked Songs, Library,
    /// History, an uploads artist).
    static func seed(for collection: QTTrackCollection) -> QTRadioSeed? {
        switch collection.kind {
        case .album:
            let key = collection.id.hasPrefix("album:") ? String(collection.id.dropFirst(6)) : collection.id
            return .album(id: key, title: collection.title, playlistId: collection.libraryID)
        case .playlist:
            guard let id = collection.playlistID, offersRadio(playlistID: id) else { return nil }
            return .playlist(id: id, title: collection.title)
        default:
            return nil
        }
    }

    /// "Start Radio" for AppKit menus (track tables, card menus, the More menu, the Dock); dimmed without a radio.
    static func menuItem(_ seed: QTRadioSeed?) -> NSMenuItem {
        QTClosureMenuItem(QTLoc.tr("Start Radio", table: .live), enabled: seed.map { canStart($0) } ?? false) {
            if let seed { startRadio(seed) }
        }
    }
}

/// "Start Radio" in SwiftUI menus (cards, the sidebar, the queue, Controls, the mini player); dimmed without a radio.
struct QTStartRadioButton: View {
    let seed: QTRadioSeed?

    var body: some View {
        Button(QTLoc.tr("Start Radio", table: .live)) {
            if let seed { QTRadioActions.startRadio(seed) }
        }
        .disabled(!(seed.map { QTRadioActions.canStart($0) } ?? false))
    }
}
