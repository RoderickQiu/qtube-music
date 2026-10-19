import QTCore
import SwiftUI

// Owner: builder "player". Signature is the shared contract (docked panel Queue tab + Stage queue drawer).

public enum QTQueueListStyle: Hashable, Sendable {
    /// Docked panel, system colours.
    case panel
    /// Stage drawer over artwork (dark glass).
    case stageDrawer
}

/// Now Playing · Up Next (user-added, reorderable, Clear with Undo) · Autoplay (dimmed). Reads `QTPlayerModel`.
public struct QTQueueList: View {
    private let style: QTQueueListStyle
    @Environment(QTPlayerModel.self) private var player
    @Environment(QTAppModel.self) private var model

    public init(style: QTQueueListStyle) {
        self.style = style
    }

    public var body: some View {
        List {
            if let now = player.queue.nowPlaying {
                Section(QTLoc.tr("Now Playing")) {
                    row(now.track)
                }
            }
            Section {
                if player.queue.upNext.isEmpty {
                    Text(QTLoc.tr("Nothing queued")).foregroundStyle(.tertiary)
                } else {
                    ForEach(player.queue.upNext) { item in
                        row(item.track).onTapGesture(count: 2) { Task { await player.jump(to: item) } }
                    }
                    .onMove { player.moveInQueue(fromOffsets: $0, toOffset: $1, in: .upNext) }
                }
            } header: {
                HStack {
                    Text(QTLoc.tr("Up Next"))
                    Spacer()
                    if !player.queue.upNext.isEmpty {
                        Button(QTLoc.tr("Clear")) {
                            let token = player.clearUpNext()
                            model.showToast(QTLoc.tr("Cleared Up Next")) { player.undoClearUpNext(token) }
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            Section(QTLoc.tr("Autoplay")) {
                ForEach(player.queue.autoplay.prefix(50)) { item in
                    row(item.track).opacity(0.62).onTapGesture(count: 2) { Task { await player.jump(to: item) } }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("qt.queueList")
    }

    private func row(_ track: QTTrack) -> some View {
        HStack(spacing: QTTheme.Spacing.s) {
            QTArtworkView(track: track, cornerRadius: 4)
                .frame(width: QTTheme.Metrics.rowArtwork, height: QTTheme.Metrics.rowArtwork)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(QTTheme.Typography.rowTitle).lineLimit(1)
                Text(track.artistLine).font(QTTheme.Typography.secondary).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
