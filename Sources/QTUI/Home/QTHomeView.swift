import QTCore
import SwiftUI

// Owner: builder "window". Home (prototype home.jsx + styles.css `.home`): greeting + mood chips, then the feed's
// shelves (Listen again, song shelves as a paged four-row grid, Music videos, playlists). ONE view for the demo
// catalog and the live library: live adds the load phase and mood chips that load that mood's feed; in the demo the
// chips only toggle. Loading is per section: the greeting is real at once; the chips and the shelves each swap their
// own placeholder (QTMoodChipsSkeleton, QTHomeShelvesSkeleton) in place, in the real geometry. (Kaset ADR-0038: AppKit
// beats SwiftUI for *big* shelves — these are lazy and small.)

public struct QTHomeView: View {
    @Environment(QTAppModel.self) private var model
    @State private var position = ScrollPosition(edge: .top)
    /// Demo catalog only; live Home keeps the chosen mood in the store (it survives leaving the page).
    @State private var demoMood: String?
    @State private var didRestore = false
    @State private var didApplyLaunchMood = false
    /// The signed-in session is still restoring: Home's loading state, before the store is live.
    private let isRestoring: Bool

    public init(isRestoring: Bool = false) {
        self.isRestoring = isRestoring
    }

    public var body: some View {
        let store = QTLiveCatalogStore.shared
        feed(live: store.isLive && !isRestoring ? store : nil)
            // Keyed by the mode: a sign-out (library → guest) resets the pages, and Home reloads anonymously.
            .task(id: store.mode) { if store.isLive && !isRestoring { await store.loadHome() } }
    }

    private func feed(live store: QTLiveCatalogStore?) -> some View {
        let mood = store?.homeMood ?? (store == nil ? demoMood : nil)
        // Live: a chosen mood shows that mood's feed (its own phase); the demo has no per-mood feeds.
        let phase: QTLivePhase = isRestoring ? .loading
            : store.map { s in s.pinnedPhase ?? mood.map { s.moodPhases[$0] ?? .loading } ?? s.homePhase } ?? .loaded
        let shelves = store.flatMap { s in mood.flatMap { s.moodFeeds[$0]?.shelves } } ?? model.catalog.home.shelves
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                header(store: store, selected: mood, phase: phase)
                switch phase {
                case .failed(let f):
                    QTLiveFailureView(failure: f) {
                        guard let store else { return }
                        Task { if let mood { await store.loadMood(mood) } else { await store.loadHome(force: true) } }
                    }
                    .frame(height: 360)
                case .loaded:
                    ForEach(shelves) { shelf in
                        QTHomeShelf(shelf: shelf)
                            .padding(.top, QTTheme.Spacing.shelfSpacing)
                    }
                case .idle, .loading:
                    QTHomeShelvesSkeleton()
                }
            }
            .padding(.bottom, 48)
        }
        .qtSoftScrollEdges()
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { _, y in
            guard didRestore, !isRestoring else { return }
            QTNavigator.shared.setScrollOffset(y, for: .section(.home))
        }
        .onAppear {
            guard !isRestoring else { return }
            let saved = model.launch.double("qt.home.scroll").map { CGFloat($0) } ?? QTNavigator.shared.scrollOffset(for: .section(.home))
            if saved > 0 { position.scrollTo(y: saved) }
            didRestore = true
            // `-qt.home.mood <id>`: launch with a mood chip selected (screenshots).
            if !didApplyLaunchMood, let id = model.launch.string("qt.home.mood") {
                didApplyLaunchMood = true
                if let store { store.selectMood(id) } else { demoMood = id }
            }
        }
        .accessibilityIdentifier("qt.home")
    }

    private func header(store: QTLiveCatalogStore?, selected: String?, phase: QTLivePhase) -> some View {
        let moods = isRestoring ? [] : model.catalog.home.moods
        let isLoading = switch phase { case .idle, .loading: true; default: false }
        return VStack(alignment: .leading, spacing: 18) {
            Text(Self.greeting(at: .now))
                .font(QTTheme.Typography.pageTitle)
                .accessibilityAddTraits(.isHeader)
            if !moods.isEmpty {
                QTChipFlow(spacing: 10) {
                    ForEach(moods) { mood in
                        Toggle(mood.title.resolved, isOn: Binding(
                            get: { selected == mood.id },
                            set: { on in
                                if let store { store.selectMood(on ? mood.id : nil) } else { demoMood = on ? mood.id : nil }
                            }
                        ))
                        .toggleStyle(QTChipToggleStyle())
                        .accessibilityIdentifier("qt.home.mood.\(mood.id)")
                    }
                }
                .controlSize(.large)
            } else if isLoading {
                QTMoodChipsSkeleton()
                    .controlSize(.large)
            }
        }
        .padding(.top, 40)
        .padding(.horizontal, QTTheme.Spacing.gutter)
    }

    /// Prototype greeting buckets: <5 night, <12 morning, <18 afternoon, else evening.
    static func greeting(at date: Date, calendar: Calendar = .current) -> String {
        let h = calendar.component(.hour, from: date)
        return QTLoc.tr(h < 5 ? "Good night" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening")
    }
}

