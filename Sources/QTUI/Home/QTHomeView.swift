import QTCore
import SwiftUI

// Owner: builder "window". Home (prototype home.jsx + styles.css `.home`): greeting + mood chips, Listen again,
// Quick picks (3 columns), Music videos, your playlists. Built only from the user's library and real shelves.
// (Kaset ADR-0038: AppKit beats SwiftUI for *big* shelves — these are lazy and small; revisit with real data.)

public struct QTHomeView: View {
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player
    @State private var position = ScrollPosition(edge: .top)
    @State private var selectedMood: String?
    @State private var didRestore = false

    public init() {}

    public var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                header
                ForEach(model.catalog.home.shelves) { shelf in
                    QTHomeShelf(shelf: shelf)
                        .padding(.top, QTTheme.Spacing.shelfSpacing)
                }
            }
            .padding(.bottom, 48)
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
        .accessibilityIdentifier("qt.home")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(Self.greeting(at: .now))
                .font(QTTheme.Typography.pageTitle)
                .accessibilityAddTraits(.isHeader)
            QTChipFlow(spacing: 10) {
                ForEach(model.catalog.home.moods) { mood in
                    Toggle(mood.title.resolved, isOn: Binding(
                        get: { selectedMood == mood.id },
                        set: { selectedMood = $0 ? mood.id : nil }
                    ))
                    .toggleStyle(QTChipToggleStyle())
                    .accessibilityIdentifier("qt.home.mood.\(mood.id)")
                }
            }
            .controlSize(.large)
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
    @State private var width: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(shelf.title.resolved)
                    .font(QTTheme.Typography.shelfTitle)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if shelf.style != .quickPicks && !fitsWithoutPaging { pager }
            }
            .padding(.horizontal, QTTheme.Spacing.gutter)
            switch shelf.style {
            case .quickPicks: QTQuickPicks(tracks: tracks, source: source, ranked: ranked)
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
        return HStack(spacing: 2) {
            Button {
                page(to: max(0, index - perPage), ids: ids)
            } label: {
                Label(QTLoc.tr("Scroll left"), systemImage: QTIcon.chevL.systemName)
            }
            .disabled(index == 0)
            Button {
                page(to: min(ids.count - 1, index + perPage), ids: ids)
            } label: {
                Label(QTLoc.tr("Scroll right"), systemImage: QTIcon.chevR.systemName)
            }
            .disabled(index + perPage >= ids.count)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .imageScale(.large)
        .controlSize(.large)
    }

    private func page(to i: Int, ids: [String]) {
        guard ids.indices.contains(i) else { return }
        withAnimation(QTTheme.Motion.animation(QTTheme.Motion.ui, reduceMotion: reduceMotion)) { firstVisible = ids[i] }
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
                        playIcon: isCurrent && player.isPlaying ? .pause : .play, showsPlay: isHovered || isCurrent)
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
            QTNavigator.shared.go(.album(a.title))
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
            QTNavigator.shared.go(.artist(a.name))
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
    private func artwork<A: View>(_ art: A, width: CGFloat, height: CGFloat, playIcon: QTIcon, showsPlay: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: QTTheme.Radius.artwork, style: .continuous)
        let anim = QTTheme.Motion.animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.4), reduceMotion: reduceMotion)
        return art
            .frame(width: width, height: height)
            .scaleEffect(isHovered && !reduceMotion ? 1.04 : 1)
            .animation(anim, value: isHovered)
            .clipShape(shape)
            .background(shape.fill(.black.opacity(0.001)).shadow(color: .black.opacity(isHovered ? 0.28 : 0.18), radius: isHovered ? 12 : 8, y: 4))
            .overlay(alignment: .bottomTrailing) {
                QTCardPlayBadge(icon: playIcon)
                    .padding(10)
                    .opacity(showsPlay ? 1 : 0)
                    .offset(y: showsPlay || reduceMotion ? 0 : 4)
                    .animation(QTTheme.Motion.animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.18), reduceMotion: reduceMotion), value: showsPlay)
            }
    }
}

/// Round accent play/pause badge on hovered cards (`.card-play`).
struct QTCardPlayBadge: View {
    let icon: QTIcon
    @Environment(QTAppModel.self) private var model
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        icon.image
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(Circle().fill(QTTheme.Colors.accent(model.palette, scheme: .light, increaseContrast: contrast == .increased)))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 6)
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

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 180), spacing: 20, alignment: .leading), count: columns),
                  alignment: .leading, spacing: 4) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                QTQuickPickRow(track: t, tracks: tracks, source: source, rank: ranked ? i + 1 : nil)
            }
        }
        .padding(.horizontal, QTTheme.Spacing.gutter)
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
                            .overlay { (isCurrent && player.isPlaying ? QTIcon.pause : QTIcon.play).image.foregroundStyle(.white) }
                            .opacity(isHovered ? 1 : 0)
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
            .opacity(isHovered || liked ? 1 : 0)
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
        if let album = track.album?.title {
            Button(QTLoc.tr("Go to Album · %@", album)) { QTNavigator.shared.go(.album(album)) }
        }
        if let artist = track.artists.first?.name {
            Button(QTLoc.tr("Go to Artist · %@", artist)) { QTNavigator.shared.go(.artist(artist)) }
        }
        Divider()
        Menu(QTLoc.tr("Add to Playlist")) {
            ForEach(model.catalog.playlists) { p in
                Button(p.title.resolved) { QTTrackActions.add([track], to: p) }
            }
        }
        .disabled(!playable)
        Button(QTLoc.tr(player.isLiked(track) ? "Remove from Liked Songs" : "Like")) { QTTrackActions.toggleLike([track]) }
        Divider()
        Button(QTLoc.tr("Copy Link")) { QTTrackActions.copyLinks([track]) }
    }
}
