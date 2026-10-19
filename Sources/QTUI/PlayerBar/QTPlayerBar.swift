import QTCore
import QTPlayback
import SwiftUI

// Owner: builder "player". Prototype `.playerbar`: now playing (320) | transport + scrubber | tools (320).
// Floats over the bottom of the content column + panel as one glass bar (`qtGlass`, Theme/QTGlass.swift).

/// The always-visible bottom bar. Owns playback controls (the panel never duplicates them).
public struct QTPlayerBar: View {
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player

    public init() {}

    public var body: some View {
        HStack(spacing: QTTheme.Spacing.l) {
            // Sides are 320 pt on wide windows and give way first on narrow ones; the centre keeps room for
            // the transport and a usable scrubber.
            QTPlayerBarNowPlaying()
                .frame(minWidth: 180, maxWidth: QTTheme.Metrics.playerBarSideWidth, alignment: .leading)
            VStack(spacing: 2) {
                QTTransportControls(style: .playerBar)
                QTScrubber()
                    .frame(maxWidth: QTTheme.Metrics.scrubberMaxWidth)
            }
            .frame(minWidth: 300, maxWidth: .infinity)
            ViewThatFits(in: .horizontal) {
                QTPlayerBarTools(showsVolumeSlider: true)
                QTPlayerBarTools(showsVolumeSlider: false)
            }
            .frame(minWidth: 180, maxWidth: QTTheme.Metrics.playerBarSideWidth, alignment: .trailing)
        }
        .padding(.leading, 12)
        .padding(.trailing, 18)
        .frame(height: QTTheme.Metrics.playerBarHeight)
        .qtGlass(.bar, in: RoundedRectangle(cornerRadius: QTTheme.Radius.playerBar, style: .continuous))
        .background { QTPlayerKeyAppearanceProbe() }
        .padding(.horizontal, QTTheme.Metrics.playerBarInset)
        .padding(.top, 4)
        .padding(.bottom, QTTheme.Metrics.playerBarInset)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("qt.player.bar")
        // Song⇄Video (`isVideoMode`) is kept in step with the loaded rendition by `QTVideoModeService`.
    }
}

// MARK: - Now playing (left)

struct QTPlayerBarNowPlaying: View {
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player

