import QTCore
import SwiftUI

// Owner: builder "desktop". Full menu bar with shortcuts (draft §8). Stub: Controls + View items.
// Note: a bare-Space key equivalent would fire while typing in search fields — handle Space in the window instead.

public struct QTCommands: Commands {
    private let model: QTAppModel

    public init(model: QTAppModel) {
        self.model = model
    }

    public var body: some Commands {
        CommandMenu(QTLoc.tr("Controls")) {
            Button(QTLoc.tr(model.player.isPlaying ? "Pause" : "Play")) { model.player.togglePlayPause() }
            Button(QTLoc.tr("Next")) { Task { await model.player.next() } }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button(QTLoc.tr("Previous")) { Task { await model.player.previous() } }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Divider()
            Button(QTLoc.tr("Like")) { if let t = model.player.nowPlaying { model.player.toggleLike(t) } }
                .keyboardShortcut("l", modifiers: .command)
            Divider()
            Button(QTLoc.tr("Song ⇄ Music Video")) { model.isVideoMode.toggle() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(model.player.nowPlaying?.hasVideo != true)
            Button(QTLoc.tr("Stage")) { model.surface = model.surface == .stage ? .window : .stage }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button(QTLoc.tr("Mini Player")) { model.surface = model.surface == .mini ? .window : .mini }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button(QTLoc.tr("Desktop Lyrics")) { model.isDesktopLyricsShown.toggle() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button(QTLoc.tr("Lyrics Earlier")) { model.player.nudgeLyricsOffset(by: 0.1) }
                .keyboardShortcut(.upArrow, modifiers: .option)
            Button(QTLoc.tr("Lyrics Later")) { model.player.nudgeLyricsOffset(by: -0.1) }
                .keyboardShortcut(.downArrow, modifiers: .option)
        }
        CommandGroup(after: .sidebar) {
            Button(QTLoc.tr(model.isPanelShown ? "Hide panel" : "Show panel")) { model.isPanelShown.toggle() }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
    }
}
