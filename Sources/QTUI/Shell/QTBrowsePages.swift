import QTCore
import QTInnerTube
import SwiftUI

// Owner: builder "window". Browse pages of the content column: Explore (New releases, Charts, Moods & genres),
// mood/genre pages, the Artist page (Songs, Albums, Singles, Videos, Fans also like). All read `QTBrowse.service`
// through `QTBrowseLoader`; with the mock service the first frame already has the page (no loading flash).

// MARK: - Loader

/// Loads one page from `QTBrowse.service`. The mock answers synchronously in `init`; a real service loads in
/// `.task` (holding launch readiness), keeping the previous page on screen while the next one arrives, and
/// reloads when the interface language changes (InnerTube `hl`).
struct QTBrowseLoader<Page: Sendable, Content: View>: View {
    let key: String
    let debounce: Duration?
    let load: @Sendable (any QTBrowseService) async throws -> Page?
    @ViewBuilder let content: (Page?) -> Content
    @State private var page: Page?
    @State private var loadedKey: String?

    init(key: String, debounce: Duration? = nil, mock: (QTMockBrowseService) -> Page?,
         load: @escaping @Sendable (any QTBrowseService) async throws -> Page?, @ViewBuilder content: @escaping (Page?) -> Content) {
        self.key = key
        self.debounce = debounce
        self.load = load
        self.content = content
        if let m = QTBrowse.service as? QTMockBrowseService {
            _page = State(initialValue: mock(m))
            _loadedKey = State(initialValue: key + "|" + QTLoc.locale.identifier)
        }
    }

    var body: some View {
        let id = key + "|" + QTLoc.locale.identifier
        content(page)
            .task(id: id) {
                guard loadedKey != id else { return }
                let token = QTReadiness.shared.hold("browse \(key)")
                defer { QTReadiness.shared.release(token) }
                if let debounce, loadedKey != nil { try? await Task.sleep(for: debounce) }
                guard !Task.isCancelled else { return }
                let service = QTBrowse.service
                let next = try? await load(service)
                guard !Task.isCancelled else { return }
                page = next
                loadedKey = id
            }
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
    @Environment(QTAppModel.self) private var model

    var body: some View {
        QTBrowseLoader(key: "explore", mock: { $0.exploreNow() }, load: { try await $0.explore() }) { content in
            QTBrowseScroll(destination: .section(.explore), identifier: "qt.explore") {
                QTPageTitle(text: QTLoc.tr("Explore"))
                if let content, !content.isEmpty {
                    sections(content)
                } else if content != nil {
                    ContentUnavailableView(QTLoc.tr("Explore"), systemImage: QTIcon.compass.systemName)
                        .frame(maxWidth: .infinity, minHeight: 360)
                }
            }
        }
    }

    @ViewBuilder
    private func sections(_ c: QTExploreContent) -> some View {
        let source = QTQueueSource(kind: .playlist, title: .localized("Explore"))
        if !c.newReleases.isEmpty {
            QTHomeShelf(shelf: QTShelf(id: "explore.new", title: .verbatim(QTLoc.tr("New releases", table: .main)),
                                       style: .cards, items: c.newReleases), source: source)
                .padding(.top, 28)
        }
        if !c.topSongs.isEmpty {
            QTHomeShelf(shelf: QTShelf(id: "explore.charts", title: .verbatim(QTLoc.tr("Charts", table: .main)),
                                       style: .quickPicks, items: c.topSongs.map { .track($0) }),
                        source: QTQueueSource(kind: .playlist, title: .verbatim(QTLoc.tr("Charts", table: .main))), ranked: true)
                .padding(.top, QTTheme.Spacing.shelfSpacing)
        }
        if !c.videos.isEmpty {
            QTHomeShelf(shelf: QTShelf(id: "explore.videos", title: .verbatim(QTLoc.tr("New music videos", table: .main)),
                                       style: .videos, items: c.videos.map { .video($0) }), source: source)
                .padding(.top, QTTheme.Spacing.shelfSpacing)
        }
        if !c.moodGroups.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                QTSectionTitle(text: QTLoc.tr("Moods & genres", table: .main))
                ForEach(Array(c.moodGroups.enumerated()), id: \.element.id) { gi, group in
                    Text(verbatim: group.title)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.top, gi == 0 ? 0 : 14)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 280), spacing: 12)], alignment: .leading, spacing: 12) {
                        ForEach(Array(group.moods.enumerated()), id: \.element.id) { i, chip in
                            QTMoodTile(chip: chip, color: tileColor(gi * 7 + i))
                        }
                    }
                }
            }
            .padding(.horizontal, QTTheme.Spacing.gutter)
            .padding(.top, QTTheme.Spacing.shelfSpacing)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("qt.explore.moods")
        }
    }

    /// Tile stripes cycle through the library's artwork colours (YouTube Music sends its own per chip).
    private func tileColor(_ i: Int) -> QTArtworkPalette? {
        let palettes = model.catalog.tracks.compactMap(\.palette)
        return palettes.isEmpty ? nil : palettes[i % palettes.count]
    }
}

