import QTCore
import SwiftUI

// Owner: builder "player". Signature is the shared contract (player bar, Stage, mini player, menu bar popover).

public enum QTTransportStyle: Hashable, Sendable {
    /// Bottom player bar: shuffle · prev · play · next · repeat.
    case playerBar
    /// Stage: larger, white over art.
    case stage
    /// Mini player / menu bar popover: prev · play · next.
    case compact
}

/// Shuffle / previous / play-pause / next / repeat. Shuffle and repeat are native toggle buttons, so "on" is a
/// filled background, not a subtle colour shift (draft §9). During an ad: previous disabled, next = Skip when allowed.
public struct QTTransportControls: View {
    private let style: QTTransportStyle
    @Environment(QTPlayerModel.self) private var player

    public init(style: QTTransportStyle) {
        self.style = style
    }

    private var glyph: CGFloat {
        switch style {
        case .playerBar: 15
        case .stage: 22
        case .compact: 17
        }
    }

    public var body: some View {
        @Bindable var player = player
        HStack(spacing: style == .stage ? 34 : 18) {
            if style != .compact {
                Toggle(isOn: $player.isShuffleOn) {
                    Label(QTLoc.tr("Shuffle"), systemImage: QTIcon.shuffle.systemName)
                }
                .toggleStyle(.button)
                .help(QTLoc.tr("Shuffle"))
                .accessibilityIdentifier("qt.transport.shuffle")
            }
            Button {
                Task { await player.previous() }
            } label: {
                Label(QTLoc.tr("Previous"), systemImage: QTIcon.prev.systemName)
            }
            .disabled(player.ad != nil)
            .help("\(QTLoc.tr("Previous"))  ⌘←")
            .accessibilityIdentifier("qt.transport.previous")

            Button {
                player.togglePlayPause()
            } label: {
                Label(QTLoc.tr(player.isPlaying ? "Pause" : "Play"),
                      systemImage: player.isPlaying ? QTIcon.pause.systemName : QTIcon.play.systemName)
                    .font(.system(size: glyph * 1.25))
                    .frame(width: glyph * 1.9, height: glyph * 1.9)
                    .contentTransition(.symbolEffect(.replace))
            }
            .help(QTLoc.tr(player.isPlaying ? "Pause" : "Play"))
            .accessibilityIdentifier("qt.transport.playPause")

            Button {
                if let ad = player.ad {
                    if ad.canSkip { player.skipAd() }
                } else {
                    Task { await player.next() }
                }
            } label: {
                Label(QTLoc.tr("Next"), systemImage: QTIcon.next.systemName)
            }
            .disabled(player.ad.map { !$0.canSkip } ?? false)
            .help("\(QTLoc.tr("Next"))  ⌘→")
            .accessibilityIdentifier("qt.transport.next")

            if style != .compact {
                Toggle(isOn: Binding(get: { player.repeatMode != .off },
                                     set: { player.repeatMode = $0 ? .all : .off })) {
                    Label(QTLoc.tr("Repeat"), systemImage: player.repeatMode == .one ? QTIcon.repeatOne.systemName : QTIcon.repeat.systemName)
                }
                .toggleStyle(.button)
                .help(QTLoc.tr("Repeat"))
                .accessibilityIdentifier("qt.transport.repeat")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.system(size: glyph))
        .foregroundStyle(style == .stage ? QTTheme.Colors.onArt : QTTheme.Colors.label)
    }
}
