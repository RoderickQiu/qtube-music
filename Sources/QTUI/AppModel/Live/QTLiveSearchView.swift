import QTCore
import QTInnerTube
import SwiftUI

// Owner: builder "data-live". Toolbar search (⌘K) against YouTube Music, grouped like Music.app: the top result
// beside the first songs, then Videos, Albums, Artists and Playlists rows. Music only (the parser drops podcasts,
// episodes and profiles). Typing is debounced; the previous results stay up until the new ones arrive.

struct QTLiveSearchView: View {
    let query: String
    @State private var shownQuery: String?

    var body: some View {
        let store = QTLiveCatalogStore.shared
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let phase = store.searchPhases[q] ?? .loading
        let display: String? = phase == .loaded ? q : shownQuery
        Group {
            if let display, let results = store.searchResults[display] {
                QTLiveSearchResults(query: display, results: results, isUpdating: display != q)
            } else if case .failed(let f) = phase {
                QTLiveFailureView(failure: f) { Task { await store.search(q, force: true) } }
            } else {
                QTLiveSkeleton(layout: .search, title: QTLoc.tr("Results for “%@”", table: .main, q))
            }
        }
        .task(id: q) {
            // Debounce keystrokes; cached queries come back at once.
            if store.searchResults[q] == nil { try? await Task.sleep(for: .milliseconds(320)) }
            guard !Task.isCancelled else { return }
            await store.search(q)
            if store.searchPhases[q] == .loaded { shownQuery = q }
        }
        .accessibilityIdentifier("qt.live.search")
    }
}

struct QTLiveSearchResults: View {
    let query: String
    let results: QTSearchResults
    let isUpdating: Bool

    var body: some View {
        if results.topResult == nil && results.items.isEmpty {
            ContentUnavailableView(QTLoc.tr("No results for “%@”", table: .main, query), systemImage: QTIcon.search.systemName)
                .accessibilityIdentifier("qt.live.search.empty")
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(QTLoc.tr("Results for “%@”", table: .main, query))
                            .font(QTTheme.Typography.pageTitle)
                            .lineLimit(1)
                        if isUpdating {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .padding(.horizontal, QTTheme.Spacing.gutter)
                    .padding(.top, 32)
                    topRow.padding(.top, 24)
                    ForEach(shelves) { shelf in
                        QTHomeShelf(shelf: shelf)
                            .padding(.top, QTTheme.Spacing.shelfSpacing)
                    }
                }
                .padding(.bottom, 48)
            }
            .accessibilityIdentifier("qt.live.search.results")
        }
    }

    private var songs: [QTTrack] {
        var list = results.songs
        if case .track(let t)? = results.topResult { list.removeAll { $0.videoId == t.videoId } }
        return Array(list.prefix(5))
    }

    @ViewBuilder private var topRow: some View {
        HStack(alignment: .top, spacing: 36) {
            if let top = results.topResult {
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle(QTLoc.tr("Top Result", table: .live))
                    QTLiveTopResultCard(item: top)
                }
                .frame(width: 260, alignment: .leading)
            }
            if !songs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle(QTLoc.tr("Songs"))
                    VStack(spacing: 2) {
                        ForEach(songs) { QTQuickPickRow(track: $0, tracks: songs) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, QTTheme.Spacing.gutter)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(verbatim: s)
            .font(QTTheme.Typography.shelfTitle)
            .accessibilityAddTraits(.isHeader)
    }

    /// Videos, Albums, Artists, Playlists — each a row of cards.
    private var shelves: [QTShelf] {
        var out: [QTShelf] = []
        let topID = results.topResult?.id
        func add(_ id: String, _ title: String, _ style: QTShelfStyle, _ items: [QTShelfItem]) {
            let items = items.filter { $0.id != topID }
            guard !items.isEmpty else { return }
            out.append(QTShelf(id: "search:\(id)", title: .verbatim(title), style: style, items: items))
        }
        add("videos", QTLoc.tr("Music videos"), .videos, results.videos.map { .video($0) })
        add("albums", QTLoc.tr("Albums"), .cards, results.albums.map { .album($0) })
        add("artists", QTLoc.tr("Artists"), .cards, results.artists.map { .artist($0) })
        add("playlists", QTLoc.tr("Playlists"), .cards, results.playlists.map { .playlist($0) })
        return out
    }
}

/// The highlighted first hit: big artwork (round for artists), title, kind, and Play for things that play.
struct QTLiveTopResultCard: View {
    let item: QTShelfItem
    @Environment(QTPlayerModel.self) private var player
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            QTLiveCardArtwork(isHovered: isHovered, circular: isArtist, showsPlay: isHovered && playable, onPlay: play) {
                QTArtworkView(artwork, cornerRadius: isArtist ? 110 : QTTheme.Radius.artworkLarge, placeholder: placeholder)
            }
            .frame(width: 220, height: isVideo ? 124 : 220)
            .padding(.bottom, 10)
            Text(verbatim: title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
            Text(verbatim: subtitle)
                .font(QTTheme.Typography.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering in
            isHovered = hovering
            if hovering { QTLiveCatalogStore.shared.prefetch(item) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .accessibilityIdentifier("qt.live.search.top")
    }

    private var isArtist: Bool { if case .artist = item { true } else { false } }
    private var isVideo: Bool { if case .video = item { true } else { false } }
    private var playable: Bool {
        switch item {
        case .track(let t), .video(let t): t.availability.isPlayable
        case .album, .playlist: true
        case .artist: false
        }
    }

    private var artwork: [QTArtworkImage] {
        switch item {
        case .track(let t): t.artwork
        case .video(let t): t.videoArtwork.isEmpty ? t.artwork : t.videoArtwork
        case .album(let a): a.artwork
        case .playlist(let p): p.artwork
        case .artist(let a): a.artwork
        }
    }

    private var placeholder: QTIcon {
        switch item {
        case .track: .note
        case .video: .video
        case .album: .album
        case .playlist: .playlist
        case .artist: .mic
        }
    }

    private var title: String {
        switch item {
        case .track(let t), .video(let t): t.title
        case .album(let a): a.title
        case .playlist(let p): p.title.resolved
        case .artist(let a): a.name
        }
    }

    private var subtitle: String {
        switch item {
        case .track(let t): "\(QTLoc.tr("Song")) · \(t.artistLine)"
        case .video(let t): "\(QTLoc.tr("Video")) · \(t.artistLine)"
        case .album(let a): QTLiveAlbumCard.subtitle(a)
        case .playlist(let p): [QTLoc.tr("Playlist"), p.owner].compactMap { $0 }.joined(separator: " · ")
        case .artist: QTLoc.tr("Artist", table: .main)
        }
    }

    private func play() {
        switch item {
        case .track(let t):
            if player.nowPlaying?.videoId == t.videoId { player.togglePlayPause() } else {
                QTTrackActions.play([t], at: 0, source: QTQueueSource(kind: .search, title: .verbatim(t.title)))
            }
        case .video(let t):
            QTTrackActions.play([t], at: 0, source: QTQueueSource(kind: .search, title: .verbatim(t.title)), video: true)
        case .album(let a): QTLiveActions.playAlbum(a.id, shuffled: false)
        case .playlist(let p): QTLiveActions.playPlaylist(p.id, title: p.title.resolved, shuffled: false)
        case .artist: break
        }
    }

    private func open() {
        switch item {
        case .track, .video: play()
        case .album(let a): QTNavigator.shared.go(.album(a.id))
        case .playlist(let p): QTNavigator.shared.go(.section(.playlist(p.id)))
        case .artist(let a): QTNavigator.shared.go(.artist(a.id))
        }
    }
}
