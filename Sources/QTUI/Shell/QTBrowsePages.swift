import QTCore
import QTInnerTube
import SwiftUI

// Owner: builder "window". The ONE set of browse pages of the content column, for the demo catalog and the live
// YouTube Music library alike: Explore (Overview · New releases · Charts · Moods & genres), mood/genre pages,
// Artist (hero or portrait, Play / Shuffle, Songs, then the page's rows in order), Album (the native track table).
// All read `QTBrowse.service` through `QTBrowseLoader`: the first frame has the page whenever it's already in hand
// (always for the demo catalog; Back/Forward for the live one), otherwise the page's skeleton, then the page — or
// one failure state with Try Again. Back/Forward restore each page's scroll position (`QTBrowseScroll`).

// MARK: - Loader

/// Loads one page from `QTBrowse.service`. Keeps the previous page on screen while a new request (a new search
/// query, a language change) loads, holds launch readiness while loading, and reloads when the interface language
/// (InnerTube `hl`) or the catalog source (demo ⇄ live) changes.
struct QTBrowseLoader<Page: Sendable, Skeleton: View, Content: View>: View {
    let request: QTBrowseRequest
    let debounce: Duration?
    let extract: (QTBrowseResponse) -> Page?
    @ViewBuilder let skeleton: () -> Skeleton
    /// The page, and whether it's the previous request's page while the current one loads.
    @ViewBuilder let content: (Page, Bool) -> Content
    @State private var page: Page?
    @State private var pageID: String?
    @State private var failure: QTLiveFailure?
    @State private var retries = 0

    init(_ request: QTBrowseRequest, debounce: Duration? = nil, extract: @escaping (QTBrowseResponse) -> Page?,
         @ViewBuilder skeleton: @escaping () -> Skeleton, @ViewBuilder content: @escaping (Page, Bool) -> Content) {
        self.request = request
        self.debounce = debounce
        self.extract = extract
        self.skeleton = skeleton
        self.content = content
        if let cached = QTBrowse.service.cached(request).flatMap(extract) {
            _page = State(initialValue: cached)
            _pageID = State(initialValue: Self.identity(request))
        }
    }

    static func identity(_ request: QTBrowseRequest) -> String {
        "\(request.key)|\(QTLoc.locale.identifier)|\(QTBrowse.sourceKey)"
    }

    var body: some View {
        let id = Self.identity(request)
        Group {
            if let pinned = QTLiveCatalogStore.shared.pinnedPhase, pinned != .loaded {
                // `-qt.live.state skeleton|offline|…` pins every page's state (screenshots).
                if case .failed(let f) = pinned { QTLiveFailureView(failure: f) {} } else { skeleton() }
            } else if let page {
                content(page, pageID != id)
            } else if let failure {
                QTLiveFailureView(failure: failure) { retries += 1 }
            } else {
                skeleton()
            }
        }
        .task(id: "\(id)#\(retries)") { await load(id: id, force: retries > 0) }
    }

    private func load(id: String, force: Bool) async {
        let service = QTBrowse.service
        if !force, let cached = service.cached(request).flatMap(extract) {
            page = cached
            pageID = id
            failure = nil
            return
        }
        guard force || pageID != id else { return }
        let token = QTReadiness.shared.hold("browse \(request.key)")
        defer { QTReadiness.shared.release(token) }
        if let debounce, !force { try? await Task.sleep(for: debounce) }
        guard !Task.isCancelled else { return }
        do {
            let next = try await service.load(request, force: force).flatMap(extract)
            guard !Task.isCancelled else { return }
            page = next
            failure = next == nil ? .unavailable : nil
        } catch {
            guard !Task.isCancelled else { return }
            page = nil
            failure = (error as? QTBrowseFailure)?.failure ?? QTLiveFailure(error)
        }
        pageID = id
    }
}

