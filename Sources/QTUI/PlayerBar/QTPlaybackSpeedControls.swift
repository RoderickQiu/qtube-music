import AppKit
import QTCore
import QTPlayback
import SwiftUI

// Owner: builder "player". Playback speed (pre-launch §9): Controls › Playback Speed with ⌥⌘. / ⌥⌘, / ⌥⌘0, the
// mini player's menu, and a "1.5×" button in the player bar and on the Stage — shown only while the speed isn't
// normal, so a speed nobody remembers setting is never a mystery. One speed for everything that plays (songs, videos,
// uploads, both engines); QTPlaybackServices saves it (`QTPlaybackEffectsPrefs.playbackRate`).

@MainActor
enum QTPlaybackSpeedMenu {
    /// The choice's menu title: "Normal" for 1×, else "1.5×".
    static func title(for rate: Double) -> String {
        QTPlaybackSpeed.isNormal(rate) ? QTLoc.tr("Normal", table: .player) : QTPlaybackSpeed.label(rate)
    }

    static func speedUp(_ player: QTPlayerModel) {
        if let r = QTPlaybackSpeed.faster(than: player.rate) { player.setRate(r) }
    }

    static func slowDown(_ player: QTPlayerModel) {
        if let r = QTPlaybackSpeed.slower(than: player.rate) { player.setRate(r) }
    }

    /// The same choices as an AppKit menu, popped from the speed button (a SwiftUI `Menu` restyled as a small button
    /// loses its accessibility element; see `QTMenuAnchor`).
    static func menu(for player: QTPlayerModel) -> NSMenu {
        let menu = NSMenu(title: QTLoc.tr("Playback Speed", table: .player))
        for rate in QTPlaybackSpeed.choices {
            menu.addItem(QTClosureMenuItem(title(for: rate), state: abs(player.rate - rate) < 0.001) { player.setRate(rate) })
        }
        menu.addItem(.separator())
        let up = QTClosureMenuItem(QTLoc.tr("Speed Up", table: .player), enabled: QTPlaybackSpeed.faster(than: player.rate) != nil) {
            speedUp(player)
        }
        up.keyEquivalent = "."
        up.keyEquivalentModifierMask = [.command, .option]
        let down = QTClosureMenuItem(QTLoc.tr("Slow Down", table: .player), enabled: QTPlaybackSpeed.slower(than: player.rate) != nil) {
            slowDown(player)
        }
        down.keyEquivalent = ","
        down.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(up)
        menu.addItem(down)
        menu.autoenablesItems = false
        return menu
    }
}

/// The choices (checked = current) and, with `includesSteps`, Speed Up / Slow Down — SwiftUI menu content for
/// Controls › Playback Speed (with its shortcuts) and the mini player's menu.
struct QTPlaybackSpeedMenuContent: View {
    let player: QTPlayerModel
    var showsShortcuts = false
    var includesSteps = true

    var body: some View {
        ForEach(QTPlaybackSpeed.choices, id: \.self) { rate in
            Toggle(QTPlaybackSpeedMenu.title(for: rate), isOn: Binding(
                get: { abs(player.rate - rate) < 0.001 },
                set: { _ in player.setRate(rate) }))
                .keyboardShortcut(showsShortcuts && QTPlaybackSpeed.isNormal(rate) ? KeyboardShortcut("0", modifiers: [.command, .option]) : nil)
        }
        if includesSteps {
            Divider()
            Button(QTLoc.tr("Speed Up", table: .player)) { QTPlaybackSpeedMenu.speedUp(player) }
                .keyboardShortcut(showsShortcuts ? KeyboardShortcut(".", modifiers: [.command, .option]) : nil)
                .disabled(QTPlaybackSpeed.faster(than: player.rate) == nil)
            Button(QTLoc.tr("Slow Down", table: .player)) { QTPlaybackSpeedMenu.slowDown(player) }
                .keyboardShortcut(showsShortcuts ? KeyboardShortcut(",", modifiers: [.command, .option]) : nil)
                .disabled(QTPlaybackSpeed.slower(than: player.rate) == nil)
        }
    }
}

/// "1.5×" in a quiet outlined capsule while the speed isn't normal; a click opens the speed choices. Over art (the
/// Stage) it is drawn in the light on-art colours.
struct QTPlaybackSpeedButton: View {
    var overArt = false
    var identifier = "qt.player.bar.speed"
    @Environment(QTPlayerModel.self) private var player
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var anchor = QTMenuAnchor()
    @State private var hovering = false

    var body: some View {
        let label = QTPlaybackSpeed.label(player.rate)
        Button {
            anchor.popUp(QTPlaybackSpeedMenu.menu(for: player))
        } label: {
            Text(verbatim: label)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(foreground)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background {
                    Capsule(style: .continuous)
                        .strokeBorder(foreground.opacity(hovering ? 0.8 : 0.45), lineWidth: 1)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .background(QTMenuAnchorView(anchor: anchor))
        .help(QTLoc.tr("Playback Speed", table: .player))
        .accessibilityLabel(QTLoc.tr("Playback Speed", table: .player))
        .accessibilityValue(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier)
    }

    private var foreground: Color {
        if overArt { return hovering ? QTTheme.Colors.onArt : QTTheme.Colors.onArtSecondary }
        return contrast == .increased || hovering ? QTTheme.Colors.label : QTTheme.Colors.secondaryLabel
    }
}
