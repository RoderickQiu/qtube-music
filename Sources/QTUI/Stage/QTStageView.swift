import QTCore
import SwiftUI

// Owner: builder "stage". Stub: blurred-art background, standard layout, quiet top bar, transport.
// To build: 3 layouts × 5 backgrounds (blur, frosted cover + grain, vinyl with tonearm, video, Metal visualizer),
// auto-hiding chrome (3 s), Appearance popover, Queue drawer, ad state, true fullscreen, Esc to close.

public struct QTStageView: View {
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player

    public init() {}

    public var body: some View {
        @Bindable var model = model
        ZStack {
            QTTheme.Colors.stageBase(player.nowPlaying?.palette)
            QTArtworkView(track: player.nowPlaying, cornerRadius: 0)
                .scaleEffect(1.15)
                .blur(radius: 90)
                .saturation(1.5)
                .brightness(-0.2)
                .accessibilityHidden(true)

            HStack(spacing: 72) {
                if model.stageLayout != .lyricsOnly {
                    VStack(spacing: 22) {
                        QTArtworkView(track: player.nowPlaying, cornerRadius: QTTheme.Radius.artworkLarge)
                            .frame(width: QTTheme.Metrics.stageArtwork, height: QTTheme.Metrics.stageArtwork)
                            .shadow(color: .black.opacity(0.5), radius: 40, y: 30)
                    }
                    .frame(maxWidth: .infinity)
                }
                if model.stageLayout != .artOnly {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(player.nowPlaying?.title ?? "").font(QTTheme.Typography.stageTitle)
                        Text(player.nowPlaying?.artistLine ?? "").font(QTTheme.Typography.stageSubtitle)
                            .foregroundStyle(QTTheme.Colors.onArtSecondary)
                        QTLyricsView(document: player.lyrics, time: player.timeline,
                                     style: .stage(centered: model.stageLayout == .lyricsOnly)) { player.seek(to: $0) }
                    }
                    .foregroundStyle(QTTheme.Colors.onArt)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, QTTheme.Metrics.stageInset)
            .padding(.top, QTTheme.Metrics.stageInset)
            .padding(.bottom, 128)

            VStack {
                HStack(spacing: 6) {
                    Button { model.surface = .window } label: {
                        Label(QTLoc.tr("Close"), systemImage: QTIcon.chevD.systemName).labelStyle(.iconOnly)
                    }
                    .keyboardShortcut(.cancelAction)
                    .help("\(QTLoc.tr("Close"))  Esc")
                    Spacer()
                    QTLyricsOptionsButton(overArt: true)
                    QTSongVideoToggle(isVideo: $model.isVideoMode, hasVideo: player.nowPlaying?.hasVideo ?? false)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 17))
                .foregroundStyle(QTTheme.Colors.onArtSecondary)
                .padding(.horizontal, QTTheme.Spacing.l)
                .frame(height: QTTheme.Metrics.stageTopBarHeight)
                Spacer()
                VStack(spacing: 10) {
                    QTScrubber(overArt: true)
                    QTTransportControls(style: .stage)
                }
                .padding(.horizontal, QTTheme.Metrics.stageInset)
                .padding(.bottom, 28)
            }
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
        .accessibilityIdentifier("qt.stage")
    }
}
