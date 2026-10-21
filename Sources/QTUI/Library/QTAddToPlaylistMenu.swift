import AppKit
import QTCore
import QTInnerTube

/// "Add to Playlist" submenu (track tables, Home cards): New Playlist…, then the playlists the songs can go into,
/// checked when they already hold every one of them. It opens at once with what the app knows (playlists it owns and
/// has loaded); when syncing, YouTube's own answer (`playlist/get_add_to_playlist`) then fills in the exact list and
/// checkmarks while the menu is open.
@MainActor
final class QTAddToPlaylistMenu: NSMenu, NSMenuDelegate {
    private let tracks: [QTTrack]
    private let excluding: String?
    private var fetch: Task<Void, Never>?

    static func make(for tracks: [QTTrack], excluding playlistID: String? = nil) -> NSMenu {
        QTAddToPlaylistMenu(tracks: tracks, excluding: playlistID)
    }

    init(tracks: [QTTrack], excluding: String?) {
        self.tracks = tracks
        self.excluding = excluding
        super.init(title: QTLoc.tr("Add to Playlist"))
        delegate = self
        rebuild(options: nil)
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    func menuWillOpen(_ menu: NSMenu) {
        guard fetch == nil, QTAccountWriter.shared.syncsToAccount else { return }
        fetch = Task { [weak self] in
            guard let self, let options = await QTAccountWriter.shared.playlistOptions(for: self.tracks) else { return }
            self.rebuild(options: options)
        }
    }

    private func rebuild(options: [QTPlaylistOption]?) {
        removeAllItems()
        let tracks = tracks
        addItem(QTClosureMenuItem(QTLoc.tr("New Playlist…", table: .main)) {
            QTPlaylistActions.newPlaylist(with: tracks)
        })
        let targets = Self.targets(options: options, excluding: excluding, tracks: tracks)
        if !targets.isEmpty { addItem(.separator()) }
        for (playlist, holdsAll) in targets {
            let item = QTClosureMenuItem(playlist.title.resolved, state: holdsAll) {
                QTTrackActions.add(tracks, to: playlist)
            }
            item.image = NSImage(systemSymbolName: QTIcon.playlist.systemName, accessibilityDescription: nil)
            addItem(item)
        }
    }

    /// The playlists to offer and whether each already holds every song: YouTube's answer when there is one, else
    /// the playlists the app knows it can edit (loaded ones with the owner's header, ones made here, the demo's).
    static func targets(options: [QTPlaylistOption]?, excluding: String?, tracks: [QTTrack],
                        writer: QTAccountWriter = .shared,
                        store: QTLiveCatalogStore = .shared) -> [(QTPlaylist, Bool)] {
        let library = writer.edits.playlists(QTAppModel.shared.catalog.playlists)
        let ids = Set(tracks.map(\.videoId))
        func holdsAll(_ p: QTPlaylist) -> Bool {
            guard p.tracks != nil || p.id.hasPrefix("local:") else { return false }
            return ids.isSubset(of: Set(writer.rows(of: p).map(\.videoId)))
        }
        if let options {
            return options.compactMap { o in
                let id = QTInnerTube.playlistBrowseId(o.id)
                guard id != excluding else { return nil }
                let p = library.first { $0.id == id }
                    ?? QTPlaylist(id: id, title: .verbatim(o.title), kind: .user, isEditable: true, privacy: o.privacy)
                return (p, o.containsVideos || holdsAll(p))
            } + library.filter { $0.id.hasPrefix("local:") && $0.id != excluding }.map { ($0, holdsAll($0)) }
        }
        return library.filter { $0.id != excluding && writer.canEdit($0) }.map { ($0, holdsAll($0)) }
    }
}