/// Skeleton rows for a section that loads below an already visible page header (Explore's sections).
struct QTBrowseRowsSkeleton: View {
    var body: some View {
        // The shelves skeleton without its title and chip row.
        QTLiveSkeleton(layout: .shelves)
            .frame(height: 760)
            .padding(.top, -110)
            .clipped()
    }
}

/// Vertical page with the system scroller that remembers its offset per destination (back/forward).
struct QTBrowseScroll<Content: View>: View {
    let destination: QTDestination
    let identifier: String
    @ViewBuilder let content: () -> Content
    @State private var position = ScrollPosition(edge: .top)
    @State private var didRestore = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 48)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { _, y in
            guard didRestore else { return }
            QTNavigator.shared.setScrollOffset(y, for: destination)
        }
        .onAppear {
            let saved = QTNavigator.shared.scrollOffset(for: destination)
            if saved > 0 { position.scrollTo(y: saved) }
            didRestore = true
        }
        .accessibilityIdentifier(identifier)
    }
}

/// Large page title at the page gutter (`.home-head h1`).
struct QTPageTitle: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(QTTheme.Typography.pageTitle)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
            .padding(.top, 40)
            .padding(.horizontal, QTTheme.Spacing.gutter)
    }
}

/// Section heading in shelf style, for sections that aren't `QTHomeShelf` rows.
struct QTSectionTitle: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(QTTheme.Typography.shelfTitle)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Explore

struct QTExploreView: View {
    @SceneStorage("qt.explore.section") private var sectionID = QTExploreSection.overview.rawValue

    private var section: QTExploreSection { QTExploreSection(rawValue: sectionID) ?? .overview }

    var body: some View {
        QTBrowseLoader(.explore, extract: \.explore) {
            QTLiveSkeleton(layout: .shelves, title: QTLoc.tr("Explore"))
        } content: { content, _ in
            QTBrowseScroll(destination: .section(.explore), identifier: "qt.explore") {
                header(content)
                sectionContent(content)
            }
        }
    }

