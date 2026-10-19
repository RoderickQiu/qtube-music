import QTCore
import QTInnerTube
import SwiftUI

// Owner: builder "window". Results for the toolbar search field (⌘K), grouped like Music.app: Top result next to
// Songs, then Music videos, Albums, Artists, Playlists — music only (YouTube Music's parser drops podcasts,
// episodes and profiles). One view for the demo catalog and the live library (`QTBrowse.service`): the demo
// answers on every keystroke; YouTube Music is debounced and keeps the previous results on screen with a small
// spinner. Demo matching folds diacritics and Traditional/Simplified Chinese ("ha phom", "Hạ Phỏm", 出牌).

struct QTSearchResultsView: View {
    let query: String

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        QTBrowseLoader(.search(q), debounce: .milliseconds(250), extract: \.search) {
            QTLiveSkeleton(layout: .search, title: QTLoc.tr("Results for “%@”", table: .main, q))
        } content: { results, isUpdating in
            if results.topResult == nil && results.items.isEmpty && !isUpdating {
                ContentUnavailableView(QTLoc.tr("No results for “%@”", table: .main, q), systemImage: QTIcon.search.systemName)
                    .accessibilityIdentifier("qt.search.empty")
            } else {
                QTSearchResultsContent(query: q, results: results, isUpdating: isUpdating)
            }
        }
    }
}

struct QTSearchResultsContent: View {
    let query: String
    let results: QTSearchResults
    var isUpdating = false

    private var source: QTQueueSource { QTQueueSource(kind: .search, title: .verbatim(query)) }
    /// The "Music videos" row: the artist's own and official videos first, compilations last (`rankedVideos`); a
    /// videos-filtered search adds up to 20 more, so keep the row to a calm length.
    static let maxVideos = 12

