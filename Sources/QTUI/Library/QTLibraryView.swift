import QTCore
import SwiftUI

// Owner: builder "window". A track-list page (Liked Songs, playlists, albums, artists, Songs): big header
// (art, title, "{n} songs · {m} min", Play / Shuffle / More, ⌘F filter) over a native NSTableView that collapses
// into a pinned compact bar with the column headings beneath it. Layout from the prototype's window.jsx /
// styles.css v2 (`.lib-head`, `.lib-compact`, `.table`, `.t-row`).

public struct QTLibraryView: View {
    private let collection: QTTrackCollection
    private let destination: QTDestination?
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    static let headerHeight: CGFloat = 36 + QTTheme.Metrics.playlistTile + 28

    public init(collection: QTTrackCollection, destination: QTDestination? = nil) {
        self.collection = collection
        self.destination = destination
    }

    /// Scaffold-compatible entry point.
    @MainActor
    public init(playlist: QTPlaylist) {
        let catalog = QTAppModel.shared.catalog
        self.init(collection: playlist.kind == .liked ? .liked(catalog) : .playlist(playlist, catalog: catalog))
    }

    public var body: some View {
        let navigator = QTNavigator.shared
        let state = navigator.listState(for: collection.id)
        let rows = QTTrackListing.rows(collection.tracks, filter: state.filter, sort: state.sort)
        let q = state.filter.trimmingCharacters(in: .whitespaces)
        let hosted = QTHostedEnvironment(model: model, player: player)
        QTTrackTable(
            collection: collection,
            rows: rows,
            state: state,
            destination: destination,
            header: AnyView(hosted.wrap(QTLibraryHeader(collection: collection, rows: rows, state: state))),
            headerHeight: Self.headerHeight,
            compact: AnyView(hosted.wrap(QTLibraryCompactBar(collection: collection, rows: rows, state: state))),
            playingID: player.nowPlaying?.videoId,
            isPlaying: player.isPlaying,
            likedIDs: player.likedTrackIDs,
            tint: QTTrackTableTint(palette: model.palette, increaseContrast: contrast == .increased),
            reduceMotion: reduceMotion,
            emptyText: q.isEmpty ? nil : QTLoc.tr("No songs match “%@”.", q),
            showsAlphabet: true
        )
        .accessibilityIdentifier("qt.library")
    }
}

/// SwiftUI content hosted inside AppKit (NSHostingView) needs the app's environment re-injected.
@MainActor
struct QTHostedEnvironment {
    let model: QTAppModel
    let player: QTPlayerModel

    func wrap<V: View>(_ view: V) -> some View {
        view
            .environment(model)
            .environment(player)
            .qtArtworkTint(model.palette)
    }
}

// MARK: - Header

/// Collection artwork: the playlist's own art, or the Liked Songs tile (artwork accent gradient + heart).
struct QTCollectionTile: View {
    let collection: QTTrackCollection
    let size: CGFloat
    var cornerRadius: CGFloat = QTTheme.Radius.artworkLarge
    var showsShadow = true
    @Environment(\.qtAccent) private var accent

