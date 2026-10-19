import QTCore
import SwiftUI

// Owner: builder "window". Results for the toolbar search field (⌘K): matching playlists as quiet capsules, then
// songs in the same native table. Matching folds diacritics and Traditional/Simplified Chinese (QTTextFolding),
// so "ha phom", "Hạ Phỏm" and 出牌 all find the same song.

struct QTSearchResultsView: View {
    let query: String
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let catalog = model.catalog
        let collection = QTTrackCollection.search(query, catalog: catalog)
        let playlists = ([catalog.liked] + catalog.playlists).filter { QTTextFolding.matches(query: query, in: $0.title.resolved) }
        if collection.tracks.isEmpty && playlists.isEmpty {
            ContentUnavailableView(QTLoc.tr("No results for “%@”", table: .main, query), systemImage: QTIcon.search.systemName)
                .accessibilityIdentifier("qt.search.empty")
        } else {
            let state = QTNavigator.shared.listState(for: "search")
            let hosted = QTHostedEnvironment(model: model, player: player)
            QTTrackTable(
                collection: collection,
                rows: QTTrackListing.rows(collection.tracks, filter: "", sort: state.sort),
                state: state,
                destination: nil,
                header: AnyView(hosted.wrap(QTSearchHeader(query: query, songCount: collection.tracks.count, playlists: playlists))),
                headerHeight: playlists.isEmpty ? 96 : 140,
                compact: nil,
                playingID: player.nowPlaying?.videoId,
                isPlaying: player.isPlaying,
                likedIDs: player.likedTrackIDs,
                tint: QTTrackTableTint(palette: model.palette, increaseContrast: contrast == .increased),
                reduceMotion: reduceMotion,
                emptyText: nil,
                showsAlphabet: false
            )
            .accessibilityIdentifier("qt.search.results")
        }
    }
}

struct QTSearchHeader: View {
    let query: String
    let songCount: Int
    let playlists: [QTPlaylist]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(QTLoc.tr("Results for “%@”", table: .main, query))
                    .font(QTTheme.Typography.pageTitle)
                    .lineLimit(1)
                Text(QTLoc.tr("%lld songs", table: .main, songCount))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if !playlists.isEmpty {
                HStack(spacing: QTTheme.Spacing.xs) {
                    ForEach(playlists) { p in
                        Button {
                            QTNavigator.shared.go(.section(p.kind == .liked ? .liked : .playlist(p.id)))
                        } label: {
                            Label(p.title.resolved, systemImage: (p.kind == .liked ? QTIcon.heart : QTIcon.playlist).systemName)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, QTTheme.Spacing.gutter)
        .padding(.top, 32)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .accessibilityIdentifier("qt.search.header")
    }
}