// MARK: - Shelf

struct QTHomeShelf: View {
    let shelf: QTShelf
    /// Queue source for songs started from this shelf (nil = Home / "Quick picks").
    var source: QTQueueSource? = nil
    /// Quick-pick rows show their chart position (Explore › Charts).
    var ranked = false
    @Environment(QTAppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var firstVisible: String?
    /// The song grid's first visible column.
    @State private var firstColumn: Int?
    @State private var width: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: QTTheme.Spacing.m) {
                Text(shelf.title.resolved)
                    .font(QTTheme.Typography.shelfTitle)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                switch shelf.style {
                case .quickPicks:
                    if songLayout.pages {
                        Button(QTLoc.tr("See All")) { QTNavigator.shared.go(.shelf(shelf)) }
                            .buttonStyle(.link)
                            .accessibilityIdentifier("qt.home.shelf.\(shelf.id).seeAll")
                        songPager
                    }
                case .cards, .videos:
                    if !fitsWithoutPaging { pager }
                }
            }
            .padding(.horizontal, QTTheme.Spacing.gutter)
            switch shelf.style {
            case .quickPicks: songGrid
            case .cards, .videos: row
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("qt.home.shelf.\(shelf.id)")
    }

    private var tracks: [QTTrack] {
        shelf.items.compactMap { if case .track(let t) = $0 { t } else if case .video(let t) = $0 { t } else { nil } }
    }

    private var itemWidth: CGFloat { shelf.style == .videos ? QTTheme.Metrics.videoCardWidth : QTTheme.Metrics.card }

    /// Short rows (search, artist pages) need no pager.
    private var fitsWithoutPaging: Bool {
        width > 0 && CGFloat(shelf.items.count) * (itemWidth + QTTheme.Spacing.shelfGap) - QTTheme.Spacing.shelfGap
            <= width - QTTheme.Spacing.gutter * 2
    }

