import QTCore
import SwiftUI

// Owner: builder "window". Native source list (system sidebar material + selection, collapsible sections).
// Songs dragged from any table or card onto a playlist are added to it ("Added “x” to y" + Undo);
// onto Liked Songs they're liked.

public struct QTSidebarView: View {
    @Environment(QTAppModel.self) private var model
    @AppStorage("qt.sidebar.libraryExpanded") private var libraryExpanded = true
    @AppStorage("qt.sidebar.playlistsExpanded") private var playlistsExpanded = true

    public init() {}

    public var body: some View {
        // Highlight follows the page actually shown (none on album/artist pages, so clicking the section you came
        // from navigates back to it); selecting goes through the navigator so it lands in back/forward history.
        let navigator = QTNavigator.shared
        List(selection: Binding<QTSidebarItem?>(
            get: { navigator.current.sidebarItem },
            set: { if let v = $0 { navigator.go(.section(v)) } }
        )) {
            Section {
                row(.home)
                row(.explore)
            }
            Section(isExpanded: $libraryExpanded) {
                row(.songs)
                row(.albums)
                row(.artists)
                row(.liked)
                row(.history)
            } header: {
                Text(QTLoc.tr("Library"))
            }
            Section(isExpanded: $playlistsExpanded) {
                ForEach(model.catalog.playlists) { p in
                    QTSidebarRow(item: .playlist(p.id), title: p.title.resolved, icon: .playlist, playlist: p)
                }
            } header: {
                Text(QTLoc.tr("Playlists"))
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("qt.sidebar")
    }

    private func row(_ item: QTSidebarItem) -> some View {
        QTSidebarRow(item: item, title: Self.title(for: item), icon: Self.icon(for: item), playlist: nil)
    }

    static func title(for item: QTSidebarItem) -> String {
        switch item {
        case .home: QTLoc.tr("Home")
        case .explore: QTLoc.tr("Explore")
        case .songs: QTLoc.tr("Songs")
        case .albums: QTLoc.tr("Albums")
        case .artists: QTLoc.tr("Artists")
        case .liked: QTLoc.tr("Liked Songs")
        case .history: QTLoc.tr("History")
        case .playlist: QTLoc.tr("Playlist")
        }
    }

    static func icon(for item: QTSidebarItem) -> QTIcon {
        switch item {
        case .home: .home
        case .explore: .compass
        case .songs: .note
        case .albums: .album
        case .artists: .mic
        case .liked: .heart
        case .history: .clock
        case .playlist: .playlist
        }
    }
}

/// One sidebar row; playlists and Liked Songs accept dropped songs.
struct QTSidebarRow: View {
    let item: QTSidebarItem
    let title: String
    let icon: QTIcon
    let playlist: QTPlaylist?
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player
    @Environment(\.qtAccent) private var accent
    @State private var isTargeted = false

    var body: some View {
        let label = Label {
            Text(verbatim: title).lineLimit(1)
        } icon: {
            icon.image
        }
        .tag(item)
        .accessibilityIdentifier("qt.sidebar.\(item.argument)")
        .qtSidebarContextMenu(for: item, playlist: playlist) // Desktop/QTSidebarContextMenu.swift
        if acceptsDrops {
            label
                .dropDestination(for: String.self) { items, _ in drop(items) } isTargeted: { isTargeted = $0 }
                .overlay {
                    // Finder-style drop highlight around the row.
                    RoundedRectangle(cornerRadius: QTTheme.Radius.control, style: .continuous)
                        .strokeBorder(accent, lineWidth: 2)
                        .padding(.horizontal, -8)
                        .padding(.vertical, -4)
                        .opacity(isTargeted ? 1 : 0)
                        .allowsHitTesting(false)
                }
        } else {
            label
        }
    }

    private var acceptsDrops: Bool {
        if case .playlist = item { return true }
        return item == .liked
    }

    private func drop(_ items: [String]) -> Bool {
        let tracks = QTTrackActions.tracks(fromDropped: items, catalog: model.catalog)
        guard !tracks.isEmpty else { return false }
        if let playlist {
            QTTrackActions.add(tracks, to: playlist)
        } else {
            let fresh = tracks.filter { !player.isLiked($0) && $0.availability.isPlayable }
            if fresh.isEmpty {
                model.showToast(QTLoc.tr("Already in %@", table: .main, QTLoc.tr("Liked Songs")))
            } else {
                QTTrackActions.toggleLike(fresh)
            }
        }
        return true
    }
}