    private func header(_ content: QTExploreContent) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(QTLoc.tr("Explore"))
                .font(QTTheme.Typography.pageTitle)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, QTTheme.Spacing.gutter)
            // In a horizontal scroll view so the control's width never becomes the content column's minimum
            // width (with the inspector open that drives the split view into an update-constraints loop).
            ScrollView(.horizontal) {
                Picker(QTLoc.tr("Explore"), selection: $sectionID) {
                    ForEach(QTExploreSection.allCases, id: \.self) { s in
                        Text(verbatim: Self.title(s, content)).tag(s.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.large)
                .padding(.horizontal, QTTheme.Spacing.gutter)
                .padding(.vertical, 2)
                .accessibilityIdentifier("qt.explore.sections")
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .padding(.top, 40)
    }

    /// YouTube Music's own (localized) names where it sends them, else ours.
    static func title(_ s: QTExploreSection, _ content: QTExploreContent) -> String {
        if let server = content.sectionTitles[s], !server.isEmpty { return server }
        return switch s {
        case .overview: QTLoc.tr("Overview", table: .main)
        case .newReleases: QTLoc.tr("New releases", table: .main)
        case .charts: QTLoc.tr("Charts", table: .main)
        case .moods: QTLoc.tr("Moods & genres", table: .main)
        }
    }

    @ViewBuilder
    private func sectionContent(_ content: QTExploreContent) -> some View {
        switch section {
        case .overview:
            shelves(content.shelves, ranked: false)
        case .newReleases, .charts:
            QTBrowseLoader(.exploreSection(section), extract: \.shelves) {
                QTBrowseRowsSkeleton()
            } content: { list, _ in
                shelves(list, ranked: section == .charts)
            }
            .id(section)
        case .moods:
            QTBrowseLoader(.moods, extract: \.moods) {
                QTBrowseRowsSkeleton()
            } content: { page, _ in
                QTMoodGrid(page: page)
            }
        }
    }

    @ViewBuilder
    private func shelves(_ list: [QTShelf], ranked: Bool) -> some View {
        if list.isEmpty {
            ContentUnavailableView(QTLoc.tr("Explore"), systemImage: QTIcon.compass.systemName)
                .frame(maxWidth: .infinity, minHeight: 360)
        } else {
            let source = QTQueueSource(kind: .playlist, title: .localized("Explore"))
            ForEach(list) { shelf in
                // Chart positions on chart song lists (the demo's Overview has its own Charts row).
                QTHomeShelf(shelf: shelf, source: source, ranked: (ranked || shelf.id == "explore.charts") && shelf.style == .quickPicks)
                    .padding(.top, QTTheme.Spacing.shelfSpacing)
            }
        }
    }
}

/// Moods & genres: one tile grid per group ("Moods & moments", "Genres"); each tile opens its page.
struct QTMoodGrid: View {
    let page: QTMoodsPage
    @Environment(QTAppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(page.groups.enumerated()), id: \.element.id) { gi, group in
                QTSectionTitle(text: group.title)
                    .padding(.top, gi == 0 ? 0 : 18)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount), alignment: .leading, spacing: 12) {
                    ForEach(Array(group.moods.enumerated()), id: \.element.id) { i, chip in
                        QTMoodTile(chip: chip, color: tileColor(gi * 7 + i))
                    }
                }
            }
        }
        .padding(.horizontal, QTTheme.Spacing.gutter)
        .padding(.top, QTTheme.Spacing.shelfSpacing)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("qt.explore.moods")
    }

    @State private var width: CGFloat = 0

    /// Tiles of at least 180 pt, counted from the measured width (no grid minimum: see QTQuickPicks).
    private var columnCount: Int {
        guard width > 0 else { return 3 }
        return max(1, Int((width - QTTheme.Spacing.gutter * 2 + 12) / (180 + 12)))
    }

    /// Tile stripes cycle through the library's artwork colours.
    private func tileColor(_ i: Int) -> QTArtworkPalette? {
        let palettes = model.catalog.tracks.lazy.compactMap(\.palette).prefix(12)
        return palettes.isEmpty ? nil : Array(palettes)[i % palettes.count]
    }
}

/// Mood / genre tile: a quiet filled rounded rectangle with a colour stripe.
struct QTMoodTile: View {
    let chip: QTMoodChip
    let color: QTArtworkPalette?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        let stripe = color.map { Color(qt: scheme == .dark ? $0.accentOnDark : $0.accentOnLight) } ?? QTTheme.Colors.systemAccent
        let shape = RoundedRectangle(cornerRadius: QTTheme.Radius.artwork, style: .continuous)
        Button {
            // A real destination, so Back / Forward and the per-page state work.
            QTNavigator.shared.go(.mood(chip))
        } label: {
            HStack(spacing: 14) {
                Capsule(style: .continuous)
                    .fill(stripe)
                    .frame(width: 4, height: 28)
                Text(verbatim: chip.title.resolved)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                QTIcon.chevR.image
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 56)
            .background(shape.fill(isHovered ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.fill.tertiary)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(QTTheme.Motion.animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.18), reduceMotion: reduceMotion), value: isHovered)
        .accessibilityIdentifier("qt.explore.mood.\(chip.id)")
    }
}

// MARK: - Mood / genre page

struct QTMoodPageView: View {
    let chip: QTMoodChip

    var body: some View {
        QTBrowseLoader(.mood(chip), extract: \.shelves) {
            QTLiveSkeleton(layout: .shelves, title: chip.title.resolved)
        } content: { shelves, _ in
            QTBrowseScroll(destination: .mood(chip), identifier: "qt.mood") {
                QTPageTitle(text: chip.title.resolved)
                if shelves.isEmpty {
                    ContentUnavailableView(chip.title.resolved, systemImage: QTIcon.compass.systemName)
                        .frame(maxWidth: .infinity, minHeight: 360)
                }
                ForEach(shelves) { shelf in
                    QTHomeShelf(shelf: shelf, source: QTQueueSource(kind: .radio, id: chip.id, title: chip.title))
                        .padding(.top, shelf.id == shelves.first?.id ? 28 : QTTheme.Spacing.shelfSpacing)
                }
            }
        }
    }
}

