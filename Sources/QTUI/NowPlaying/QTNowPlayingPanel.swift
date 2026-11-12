import AppKit
import QTCore
import QTPlayback
import SwiftUI

// Owner: builder "player". The docked panel: two tabs (Now Playing with lyrics, Queue), no transport.
// The Now Playing | Queue switch heads the panel (like the tab bar at the top of Xcode's inspector); the toolbar's
// Show / Hide Panel button (⌥⌘N) at the window's trailing edge opens and closes it. Blurred artwork backdrop.

public struct QTNowPlayingPanel: View {
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        ZStack {
            QTPanelBackdrop(track: player.nowPlaying)
            VStack(spacing: 0) {
                QTPanelTabPicker()
                    .padding(.top, QTTheme.Spacing.xs)
                    .padding(.horizontal, QTTheme.Spacing.m)
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

/// Now Playing | Queue, centred at the top of the panel.
struct QTPanelTabPicker: View {
    @Environment(QTAppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Picker(selection: $model.panelTab) {
            Text(QTLoc.tr("Now Playing")).tag(QTPanelTab.nowPlaying)
            Text(QTLoc.tr("Queue")).tag(QTPanelTab.queue)
        } label: {
            Text(QTLoc.tr("Now Playing"))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("qt.player.panel.tabs")
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
        // Under the floating player bar, but not up under the toolbar, and clipped (the scaled, blurred art spreads
        // past its frame): the toolbar's glass buttons re-render whenever what's behind them changes, so a backdrop
        // sliding in under them made the whole toolbar flash.
        .ignoresSafeArea(edges: .bottom)
        .clipped()
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
                .qtLyricsFileDrop(model)
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
                // Title and album → the album page, each artist → their page (QTTrackLinks.swift).
                QTTrackTitleLink(track: track)
                    .font(QTTheme.Typography.panelTitle)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("qt.player.panel.title")
                QTTrackLinkLine(track: track, albumSeparator: " · ")
                    .font(QTTheme.Typography.secondary)
                    .foregroundStyle(.secondary)
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
