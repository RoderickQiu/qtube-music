import AppKit
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

    static let headerHeight: CGFloat = 36 + QTTheme.Metrics.playlistTile + 28

    /// Albums carry a linked artist line under the title.
    static func headerHeight(for collection: QTTrackCollection) -> CGFloat {
        headerHeight + (collection.kind == .album ? 30 : 0)
    }

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
            headerHeight: Self.headerHeight(for: collection),
            compact: AnyView(hosted.wrap(QTLibraryCompactBar(collection: collection, rows: rows, state: state))),
            playingID: player.nowPlaying?.videoId,
            isPlaying: player.isPlaying,
            likedIDs: player.likedTrackIDs,
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
            .qtArtworkAccent(model.palette)
    }
}

// MARK: - Header

/// Collection artwork: the playlist's own art, or a fixed tile. Liked Songs is a calm gradient of the *system*
/// accent with a white heart (like Music's Favourites tile) — it never changes with the playing song; a collection
/// without art gets a quiet system fill with its glyph.
struct QTCollectionTile: View {
    let collection: QTTrackCollection
    let size: CGFloat
    var cornerRadius: CGFloat = QTTheme.Radius.artworkLarge
    var showsShadow = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if collection.kind == .liked {
                let accent = QTTheme.Colors.systemAccent
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(LinearGradient(colors: [accent.mix(with: .white, by: scheme == .dark ? 0.12 : 0.22),
                                                  accent.mix(with: .black, by: scheme == .dark ? 0.30 : 0.16)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        collection.placeholderIcon.image
                            .font(.system(size: size * 0.38, weight: .regular))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    }
            } else if collection.artwork.isEmpty {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.fill.tertiary)
                    .overlay {
                        collection.placeholderIcon.image
                            .font(.system(size: size * 0.34, weight: .regular))
                            .foregroundStyle(.secondary)
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

    /// "12 songs · 50 min", or "2 of 12 songs" while a filter is narrowing the list. The count is
    /// max(rows, YouTube Music's own count) so it matches YouTube Music while pages are still streaming in, past the
    /// paging limit and with unavailable rows left out. While more pages are still streaming in the minutes are left
    /// out (they'd climb with every page); afterwards they're the playable songs' total.
    static func countLine(collection: QTTrackCollection, rows: [QTTrack], filter: String, reportedCount: Int? = nil,
                          isLoadingMore: Bool = false) -> String {
        let loaded = collection.tracks.count
        let total = max(loaded, reportedCount ?? 0)
        if filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if isLoadingMore && total > loaded { return QTLoc.tr("%lld songs", table: .main, total) }
            return QTFormat.songCountAndMinutes(count: total, seconds: collection.totalDuration)
        }
        return QTLoc.tr("%lld of %lld songs", table: .main, rows.count, total)
    }

    /// YouTube Music's count for this playlist (live library only; `LM` = Liked).
    static func reportedCount(for collection: QTTrackCollection) -> Int? {
        guard collection.kind == .liked || collection.kind == .playlist, let id = collection.playlistID else { return nil }
        let store = QTLiveCatalogStore.shared
        guard store.mode == .live else { return nil }
        return store.reportedTrackCounts[collection.kind == .liked ? "LM" : id]
    }

    static func isLoadingMore(_ collection: QTTrackCollection) -> Bool {
        collection.kind == .liked && QTLiveCatalogStore.shared.mode == .live && QTLiveCatalogStore.shared.isLoadingMoreLiked
    }

    var body: some View {
        // Narrower content columns (a smaller window with the panel open) step down instead of truncating the title
        // and the Play / Shuffle labels: a smaller tile and filter, then the filter moves onto the actions row.
        ViewThatFits(in: .horizontal) {
            row(tile: QTTheme.Metrics.playlistTile, filterWidth: 220)
            row(tile: 120, filterWidth: 170)
            row(tile: 96, filterWidth: nil)
        }
        .padding(.horizontal, QTTheme.Spacing.gutter)
        .padding(.top, 36)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("qt.library.header")
    }

    /// `filterWidth: nil` puts a flexible filter at the end of the actions row.
    private func row(tile: CGFloat, filterWidth: CGFloat?) -> some View {
        HStack(alignment: .bottom, spacing: 28) {
            QTCollectionTile(collection: collection, size: tile)
            VStack(alignment: .leading, spacing: 0) {
                Text(collection.kindLabel)
                    .font(QTTheme.Typography.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: collection.title)
                    .font(QTTheme.Typography.pageTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // A long title truncates rather than forcing the narrow layout (ViewThatFits measures ideals).
                    .frame(idealWidth: 160, alignment: .leading)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                    .help(collection.title)
                if collection.kind == .album, let ref = collection.tracks.first?.artists.first {
                    let artist = ref.name
                    // The album's artist opens the artist page (Music.app's linked subtitle).
                    Button {
                        QTNavigator.shared.go(.artist(ref))
                    } label: {
                        Text(verbatim: collection.tracks.first?.artistLine ?? artist)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.tint)
                            .lineLimit(1)
                            .frame(idealWidth: 160, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 4)
                    .accessibilityIdentifier("qt.library.albumArtist")
                    .help(QTLoc.tr("Go to Artist · %@", artist))
                }
                Text(Self.countLine(collection: collection, rows: rows, filter: state.filter, reportedCount: Self.reportedCount(for: collection),
                                    isLoadingMore: Self.isLoadingMore(collection)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("qt.library.count")
                HStack(spacing: 16) {
                    // The wide variants never truncate Play / Shuffle; the last one has no hard minimum at all (a
                    // content minimum feeds AppKit's split-view constraints into an update-constraints loop).
                    if filterWidth != nil {
                        QTLibraryActions(collection: collection, rows: rows).fixedSize()
                    } else {
                        QTLibraryActions(collection: collection, rows: rows).layoutPriority(1)
                        filter.frame(minWidth: 0, idealWidth: 160, maxWidth: 220)
                    }
                }
                .padding(.top, 18)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let filterWidth {
                filter
                    .frame(width: filterWidth)
                    .frame(height: tile, alignment: .center)
            }
        }
    }

    private var filter: some View {
        @Bindable var state = state
        return QTFilterField(text: $state.filter, prompt: collection.filterPrompt,
                             focusRequest: QTNavigator.shared.filterFocusRequest, isFocusTarget: !state.isHeaderPinned,
                             identifier: "qt.library.filter", onMoveDown: { state.focusTable?() })
    }
}

/// Play / Shuffle / More for a collection (big header).
struct QTLibraryActions: View {
    let collection: QTTrackCollection
    let rows: [QTTrack]
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
            .qtGlassButton(.primary)
            .help(QTLoc.tr("Play"))
            .accessibilityIdentifier("qt.library.play")

            Button {
                QTTrackActions.shuffle(rows, source: collection.queueSource)
            } label: {
                Label(QTLoc.tr("Shuffle"), systemImage: QTIcon.shuffle.systemName)
            }
            .qtGlassButton(.secondary)
            .help(QTLoc.tr("Shuffle"))
            .accessibilityIdentifier("qt.library.shuffle")

            // A real button that pops a native NSMenu under itself: a SwiftUI Menu restyled as a glass button
            // drew fine but had no Accessibility element, so VoiceOver / Voice Control couldn't reach these items.
            Button {
                anchor.popUp(Self.moreMenu(playable))
            } label: {
                Label {
                    Text(QTLoc.tr("More"))
                } icon: {
                    // Same height as Play / Shuffle beside it.
                    Image(systemName: QTIcon.more.systemName).frame(width: 20, height: 20)
                }
            }
            .qtGlassButton(.secondary, iconOnly: true)
            .background(QTMenuAnchorView(anchor: anchor))
            .help(QTLoc.tr("More"))
            .accessibilityLabel(QTLoc.tr("More"))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("qt.library.more")
        }
        .controlSize(.large)
        .disabled(playable.isEmpty)
    }

    @State private var anchor = QTMenuAnchor()

    static func moreMenu(_ playable: [QTTrack]) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(QTClosureMenuItem(QTLoc.tr("Play Next")) { QTTrackActions.playNext(playable) })
        menu.addItem(QTClosureMenuItem(QTLoc.tr("Add to Queue")) { QTTrackActions.addToQueue(playable) })
        menu.addItem(.separator())
        menu.addItem(QTClosureMenuItem(QTLoc.tr("Copy Link")) { QTTrackActions.copyLinks(playable) })
        return menu
    }
}

/// Where a SwiftUI button pops an AppKit menu: a zero-content view behind the button that knows its frame.
@MainActor
final class QTMenuAnchor {
    fileprivate weak var view: NSView?

    /// Pops `menu` just below the anchored control, left-aligned with it (like a pull-down button).
    func popUp(_ menu: NSMenu) {
        guard let view else { return }
        let y: CGFloat = view.isFlipped ? view.bounds.maxY + 4 : view.bounds.minY - 4
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.minX, y: y), in: view)
    }
}

struct QTMenuAnchorView: NSViewRepresentable {
    let anchor: QTMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let v = QTMenuAnchorNSView()
        anchor.view = v
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }
}

private final class QTMenuAnchorNSView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
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
