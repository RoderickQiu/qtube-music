import AppKit
import QTCore
import QTPlayback
import SwiftUI

// Owner: builder "player". The docked inspector: two tabs (Now Playing with lyrics, Queue), no transport.
// Its own header (like Xcode's inspector tab bar) carries the tab picker and the hide button (⌥⌘N), so the
// panel closes from where it is. Blurred artwork backdrop.

public struct QTNowPlayingPanel: View {
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        ZStack {
            QTPanelBackdrop(track: player.nowPlaying)
            Group {
                switch model.panelTab {
                case .nowPlaying: QTNowPlayingTab()
                case .queue: QTQueueList(style: .panel)
                }
            }
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The panel's header lives in the window toolbar over the inspector (Now Playing | Queue · hide), so the
        // art-tinted backdrop runs up under the title bar and there is no extra header row or hard divider.
        .toolbar {
            // SwiftUI keeps a collapsed inspector's toolbar items; they leave with the panel.
            if model.surface != .stage, model.isPanelShown {
                QTPanelToolbar()
            }
        }
        .animation(QTTheme.Motion.animation(QTTheme.Motion.ui, reduceMotion: reduceMotion), value: model.panelTab)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("qt.player.panel")
    }
}

// MARK: - Header

/// Now Playing | Queue (segmented) · hide button, as toolbar items of the inspector's section of the window toolbar
/// (like Xcode's inspector tabs), so the panel still closes from its own header.
struct QTPanelToolbar: ToolbarContent {
    @Environment(QTAppModel.self) private var model

    var body: some ToolbarContent {
        @Bindable var model = model
        ToolbarItem(placement: .automatic) {
            Picker(selection: $model.panelTab) {
                Text(QTLoc.tr("Now Playing")).tag(QTPanelTab.nowPlaying)
                Text(QTLoc.tr("Queue")).tag(QTPanelTab.queue)
            } label: {
                Text(QTLoc.tr("Now Playing"))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("qt.player.panel.tabs")
        }
        // Tabs at the panel's leading edge, hide at its trailing edge (prototype).
        if #available(macOS 26, *) {
            ToolbarSpacer(.flexible)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                withAnimation(QTTheme.Motion.animation(QTTheme.Motion.spring, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) {
                    model.isPanelShown = false
                }
            } label: {
                Label(QTLoc.tr("Hide Panel", table: .desktop), systemImage: QTIcon.sidebar.systemName)
            }
            .help("\(QTLoc.tr("Hide Panel", table: .desktop))  ⌥⌘N")
            .accessibilityIdentifier("qt.player.panel.hide")
        }
    }
}

// MARK: - Backdrop

/// The current artwork, heavily blurred under a system material: the panel takes the song's colour without
/// becoming a picture. Solid window background with Reduce Transparency.
struct QTPanelBackdrop: View {
    let track: QTTrack?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if reduceTransparency {
                QTTheme.Colors.windowBackground
            } else {
                QTArtworkView(track: track, cornerRadius: 0)
                    .scaleEffect(1.3)
                    .blur(radius: 60)
                    .saturation(1.15)
                    .opacity(scheme == .dark ? 0.42 : 0.32)
                    .overlay(.regularMaterial)
                    .id(track?.videoId)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Now Playing tab

struct QTNowPlayingTab: View {
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            QTNowPlayingHero()
            QTLyricsView(document: player.lyrics, time: player.timeline, style: .panel) { player.seek(to: $0) }
                // Lyrics step away while an ad plays (as on the Stage) and come back where they were: a dimmed,
                // frozen column read as disabled.
                .opacity(player.ad == nil ? 1 : 0)
                .allowsHitTesting(player.ad == nil)
                .accessibilityHidden(player.ad != nil)
                .animation(QTTheme.Motion.animation(QTTheme.Motion.ui, reduceMotion: reduceMotion), value: player.ad == nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("qt.player.panel.lyrics")
        }
    }
}

/// Compact header: artwork (or the MV still in Video mode, or the ad state) · title / artist · album ·
/// Song|Video and lyrics options.
struct QTNowPlayingHero: View {
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsVideo: Bool { model.isVideoMode && player.nowPlaying?.hasVideo == true }

    var body: some View {
        let track = player.nowPlaying
        let side = QTTheme.Metrics.panelHeroArtwork
        HStack(spacing: 18) {
            // Video mode widens the tile towards 16:9 only as far as the panel's current width allows: the text
            // column keeps its room and the panel never grows on Song⇄Video (the video is cropped to fill).
            artwork(track)
                .frame(minWidth: side, idealWidth: showsVideo ? 156 : side, maxWidth: showsVideo ? 156 : side)
                .frame(height: side)
                .layoutPriority(1)
                .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(track?.title ?? "")
                    .font(QTTheme.Typography.panelTitle)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("qt.player.panel.title")
                Text(subtitle(track))
                    .font(QTTheme.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 3)
                // Song|Video and lyrics options only with something playing.
                if track != nil {
                    // The options icon right after the switch, as one row of controls under the title (pushed to the
                    // panel's edge it floated apart from everything).
                    HStack(spacing: QTTheme.Spacing.s) {
                        QTSongVideoToggle(isVideo: Binding(get: { model.isVideoMode }, set: { model.isVideoMode = $0 }),
                                          hasVideo: track?.hasVideo ?? false)
                            // Secondary to the Now Playing | Queue switch above it: a small segmented control under the title.
                            .controlSize(.small)
                        QTLyricsOptionsButton()
                    }
                    .padding(.top, 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 28)
        .padding(.trailing, 18)
        .padding(.vertical, 20)
        .frame(minHeight: QTTheme.Metrics.panelHeroHeight)
        .animation(QTTheme.Motion.animation(QTTheme.Motion.spring, reduceMotion: reduceMotion), value: showsVideo)
    }

    private func subtitle(_ track: QTTrack?) -> String {
        track?.qtNowPlayingSubtitle(separator: " · ") ?? ""
    }

    @ViewBuilder
    private func artwork(_ track: QTTrack?) -> some View {
        if player.ad != nil {
            QTAdArtworkView(track: track, cornerRadius: QTTheme.Radius.artwork)
        } else {
            Button {
                model.surface = .stage
            } label: {
                // M5: in Video mode the real music video replaces the artwork. The slot stays put across Song⇄Video
                // so the video can crossfade in over the MV still (first frame) and out to the artwork (switch).
                QTLiveVideoView(kind: .panel, cornerRadius: QTTheme.Radius.artwork) {
                    QTArtworkView(track: track, video: showsVideo, cornerRadius: QTTheme.Radius.artwork)
                        .id(showsVideo)
                        .transition(.opacity)
                }
            }
            .buttonStyle(.plain)
            .help("\(QTLoc.tr("Open Stage"))  ⇧⌘F")
            .accessibilityLabel(QTLoc.tr("Open Stage"))
            .accessibilityIdentifier("qt.player.panel.artwork")
        }
    }
}
