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
            VStack(spacing: 0) {
                QTPanelHeader()
                Divider()
                Group {
                    switch model.panelTab {
                    case .nowPlaying: QTNowPlayingTab()
                    case .queue: QTQueueList(style: .panel)
                    }
                }
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(QTTheme.Motion.animation(QTTheme.Motion.ui, reduceMotion: reduceMotion), value: model.panelTab)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("qt.player.panel")
    }
}

// MARK: - Header

/// Now Playing | Queue (segmented) · hide button.
struct QTPanelHeader: View {
    @Environment(QTAppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model
        HStack(spacing: QTTheme.Spacing.s) {
            Picker(selection: $model.panelTab) {
                Text(QTLoc.tr("Now Playing")).tag(QTPanelTab.nowPlaying)
                Text(QTLoc.tr("Queue")).tag(QTPanelTab.queue)
            } label: {
                Text(QTLoc.tr("Now Playing"))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.regular)
            .fixedSize()
            .accessibilityIdentifier("qt.player.panel.tabs")
            Spacer(minLength: 0)
            Button {
                withAnimation(QTTheme.Motion.animation(QTTheme.Motion.spring, reduceMotion: reduceMotion)) {
                    model.isPanelShown = false
                }
            } label: {
                Label(QTLoc.tr("Hide panel"), systemImage: QTIcon.sidebar.systemName)
            }
            .qtGlassButton(.secondary, iconOnly: true)
            .help("\(QTLoc.tr("Hide panel"))  ⌥⌘N")
            .accessibilityIdentifier("qt.player.panel.hide")
        }
        .padding(.leading, 24)
        .padding(.trailing, 14)
        .frame(height: 52)
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
            Divider()
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
        let artSize = CGSize(width: showsVideo ? 156 : QTTheme.Metrics.panelHeroArtwork, height: QTTheme.Metrics.panelHeroArtwork)
        HStack(spacing: 18) {
            artwork(track)
                .frame(width: artSize.width, height: artSize.height)
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
                HStack(spacing: QTTheme.Spacing.xs) {
                    QTSongVideoToggle(isVideo: Binding(get: { model.isVideoMode }, set: { model.isVideoMode = $0 }),
                                      hasVideo: track?.hasVideo ?? false)
                        .controlSize(.regular)
                    Spacer(minLength: 0)
                    QTLyricsOptionsButton()
                }
                .padding(.top, 12)
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
        guard let track else { return "" }
        if let album = track.album?.title, !album.isEmpty, album != track.title {
            return "\(track.artistLine) · \(album)"
        }
        return track.artistLine
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