    private var row: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: QTTheme.Spacing.shelfGap) {
                ForEach(shelf.items) { item in
                    QTHomeCard(item: item, shelfTracks: tracks, source: source ?? QTQueueSource(kind: .home, title: .localized("Home")))
                        .id(item.id)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, QTTheme.Spacing.gutter)
            .padding(.bottom, 10) // room for artwork shadows
        }
        .scrollIndicators(.never)
        .scrollPosition(id: $firstVisible, anchor: .leading)
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
    }

    /// Prototype `.shelf-nav`: quiet chevrons paging the row.
    private var pager: some View {
        let ids = shelf.items.map(\.id)
        let index = firstVisible.flatMap { ids.firstIndex(of: $0) } ?? 0
        let perPage = max(1, Int((width - QTTheme.Spacing.gutter * 2 + QTTheme.Spacing.shelfGap) / (itemWidth + QTTheme.Spacing.shelfGap)))
        return chevrons(index: index, perPage: perPage, count: ids.count) { i in
            guard ids.indices.contains(i) else { return }
            firstVisible = ids[i]
        }
    }

    private func chevrons(index: Int, perPage: Int, count: Int, to page: @escaping (Int) -> Void) -> some View {
        let go = { (i: Int) in
            withAnimation(QTTheme.Motion.animation(QTTheme.Motion.ui, reduceMotion: reduceMotion)) { page(i) }
        }
        return HStack(spacing: 2) {
            Button {
                go(max(0, index - perPage))
            } label: {
                Label(QTLoc.tr("Scroll left"), systemImage: QTIcon.chevL.systemName)
            }
            .disabled(index == 0)
            .accessibilityIdentifier("qt.home.shelf.\(shelf.id).previous")
            Button {
                go(min(count - 1, index + perPage))
            } label: {
                Label(QTLoc.tr("Scroll right"), systemImage: QTIcon.chevR.systemName)
            }
            .disabled(index + perPage >= count)
            .accessibilityIdentifier("qt.home.shelf.\(shelf.id).next")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .imageScale(.large)
        .controlSize(.large)
    }

    // MARK: Song grid

    private var songLayout: QTSongShelfLayout { QTSongShelfLayout(width: width, tracks: tracks.count, ranked: ranked) }

    /// Song shelves (Quick picks, Trending, charts) as Music.app's Top Songs: up to four rows, columns filling top
    /// to bottom (YouTube Music's order), as many columns as the width holds per page, paged sideways; See All
    /// opens the whole list as a track table.
    private var songGrid: some View {
        let layout = songLayout
        let tracks = self.tracks
        let source = self.source
        return ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: QTSongShelfLayout.columnSpacing) {
                ForEach(0..<layout.columns, id: \.self) { c in
                    VStack(alignment: .leading, spacing: QTSongShelfLayout.rowSpacing) {
                        ForEach(layout.range(ofColumn: c, tracks: tracks.count), id: \.self) { i in
                            QTQuickPickRow(track: tracks[i], tracks: tracks, source: source, rank: ranked ? i + 1 : nil)
                        }
                    }
                    .frame(width: layout.columnWidth, alignment: .topLeading)
                    .id(c)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, QTTheme.Spacing.gutter, for: .scrollContent)
        .scrollIndicators(.never)
        .scrollPosition(id: $firstColumn, anchor: .leading)
        .scrollTargetBehavior(.viewAligned)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
    }

    private var songPager: some View {
        let layout = songLayout
        return chevrons(index: firstColumn ?? 0, perPage: layout.perPage, count: layout.columns) { firstColumn = $0 }
    }
}

/// Geometry of a paged song shelf (pure, tested): columns per page by the Quick picks rule (up to three, none
/// narrower than a readable row), up to four rows, then as many columns as the songs need.
struct QTSongShelfLayout: Equatable {
    static let maxRows = 4
    static let maxColumnsPerPage = 3
    static let columnSpacing: CGFloat = 20
    static let rowSpacing: CGFloat = 4

    /// Columns on screen at once.
    let perPage: Int
    let rows: Int
    /// All columns.
    let columns: Int
    let columnWidth: CGFloat

    /// More columns than one page: chevrons and See All.
    var pages: Bool { columns > perPage }

    /// - Parameter width: the shelf's full width, gutters included (0 = not measured yet).
    init(width: CGFloat, tracks: Int, ranked: Bool) {
        let perPage = QTQuickPicks.columnCount(forWidth: width, tracks: tracks, maxColumns: Self.maxColumnsPerPage, ranked: ranked)
        let rows = min(Self.maxRows, max(1, (tracks + perPage - 1) / perPage))
        self.perPage = perPage
        self.rows = rows
        columns = max(1, (tracks + rows - 1) / rows)
        let inner = width - QTTheme.Spacing.gutter * 2 - Self.columnSpacing * CGFloat(perPage - 1)
        columnWidth = width > 0 ? max(120, inner / CGFloat(perPage)) : QTQuickPicks.minRowWidth
    }

    /// Song indices in column `c` (top to bottom).
    func range(ofColumn c: Int, tracks: Int) -> Range<Int> {
        min(tracks, c * rows)..<min(tracks, (c + 1) * rows)
    }
}

// MARK: - Cards

