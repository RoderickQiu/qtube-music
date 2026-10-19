import QTCore
import QTPlayback
import SwiftUI

// Owner: builder "player". Stub layout from the prototype (.playerbar): now playing | transport + scrubber | tools.

/// The always-visible bottom bar. Owns playback controls (the panel never duplicates them).
public struct QTPlayerBar: View {
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player

    public init() {}

    public var body: some View {
        HStack(spacing: QTTheme.Spacing.l) {
            nowPlaying
                .frame(width: QTTheme.Metrics.playerBarSideWidth, alignment: .leading)
            VStack(spacing: 6) {
                QTTransportControls(style: .playerBar)
                QTScrubber()
                    .frame(maxWidth: QTTheme.Metrics.scrubberMaxWidth)
            }
            .frame(maxWidth: .infinity)
            tools
                .frame(width: QTTheme.Metrics.playerBarSideWidth, alignment: .trailing)
        }
        .padding(.horizontal, 28)
        .frame(height: QTTheme.Metrics.playerBarHeight)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityIdentifier("qt.playerBar")
    }

    private var nowPlaying: some View {
        HStack(spacing: 14) {
            QTArtworkView(track: player.nowPlaying, cornerRadius: QTTheme.Radius.control)
                .frame(width: QTTheme.Metrics.playerBarArtwork, height: QTTheme.Metrics.playerBarArtwork)
                .onTapGesture { model.surface = .stage }
                .help("\(QTLoc.tr("Open Stage"))  ⇧⌘F")
            VStack(alignment: .leading, spacing: 2) {
                if player.ad != nil {
                    Text(QTLoc.tr("Advertisement")).font(QTTheme.Typography.rowTitle).lineLimit(1)
                    Text(QTLoc.tr("Then: %@", player.nowPlaying?.title ?? "")).font(QTTheme.Typography.secondary)
                        .foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(player.nowPlaying?.title ?? "").font(QTTheme.Typography.rowTitle).lineLimit(1)
                    Text(player.nowPlaying?.artistLine ?? "").font(QTTheme.Typography.secondary)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let track = player.nowPlaying {
                Button {
                    player.toggleLike(track)
                } label: {
                    Label(QTLoc.tr("Like"), systemImage: player.isLiked(track) ? QTIcon.heartFill.systemName : QTIcon.heart.systemName)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(player.isLiked(track) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.borderless)
                .help("\(QTLoc.tr("Like"))  ⌘L")
            }
        }
    }

    private var tools: some View {
        @Bindable var model = model
        return HStack(spacing: 10) {
            Button { model.panelTab = .nowPlaying; model.isPanelShown = true } label: {
                Label(QTLoc.tr("Lyrics"), systemImage: QTIcon.lyrics.systemName)
            }
            .help(QTLoc.tr("Lyrics"))
            Button { model.panelTab = .queue; model.isPanelShown = true } label: {
                Label(QTLoc.tr("Queue"), systemImage: QTIcon.list.systemName)
            }
            .help(QTLoc.tr("Queue"))
            Button {} label: { Label(QTLoc.tr("AirPlay"), systemImage: QTIcon.airplay.systemName) }
                .help(QTLoc.tr("AirPlay"))
            Image(systemName: QTIcon.volume.systemName)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: Binding(get: { player.state.volume }, set: { player.setVolume($0) }), in: 0...1)
                .controlSize(.small)
                .frame(width: 84)
                .accessibilityLabel(QTLoc.tr("Volume"))
            Button { model.surface = model.surface == .mini ? .window : .mini } label: {
                Label(QTLoc.tr("Mini player"), systemImage: QTIcon.mini.systemName)
            }
            .help("\(QTLoc.tr("Mini player"))  ⇧⌘M")
            Button { model.surface = .stage } label: {
                Label(QTLoc.tr("Stage"), systemImage: QTIcon.expand.systemName)
            }
            .help("\(QTLoc.tr("Stage"))  ⇧⌘F")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }
}

/// Elapsed · progress · remaining. Disabled (and shows the ad countdown) while an ad plays.
public struct QTScrubber: View {
    private let overArt: Bool
    @Environment(QTPlayerModel.self) private var player
    @State private var scrubbing: Double?

    public init(overArt: Bool = false) {
        self.overArt = overArt
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: player.timeline.rate > 0 || player.ad != nil ? 0.25 : 3600)) { _ in
            let duration = max(player.duration, 1)
            let now = scrubbing ?? player.timeline.currentTime
            HStack(spacing: QTTheme.Spacing.xs) {
                Text(player.ad != nil ? QTLoc.tr("Ad") : QTFormat.duration(now))
                    .frame(width: 44, alignment: .leading)
                Slider(value: Binding(get: { player.ad?.progress ?? (now / duration) },
                                      set: { scrubbing = $0 * duration }),
                       in: 0...1) { editing in
                    if !editing, let s = scrubbing { player.seek(to: s); scrubbing = nil }
                }
                .controlSize(.mini)
                .disabled(player.ad != nil)
                .accessibilityLabel(QTLoc.tr("Time"))
                Text(player.ad.map { QTFormat.duration($0.remaining.rounded(.up)) } ?? QTFormat.remaining(duration - now))
                    .frame(width: 44, alignment: .trailing)
            }
            .font(QTTheme.Typography.caption)
            .monospacedDigit()
            .foregroundStyle(overArt ? QTTheme.Colors.onArtSecondary : QTTheme.Colors.tertiaryLabel)
        }
    }
}
