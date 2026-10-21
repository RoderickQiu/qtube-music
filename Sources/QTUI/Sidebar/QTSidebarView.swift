import QTCore
import SwiftUI

// Owner: builder "window". Native source list (system sidebar material + selection, collapsible sections).
// Songs dragged from any table or card onto a playlist are added to it ("Added “x” to y" + Undo);
// onto Liked Songs they're liked.

public struct QTSidebarView: View {
    @Environment(QTAppModel.self) private var model
    @AppStorage("qt.sidebar.libraryExpanded") private var libraryExpanded = true
    @AppStorage("qt.sidebar.playlistsExpanded") private var playlistsExpanded = true
    /// The playlist whose name is being edited in place (context menu › Rename, like Finder and Music).
    @State private var renamingID: String?

    public init() {}

    public var body: some View {
        // Highlight follows the page actually shown (none on album/artist pages, so clicking the section you came
        // from navigates back to it — and none while search results replace the page); selecting goes through the
        // navigator so it lands in back/forward history (and leaves the search).
        let navigator = QTNavigator.shared
        let isSearching = !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        List(selection: Binding<QTSidebarItem?>(
            get: { isSearching ? nil : navigator.current.sidebarItem },
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
                // Always listed (signed in, guest and demo alike): ⌘8 stays put, and an account without uploads
                // learns where they would go (the page says how to add some).
                row(.uploads)
            } header: {
                Text(QTLoc.tr("Library"))
            }
            // The library's playlists with this Mac's changes (renamed, deleted, made here) and pending ones.
            let playlists = QTAccountWriter.shared.edits.playlists(model.catalog.playlists)
            if !playlists.isEmpty {
                Section(isExpanded: $playlistsExpanded) {
                    ForEach(playlists) { p in
                        QTSidebarRow(item: .playlist(p.id), title: p.title.resolved, icon: .playlist, playlist: p,
                                     renaming: $renamingID)
                    }
                } header: {
                    Text(QTLoc.tr("Playlists"))
                        .contextMenu {
                            if !QTLiveCatalogStore.shared.isGuest {
                                Button(QTLoc.tr("New Playlist…", table: .main)) { QTPlaylistActions.newPlaylist() }
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Guest mode: the one way into the account, at the foot of the source list.
            if QTLiveCatalogStore.shared.isGuest {
                QTSignInButton()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, QTTheme.Spacing.m)
                    .padding(.vertical, QTTheme.Spacing.s)
                    .accessibilityIdentifier("qt.sidebar.signIn")
            }
        }
        .accessibilityIdentifier("qt.sidebar")
    }

    private func row(_ item: QTSidebarItem) -> some View {
        QTSidebarRow(item: item, title: Self.title(for: item), icon: Self.icon(for: item), playlist: nil,
                     renaming: .constant(nil))
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
        case .uploads: QTLoc.tr("Uploads")
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
        case .uploads: .upload
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
    @Binding var renaming: String?
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player
    @Environment(\.qtAccent) private var accent
    @State private var isTargeted = false
    @State private var draftName = ""
    @FocusState private var isEditingName: Bool

    private var isRenaming: Bool { playlist != nil && renaming == playlist?.id }

    var body: some View {
        let label = Label {
            if isRenaming {
                // In place, like Finder: ↩ keeps the name, Esc (or clicking away) leaves it as it was.
                TextField(QTLoc.tr("Name", table: .main), text: $draftName)
                    .textFieldStyle(.plain)
                    .focused($isEditingName)
                    .onSubmit(commitRename)
                    .onExitCommand { renaming = nil }
                    .onChange(of: isEditingName) { _, focused in if !focused { renaming = nil } }
                    .onAppear {
                        draftName = title
                        isEditingName = true
                    }
                    .accessibilityIdentifier("qt.sidebar.rename")
            } else {
                Text(verbatim: title).lineLimit(1)
            }
        } icon: {
            icon.image
        }
        .tag(item)
        .accessibilityIdentifier("qt.sidebar.\(item.argument)")
        .qtSidebarContextMenu(for: item, playlist: playlist, onRename: { renaming = playlist?.id }) // Desktop/QTSidebarContextMenu.swift
        if acceptsDrops {
            label
                .dropDestination(for: String.self) { items, _ in drop(items) } isTargeted: { isTargeted = $0 }
                .overlay {
                    // Finder-style drop highlight around the row, in the app's accent.
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

    private func commitRename() {
        defer { renaming = nil }
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let playlist, !name.isEmpty, name != title else { return }
        QTAccountWriter.shared.editDetails(playlist, title: name, description: playlist.description ?? "",
                                           privacy: playlist.privacy ?? .private)
    }

    /// Liked Songs, and playlists songs can go into (the account's own; one not opened yet may be, so it tries).
    private var acceptsDrops: Bool {
        if let playlist { return QTAccountWriter.shared.canEdit(playlist) || playlist.isEditable == nil }
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
