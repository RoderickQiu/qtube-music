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

/// Shuffle / previous / play-pause / next / repeat. Shuffle and repeat are native toggle buttons in the
/// accessory-bar style, so "on" is a filled bezel, not a subtle colour shift (draft §9). Repeat cycles
/// off → all → one. During an ad: previous is disabled and next skips the ad once YouTube allows it.
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
        case .compact: 16
        }
    }

    private var playGlyph: CGFloat {
        switch style {
        case .playerBar: 22
        case .stage: 34
        case .compact: 22
        }
    }

    private var spacing: CGFloat {
        switch style {
        case .playerBar: 14
        case .stage: 30
        case .compact: 18
        }
    }

    public var body: some View {
        HStack(spacing: spacing) {
            if style != .compact { shuffle }
            previous
            playPause
            next
            if style != .compact { repeatToggle }
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(style == .stage ? QTTheme.Colors.onArt : QTTheme.Colors.label)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("qt.transport.\(style)")
    }

    // MARK: Pieces

    private var shuffle: some View {
        @Bindable var player = player
        return Toggle(isOn: $player.isShuffleOn) {
            Label(QTLoc.tr("Shuffle"), systemImage: QTIcon.shuffle.systemName)
                .font(.system(size: glyph - 2, weight: .semibold))
                .frame(width: glyph + 10, height: glyph + 6)
        }
        .toggleStyle(.button)
        .buttonStyle(.accessoryBar)
        .help(QTLoc.tr("Shuffle"))
        .accessibilityValue(QTLoc.tr(player.isShuffleOn ? "On" : "Off"))
        .accessibilityIdentifier("qt.transport.shuffle")
    }

    private var repeatToggle: some View {
        Toggle(isOn: Binding(get: { player.repeatMode != .off }, set: { _ in cycleRepeat() })) {
            Label(QTLoc.tr("Repeat"), systemImage: player.repeatMode == .one ? QTIcon.repeatOne.systemName : QTIcon.repeat.systemName)
                .font(.system(size: glyph - 2, weight: .semibold))
                .frame(width: glyph + 10, height: glyph + 6)
                .contentTransition(.symbolEffect(.replace))
        }
        .toggleStyle(.button)
        .buttonStyle(.accessoryBar)
        .help(QTLoc.tr(player.repeatMode == .one ? "Repeat One" : "Repeat", table: .player))
        .accessibilityValue(QTLoc.tr(player.repeatMode == .off ? "Off" : "On"))
        .accessibilityIdentifier("qt.transport.repeat")
    }

    private var previous: some View {
        Button {
            Task { await player.previous() }
        } label: {
            Label(QTLoc.tr("Previous"), systemImage: QTIcon.prev.systemName)
                .font(.system(size: glyph + 2))
                .frame(width: glyph + 14, height: glyph + 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(player.ad != nil)
        .help("\(QTLoc.tr("Previous"))  ⌘←")
        .accessibilityIdentifier("qt.transport.previous")
    }

    private var playPause: some View {
        Button {
            player.togglePlayPause()
        } label: {
            Label(QTLoc.tr(player.isPlaying ? "Pause" : "Play"),
                  systemImage: player.isPlaying ? QTIcon.pause.systemName : QTIcon.play.systemName)
                .font(.system(size: playGlyph))
                .frame(width: playGlyph + 12, height: playGlyph + 10)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace.downUp))
        }
        .buttonStyle(.borderless)
        .help("\(QTLoc.tr(player.isPlaying ? "Pause" : "Play"))  Space")
        .accessibilityIdentifier("qt.transport.playPause")
    }

    private var next: some View {
        let ad = player.ad
        return Button {
            if let ad {
                if ad.canSkip { player.skipAd() }
            } else {
                Task { await player.next() }
            }
        } label: {
            Label(QTLoc.tr(ad != nil ? "Skip" : "Next"), systemImage: QTIcon.next.systemName)
                .font(.system(size: glyph + 2))
                .frame(width: glyph + 14, height: glyph + 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(ad.map { !$0.canSkip } ?? false)
        .help(ad != nil ? QTLoc.tr("Skip") : "\(QTLoc.tr("Next"))  ⌘→")
        .accessibilityIdentifier("qt.transport.next")
    }

    private func cycleRepeat() {
        switch player.repeatMode {
        case .off: player.repeatMode = .all
        case .all: player.repeatMode = .one
        case .one: player.repeatMode = .off
        }
    }
}
