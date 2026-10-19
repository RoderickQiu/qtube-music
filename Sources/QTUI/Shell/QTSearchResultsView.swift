import QTCore
import QTInnerTube
import SwiftUI

// Owner: builder "window". Results for the toolbar search field (⌘K), grouped like Music.app: Top result next to
// Songs, then Music videos, Albums, Artists, Playlists — music only. Results update on every keystroke (the mock
// answers synchronously; a network service is debounced and keeps the previous results on screen). Matching
// folds diacritics and Traditional/Simplified Chinese, so "ha phom", "Hạ Phỏm" and 出牌 find the same song.

struct QTSearchResultsView: View {
    let query: String

    var body: some View {
        QTBrowseLoader(key: "search:\(query)", debounce: .milliseconds(180), mock: { $0.searchNow(query) },
                       load: { [query] in try await $0.search(query) }) { results in
            if let results {
                if results.topResult == nil && results.items.isEmpty {
                    ContentUnavailableView(QTLoc.tr("No results for “%@”", table: .main, query), systemImage: QTIcon.search.systemName)
                        .accessibilityIdentifier("qt.search.empty")
                } else {
                    QTSearchResultsContent(query: query, results: results)
                }
            }
        }
    }
}

struct QTSearchResultsContent: View {
    let query: String
    let results: QTSearchResults
    @Environment(QTAppModel.self) private var model

    private var source: QTQueueSource { QTQueueSource(kind: .search, title: .verbatim(query)) }

    var body: some View {
        let songs = results.songs
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                Text(QTLoc.tr("Results for “%@”", table: .main, query))
                    .font(QTTheme.Typography.pageTitle)
                    .lineLimit(1)
                    .padding(.top, 40)
                    .padding(.horizontal, QTTheme.Spacing.gutter)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("qt.search.header")
                topRow(songs: songs)
                    .padding(.top, 28)
                shelf("search.videos", QTLoc.tr("Music videos"), .videos, results.videos.map { .video($0) })
                shelf("search.albums", QTLoc.tr("Albums"), .cards, results.albums.map { .album($0) })
                shelf("search.artists", QTLoc.tr("Artists"), .cards, results.artists.map { .artist($0) })
                shelf("search.playlists", QTLoc.tr("Playlists"), .cards, results.playlists.map { .playlist($0) })
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 48)
        }
        .accessibilityIdentifier("qt.search.results")
    }

    /// Top result card beside the first songs (Music.app / YouTube Music layout).
    @ViewBuilder
    private func topRow(songs: [QTTrack]) -> some View {
        // When the top result is a song it leads the Songs list too, so the list plays in order from it.
        let topSong: QTTrack? = if case .track(let t) = results.topResult { t } else { nil }
        let list = (topSong.map { [$0] } ?? []) + songs
        HStack(alignment: .top, spacing: 28) {
            if let top = results.topResult {
                VStack(alignment: .leading, spacing: 14) {
                    QTSectionTitle(text: QTLoc.tr("Top result", table: .main))
                    QTSearchTopResult(item: top, songs: list, source: source)
                }
                .frame(width: 320, alignment: .leading)
            }
            // A lone song that is already the top result isn't repeated beside it.
            if !songs.isEmpty {
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
    private func shelf(_ id: String, _ title: String, _ style: QTShelfStyle, _ items: [QTShelfItem]) -> some View {
        if !items.isEmpty {
            QTHomeShelf(shelf: QTShelf(id: id, title: .verbatim(title), style: style, items: items), source: source)
                .padding(.top, QTTheme.Spacing.shelfSpacing)
        }
    }
}

/// The highlighted result: big artwork, name, kind · artist, and one primary action.
struct QTSearchTopResult: View {
    let item: QTShelfItem
    let songs: [QTTrack]
    let source: QTQueueSource
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: QTTheme.Radius.floating, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            artwork
                .frame(width: 104, height: 104)
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
                .accessibilityIdentifier("qt.search.top.play")
                if isArtist || isAlbum {
                    Button(action: open) {
                        Label(QTLoc.tr(isArtist ? "Go to Artist · %@" : "Go to Album · %@", title), systemImage: QTIcon.chevR.systemName)
                            .labelStyle(.iconOnly)
                    }
                    .qtGlassButton(.secondary, iconOnly: true)
                    .help(QTLoc.tr(isArtist ? "Go to Artist · %@" : "Go to Album · %@", title))
                }
            }
            .controlSize(.regular)
            .padding(.top, 14)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(isHovered ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.fill.quaternary)))
        .contentShape(shape)
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { open() }
        .contextMenu { if case .track(let t) = item { QTTrackContextMenu(track: t) } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("qt.search.top")
    }

    private var isArtist: Bool { if case .artist = item { true } else { false } }
    private var isAlbum: Bool { if case .album = item { true } else { false } }

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
        case .playlist: QTLoc.tr("Playlist")
        }
    }

    private func tracks() -> [QTTrack] {
        switch item {
        case .track: songs
        case .video(let t): [t]
        case .album(let a): a.tracks ?? model.catalog.tracks.filter { $0.album?.title == a.title }
        case .artist(let a): model.catalog.tracks.filter { $0.artists.contains { $0.name == a.name } }
        case .playlist(let p): p.tracks ?? []
        }
    }

    private func play() {
        let ts = tracks().filter(\.availability.isPlayable)
        guard !ts.isEmpty else { return }
        if case .video = item { QTTrackActions.play(ts, at: 0, source: source, video: true); return }
        QTTrackActions.play(ts, at: 0, source: source)
    }

    private func open() {
        switch item {
        case .track, .video: play()
        case .album(let a): QTNavigator.shared.go(.album(a.title))
        case .artist(let a): QTNavigator.shared.go(.artist(a.name))
        case .playlist(let p): QTNavigator.shared.go(.section(p.kind == .liked ? .liked : .playlist(p.id)))
        }
    }
}
