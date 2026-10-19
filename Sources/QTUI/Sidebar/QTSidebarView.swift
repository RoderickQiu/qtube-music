import QTCore
import SwiftUI

// Owner: builder "window". Native source list (system sidebar material + selection).

public struct QTSidebarView: View {
    @Environment(QTAppModel.self) private var model

    public init() {}

    public var body: some View {
        @Bindable var model = model
        List(selection: Binding<QTSidebarItem?>(get: { model.sidebarSelection }, set: { if let v = $0 { model.sidebarSelection = v } })) {
            Section {
                item(.home)
                item(.explore)
            }
            Section(QTLoc.tr("Library")) {
                item(.songs)
                item(.albums)
                item(.artists)
                item(.liked)
                item(.history)
            }
            Section(QTLoc.tr("Playlists")) {
                ForEach(model.catalog.playlists) { p in
                    Label(p.title.resolved, systemImage: QTIcon.playlist.systemName)
                        .tag(QTSidebarItem.playlist(p.id))
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("qt.sidebar")
    }

    private func item(_ i: QTSidebarItem) -> some View {
        Label(Self.title(for: i), systemImage: Self.icon(for: i).systemName).tag(i)
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
