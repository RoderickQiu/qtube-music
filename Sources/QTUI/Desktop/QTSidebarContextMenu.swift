import AppKit
import QTCore
import SwiftUI

// Owner: builder "desktop". Right-click menu of the sidebar's Liked Songs and playlist rows (spec §8: real
// context menus, like Music's sidebar): Play, Shuffle, Play Next, Copy Link; for the account's own playlists also
// Rename (in place), Edit Playlist… and Delete Playlist…, and Remove from Library for saved ones. Live playlists load
// their first page on demand; the mock catalog plays its own lists. Changes go through `QTAccountWriter`.

extension View {
    /// Adds the playlist context menu to a sidebar row (only Liked Songs and playlists get one). `onRename` starts
    /// editing the row's name in place.
    func qtSidebarContextMenu(for item: QTSidebarItem, playlist: QTPlaylist?,
                              onRename: (() -> Void)? = nil) -> some View {
        modifier(QTSidebarContextMenuModifier(item: item, playlist: playlist, onRename: onRename))
    }
}

private struct QTSidebarContextMenuModifier: ViewModifier {
    let item: QTSidebarItem
    let playlist: QTPlaylist?
    let onRename: (() -> Void)?

    func body(content: Content) -> some View {
        // Guest mode has no library to play from (Liked Songs asks to sign in).
        if !QTLiveCatalogStore.shared.isGuest, let target = QTSidebarPlaylistTarget(item: item, playlist: playlist) {
            content.contextMenu {
                Button(QTLoc.tr("Play")) { target.play(shuffled: false) }
                Button(QTLoc.tr("Shuffle")) { target.play(shuffled: true) }
                Button(QTLoc.tr("Play Next")) { target.playNext() }
                Divider()
                Button(QTLoc.tr("Copy Link")) { target.copyLink() }
                if let playlist {
                    // Playlists the library only saved (someone else's) can't be edited, only removed from it.
                    let writer = QTAccountWriter.shared
                    if writer.canEdit(playlist) {
                        Divider()
                        if let onRename { Button(QTLoc.tr("Rename", table: .main), action: onRename) }
                        Button(QTLoc.tr("Edit Playlist…", table: .main)) { QTPlaylistActions.edit(playlist) }
                        Button(QTLoc.tr("Delete Playlist…", table: .main)) { QTPlaylistActions.delete(playlist) }
                    } else if playlist.isEditable == false, playlist.kind == .user {
                        Divider()
                        Button(QTLoc.tr("Remove from Library", table: .main)) {
                            QTPlaylistActions.toggleSaved(id: playlist.id, title: playlist.title.resolved)
                        }
                    }
                }
            }
        } else {
            content
        }
    }
}

/// What a sidebar row's menu acts on: Liked Songs (`LM`) or one playlist.
@MainActor
struct QTSidebarPlaylistTarget {
    let id: String
    let title: String

    init?(item: QTSidebarItem, playlist: QTPlaylist?) {
        switch item {
        case .liked:
            id = "LM"
            title = QTLoc.tr("Liked Songs")
        case .playlist(let pid):
            id = pid
            title = playlist?.title.resolved ?? pid
        default:
            return nil
        }
    }

    /// `https://music.youtube.com/playlist?list=<id>` (Liked Songs is the `LM` list).
    var link: String { "https://music.youtube.com/playlist?list=\(id.hasPrefix("VL") ? String(id.dropFirst(2)) : id)" }

    private var source: QTQueueSource { QTQueueSource(kind: .playlist, id: id, title: .verbatim(title)) }

    /// The list's tracks: the live library's (first page loaded on demand) or the demo catalog's.
    func tracks(model: QTAppModel = .shared) async -> [QTTrack] {
        let store = QTLiveCatalogStore.shared
        if store.isLive {
            await store.loadPlaylist(id)
            return store.playlist(id)?.tracks ?? []
        }
        let catalog = model.catalog
        if id == "LM" { return QTTrackCollection.liked(catalog).tracks }
        guard let p = store.playlist(id) else { return [] }
        return QTTrackCollection.playlist(p, catalog: catalog).tracks
    }

    func play(shuffled: Bool) {
        Task { @MainActor in
            let tracks = await tracks()
            if shuffled {
                QTTrackActions.shuffle(tracks, source: source)
            } else if let i = tracks.firstIndex(where: \.availability.isPlayable) {
                QTTrackActions.play(tracks, at: i, source: source)
            }
        }
    }

    func playNext() {
        Task { @MainActor in QTTrackActions.playNext(await tracks()) }
    }

    func copyLink() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(link, forType: .string)
        QTAppModel.shared.showToast(QTLoc.tr("Link copied"))
    }
}
