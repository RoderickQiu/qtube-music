import QTCore
import SwiftUI

// Owner: builder "window". Library › Uploads — the user's own uploaded music, read-only (uploading and deleting stay
// on music.youtube.com). ONE page for the demo catalog and the live library: a segmented Songs | Albums | Artists
// control in the window's toolbar (it stays put while the song table scrolls and when the page under it changes
// from a table to a grid), over the same track table and card grids the rest of the library uses. Live: one list
// per segment, loaded when first shown, with the usual skeleton / failure states; guest mode never gets here
// (QTLivePage shows the sign-in prompt). An account without uploads gets an empty state that says where uploads
// come from.

/// Library › Uploads segments.
public enum QTUploadsSection: String, Sendable, Hashable, CaseIterable {
    case songs, albums, artists

    var title: String {
        switch self {
        case .songs: QTLoc.tr("Songs")
        case .albums: QTLoc.tr("Albums")
        case .artists: QTLoc.tr("Artists")
        }
    }
}

struct QTUploadsPage: View {
    @Environment(QTAppModel.self) private var model
    @SceneStorage("qt.uploads.section") private var sectionID = QTUploadsSection.songs.rawValue

    /// `-qt.uploads.section songs|albums|artists` picks the segment once per launch (screenshots).
    @MainActor private static var didApplyLaunchSection = false

    private var section: QTUploadsSection { QTUploadsSection(rawValue: sectionID) ?? .songs }

    var body: some View {
        let store = QTLiveCatalogStore.shared
        Group {
            if store.isLive {
                QTLivePhaseView(phase: store.uploadsPhase(section), skeleton: skeleton,
                                retry: { Task { await store.loadUploads(section, force: true) } }) {
                    list(store.uploads)
                }
            } else {
                // DEBUG `-qt.uploads.empty YES`: the demo library without uploads (the empty state's screenshot).
                list(model.launch.bool("qt.uploads.empty") == true ? .empty : model.catalog.uploads)
            }
        }
        .id(section)
        .toolbar {
            if model.surface != .stage {
                ToolbarItem(placement: .navigation) { picker }
            }
        }
        .task(id: section) { await store.loadUploads(section) }
        .onAppear(perform: applyLaunchSection)
    }

    private var picker: some View {
        Picker(QTLoc.tr("Uploads"), selection: $sectionID) {
            ForEach(QTUploadsSection.allCases, id: \.self) { s in
                Text(s.title).tag(s.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(QTLoc.tr("Show uploaded songs, albums or artists", table: .live))
        .accessibilityIdentifier("qt.uploads.sections")
    }

    private var skeleton: QTLiveSkeleton {
        section == .songs ? QTLiveSkeleton(layout: .trackList, title: QTLoc.tr("Uploads"))
            : QTLiveSkeleton(layout: .grid, title: QTLoc.tr("Uploads"))
    }

    @ViewBuilder
    private func list(_ uploads: QTUploads) -> some View {
        switch section {
        case .songs where !uploads.songs.isEmpty:
            QTLibraryView(collection: QTTrackCollection(id: "uploads", kind: .uploads, title: QTLoc.tr("Uploads"),
                                                        tracks: uploads.songs),
                          destination: .section(.uploads))
        case .albums where !uploads.albums.isEmpty:
            QTLibraryGridPage(title: QTLoc.tr("Uploads"), items: uploads.albums, identifier: "qt.uploads.albums") { album in
                QTHomeCard(item: .album(album), shelfTracks: [])
            }
        case .artists where !uploads.artists.isEmpty:
            QTLibraryGridPage(title: QTLoc.tr("Uploads"), items: uploads.artists, identifier: "qt.uploads.artists") { artist in
                QTHomeCard(item: .artist(artist), shelfTracks: [])
            }
        default:
            // An account with uploads has songs, albums and artists alike, so one empty list means none at all.
            QTUploadsEmptyView()
        }
    }

    private func applyLaunchSection() {
        guard !Self.didApplyLaunchSection else { return }
        Self.didApplyLaunchSection = true
        if let arg = model.launch.string("qt.uploads.section"), QTUploadsSection(rawValue: arg) != nil { sectionID = arg }
    }
}

/// No uploads yet: what the page is for, and where uploading happens (the app itself never uploads).
struct QTUploadsEmptyView: View {
    static let uploadURL = URL(string: "https://music.youtube.com/")!

    var body: some View {
        ContentUnavailableView {
            Label(QTLoc.tr("No Uploads", table: .live), systemImage: QTIcon.upload.systemName)
        } description: {
            Text(QTLoc.tr("Music you upload at music.youtube.com shows up here.", table: .live))
        } actions: {
            Link(QTLoc.tr("Open YouTube Music in Your Browser", table: .live), destination: Self.uploadURL)
                .accessibilityIdentifier("qt.uploads.empty.open")
        }
        .accessibilityIdentifier("qt.uploads.empty")
    }
}
