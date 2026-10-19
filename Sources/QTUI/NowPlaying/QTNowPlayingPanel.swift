import QTCore
import SwiftUI

// Owner: builder "player". The docked inspector: two tabs (Now Playing with lyrics, Queue), no transport.
// Closes from its own toolbar button (⌥⌘N); blurred artwork backdrop.

public struct QTNowPlayingPanel: View {
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player

    public init() {}

    public var body: some View {
        @Bindable var model = model
        ZStack {
            QTArtworkView(track: player.nowPlaying, cornerRadius: 0)
                .blur(radius: 60)
                .saturation(1.4)
                .opacity(0.45)
                .overlay(.regularMaterial)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            switch model.panelTab {
            case .nowPlaying: nowPlaying
            case .queue: QTQueueList(style: .panel)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(selection: $model.panelTab) {
                    Text(QTLoc.tr("Now Playing")).tag(QTPanelTab.nowPlaying)
                    Text(QTLoc.tr("Queue")).tag(QTPanelTab.queue)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        .accessibilityIdentifier("qt.nowPlayingPanel")
    }

    private var nowPlaying: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                QTArtworkView(track: player.nowPlaying, video: model.isVideoMode)
                    .frame(width: model.isVideoMode && player.nowPlaying?.hasVideo == true ? 156 : QTTheme.Metrics.panelHeroArtwork,
                           height: QTTheme.Metrics.panelHeroArtwork)
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                    .onTapGesture { model.surface = .stage }
                    .help("\(QTLoc.tr("Open Stage"))  ⇧⌘F")
                VStack(alignment: .leading, spacing: 4) {
                    Text(player.nowPlaying?.title ?? "")
                        .font(QTTheme.Typography.panelTitle)
                        .lineLimit(2)
                    Text(player.nowPlaying?.artistLine ?? "")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack {
                        QTSongVideoToggle(isVideo: Binding(get: { model.isVideoMode }, set: { model.isVideoMode = $0 }),
                                          hasVideo: player.nowPlaying?.hasVideo ?? false)
                            .controlSize(.small)
                        Spacer()
                        QTLyricsOptionsButton()
                    }
                    .padding(.top, 6)
                }
            }
            .padding(.leading, 28)
            .padding(.trailing, 22)
            .frame(height: QTTheme.Metrics.panelHeroHeight)
            Divider()
            if player.ad == nil {
                QTLyricsView(document: player.lyrics, time: player.timeline, style: .panel) { player.seek(to: $0) }
            } else {
                Spacer()
            }
        }
    }
}