struct QTHomeCard: View {
    let item: QTShelfItem
    let shelfTracks: [QTTrack]
    var source = QTQueueSource(kind: .home, title: .localized("Home"))
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        switch item {
        case .track(let t): trackCard(t, video: false)
        case .video(let t): trackCard(t, video: true)
        case .playlist(let p): playlistCard(p)
        // Live shelves (data-live) open albums/artists by browse/channel id through the live store; the demo
        // catalog's cards open the mock browse pages by title.
        case .album(let a):
            if QTLiveCatalogStore.shared.isLive { QTLiveAlbumCard(album: a) } else { albumCard(a) }
        case .artist(let a):
            if QTLiveCatalogStore.shared.isLive { QTLiveArtistCard(artist: a) } else { artistCard(a) }
        }
    }

    private func trackCard(_ t: QTTrack, video: Bool) -> some View {
        let w = video ? QTTheme.Metrics.videoCardWidth : QTTheme.Metrics.card
        let h = video ? QTTheme.Metrics.videoCardHeight : QTTheme.Metrics.card
        let isCurrent = player.nowPlaying?.videoId == t.videoId
        return Button {
            if isCurrent && (!video || player.mode == .video) {
                player.togglePlayPause()
            } else {
                let i = shelfTracks.firstIndex(of: t) ?? 0
                QTTrackActions.play(shelfTracks, at: i, source: source, video: video)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                artwork(QTArtworkView(track: t, video: video), width: w, height: h,
                        playIcon: isCurrent && player.isPlaying ? .pause : .play, showsPlay: isHovered || isCurrent,
                        nowPlaying: isCurrent && !isHovered ? player.isPlaying : nil)
                    .padding(.bottom, 6)
                Text(verbatim: t.title)
                    .font(QTTheme.Typography.rowTitle)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Text(verbatim: t.artistLine)
                    .font(QTTheme.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: w, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu { QTTrackContextMenu(track: t) }
        .draggable(QTTrackActions.link(for: t))
        .help(t.title)
        .accessibilityLabel(QTLoc.tr("Play %@", t.title))
        .accessibilityIdentifier("qt.home.card.\(video ? "video" : "track").\(t.videoId)")
    }

    private func playlistCard(_ p: QTPlaylist) -> some View {
        let liked = p.kind == .liked
        let collection = liked ? QTTrackCollection.liked(model.catalog) : QTTrackCollection.playlist(p, catalog: model.catalog)
        return Button {
            QTNavigator.shared.go(.section(liked ? .liked : .playlist(p.id)))
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                artwork(QTCollectionTile(collection: collection, size: QTTheme.Metrics.card, cornerRadius: QTTheme.Radius.artwork, showsShadow: false),
                        width: QTTheme.Metrics.card, height: QTTheme.Metrics.card, playIcon: .play, showsPlay: false)
                    .padding(.bottom, 6)
                Text(verbatim: collection.title)
                    .font(QTTheme.Typography.rowTitle)
                    .lineLimit(1)
                Text(liked ? QTFormat.songCountAndMinutes(count: collection.tracks.count, seconds: collection.totalDuration) : QTLoc.tr("Playlist"))
                    .font(QTTheme.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: QTTheme.Metrics.card, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0; if $0 { QTLiveCatalogStore.shared.prefetch(item) } }
        .dropDestination(for: String.self) { items, _ in
            let tracks = QTTrackActions.tracks(fromDropped: items, catalog: model.catalog)
            guard !tracks.isEmpty else { return false }
            if liked { QTTrackActions.toggleLike(tracks.filter { !player.isLiked($0) }) } else { QTTrackActions.add(tracks, to: p) }
            return true
        }
        .accessibilityIdentifier("qt.home.card.playlist.\(p.id)")
    }

    /// Album / single: opens the album page; the hover badge plays it.
    private func albumCard(_ a: QTAlbum) -> some View {
        let size = QTTheme.Metrics.card
        let tracks = a.tracks ?? []
        return Button {
            QTNavigator.shared.go(.album(a.id))
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                artwork(QTArtworkView(a.artwork, cornerRadius: 0, placeholder: .album), width: size, height: size,
                        playIcon: .play, showsPlay: isHovered && !tracks.isEmpty)
                    .overlay(alignment: .bottomTrailing) {
                        // The badge plays without opening the page.
                        Color.clear.frame(width: 56, height: 56).contentShape(Rectangle())
                            .onTapGesture {
                                QTTrackActions.play(tracks, at: 0, source: QTQueueSource(kind: .album, title: .verbatim(a.title)))
                            }
                            .opacity(isHovered && !tracks.isEmpty ? 1 : 0)
                    }
                    .padding(.bottom, 6)
                Text(verbatim: a.title)
                    .font(QTTheme.Typography.rowTitle)
                    .lineLimit(1)
                Text(verbatim: Self.albumSubtitle(a))
                    .font(QTTheme.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: size, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(a.title)
        .accessibilityIdentifier("qt.browse.card.album.\(a.id)")
    }

    /// "Single · Hoàng Thùy Linh", "Album · 2019".
    static func albumSubtitle(_ a: QTAlbum) -> String {
        let kind = a.kind == .album ? QTLoc.tr("Album") : a.kind == .ep ? QTLoc.tr("EP", table: .main) : QTLoc.tr("Single", table: .main)
        let artists = a.artists.map(\.name).formatted(.list(type: .and, width: .narrow).locale(QTLoc.locale))
        let detail = a.year.map { String($0) } ?? artists
        return detail.isEmpty ? kind : QTLoc.tr("%@ · %@", table: .main, kind, detail)
    }

    /// Artist: round portrait, centred name (Music.app).
    private func artistCard(_ a: QTArtist) -> some View {
        let size = QTTheme.Metrics.card
        let anim = QTTheme.Motion.animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.4), reduceMotion: reduceMotion)
        return Button {
            QTNavigator.shared.go(.artist(a.id))
        } label: {
            VStack(spacing: 4) {
                QTArtworkView(a.artwork, cornerRadius: 0, placeholder: .mic)
                    .frame(width: size, height: size)
                    .scaleEffect(isHovered && !reduceMotion ? 1.04 : 1)
                    .animation(anim, value: isHovered)
                    .clipShape(Circle())
                    .background(Circle().fill(.black.opacity(0.001)).shadow(color: .black.opacity(isHovered ? 0.28 : 0.18), radius: isHovered ? 12 : 8, y: 4))
                    .padding(.bottom, 6)
                Text(verbatim: a.name)
                    .font(QTTheme.Typography.rowTitle)
                    .lineLimit(1)
                Text(QTLoc.tr("Artist", table: .main))
                    .font(QTTheme.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
            .frame(width: size)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(a.name)
        .accessibilityIdentifier("qt.browse.card.artist.\(a.id)")
    }

    /// Artwork with hover zoom (inside its rounded clip), soft shadow, and the accent play button.
    private func artwork<A: View>(_ art: A, width: CGFloat, height: CGFloat, playIcon: QTIcon, showsPlay: Bool,
                                     nowPlaying: Bool? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: QTTheme.Radius.artwork, style: .continuous)
        let anim = QTTheme.Motion.animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.4), reduceMotion: reduceMotion)
        return art
            .frame(width: width, height: height)
            .scaleEffect(isHovered && !reduceMotion ? 1.04 : 1)
            .animation(anim, value: isHovered)
            .clipShape(shape)
            .background(shape.fill(.black.opacity(0.001)).shadow(color: .black.opacity(isHovered ? 0.28 : 0.18), radius: isHovered ? 12 : 8, y: 4))
            .overlay(alignment: .bottomTrailing) {
                QTCardPlayBadge(icon: playIcon, nowPlaying: nowPlaying)
                    .padding(10)
                    .opacity(showsPlay ? 1 : 0)
                    .offset(y: showsPlay || reduceMotion ? 0 : 4)
                    .animation(QTTheme.Motion.animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.18), reduceMotion: reduceMotion), value: showsPlay)
            }
    }
}

/// Play/pause badge on hovered cards (`.card-play`): a small glass disc over the artwork with a white glyph, like
/// Music.app's — neutral, so a column of hovered cards never competes with the page's Play button or the sidebar.
/// On the current track's card, unhovered, the disc holds the now-playing marker instead (bars / still speaker).
struct QTCardPlayBadge: View {
    let icon: QTIcon
    var nowPlaying: Bool? = nil

    var body: some View {
        Group {
            if let nowPlaying {
                QTNowPlayingGlyph(isPlaying: nowPlaying, pointSize: 13, weight: .semibold, tint: .white)
            } else {
                icon.image
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 36, height: 36)
        .qtGlass(.overArt, in: Circle())
        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        .accessibilityHidden(true)
    }
}

// MARK: - Quick picks

struct QTQuickPicks: View {
    let tracks: [QTTrack]
    /// nil = "Quick picks" (Home).
    var source: QTQueueSource? = nil
    var ranked = false
    var columns = 3
    @State private var width: CGFloat = 0

    /// The narrowest row that still reads: 6 pt padding + 52 pt art + 14 + ~136 pt of title + 14 + 32 pt heart + 6
    /// (about ten Han characters or a short Latin title before the ellipsis). A chart rank adds its column.
    static let minRowWidth: CGFloat = 260
    private static let rankWidth: CGFloat = 36
    private static let columnSpacing: CGFloat = 20

    /// Up to `columns`, fewer when a row would drop under `minRowWidth` — the same rule in every appearance and
    /// catalog, so titles show meaningfully instead of three truncated stubs. Counted from the measured width rather
    /// than `GridItem(.flexible(minimum:))`: a grid minimum becomes the content column's minimum width, and with the
    /// inspector open that feeds AppKit's split-view constraints into an update-constraints loop (crash) on the
    /// macOS 26+ design.
    /// Never more columns than songs: a lone song (a one-song artist) gets the whole row, so a long title such as
    /// "Chúng Ta Của Hiện Tại" isn't cut to a third of the width beside empty space.
    private var columnCount: Int {
        Self.columnCount(forWidth: width, tracks: tracks.count, maxColumns: columns, ranked: ranked)
    }

    /// `width` is the grid's measured width including its gutters (0 = not measured yet).
    static func columnCount(forWidth width: CGFloat, tracks: Int, maxColumns: Int, ranked: Bool = false) -> Int {
        let wanted = min(maxColumns, max(1, tracks))
        guard width > 0 else { return wanted }
        let available = width - QTTheme.Spacing.gutter * 2 + columnSpacing
        let row = minRowWidth + (ranked ? rankWidth : 0)
        return min(wanted, max(1, Int(available / (row + columnSpacing))))
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.columnSpacing, alignment: .leading), count: columnCount),
                  alignment: .leading, spacing: 4) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                QTQuickPickRow(track: t, tracks: tracks, source: source, rank: ranked ? i + 1 : nil)
            }
        }
        .padding(.horizontal, QTTheme.Spacing.gutter)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
    }
}

