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
    @Environment(\.colorSchemeContrast) private var contrast

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

    /// "12 songs · 50 min", or "2 of 12 songs" while a filter is narrowing the list.
    static func countLine(collection: QTTrackCollection, rows: [QTTrack], filter: String) -> String {
        if filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return QTFormat.songCountAndMinutes(count: collection.tracks.count, seconds: collection.totalDuration)
        }
        return QTLoc.tr("%lld of %lld songs", table: .main, rows.count, collection.tracks.count)
    }

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
                if collection.kind == .album, let ref = collection.tracks.first?.artists.first {
                    let artist = ref.name
                    // The album's artist opens the artist page (Music.app's linked subtitle).
                    Button {
                        QTNavigator.shared.go(.artist(ref))
                    } label: {
                        Text(verbatim: collection.tracks.first?.artistLine ?? artist)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 4)
                    .accessibilityIdentifier("qt.library.albumArtist")
                    .help(QTLoc.tr("Go to Artist · %@", artist))
                }
                Text(Self.countLine(collection: collection, rows: rows, filter: state.filter))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("qt.library.count")
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
