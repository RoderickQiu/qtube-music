import QTCore
import SwiftUI

// Owner: builder "window". Library › Albums and Artists — ONE pair of pages for the demo catalog and the live
// library. Live: the store's library albums/artists (skeleton, failure state, empty state). Demo: derived from the
// library's songs. Both draw the same cards as Home shelves (`QTHomeCard`, which opens live items by browse id and
// demo items by title).

enum QTLibraryIndex {
    /// The demo library's albums (first appearance of each album title; sorted like Music.app). Keyed by title,
    /// which is how the mock browse pages open albums.
    static func albums(_ tracks: [QTTrack]) -> [QTAlbum] {
        var order: [String] = []
        var byTitle: [String: QTAlbum] = [:]
        for t in tracks {
            guard let title = t.album?.title else { continue }
            if byTitle[title] == nil {
                order.append(title)
                byTitle[title] = QTAlbum(id: title, title: title, artists: t.artists, artwork: t.artwork, tracks: [])
            }
            byTitle[title]?.tracks?.append(t)
        }
        return order.compactMap { byTitle[$0] }.sorted(by: sortedByKey(\.title))
    }

    /// The demo library's artists, keyed by name (the mock browse pages open artists by name).
    static func artists(_ tracks: [QTTrack]) -> [QTArtist] {
        var order: [String] = []
        var art: [String: [QTArtworkImage]] = [:]
        for t in tracks {
            for a in t.artists where art[a.name] == nil {
                order.append(a.name)
                art[a.name] = t.artwork
            }
        }
        return order.map { QTArtist(id: $0, name: $0, artwork: art[$0] ?? []) }.sorted(by: sortedByKey(\.name))
    }

    private static func sortedByKey<T>(_ name: KeyPath<T, String>) -> (T, T) -> Bool {
        { QTTextFolding.sortKey($0[keyPath: name]).compare(QTTextFolding.sortKey($1[keyPath: name]), options: .numeric) == .orderedAscending }
    }
}

/// Library › Albums.
struct QTLibraryAlbumsPage: View {
    @Environment(QTAppModel.self) private var model

    var body: some View {
        let store = QTLiveCatalogStore.shared
        if store.isLive {
            QTLivePhaseView(phase: store.albumsPhase, skeleton: QTLiveSkeleton(layout: .grid, title: QTLoc.tr("Albums")),
                            retry: { Task { await store.loadLibraryAlbums(force: true) } }) {
                grid(store.libraryAlbums)
            }
            .task { await store.loadLibraryAlbums() }
        } else {
            grid(QTLibraryIndex.albums(model.catalog.tracks))
        }
    }

    @ViewBuilder
    private func grid(_ albums: [QTAlbum]) -> some View {
        if albums.isEmpty {
            ContentUnavailableView(QTLoc.tr("No Albums", table: .live), systemImage: QTIcon.album.systemName)
                .accessibilityIdentifier("qt.library.albums.empty")
        } else {
            QTLibraryGridPage(title: QTLoc.tr("Albums"), items: albums, identifier: "qt.library.albums") { album in
                QTHomeCard(item: .album(album), shelfTracks: [])
            }
        }
    }
}

/// Library › Artists.
struct QTLibraryArtistsPage: View {
    @Environment(QTAppModel.self) private var model

    var body: some View {
        let store = QTLiveCatalogStore.shared
        if store.isLive {
            QTLivePhaseView(phase: store.artistsPhase, skeleton: QTLiveSkeleton(layout: .grid, title: QTLoc.tr("Artists")),
                            retry: { Task { await store.loadLibraryArtists(force: true) } }) {
                grid(store.libraryArtists)
            }
            .task { await store.loadLibraryArtists() }
        } else {
            grid(QTLibraryIndex.artists(model.catalog.tracks))
        }
    }

    @ViewBuilder
    private func grid(_ artists: [QTArtist]) -> some View {
        if artists.isEmpty {
            ContentUnavailableView(QTLoc.tr("No Artists", table: .live), systemImage: QTIcon.mic.systemName)
                .accessibilityIdentifier("qt.library.artists.empty")
        } else {
            QTLibraryGridPage(title: QTLoc.tr("Artists"), items: artists, identifier: "qt.library.artists") { artist in
                QTHomeCard(item: .artist(artist), shelfTracks: [])
            }
        }
    }
}

/// Page title + a grid of fixed-size cards. Columns are counted from the measured width (no grid minimums: with the
/// inspector open a content minimum feeds AppKit's split-view constraints into an update-constraints loop).
struct QTLibraryGridPage<Item: Identifiable, Card: View>: View {
    let title: String
    let items: [Item]
    let identifier: String
    @ViewBuilder let card: (Item) -> Card
    @State private var width: CGFloat = 0

    private var columnCount: Int {
        let gap = QTTheme.Spacing.shelfGap
        guard width > 0 else { return 4 }
        return max(1, Int((width - QTTheme.Spacing.gutter * 2 + gap) / (QTTheme.Metrics.card + gap)))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(verbatim: title)
                    .font(QTTheme.Typography.pageTitle)
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: QTTheme.Spacing.shelfGap, alignment: .topLeading),
                                         count: columnCount),
                          alignment: .leading, spacing: 28) {
                    ForEach(items) { card($0) }
                }
            }
            .padding(.horizontal, QTTheme.Spacing.gutter)
            .padding(.top, 40)
            .padding(.bottom, 48)
        }
        .qtSoftScrollEdges()
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .accessibilityIdentifier(identifier)
    }
}