    var body: some View {
        let topID = results.topResult?.id
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(QTLoc.tr("Results for “%@”", table: .main, query))
                        .font(QTTheme.Typography.pageTitle)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("qt.search.header")
                    if isUpdating {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.top, 40)
                .padding(.horizontal, QTTheme.Spacing.gutter)
                topRow
                    .padding(.top, 28)
                shelf("search.videos", QTLoc.tr("Music videos"), .videos, results.rankedVideos.prefix(Self.maxVideos).map { .video($0) }, except: topID)
                shelf("search.albums", QTLoc.tr("Albums"), .cards, results.albums.map { .album($0) }, except: topID)
                shelf("search.artists", QTLoc.tr("Artists"), .cards, results.artists.map { .artist($0) }, except: topID)
                shelf("search.playlists", QTLoc.tr("Playlists"), .cards, results.playlists.map { .playlist($0) }, except: topID)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 48)
        }
        .qtSoftScrollEdges()
        .accessibilityIdentifier("qt.search.results")
    }

    private var topSong: QTTrack? { if case .track(let t) = results.topResult { t } else { nil } }

    /// Songs in result order; a song that is the top result leads the list, so the list plays on from it.
    private var songs: [QTTrack] {
        let top = topSong
        return (top.map { [$0] } ?? []) + results.songs.filter { $0.videoId != top?.videoId }
    }

    /// Top result card beside the first songs (Music.app / YouTube Music layout). No hard widths: the card is at
    /// most 320 pt and gives way when the column is narrow — a fixed width here became the content column's minimum,
    /// and with the panel open in a smaller window AppKit's split view looped on update-constraints until it threw
    /// (the 2026-10-19 crash family, see docs/architecture.md › Native UI rules).
    @ViewBuilder
    private var topRow: some View {
        let list = songs
        HStack(alignment: .top, spacing: 28) {
            if let top = results.topResult {
                VStack(alignment: .leading, spacing: 14) {
                    QTSectionTitle(text: QTLoc.tr("Top result", table: .main))
                    QTSearchTopResult(item: top, songs: list, source: source)
                }
                .frame(minWidth: 0, idealWidth: 320, maxWidth: 320, alignment: .leading)
                .layoutPriority(1)
            }
            // A lone song that is already the top result isn't repeated beside it.
            if list.count > (topSong == nil ? 0 : 1) {
                VStack(alignment: .leading, spacing: 14) {
                    QTSectionTitle(text: QTLoc.tr("Songs"))
                    VStack(spacing: 2) {
                        ForEach(list.prefix(4)) { t in
                            QTQuickPickRow(track: t, tracks: list, source: source)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("qt.search.songs")
            }
        }
        .padding(.horizontal, QTTheme.Spacing.gutter)
    }

    @ViewBuilder
    private func shelf(_ id: String, _ title: String, _ style: QTShelfStyle, _ items: [QTShelfItem], except topID: String?) -> some View {
        let items = items.filter { $0.id != topID }
        if !items.isEmpty {
            QTHomeShelf(shelf: QTShelf(id: id, title: .verbatim(title), style: style, items: items), source: source)
                .padding(.top, QTTheme.Spacing.shelfSpacing)
        }
    }
}

/// The highlighted result: big artwork, name, kind · artist, Play, and Go to Album/Artist. Double-click opens it.
struct QTSearchTopResult: View {
    let item: QTShelfItem
    let songs: [QTTrack]
    let source: QTQueueSource
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: QTTheme.Radius.floating, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            artwork
                .frame(width: 104, height: isVideo ? 58.5 : 104)
                .frame(height: 104, alignment: .center)
                .clipShape(isArtist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: QTTheme.Radius.artwork, style: .continuous)))
                .shadow(color: .black.opacity(0.22), radius: 10, y: 6)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .font(.title2.bold())
                .lineLimit(1)
                .padding(.top, 16)
            Text(verbatim: subtitle)
                .font(QTTheme.Typography.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 2)
            HStack(spacing: 10) {
                Button(action: play) {
                    Label(QTLoc.tr("Play"), systemImage: QTIcon.play.systemName)
                }
                .qtGlassButton(.primary)
                .disabled(!isPlayable)
                .accessibilityIdentifier("qt.search.top.play")
                if isArtist || isAlbum {
                    Button(action: open) {
                        Label(QTLoc.tr(isArtist ? "Go to Artist · %@" : "Go to Album · %@", title), systemImage: QTIcon.chevR.systemName)
                            .labelStyle(.iconOnly)
                    }
                    .qtGlassButton(.secondary, iconOnly: true)
                    .help(QTLoc.tr(isArtist ? "Go to Artist · %@" : "Go to Album · %@", title))
                    .accessibilityIdentifier("qt.search.top.open")
                }
            }
            .controlSize(.regular)
            .padding(.top, 14)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(isHovered ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.fill.quaternary)))
        .contentShape(shape)
        .onHover { hovering in
            isHovered = hovering
            if hovering { QTLiveCatalogStore.shared.prefetch(item) }
        }
        .onTapGesture(count: 2) { open() }
        .contextMenu { if case .track(let t) = item { QTTrackContextMenu(track: t) } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("qt.search.top")
    }

    private var isArtist: Bool { if case .artist = item { true } else { false } }
    private var isAlbum: Bool { if case .album = item { true } else { false } }
    private var isVideo: Bool { if case .video = item { true } else { false } }

    private var isPlayable: Bool {
        switch item {
        case .track(let t), .video(let t): t.availability.isPlayable
        case .album, .artist, .playlist: true
        }
    }

    @ViewBuilder private var artwork: some View {
        switch item {
        case .track(let t): QTArtworkView(track: t, cornerRadius: 0)
        case .video(let t): QTArtworkView(track: t, video: true, cornerRadius: 0, contentMode: .fill)
        case .album(let a): QTArtworkView(a.artwork, cornerRadius: 0, placeholder: .album)
        case .artist(let a): QTArtworkView(a.artwork, cornerRadius: 0, placeholder: .mic)
        case .playlist(let p): QTArtworkView(p.artwork, cornerRadius: 0, placeholder: .playlist)
        }
    }

    private var title: String {
        switch item {
        case .track(let t), .video(let t): t.title
        case .album(let a): a.title
        case .artist(let a): a.name
        case .playlist(let p): p.title.resolved
        }
    }

    private var subtitle: String {
        switch item {
        case .track(let t): QTLoc.tr("%@ · %@", table: .main, QTLoc.tr("Song"), t.artistLine)
        case .video(let t): QTLoc.tr("%@ · %@", table: .main, QTLoc.tr("Video"), t.artistLine)
        case .album(let a): QTHomeCard.albumSubtitle(a)
        case .artist: QTLoc.tr("Artist", table: .main)
        case .playlist(let p): [QTLoc.tr("Playlist"), p.owner].compactMap { $0 }.joined(separator: " · ")
        }
    }

    private func play() {
        switch item {
        case .track:
            QTTrackActions.play(songs, at: songs.firstIndex(where: \.availability.isPlayable) ?? 0, source: source)
        case .video(let t):
            QTTrackActions.play([t], at: 0, source: source, video: true)
        case .album(let a): QTBrowseActions.playAlbum(a)
        case .artist(let a): QTBrowseActions.playArtist(a)
        case .playlist(let p): QTBrowseActions.playPlaylist(p)
        }
    }

    private func open() {
        switch item {
        case .track, .video: play()
        case .album(let a): QTNavigator.shared.go(.album(a.id))
        case .artist(let a): QTNavigator.shared.go(.artist(a.id))
        case .playlist(let p): QTNavigator.shared.go(.section(p.kind == .liked ? .liked : .playlist(p.id)))
        }
    }
}
