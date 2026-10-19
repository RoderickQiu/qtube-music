import QTCore
import QTInnerTube
import SwiftUI

// Owner: builder "data-live". Content pages backed by YouTube Music. Track lists reuse the window builder's
// QTLibraryView (native NSTableView, sticky compact header); Home and the library grids are the window's one set
// (QTHomeView, QTLibraryAlbumsPage / QTLibraryArtistsPage) for demo + live; these views add loading, failure and
// guest (sign-in) states. Explore, mood, album, artist and
// search pages are the window's shared browse pages (Shell/), fed by `QTLiveBrowseService`.

/// Live replacement for a content-column destination (see `QTLiveCatalogStore.handles(_:)`).
struct QTLivePage: View {
    let destination: QTDestination
    @Environment(QTAppModel.self) private var model

    var body: some View {
        let store = QTLiveCatalogStore.shared
        switch store.mode {
        case .restoring:
            // Home's own loading state (real greeting, chip and shelf placeholders), so restoring → loading →
            // loaded never swaps one skeleton for another of a different shape.
            if destination == .section(.home) { QTHomeView(isRestoring: true) } else { skeleton }
        case .guest:
            // Guest mode: YouTube Music without an account; the library's places ask to sign in.
            if QTLiveCatalogStore.isLibrary(destination) {
                QTLiveSignInPrompt(destination: destination)
            } else {
                page
            }
        case .mock, .live:
            page
        }
    }

    private var skeleton: QTLiveSkeleton {
        switch destination {
        case .section(.explore): QTLiveSkeleton(layout: .shelves, title: QTLoc.tr("Explore"))
        case .section(.albums): QTLiveSkeleton(layout: .grid, title: QTLoc.tr("Albums"))
        case .section(.artists): QTLiveSkeleton(layout: .grid, title: QTLoc.tr("Artists"))
        case .artist: QTLiveSkeleton(layout: .artist)
        default: QTLiveSkeleton(layout: .trackList)
        }
    }

    @ViewBuilder private var page: some View {
        switch destination {
        case .section(.home): QTHomeView() // one Home for demo + live (Home/)
        // Browse pages are the window's one set (Shell/QTBrowsePages.swift), reading the store through
        // QTLiveBrowseService.
        case .section(.explore): QTExploreView()
        case .section(.liked): QTLiveCollectionPage(playlistID: "LM", destination: destination)
        case .section(.playlist(let id)): QTLiveCollectionPage(playlistID: id, destination: destination)
        case .section(.songs): QTLiveSongsPage(destination: destination)
        // One pair of library grids for demo + live (Library/QTLibraryGrids.swift).
        case .section(.albums): QTLibraryAlbumsPage()
        case .section(.artists): QTLibraryArtistsPage()
        case .section(.history): EmptyView() // not handled (local history)
        case .album(let key): QTAlbumPageView(key: key)
        case .artist(let key): QTArtistPageView(key: key)
        case .mood(let chip): QTMoodPageView(chip: chip)
        case .shelf(let shelf): QTLibraryView(collection: .shelf(shelf), destination: destination)
        }
    }
}

// MARK: - Track lists

/// Liked Songs or a playlist: the first page shows as soon as it arrives, later pages stream in.
struct QTLiveCollectionPage: View {
    let playlistID: String
    let destination: QTDestination
    @Environment(QTAppModel.self) private var model

    var body: some View {
        let store = QTLiveCatalogStore.shared
        let p = store.playlist(playlistID)
        QTLivePhaseView(phase: store.playlistPhase(playlistID),
                        skeleton: QTLiveSkeleton(layout: .trackList, title: playlistID == "LM" ? QTLoc.tr("Liked Songs") : p?.title.resolved),
                        retry: { Task { await store.loadPlaylist(playlistID, force: true) } }) {
            if playlistID == "LM" {
                QTLibraryView(collection: .liked(model.catalog), destination: destination)
            } else if let p {
                QTLibraryView(collection: .playlist(p, catalog: model.catalog), destination: destination)
            }
        }
        .task(id: playlistID) { await store.loadPlaylist(playlistID) }
    }
}

struct QTLiveSongsPage: View {
    let destination: QTDestination

    var body: some View {
        let store = QTLiveCatalogStore.shared
        QTLivePhaseView(phase: store.songsPhase, skeleton: QTLiveSkeleton(layout: .trackList, title: QTLoc.tr("Songs")),
                        retry: { Task { await store.loadLibrarySongs(force: true) } }) {
            QTLibraryView(collection: QTTrackCollection(id: "songs", kind: .songs, title: QTLoc.tr("Songs"),
                                                        tracks: store.librarySongs),
                          destination: destination)
        }
        .task { await store.loadLibrarySongs() }
    }
}
