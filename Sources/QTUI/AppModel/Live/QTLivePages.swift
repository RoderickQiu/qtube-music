import QTCore
import QTInnerTube
import SwiftUI

// Owner: builder "data-live". Content pages backed by YouTube Music. Track lists reuse the window builder's
// QTLibraryView (native NSTableView, sticky compact header) and Home's shelves reuse QTHomeShelf; these views add
// loading, failure and signed-out states, Home mood filtering and library grids. Explore, mood, album, artist and
// search pages are the window's shared browse pages (Shell/), fed by `QTLiveBrowseService`.

/// Live replacement for a content-column destination (see `QTLiveCatalogStore.handles(_:)`).
struct QTLivePage: View {
    let destination: QTDestination
    @Environment(QTAppModel.self) private var model

    var body: some View {
        let store = QTLiveCatalogStore.shared
        switch store.mode {
        case .restoring:
            skeleton
        case .signedOut:
            QTLiveSignedOutView()
        case .mock, .live:
            if store.auth.state == .sessionExpired {
                QTLiveSignedOutView()
            } else {
                page
            }
        }
    }

    private var skeleton: QTLiveSkeleton {
        switch destination {
        case .section(.home): QTLiveSkeleton(layout: .shelves, title: QTHomeView.greeting(at: .now))
        case .section(.explore): QTLiveSkeleton(layout: .shelves, title: QTLoc.tr("Explore"))
        case .section(.albums): QTLiveSkeleton(layout: .grid, title: QTLoc.tr("Albums"))
        case .section(.artists): QTLiveSkeleton(layout: .grid, title: QTLoc.tr("Artists"))
        case .artist: QTLiveSkeleton(layout: .artist)
        default: QTLiveSkeleton(layout: .trackList)
        }
    }

    @ViewBuilder private var page: some View {
        switch destination {
        case .section(.home): QTLiveHomeView()
        // Browse pages are the window's one set (Shell/QTBrowsePages.swift), reading the store through
        // QTLiveBrowseService.
        case .section(.explore): QTExploreView()
        case .section(.liked): QTLiveCollectionPage(playlistID: "LM", destination: destination)
        case .section(.playlist(let id)): QTLiveCollectionPage(playlistID: id, destination: destination)
        case .section(.songs): QTLiveSongsPage(destination: destination)
        case .section(.albums): QTLiveLibraryAlbumsPage()
        case .section(.artists): QTLiveLibraryArtistsPage()
        case .section(.history): EmptyView() // not handled (local history)
        case .album(let key): QTAlbumPageView(key: key)
        case .artist(let key): QTArtistPageView(key: key)
        case .mood(let chip): QTMoodPageView(chip: chip)
        }
    }
}

// MARK: - Home

struct QTLiveHomeView: View {
    @Environment(QTAppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition(edge: .top)
    @State private var didRestore = false

    var body: some View {
        let store = QTLiveCatalogStore.shared
        QTLivePhaseView(phase: store.homePhase,
                        skeleton: QTLiveSkeleton(layout: .shelves, title: QTHomeView.greeting(at: .now)),
                        retry: { Task { await store.loadHome(force: true) } }) {
            content(store)
        }
        .task { await store.loadHome() }
    }

    private func content(_ store: QTLiveCatalogStore) -> some View {
        let mood = store.homeMood
        let moodPhase = mood.map { store.moodPhases[$0] ?? .loading } ?? .loaded
        let shelves = mood.flatMap { store.moodFeeds[$0]?.shelves } ?? model.catalog.home.shelves
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                header(store)
                switch moodPhase {
                case .failed(let f):
                    QTLiveFailureView(failure: f) { if let mood { Task { await store.loadMood(mood) } } }
                        .frame(height: 360)
                case .loaded:
                    ForEach(shelves) { shelf in
                        QTHomeShelf(shelf: shelf)
                            .padding(.top, QTTheme.Spacing.shelfSpacing)
                    }
                    .transition(.opacity)
                default:
                    QTLiveSkeleton(layout: .shelves).frame(height: 760).padding(.top, -110)
                }
            }
            .padding(.bottom, 48)
            .animation(QTTheme.Motion.animation(QTTheme.Motion.ui, reduceMotion: reduceMotion), value: mood)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { _, y in
            guard didRestore else { return }
            QTNavigator.shared.setScrollOffset(y, for: .section(.home))
        }
        .onAppear {
            let saved = model.launch.double("qt.home.scroll").map { CGFloat($0) } ?? QTNavigator.shared.scrollOffset(for: .section(.home))
            if saved > 0 { position.scrollTo(y: saved) }
            didRestore = true
        }
        .accessibilityIdentifier("qt.live.home")
    }

    private func header(_ store: QTLiveCatalogStore) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(QTHomeView.greeting(at: .now))
                .font(QTTheme.Typography.pageTitle)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, QTTheme.Spacing.gutter)
            ScrollView(.horizontal) {
                HStack(spacing: QTTheme.Spacing.xs) {
                    ForEach(model.catalog.home.moods) { mood in
                        Toggle(mood.title.resolved, isOn: Binding(
                            get: { store.homeMood == mood.id },
                            set: { store.selectMood($0 ? mood.id : nil) }
                        ))
                        .toggleStyle(.button)
                        .buttonBorderShape(.capsule)
                        .accessibilityIdentifier("qt.live.home.mood.\(mood.id)")
                    }
                }
                .controlSize(.large)
                .padding(.horizontal, QTTheme.Spacing.gutter)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
        }
        .padding(.top, 40)
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
// MARK: - Library grids

struct QTLiveLibraryAlbumsPage: View {
    var body: some View {
        let store = QTLiveCatalogStore.shared
        QTLivePhaseView(phase: store.albumsPhase, skeleton: QTLiveSkeleton(layout: .grid, title: QTLoc.tr("Albums")),
                        retry: { Task { await store.loadLibraryAlbums(force: true) } }) {
            if store.libraryAlbums.isEmpty {
                ContentUnavailableView(QTLoc.tr("No Albums", table: .live), systemImage: QTIcon.album.systemName)
                    .accessibilityIdentifier("qt.live.albums.empty")
            } else {
                QTLibraryGridPage(title: QTLoc.tr("Albums"), items: store.libraryAlbums, identifier: "qt.live.albums") {
                    QTLiveAlbumCard(album: $0)
                }
            }
        }
        .task { await store.loadLibraryAlbums() }
    }
}

struct QTLiveLibraryArtistsPage: View {
    var body: some View {
        let store = QTLiveCatalogStore.shared
        QTLivePhaseView(phase: store.artistsPhase, skeleton: QTLiveSkeleton(layout: .grid, title: QTLoc.tr("Artists")),
                        retry: { Task { await store.loadLibraryArtists(force: true) } }) {
            if store.libraryArtists.isEmpty {
                ContentUnavailableView(QTLoc.tr("No Artists", table: .live), systemImage: QTIcon.mic.systemName)
                    .accessibilityIdentifier("qt.live.artists.empty")
            } else {
                QTLibraryGridPage(title: QTLoc.tr("Artists"), items: store.libraryArtists, identifier: "qt.live.artists") {
                    QTLiveArtistCard(artist: $0)
                }
            }
        }
        .task { await store.loadLibraryArtists() }
    }
}