    var body: some View {
        let ad = player.ad
        HStack(spacing: 14) {
            Button {
                model.surface = .stage
            } label: {
                QTArtworkView(track: player.nowPlaying, cornerRadius: QTTheme.Radius.control)
                    .frame(width: QTTheme.Metrics.playerBarArtwork, height: QTTheme.Metrics.playerBarArtwork)
                    .brightness(ad != nil ? -0.25 : 0)
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .help("\(QTLoc.tr("Open Stage"))  ⇧⌘F")
            .accessibilityLabel(QTLoc.tr("Open Stage"))
            .accessibilityIdentifier("qt.player.bar.artwork")

            VStack(alignment: .leading, spacing: 2) {
                if ad != nil {
                    Text(QTLoc.tr("Advertisement"))
                        .font(QTTheme.Typography.rowTitle)
                    Text(QTLoc.tr("Then: %@", player.nowPlaying?.title ?? ""))
                        .font(QTTheme.Typography.secondary)
                        .foregroundStyle(.secondary)
                } else {
                    Text(player.nowPlaying?.title ?? "")
                        .font(QTTheme.Typography.rowTitle)
                    Text(player.nowPlaying?.artistLine ?? "")
                        .font(QTTheme.Typography.secondary)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(-1)
            .accessibilityElement(children: .combine)

            if let ad {
                QTAdSkipControl(ad: ad)
                    .padding(.leading, 2)
            } else if let track = player.nowPlaying {
                QTLikeButton(track: track)
            }
        }
    }
}

/// ♥ for a track: accent when liked, quiet otherwise.
struct QTLikeButton: View {
    let track: QTTrack
    @Environment(QTPlayerModel.self) private var player

    var body: some View {
        let liked = player.isLiked(track)
        Button {
            player.toggleLike(track)
        } label: {
            Label(QTLoc.tr(liked ? "Remove from Liked Songs" : "Like"),
                  systemImage: liked ? QTIcon.heartFill.systemName : QTIcon.heart.systemName)
                .labelStyle(.iconOnly)
                .font(.system(size: 15))
                .foregroundStyle(liked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .help("\(QTLoc.tr(liked ? "Remove from Liked Songs" : "Like"))  ⌘L")
        .accessibilityIdentifier("qt.player.bar.like")
    }
}

/// The ad's Skip control. In the player bar it is always a real button: disabled while YouTube counts down
/// ("Skip in 4", tabular figures), then a prominent "Skip" the moment skipping is allowed (⌘→ does the same).
/// Over art (Stage, ad artwork) the countdown is quiet text and Skip a white capsule, as in the prototype.
public struct QTAdSkipControl: View {
    private let ad: QTAdState
    private let overArt: Bool
    @Environment(QTPlayerModel.self) private var player
    @Environment(\.colorScheme) private var colorScheme

    public init(ad: QTAdState, overArt: Bool = false) {
        self.ad = ad
        self.overArt = overArt
    }

    private var waitTitle: String? {
        ad.skippableIn.map { QTLoc.tr("Skip in %lld", Int($0.rounded(.up))) }
    }

    public var body: some View {
        Group {
            if overArt {
                if ad.canSkip {
                    Button { player.skipAd() } label: {
                        Text(QTLoc.tr("Skip"))
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .tint(.white)
                    .foregroundStyle(.black)
                    .help("\(QTLoc.tr("Skip"))  ⌘→")
                    .accessibilityIdentifier("qt.player.ad.skip")
                } else if let waitTitle {
                    Text(waitTitle)
                        .font(QTTheme.Typography.secondary)
                        .monospacedDigit()
                        .foregroundStyle(QTTheme.Colors.onArtSecondary)
                        .fixedSize()
                        .accessibilityIdentifier("qt.player.ad.wait")
                }
            } else if ad.canSkip {
                Button(QTLoc.tr("Skip")) { player.skipAd() }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .fixedSize()
                    .help("\(QTLoc.tr("Skip"))  ⌘→")
                    .accessibilityIdentifier("qt.player.ad.skip")
            } else if let waitTitle {
                Button(waitTitle) {}
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .monospacedDigit()
                    .disabled(true)
                    .fixedSize()
                    .accessibilityIdentifier("qt.player.ad.wait")
            }
        }
        .environment(\.colorScheme, overArt ? .dark : colorScheme)
    }
}

// MARK: - Tools (right)

struct QTPlayerBarTools: View {
    var showsVolumeSlider = true
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            panelToggle(.nowPlaying, title: QTLoc.tr("Lyrics"), icon: .lyrics, id: "lyrics")
            panelToggle(.queue, title: QTLoc.tr("Queue"), icon: .list, id: "queue")
            QTAirPlayButton()
                .frame(width: 28, height: 28)
            QTVolumeControl(showsSlider: showsVolumeSlider)
                .padding(.horizontal, 4)
            toolButton(QTLoc.tr("Mini player"), icon: .mini, shortcut: "⇧⌘M", id: "mini") {
                model.surface = model.surface == .mini ? .window : .mini
            }
            toolButton(QTLoc.tr("Stage"), icon: .expand, shortcut: "⇧⌘F", id: "stage") {
                model.surface = .stage
            }
        }
        .labelStyle(.iconOnly)
    }

    /// Lyrics / Queue: on (filled) while the panel shows that tab, like Music.app's lyrics and queue buttons.
    private func panelToggle(_ tab: QTPanelTab, title: String, icon: QTIcon, id: String) -> some View {
        Toggle(isOn: Binding(
            get: { model.isPanelShown && model.panelTab == tab },
            set: { on in
                withAnimation(QTTheme.Motion.animation(QTTheme.Motion.spring, reduceMotion: reduceMotion)) {
                    if on {
                        model.panelTab = tab
                        model.isPanelShown = true
                    } else {
                        model.isPanelShown = false
                    }
                }
            })) {
            Label(title, systemImage: icon.systemName)
                .font(.system(size: 14))
                .frame(width: 22, height: 20)
        }
        .toggleStyle(.button)
        .buttonStyle(.accessoryBar)
        .help(title)
        .accessibilityIdentifier("qt.player.bar.\(id)")
    }

    private func toolButton(_ title: String, icon: QTIcon, shortcut: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon.systemName)
                .font(.system(size: 14))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("\(title)  \(shortcut)")
        .accessibilityIdentifier("qt.player.bar.\(id)")
    }
}

/// Speaker (click = mute) + native slider. The glyph's waves follow the level (SF Symbols variable value).
/// On narrow windows the slider moves into a popover opened from the speaker.
struct QTVolumeControl: View {
    var showsSlider = true
    @Environment(QTPlayerModel.self) private var player
    @State private var isPopoverShown = false

    var body: some View {
        let state = player.state
        let level = state.isMuted ? 0 : state.volume
        HStack(spacing: 6) {
            Button {
                if showsSlider { player.engine.setMuted(!state.isMuted) } else { isPopoverShown.toggle() }
            } label: {
                Image(systemName: level == 0 ? QTIcon.volumeMuted.systemName : "speaker.wave.3.fill", variableValue: level)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 13))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            // With the slider beside it the speaker mutes; on narrow bars it opens the volume popover.
            .help(muteTitle(isMuted: state.isMuted))
            .accessibilityLabel(muteTitle(isMuted: state.isMuted))
            .accessibilityIdentifier("qt.player.bar.mute")
            .popover(isPresented: $isPopoverShown, arrowEdge: .top) {
                slider(level: level, isMuted: state.isMuted)
                    .frame(width: 140)
                    .padding(QTTheme.Spacing.s)
            }
            if showsSlider {
                slider(level: level, isMuted: state.isMuted)
                    .frame(width: 80)
            }
        }
    }

    private func muteTitle(isMuted: Bool) -> String {
        guard showsSlider else { return QTLoc.tr("Volume") }
        return QTLoc.tr(isMuted ? "Unmute" : "Mute", table: .player)
    }

    private func slider(level: Double, isMuted: Bool) -> some View {
        Slider(value: Binding(get: { level }, set: { v in
            if isMuted { player.engine.setMuted(false) }
            player.setVolume(v)
        }), in: 0...1)
            .controlSize(.mini)
            .accessibilityLabel(QTLoc.tr("Volume"))
            .accessibilityIdentifier("qt.player.bar.volume")
    }
}