/// Mood / genre tile: a quiet filled rounded rectangle with a colour stripe (YouTube Music's chip colour).
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
        QTBrowseLoader(key: "mood:\(chip.id)", mock: { $0.moodNow(chip) }, load: { [chip] in try await $0.mood(chip) }) { shelves in
            QTBrowseScroll(destination: .mood(chip), identifier: "qt.mood") {
                QTPageTitle(text: chip.title.resolved)
                ForEach(shelves ?? []) { shelf in
                    QTHomeShelf(shelf: shelf, source: QTQueueSource(kind: .radio, id: chip.id, title: chip.title))
                        .padding(.top, shelf.id == shelves?.first?.id ? 28 : QTTheme.Spacing.shelfSpacing)
                }
            }
        }
    }
}

// MARK: - Artist

struct QTArtistPageView: View {
    let name: String

    var body: some View {
        QTBrowseLoader(key: "artist:\(name)", mock: { $0.artistNow(name) }, load: { [name] in try await $0.artist(name) }) { page in
            if let page {
                QTArtistPageContent(page: page)
            } else {
                ContentUnavailableView(name, systemImage: QTIcon.mic.systemName)
            }
        }
    }
}

struct QTArtistPageContent: View {
    let page: QTArtistPage
    @Environment(QTAppModel.self) private var model

    var body: some View {
        let artist = page.artist
        let source = QTQueueSource(kind: .artist, id: artist.id, title: .verbatim(artist.name))
        QTBrowseScroll(destination: .artist(artist.name), identifier: "qt.artist") {
            header(artist, source: source)
            if !page.songs.isEmpty {
                QTHomeShelf(shelf: QTShelf(id: "artist.songs", title: .verbatim(QTLoc.tr("Songs")), style: .quickPicks,
                                           items: page.songs.prefix(9).map { .track($0) }), source: source)
                    .padding(.top, QTTheme.Spacing.shelfSpacing)
            }
            shelf("artist.albums", QTLoc.tr("Albums"), .cards, page.albums.map { .album($0) }, source)
            shelf("artist.singles", QTLoc.tr("Singles", table: .main), .cards, page.singles.map { .album($0) }, source)
            shelf("artist.videos", QTLoc.tr("Videos", table: .main), .videos, page.videos.map { .video($0) }, source)
            shelf("artist.playlists", QTLoc.tr("Playlists"), .cards, page.playlists.map { .playlist($0) }, source)
            shelf("artist.related", QTLoc.tr("Fans also like", table: .main), .cards, page.relatedArtists.map { .artist($0) }, source)
        }
    }

    @ViewBuilder
    private func shelf(_ id: String, _ title: String, _ style: QTShelfStyle, _ items: [QTShelfItem], _ source: QTQueueSource) -> some View {
        if !items.isEmpty {
            QTHomeShelf(shelf: QTShelf(id: id, title: .verbatim(title), style: style, items: items), source: source)
                .padding(.top, QTTheme.Spacing.shelfSpacing)
        }
    }

    /// Round portrait, name, audience / song count, Play + Shuffle (draft §7 "Shuffle works everywhere").
    private func header(_ artist: QTArtist, source: QTQueueSource) -> some View {
        let songs = page.songs
        let playable = songs.filter(\.availability.isPlayable)
        return HStack(alignment: .center, spacing: 28) {
            QTArtworkView(artist.artwork, cornerRadius: 0, placeholder: .mic)
                .frame(width: 168, height: 168)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(QTLoc.tr("Artist", table: .main))
                    .font(QTTheme.Typography.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: artist.name)
                    .font(QTTheme.Typography.pageTitle)
                    .lineLimit(1)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: page.audience ?? QTLoc.tr("%lld songs", table: .main, songs.count))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                HStack(spacing: 10) {
                    Button {
                        QTTrackActions.play(playable, at: 0, source: source)
                    } label: {
                        Label(QTLoc.tr("Play"), systemImage: QTIcon.play.systemName)
                    }
                    .qtGlassButton(.primary)
                    .accessibilityIdentifier("qt.artist.play")
                    Button {
                        QTTrackActions.shuffle(playable, source: source)
                    } label: {
                        Label(QTLoc.tr("Shuffle"), systemImage: QTIcon.shuffle.systemName)
                    }
                    .qtGlassButton(.secondary)
                    .accessibilityIdentifier("qt.artist.shuffle")
                }
                .controlSize(.large)
                .disabled(playable.isEmpty)
                .padding(.top, 18)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, QTTheme.Spacing.gutter)
        .padding(.top, 36)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("qt.artist.header")
    }
}