struct QTQuickPickRow: View {
    let track: QTTrack
    let tracks: [QTTrack]
    var source: QTQueueSource? = nil
    /// Chart position, shown before the artwork.
    var rank: Int? = nil
    @Environment(QTPlayerModel.self) private var player
    @State private var isHovered = false

    var body: some View {
        let isCurrent = player.nowPlaying?.videoId == track.videoId
        let liked = player.isLiked(track)
        // The heart is a control, not decoration: it appears on hover and on the now-playing row, filled in the
        // app's accent when liked — the same heart as the player bar and the track tables.
        let showsHeart = isHovered || isCurrent
        HStack(spacing: 14) {
            if let rank {
                Text(rank, format: .number)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 22, alignment: .trailing)
                    .accessibilityLabel(QTLoc.tr("Number %lld", table: .main, rank))
            }
            Button(action: play) {
                QTArtworkView(track: track, cornerRadius: QTTheme.Radius.control)
                    .frame(width: QTTheme.Metrics.quickPickArtwork, height: QTTheme.Metrics.quickPickArtwork)
                    .overlay {
                        RoundedRectangle(cornerRadius: QTTheme.Radius.control, style: .continuous)
                            .fill(.black.opacity(0.4))
                            .overlay {
                                if isHovered {
                                    (isCurrent && player.isPlaying ? QTIcon.pause : QTIcon.play).image.foregroundStyle(.white)
                                } else if isCurrent {
                                    QTNowPlayingGlyph(isPlaying: player.isPlaying, pointSize: 13, weight: .semibold, tint: .white)
                                }
                            }
                            .opacity(isHovered || isCurrent ? 1 : 0)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(QTLoc.tr("Play %@", track.title))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: track.title)
                    .font(QTTheme.Typography.rowTitle)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Text(verbatim: track.artistLine)
                    .font(QTTheme.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                player.toggleLike(track)
            } label: {
                Label(QTLoc.tr(liked ? "Remove from Liked Songs" : "Like"), systemImage: (liked ? QTIcon.heartFill : QTIcon.heart).systemName)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(liked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.borderless)
            .frame(width: 32)
            .opacity(showsHeart ? 1 : 0)
            .allowsHitTesting(showsHeart)
            .help("\(QTLoc.tr(liked ? "Remove from Liked Songs" : "Like"))  ⌘L")
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: QTTheme.Radius.artwork, style: .continuous)
            .fill(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2, perform: play)
        .contextMenu { QTTrackContextMenu(track: track) }
        .draggable(QTTrackActions.link(for: track))
        .accessibilityElement(children: .combine)
        .accessibilityAction { play() }
        .accessibilityIdentifier("qt.home.pick.\(track.videoId)")
    }

    private func play() {
        if player.nowPlaying?.videoId == track.videoId { player.togglePlayPause(); return }
        QTTrackActions.play(tracks, at: tracks.firstIndex(of: track) ?? 0,
                            source: source ?? QTQueueSource(kind: .home, title: .localized("Quick picks")))
    }
}

// MARK: - Context menu (SwiftUI cards; same items as the table's NSMenu)

struct QTTrackContextMenu: View {
    let track: QTTrack
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player

