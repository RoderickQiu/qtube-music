import AppKit
import QTCore
import QTPlayback
import SwiftUI

// Owner: builder "player". Sleep timer (pre-launch round 2, item 3; `QTSleepTimer` in QTPlayback does the work):
// Controls › Sleep Timer, the Dock menu and the mini player's menu offer 15 / 30 / 45 / 60 / 90 Minutes, End of Song
// and Turn Off, the active choice checked. While a timer runs, a quiet "☾ 12:34" button in the player bar, the Stage's
// bottom bar and the menu bar popover counts down; a click offers the same choices. Like the speed button, it is
// there only while it means something.

@MainActor
enum QTSleepTimerMenu {
    /// Every choice in menu order (`Divider` before End of Song).
    static var choices: [QTSleepTimerChoice] {
        QTSleepTimerChoice.presetMinutes.map { .minutes($0) } + [.endOfSong]
    }

    static func title(for choice: QTSleepTimerChoice) -> String {
        switch choice {
        case .minutes(let minutes): QTLoc.tr("%lld Minutes", table: .player, minutes)
        case .endOfSong: QTLoc.tr("End of Song", table: .player)
        }
    }

    /// End of Song needs a song.
    static func isEnabled(_ choice: QTSleepTimerChoice, player: QTPlayerModel) -> Bool {
        choice != .endOfSong || player.nowPlaying != nil
    }

    /// "12:34" (time left, rounded up so it reads 0:01 until the very end), or nil for End of Song.
    static func countdown(_ timer: QTSleepTimer) -> String? {
        timer.remaining.map { QTFormat.duration($0.rounded(.up)) }
    }

    /// The choices as an AppKit menu: the player bar's button and the Dock's submenu.
    static func menu(for player: QTPlayerModel) -> NSMenu {
        let timer = player.sleepTimer
        let menu = NSMenu(title: QTLoc.tr("Sleep Timer", table: .player))
        menu.autoenablesItems = false
        for choice in choices {
            if choice == .endOfSong { menu.addItem(.separator()) }
            menu.addItem(QTClosureMenuItem(title(for: choice), enabled: isEnabled(choice, player: player),
                                           state: timer.choice == choice) { timer.start(choice) })
        }
        menu.addItem(.separator())
        menu.addItem(QTClosureMenuItem(QTLoc.tr("Turn Off", table: .player), enabled: timer.isActive) { timer.turnOff() })
        return menu
    }

    /// "Sleep Timer ›" for the Dock menu.
    static func menuItem(for player: QTPlayerModel) -> NSMenuItem {
        let item = NSMenuItem(title: QTLoc.tr("Sleep Timer", table: .player), action: nil, keyEquivalent: "")
        item.submenu = menu(for: player)
        return item
    }
}

/// The same choices as SwiftUI menu content: Controls › Sleep Timer and the mini player's menu. Choosing the checked
/// length again starts it over.
struct QTSleepTimerMenuContent: View {
    let player: QTPlayerModel

    var body: some View {
        let timer = player.sleepTimer
        ForEach(QTSleepTimerMenu.choices, id: \.self) { choice in
            if choice == .endOfSong { Divider() }
            Toggle(QTSleepTimerMenu.title(for: choice), isOn: Binding(
                get: { timer.choice == choice },
                set: { _ in timer.start(choice) }))
                .disabled(!QTSleepTimerMenu.isEnabled(choice, player: player))
        }
        Divider()
        Button(QTLoc.tr("Turn Off", table: .player)) { timer.turnOff() }
            .disabled(!timer.isActive)
    }
}

/// "☾ 12:34" in a quiet outlined capsule while a sleep timer runs (just the moon for End of Song; filled while the
/// volume fades); a click offers the choices. Over art (the Stage) in the light on-art colours.
struct QTSleepTimerButton: View {
    var overArt = false
    var identifier = "qt.player.bar.sleepTimer"
    @Environment(QTPlayerModel.self) private var player
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var anchor = QTMenuAnchor()
    @State private var hovering = false

    var body: some View {
        let timer = player.sleepTimer
        QTTickingView(every: .seconds(1), isRunning: timer.deadline != nil) {
            let countdown = QTSleepTimerMenu.countdown(timer)
            Button {
                anchor.popUp(QTSleepTimerMenu.menu(for: player))
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: QTIcon.sleepTimer.systemName)
                        .symbolVariant(timer.isFading ? .fill : .none)
                        .font(.system(size: 10, weight: .semibold))
                    if let countdown {
                        Text(verbatim: countdown)
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(foreground)
                .padding(.horizontal, countdown == nil ? 5 : 6)
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
            .help(QTLoc.tr("Sleep Timer", table: .player))
            .accessibilityLabel(QTLoc.tr("Sleep Timer", table: .player))
            .accessibilityValue(countdown ?? QTLoc.tr("End of Song", table: .player))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(identifier)
        }
    }

    private var foreground: Color {
        if overArt { return hovering ? QTTheme.Colors.onArt : QTTheme.Colors.onArtSecondary }
        return contrast == .increased || hovering ? QTTheme.Colors.label : QTTheme.Colors.secondaryLabel
    }
}

#if DEBUG
extension QTPlayerLaunch {
    /// `-qt.player.sleepTimer <seconds>|end`: a timer already running with that much left (checked on the shortest
    /// length that covers it), or End of Song — for screenshots of the countdown. Inside the last 30 s of a playing
    /// launch (`-qt.paused NO`) it fades.
    static func applySleepTimer(_ launch: QTLaunchOptions, to player: QTPlayerModel) {
        guard let arg = launch.string("qt.player.sleepTimer") else { return }
        if arg.lowercased() == "end" { return player.sleepTimer.start(.endOfSong) }
        guard let seconds = Double(arg), seconds > 0 else { return }
        player.sleepTimer.start(.preset(covering: seconds), remaining: seconds)
    }
}
#endif