// MARK: - Album

/// An album: the native track table with the album header (art, title, linked artist, Play / Shuffle / More).
struct QTAlbumPageView: View {
    let key: String
    var destination: QTDestination { .album(key) }

    var body: some View {
        QTBrowseLoader(.album(key), extract: \.album) {
            QTLiveSkeleton(layout: .trackList)
        } content: { page, _ in
            QTLibraryView(collection: Self.collection(page, key: key), destination: destination)
                .task(id: page.album.title) { QTNavigator.shared.notePageTitle(page.album.title, for: destination) }
        }
    }

    /// The collection id matches `QTTrackCollection.listKey(for: .album(key))`, so filter/sort/scroll survive Back.
    static func collection(_ page: QTAlbumPage, key: String) -> QTTrackCollection {
        QTTrackCollection(id: "album:\(key)", kind: .album, title: page.album.title, artwork: page.album.artwork,
                          tracks: page.album.tracks ?? [])
    }
}

// MARK: - Artist

struct QTArtistPageView: View {
    let key: String

    var body: some View {
        QTBrowseLoader(.artist(key), extract: \.artist) {
            QTLiveSkeleton(layout: .artist)
        } content: { page, _ in
            QTArtistPageContent(page: page, destination: .artist(key))
                .task(id: page.artist.name) { QTNavigator.shared.notePageTitle(page.artist.name, for: .artist(key)) }
        }
    }
}

/// Hero (the artist's wide photo when YouTube Music has one, else a round portrait), Play / Shuffle, top Songs,
/// then the page's rows in order — Albums, Singles & EPs, Videos, playlists, Fans also like — and the bio.
struct QTArtistPageContent: View {
    let page: QTArtistPage
    let destination: QTDestination

    private var source: QTQueueSource { QTQueueSource(kind: .artist, id: page.artist.id, title: .verbatim(page.artist.name)) }

    /// Wide photo → hero banner; square → portrait.
    private var isWide: Bool {
        guard let best = page.artist.artwork.max(by: { ($0.width ?? 0) < ($1.width ?? 0) }),
              let w = best.width, let h = best.height, h > 0 else { return false }
        return Double(w) / Double(h) > 1.5
    }