    var body: some View {
        let playable = track.availability.isPlayable
        Button(QTLoc.tr("Play")) { QTTrackActions.play([track], at: 0, source: nil) }.disabled(!playable)
        Button(QTLoc.tr("Play Next")) { QTTrackActions.playNext([track]) }.disabled(!playable)
        Button(QTLoc.tr("Add to Queue")) { QTTrackActions.addToQueue([track]) }.disabled(!playable)
        Divider()
        if track.hasVideo {
            Button(QTLoc.tr("Play Music Video")) { QTTrackActions.play([track], at: 0, source: nil, video: true) }.disabled(!playable)
        } else {
            Button(QTLoc.tr("No Music Video")) {}.disabled(true)
        }
        if let album = track.album {
            Button(QTLoc.tr("Go to Album · %@", album.title)) { QTNavigator.shared.go(.album(album)) }
        }
        if let artist = track.artists.first {
            Button(QTLoc.tr("Go to Artist · %@", artist.name)) { QTNavigator.shared.go(.artist(artist)) }
        }
        Divider()
        if QTLiveCatalogStore.shared.isGuest {
            // Guest mode: no playlists of one's own; the item offers to sign in.
            Button(QTLoc.tr("Add to Playlist")) { _ = QTAccountGate.allows(.addToPlaylist) }
                .disabled(!playable)
        } else {
            // Same choices as the track tables' submenu (QTAddToPlaylistMenu): New Playlist…, then the playlists the
            // song can go into, checked when it's already there.
            Menu(QTLoc.tr("Add to Playlist")) {
                Button(QTLoc.tr("New Playlist…", table: .main)) { QTPlaylistActions.newPlaylist(with: [track]) }
                let targets = QTAddToPlaylistMenu.targets(options: nil, excluding: nil, tracks: [track])
                if !targets.isEmpty { Divider() }
                ForEach(targets, id: \.0.id) { p, holds in
                    Toggle(p.title.resolved, isOn: Binding(get: { holds }, set: { _ in QTTrackActions.add([track], to: p) }))
                }
            }
            .disabled(!playable)
        }
        Button(QTLoc.tr(player.isLiked(track) ? "Remove from Liked Songs" : "Like")) { QTTrackActions.toggleLike([track]) }
        Divider()
        Button(QTLoc.tr("Copy Link")) { QTTrackActions.copyLinks([track]) }
    }
}
