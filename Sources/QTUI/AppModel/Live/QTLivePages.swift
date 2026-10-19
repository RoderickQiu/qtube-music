import QTCore
import QTInnerTube
import SwiftUI

// Owner: builder "data-live". Content pages backed by YouTube Music. Track lists reuse the window builder's
// QTLibraryView (native NSTableView, sticky compact header) and Home's shelves reuse QTHomeShelf; these views add
// loading, failure and signed-out states, mood filtering, Explore, library grids and album pages.

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
        case .section(.explore): QTLiveExploreView()
        case .section(.liked): QTLiveCollectionPage(playlistID: "LM", destination: destination)
        case .section(.playlist(let id)): QTLiveCollectionPage(playlistID: id, destination: destination)
        case .section(.songs): QTLiveSongsPage(destination: destination)
        case .section(.albums): QTLiveLibraryAlbumsPage()
        case .section(.artists): QTLiveLibraryArtistsPage()
        case .section(.history): EmptyView() // not handled (local history)
        case .album(let key): QTLiveAlbumPage(key: key, destination: destination)
        case .artist(let key): QTLiveArtistView(key: key)
        case .mood(let chip): QTLiveMoodPage(mood: chip)
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

// MARK: - Explore

struct QTLiveExploreView: View {
    @State private var section: QTLiveExploreSection = .overview

    var body: some View {
        let store = QTLiveCatalogStore.shared
        QTLivePhaseView(phase: store.explorePhase, skeleton: QTLiveSkeleton(layout: .shelves, title: QTLoc.tr("Explore")),
                        retry: { Task { await store.loadExplore(force: true) } }) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    header(store)
                    sectionContent(store)
                }
                .padding(.bottom, 48)
            }
            .accessibilityIdentifier("qt.live.explore")
        }
        .task { await store.loadExplore() }
        .task(id: section) { await store.loadExploreSection(section) }
    }

    private func header(_ store: QTLiveCatalogStore) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(QTLoc.tr("Explore"))
                .font(QTTheme.Typography.pageTitle)
                .accessibilityAddTraits(.isHeader)
            Picker(QTLoc.tr("Explore"), selection: $section) {
                ForEach(QTLiveExploreSection.allCases, id: \.self) { s in
                    Text(verbatim: title(s, store)).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.large)
            .accessibilityIdentifier("qt.live.explore.sections")
        }
        .padding(.top, 40)
        .padding(.horizontal, QTTheme.Spacing.gutter)
    }

    /// Server-localized names of Explore's own destinations where YouTube Music sends them.
    private func title(_ s: QTLiveExploreSection, _ store: QTLiveCatalogStore) -> String {
        let d = store.explore?.destinations ?? []
        func server(_ id: String) -> String? { d.first { QTBrowseTarget(moodChipID: $0.id).browseId == id }?.title.resolved }
        switch s {
        case .overview: return QTLoc.tr("Overview", table: .live)
        case .newReleases: return server("FEmusic_new_releases") ?? QTLoc.tr("New Releases", table: .live)
        case .charts: return server("FEmusic_charts") ?? QTLoc.tr("Charts", table: .live)
        case .moods: return server("FEmusic_moods_and_genres") ?? QTLoc.tr("Moods & Genres", table: .live)
        }
    }

    @ViewBuilder private func sectionContent(_ store: QTLiveCatalogStore) -> some View {
        switch section {
        case .overview:
            shelves(store.explore?.shelves ?? [])
        case .moods:
            phased(store.exploreSectionPhases[.moods] ?? .loading, retry: { Task { await store.loadExploreSection(.moods, force: true) } }) {
                moodsGrid(store.moodsPage)
            }
        default:
            phased(store.exploreSectionPhases[section] ?? .loading,
                   retry: { Task { await store.loadExploreSection(section, force: true) } }) {
                shelves(store.exploreSections[section] ?? [])
            }
        }
    }

    @ViewBuilder
    private func phased<C: View>(_ phase: QTLivePhase, retry: @escaping () -> Void, @ViewBuilder _ content: () -> C) -> some View {
        switch phase {
        case .loaded: content()
        case .failed(let f): QTLiveFailureView(failure: f, retry: retry).frame(height: 360)
        default: QTLiveSkeleton(layout: .shelves).frame(height: 760).padding(.top, -110)
        }
    }

    private func shelves(_ list: [QTShelf]) -> some View {
        ForEach(list) { shelf in
            QTHomeShelf(shelf: shelf)
                .padding(.top, QTTheme.Spacing.shelfSpacing)
        }
    }

    private func moodsGrid(_ page: QTMoodsPage?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(page?.groups ?? []) { group in
                VStack(alignment: .leading, spacing: 14) {
                    Text(verbatim: group.title)
                        .font(QTTheme.Typography.shelfTitle)
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10, alignment: .leading)],
                              alignment: .leading, spacing: 10) {
                        ForEach(group.moods) { mood in
                            Button {
                                // A real destination, so Back / Forward and the per-page state work.
                                QTNavigator.shared.go(.mood(mood))
                            } label: {
                                Text(mood.title.resolved)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .accessibilityIdentifier("qt.live.explore.mood.\(mood.id)")
                        }
                    }
                }
                .padding(.top, QTTheme.Spacing.shelfSpacing)
            }
        }
        .padding(.horizontal, QTTheme.Spacing.gutter)
    }
}

/// A mood or genre page (`QTDestination.mood`) from YouTube Music's own mood browse page.
struct QTLiveMoodPage: View {
    let mood: QTMoodChip

    var body: some View {
        let store = QTLiveCatalogStore.shared
        let key = "moodpage:\(mood.id)"
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                Text(mood.title.resolved)
                    .font(QTTheme.Typography.pageTitle)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, QTTheme.Spacing.gutter)
                    .padding(.top, 40)
                switch store.moodPhases[key] ?? .loading {
                case .loaded:
                    ForEach(store.moodFeeds[key]?.shelves ?? []) { shelf in
                        QTHomeShelf(shelf: shelf)
                            .padding(.top, QTTheme.Spacing.shelfSpacing)
                    }
                case .failed(let f):
                    QTLiveFailureView(failure: f, retry: { Task { await store.loadMoodPage(mood) } }).frame(height: 360)
                default:
                    QTLiveSkeleton(layout: .shelves).frame(height: 760).padding(.top, -110)
                }
            }
            .padding(.bottom, 48)
        }
        .task(id: mood.id) { await store.loadMoodPage(mood) }
        .accessibilityIdentifier("qt.live.mood")
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

struct QTLiveAlbumPage: View {
    let key: String
    let destination: QTDestination

    var body: some View {
        let store = QTLiveCatalogStore.shared
        QTLivePhaseView(phase: store.albumPhases[key] ?? .idle, skeleton: QTLiveSkeleton(layout: .trackList),
                        retry: { Task { await store.loadAlbum(key, force: true) } }) {
            if let page = store.albumPages[key] {
                QTLibraryView(collection: QTTrackCollection(id: "album:\(key)", kind: .album, title: page.album.title,
                                                            artwork: page.album.artwork, tracks: page.album.tracks ?? []),
                              destination: destination)
            }
        }
        .task(id: key) { await store.loadAlbum(key) }
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
