import QTCore
import QTPlayback
import SwiftUI

// Owner: builder "player". Signature is the shared contract (docked panel Queue tab + Stage queue drawer).

public enum QTQueueListStyle: Hashable, Sendable {
    /// Docked panel, system colours.
    case panel
    /// Stage drawer over artwork (dark glass): forces the dark appearance and a clear list background.
    case stageDrawer
}

/// Now Playing · Up Next (you added: drag to reorder, ⌫ to remove, Clear with Undo) · Autoplay from the source
/// (dimmed, with an off switch), plus "Save Queue as Playlist". A native `List` with Finder-style selection:
/// double-click or ↩ plays, right-click for the context menu.
public struct QTQueueList: View {
    private let style: QTQueueListStyle
    @Environment(QTPlayerModel.self) private var player
    @Environment(QTAppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection = Set<UUID>()

    public init(style: QTQueueListStyle) {
        self.style = style
    }

    private var queue: QTQueue { player.queue }

    public var body: some View {
        // Section titles are plain rows rather than List section headers: pinned headers get an opaque bar
        // that fights the panel's frosted artwork backdrop.
        let list = List(selection: $selection) {
            if let now = queue.nowPlaying {
                QTQueueSectionHeader(title: QTLoc.tr("Now Playing"))
                    .qtQueueHeaderRow(first: true)
                QTQueueRow(track: now.track, kind: .nowPlaying, isPlaying: player.isPlaying)
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
            }

            QTQueueSectionHeader(title: QTLoc.tr("Up Next")) {
                if !queue.upNext.isEmpty {
                    Button(QTLoc.tr("Clear")) { clearUpNext() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tint)
                        .help(QTLoc.tr("Clear Up Next", table: .player))
                        .accessibilityIdentifier("qt.player.queue.clear")
                }
            }
            .qtQueueHeaderRow(first: queue.nowPlaying == nil)
            if queue.upNext.isEmpty {
                QTQueueEmptyRow()
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
            } else {
                ForEach(queue.upNext) { item in
                    QTQueueRow(track: item.track, kind: .upNext)
                        .tag(item.id)
                        .listRowSeparator(.hidden)
                }
                .onMove { player.moveInQueue(fromOffsets: $0, toOffset: $1, in: .upNext) }
                .onDelete { offsets in player.removeFromQueue(Set(offsets.map { queue.upNext[$0].id })) }
            }

            if !queue.autoplay.isEmpty {
                QTQueueSectionHeader(title: autoplayTitle) {
                    Toggle(QTLoc.tr("Autoplay"), isOn: Binding(
                        get: { queue.isAutoplayEnabled },
                        set: { on in
                            withAnimation(QTTheme.Motion.animation(QTTheme.Motion.ui, reduceMotion: reduceMotion)) {
                                player.setAutoplayEnabled(on)
                            }
                        }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .help(QTLoc.tr("Autoplay"))
                        .accessibilityIdentifier("qt.player.queue.autoplaySwitch")
                }
                .qtQueueHeaderRow(first: false)
                if queue.isAutoplayEnabled {
                    ForEach(queue.autoplay.prefix(50)) { item in
                        QTQueueRow(track: item.track, kind: .autoplay)
                            .tag(item.id)
                            .listRowSeparator(.hidden)
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 22)
        .contextMenu(forSelectionType: UUID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            if let id = ids.first, let item = item(id) { Task { await player.jump(to: item) } }
        }
        .onDeleteCommand { remove(selection) }
        .onChange(of: queue) { selection = selection.filter { item($0) != nil } }
        .accessibilityIdentifier(style == .panel ? "qt.player.queue.panel" : "qt.player.queue.stageDrawer")

        switch style {
        case .panel:
            // Rows scroll under the footer's bar material, like Music's queue. The docked panel runs under the
            // window's floating player bar (an inspector column gets no safe-area inset from it), so the footer —
            // and with it the last rows and the scroller — stops above the bar.
            list.safeAreaInset(edge: .bottom, spacing: 0) {
                footer
                    .padding(.bottom, QTTheme.Metrics.playerBarHeight + QTTheme.Metrics.playerBarInset)
                    .background(.bar)
            }
        case .stageDrawer:
            // The footer sits on the drawer's glass with no fill of its own, so it goes below the list rather
            // than over it (rows must not show through).
            VStack(spacing: 0) {
                list
                footer
            }
            .environment(\.colorScheme, .dark)
        }
    }

    // MARK: Pieces

    private var autoplayTitle: String {
        guard let source = queue.autoplaySource else { return QTLoc.tr("Autoplay") }
        return QTLoc.tr("Autoplay · from “%@”", table: .player, source.title.resolved)
    }

    private var footer: some View {
        let tracks = ([queue.nowPlaying].compactMap { $0 } + queue.upNext
            + (queue.isAutoplayEnabled ? queue.autoplay : [])).map(\.track)
        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: QTTheme.Spacing.s) {
                Button {
                    saveAsPlaylist(tracks)
                } label: {
                    Label(QTLoc.tr("Save Queue as Playlist", table: .player), systemImage: "text.badge.plus")
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
                .layoutPriority(1)
                .disabled(tracks.isEmpty)
                .accessibilityIdentifier("qt.player.queue.save")
                Spacer(minLength: 0)
                Text(QTFormat.songCountAndMinutes(count: tracks.count, seconds: tracks.reduce(0) { $0 + $1.duration }))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .font(QTTheme.Typography.secondary)
            .padding(.horizontal, 20)
            .frame(height: 40)
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<UUID>) -> some View {
        let items = ids.compactMap(item)
        if items.count == 1, let first = items.first {
            Button(QTLoc.tr("Play")) { Task { await player.jump(to: first) } }
            if queue.upNext.first?.id != first.id {
                Button(QTLoc.tr("Play Next")) { player.moveInQueue(itemID: first.id, to: .upNext, at: 0) }
            }
            Divider()
        }
        if !items.isEmpty {
            Button(QTLoc.tr("Remove from Queue", table: .player)) { remove(ids) }
        }
        if !queue.upNext.isEmpty {
            Divider()
            Button(QTLoc.tr("Clear Up Next", table: .player)) { clearUpNext() }
        }
    }

    private func item(_ id: UUID) -> QTQueueItem? {
        queue.upNext.first { $0.id == id } ?? queue.autoplay.first { $0.id == id }
    }

    private func remove(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        withAnimation(QTTheme.Motion.animation(QTTheme.Motion.ui, reduceMotion: reduceMotion)) {
            player.removeFromQueue(ids)
        }
        selection.subtract(ids)
    }

    private func clearUpNext() {
        let token = withAnimation(QTTheme.Motion.animation(QTTheme.Motion.ui, reduceMotion: reduceMotion)) {
            player.clearUpNext()
        }
        model.showToast(QTLoc.tr("Cleared Up Next")) { [player] in player.undoClearUpNext(token) }
    }

    /// New Playlist with the queue's songs, named after today ("Queue · Oct 20"); it goes to the account when
    /// syncing, else stays on this Mac (the sheet says which).
    private func saveAsPlaylist(_ tracks: [QTTrack]) {
        let name = QTLoc.tr("Queue · %@", table: .player,
                            Date.now.formatted(Date.FormatStyle(locale: QTLoc.locale).month(.abbreviated).day()))
        QTPlaylistActions.newPlaylist(with: tracks, suggestedTitle: name, model: model)
    }
}

// MARK: - Rows

enum QTQueueRowKind {
    case nowPlaying, upNext, autoplay
}

struct QTQueueRow: View {
    let track: QTTrack
    let kind: QTQueueRowKind
    var isPlaying = false

    var body: some View {
        HStack(spacing: QTTheme.Spacing.s) {
            QTArtworkView(track: track, cornerRadius: 4)
                .frame(width: QTTheme.Metrics.rowArtwork, height: QTTheme.Metrics.rowArtwork)
                .overlay {
                    if kind == .nowPlaying {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.black.opacity(0.35))
                            QTNowPlayingGlyph(isPlaying: isPlaying, pointSize: 13, weight: .semibold, tint: .white)
                        }
                        .accessibilityHidden(true)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(QTTheme.Typography.rowTitle)
                    .foregroundStyle(kind == .nowPlaying ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                Text(track.artistLine)
                    .font(QTTheme.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            Text(QTFormat.duration(track.duration))
                .font(QTTheme.Typography.secondary)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .opacity(kind == .autoplay ? 0.62 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Up Next with nothing in it: a quiet slot shaped like a row. No explanatory copy.
struct QTQueueEmptyRow: View {
    var body: some View {
        HStack(spacing: QTTheme.Spacing.s) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(QTTheme.Colors.fill)
                .frame(width: QTTheme.Metrics.rowArtwork, height: QTTheme.Metrics.rowArtwork)
                .overlay {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
            Text(QTLoc.tr("Nothing queued"))
                .font(QTTheme.Typography.body)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("qt.player.queue.empty")
    }
}

private extension View {
    /// A section title row: not selectable, no separator, extra space above (prototype `.q-head` margins).
    func qtQueueHeaderRow(first: Bool) -> some View {
        self.padding(.top, first ? 4 : 14)
            .selectionDisabled()
            .listRowSeparator(.hidden)
            .moveDisabled(true)
            .deleteDisabled(true)
    }
}

struct QTQueueSectionHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: QTTheme.Spacing.xs) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            trailing
        }
        .font(QTTheme.Typography.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(minHeight: 22)
        .accessibilityAddTraits(.isHeader)
    }
}