    var body: some View {
        QTBrowseScroll(destination: destination, identifier: "qt.artist") {
            if isWide { hero } else { portraitHeader }
            if !page.songs.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    QTSectionTitle(text: QTLoc.tr("Songs"))
                        .padding(.horizontal, QTTheme.Spacing.gutter)
                    QTQuickPicks(tracks: Array(page.songs.prefix(9)), source: source)
                }
                .padding(.top, QTTheme.Spacing.shelfSpacing)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("qt.artist.songs")
            }
            ForEach(page.shelves) { shelf in
                QTHomeShelf(shelf: shelf, source: source)
                    .padding(.top, QTTheme.Spacing.shelfSpacing)
            }
            if let about = page.description, !about.isEmpty {
                Text(verbatim: about)
                    .font(QTTheme.Typography.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .frame(maxWidth: 640, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, QTTheme.Spacing.gutter)
                    .padding(.top, QTTheme.Spacing.shelfSpacing)
            }
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            QTArtworkView(page.artist.artwork, cornerRadius: 0, placeholder: .mic)
                .frame(maxWidth: .infinity)
                .frame(height: 360)
                .overlay {
                    // Legibility for the name, not decoration.
                    LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.62), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .clipped()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: page.artist.name)
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 2)
                    .accessibilityAddTraits(.isHeader)
                if let audience = page.audience {
                    Text(verbatim: audience)
                        .font(QTTheme.Typography.secondary)
                        .foregroundStyle(.white.opacity(0.85))
                }
                actions.padding(.top, 12)
            }
            .padding(.horizontal, QTTheme.Spacing.gutter)
            .padding(.bottom, 28)
            .environment(\.colorScheme, .dark)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("qt.artist.header")
    }

    private var portraitHeader: some View {
        HStack(alignment: .center, spacing: 28) {
            QTArtworkView(page.artist.artwork, cornerRadius: 0, placeholder: .mic)
                .frame(width: 168, height: 168)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(QTLoc.tr("Artist", table: .main))
                    .font(QTTheme.Typography.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: page.artist.name)
                    .font(QTTheme.Typography.pageTitle)
                    .lineLimit(1)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: page.audience ?? QTLoc.tr("%lld songs", table: .main, page.songs.count))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                actions.padding(.top, 18)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, QTTheme.Spacing.gutter)
        .padding(.top, 36)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("qt.artist.header")
    }

    /// Play / Shuffle the artist's songs (draft §7 "Shuffle works everywhere").
    private var actions: some View {
        let songs = page.songs
        return HStack(spacing: 10) {
            Button {
                if let i = songs.firstIndex(where: \.availability.isPlayable) { QTTrackActions.play(songs, at: i, source: source) }
            } label: {
                Label(QTLoc.tr("Play"), systemImage: QTIcon.play.systemName)
            }
            .qtGlassButton(.primary)
            .accessibilityIdentifier("qt.artist.play")
            Button {
                QTTrackActions.shuffle(songs, source: source)
            } label: {
                Label(QTLoc.tr("Shuffle"), systemImage: QTIcon.shuffle.systemName)
            }
            .qtGlassButton(.secondary)
            .accessibilityIdentifier("qt.artist.shuffle")
        }
        .controlSize(.large)
        .disabled(!songs.contains(where: \.availability.isPlayable))
    }
}

// MARK: - Actions

/// Playing a browse item that may need its page first (an album card, a search top result).
@MainActor
enum QTBrowseActions {
    static func playAlbum(_ album: QTAlbum, shuffled: Bool = false) {
        let source = QTQueueSource(kind: .album, id: album.id, title: .verbatim(album.title))
        if let tracks = album.tracks, !tracks.isEmpty { start(tracks, source: source, shuffled: shuffled); return }
        Task { @MainActor in
            guard let tracks = try? await QTBrowse.service.album(album.id)?.album.tracks else { return }
            start(tracks, source: source, shuffled: shuffled)
        }
    }

    static func playArtist(_ artist: QTArtist, shuffled: Bool = false) {
        let source = QTQueueSource(kind: .artist, id: artist.id, title: .verbatim(artist.name))
        Task { @MainActor in
            guard let songs = try? await QTBrowse.service.artist(artist.id)?.songs else { return }
            start(songs, source: source, shuffled: shuffled)
        }
    }

    static func playPlaylist(_ playlist: QTPlaylist, shuffled: Bool = false) {
        if let tracks = playlist.tracks, !tracks.isEmpty {
            start(tracks, source: QTQueueSource(kind: .playlist, id: playlist.id, title: playlist.title), shuffled: shuffled)
        } else if QTLiveCatalogStore.shared.isLive {
            QTLiveActions.playPlaylist(playlist.id, title: playlist.title.resolved, shuffled: shuffled)
        }
    }

    private static func start(_ tracks: [QTTrack], source: QTQueueSource, shuffled: Bool) {
        guard !tracks.isEmpty else { return }
        if shuffled {
            QTTrackActions.shuffle(tracks, source: source)
        } else if let i = tracks.firstIndex(where: \.availability.isPlayable) {
            QTTrackActions.play(tracks, at: i, source: source)
        }
    }
}