    var body: some View {
        Group {
            if collection.kind == .liked || collection.artwork.isEmpty {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(LinearGradient(colors: [accent, accent.mix(with: .black, by: 0.55)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        collection.placeholderIcon.image
                            .font(.system(size: size * 0.38, weight: .regular))
                            .foregroundStyle(.white)
                            .symbolRenderingMode(.hierarchical)
                    }
            } else {
                QTArtworkView(collection.artwork, cornerRadius: cornerRadius, placeholder: collection.placeholderIcon)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(showsShadow ? 0.25 : 0), radius: 12, y: 8)
        .accessibilityHidden(true)
    }
}

struct QTLibraryHeader: View {
    let collection: QTTrackCollection
    let rows: [QTTrack]
    let state: QTTrackListState
    @Environment(QTAppModel.self) private var model

    var body: some View {
        @Bindable var state = state
        let navigator = QTNavigator.shared
        HStack(alignment: .bottom, spacing: 28) {
            QTCollectionTile(collection: collection, size: QTTheme.Metrics.playlistTile)
                .padding(.trailing, 0)
            VStack(alignment: .leading, spacing: 0) {
                Text(collection.kindLabel)
                    .font(QTTheme.Typography.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: collection.title)
                    .font(QTTheme.Typography.pageTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                    .help(collection.title)
                Text(QTFormat.songCountAndMinutes(count: collection.tracks.count, seconds: collection.totalDuration))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                QTLibraryActions(collection: collection, rows: rows)
                    .padding(.top, 18)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            QTFilterField(text: $state.filter, prompt: collection.filterPrompt,
                          focusRequest: navigator.filterFocusRequest, isFocusTarget: !state.isHeaderPinned,
                          identifier: "qt.library.filter", onMoveDown: { state.focusTable?() })
                .frame(width: 220)
                .frame(height: QTTheme.Metrics.playlistTile, alignment: .center)
        }
        .padding(.horizontal, QTTheme.Spacing.gutter)
        .padding(.top, 36)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("qt.library.header")
    }
}

/// Play / Shuffle / More for a collection (big header).
struct QTLibraryActions: View {
    let collection: QTTrackCollection
    let rows: [QTTrack]
    @Environment(QTAppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let playable = rows.filter(\.availability.isPlayable)
        HStack(spacing: 10) {
            Button {
                if let i = rows.firstIndex(where: \.availability.isPlayable) {
                    QTTrackActions.play(rows, at: i, source: collection.queueSource)
                }
            } label: {
                Label(QTLoc.tr("Play"), systemImage: QTIcon.play.systemName)
            }
            .buttonStyle(.borderedProminent)
            // White text needs the deeper variant of the artwork accent in both appearances.
            .tint(QTTheme.Colors.accent(model.palette, scheme: .light, increaseContrast: contrast == .increased))
            .buttonBorderShape(.capsule)
            .accessibilityIdentifier("qt.library.play")

            Button {
                QTTrackActions.shuffle(rows, source: collection.queueSource)
            } label: {
                Label(QTLoc.tr("Shuffle"), systemImage: QTIcon.shuffle.systemName)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .accessibilityIdentifier("qt.library.shuffle")

            Menu {
                Button(QTLoc.tr("Play Next")) { QTTrackActions.playNext(playable) }
                Button(QTLoc.tr("Add to Queue")) { QTTrackActions.addToQueue(playable) }
                Divider()
                Button(QTLoc.tr("Copy Link")) { QTTrackActions.copyLinks(playable) }
            } label: {
                Label(QTLoc.tr("More"), systemImage: QTIcon.more.systemName)
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(QTLoc.tr("More"))
            .buttonBorderShape(.capsule)
            .accessibilityIdentifier("qt.library.more")
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .disabled(playable.isEmpty)
    }
}

/// Pinned compact bar: tiny tile, title, Play, Shuffle, filter (`.lib-compact`).
struct QTLibraryCompactBar: View {
    let collection: QTTrackCollection
    let rows: [QTTrack]
    let state: QTTrackListState

    var body: some View {
        @Bindable var state = state
        let navigator = QTNavigator.shared
        HStack(spacing: 10) {
            QTCollectionTile(collection: collection, size: 30, cornerRadius: QTTheme.Radius.control, showsShadow: false)
            Text(verbatim: collection.title)
                .font(.headline)
                .lineLimit(1)
                .padding(.trailing, 6)
            Button {
                if let i = rows.firstIndex(where: \.availability.isPlayable) {
                    QTTrackActions.play(rows, at: i, source: collection.queueSource)
                }
            } label: {
                Label(QTLoc.tr("Play"), systemImage: QTIcon.play.systemName)
            }
            .help(QTLoc.tr("Play"))
            .accessibilityIdentifier("qt.library.compact.play")
            Button {
                QTTrackActions.shuffle(rows, source: collection.queueSource)
            } label: {
                Label(QTLoc.tr("Shuffle"), systemImage: QTIcon.shuffle.systemName)
            }
            .help(QTLoc.tr("Shuffle"))
            .accessibilityIdentifier("qt.library.compact.shuffle")
            Spacer(minLength: 16)
            QTFilterField(text: $state.filter, prompt: collection.filterPrompt,
                          focusRequest: navigator.filterFocusRequest, isFocusTarget: state.isHeaderPinned,
                          identifier: "qt.library.compact.filter", onMoveDown: { state.focusTable?() })
                .frame(width: 200)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .imageScale(.large)
        .padding(.horizontal, QTTheme.Spacing.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("qt.library.compactBar")
    }
}
