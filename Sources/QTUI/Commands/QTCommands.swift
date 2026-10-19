import AppKit
import QTCore
import SwiftUI

// Owner: builder "desktop". The full menu bar (draft §8, HANDOFF §5 keyboard map):
//   QTube Music (system) · File (system Close) · Edit (+ Search Music ⌘K, Filter ⌘F) · View (panel ⌥⌘N,
//   sections ⌘1–4 in sidebar order, Back ⌘[ / Forward ⌘] through QTNavigator, system sidebar / full screen) · Controls (Space, ⌘←/→, ⌘L, shuffle, repeat, ⌘↑/↓ volume,
//   ⇧⌘V, ⇧⌘P, ⇧⌘F, ⇧⌘M, ⇧⌘L, ⌥↑/↓) · Window (system + "QTube Music" ⌘0) · Help (Keyboard Shortcuts ⌘/).
// Esc closes the Stage / its drawer inside the Stage view (`.cancelAction`), not as a menu item, so popovers and
// sheets keep their own Esc. Text-editing collisions (Space, ⌘←…) are routed to the text field (QTKeyRouting).

public struct QTCommands: Commands {
    private let model: QTAppModel
    @Environment(\.openWindow) private var openWindow

    public init(model: QTAppModel) {
        self.model = model
    }

    private var player: QTPlayerModel { model.player }
    private var desktop: QTDesktopCoordinator { QTDesktopCoordinator.shared }
    private var navigator: QTNavigator { QTNavigator.shared }
    private var stage: QTStageCoordinator { QTStageCoordinator.shared }

    public var body: some Commands {
        let _ = desktop.register(openWindow: openWindow)

        // File: no document model; keep the system Close, drop New/Print.
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .printItem) {}

        // Edit
        CommandGroup(after: .pasteboard) {
            Divider()
            Button(QTLoc.tr("Search Music…", table: .desktop)) { focusSearch() }
                .keyboardShortcut("k", modifiers: .command)
            Button(QTLoc.tr("Filter")) { focusFilter() }
                .keyboardShortcut("f", modifiers: .command)
        }

        // View
        CommandGroup(after: .sidebar) {
            Button(QTLoc.tr(model.isPanelShown ? "Hide panel" : "Show panel")) { model.isPanelShown.toggle() }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Picker(QTLoc.tr("Panel", table: .desktop), selection: Binding(get: { model.panelTab }, set: { tab in
                model.panelTab = tab
                model.isPanelShown = true
            })) {
                Text(QTLoc.tr("Now Playing")).tag(QTPanelTab.nowPlaying)
                Text(QTLoc.tr("Queue")).tag(QTPanelTab.queue)
            }
            .pickerStyle(.inline)
            Divider()
            section(.home, title: QTLoc.tr("Home"), key: "1")
            section(.explore, title: QTLoc.tr("Explore"), key: "2")
            section(.songs, title: QTLoc.tr("Songs"), key: "3")
            section(.liked, title: QTLoc.tr("Liked Songs"), key: "4")
            Divider()
            Button(QTLoc.tr("Back")) { navigator.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!navigator.canGoBack || model.surface == .stage)
            Button(QTLoc.tr("Forward")) { navigator.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!navigator.canGoForward || model.surface == .stage)
            Divider()
        }

        // Controls (prototype order, desktop.jsx › controlsMenuItems)
        CommandMenu(QTLoc.tr("Controls")) {
            Button(QTLoc.tr(player.isPlaying ? "Pause" : "Play")) { player.togglePlayPause() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(player.nowPlaying == nil)
            Button(QTLoc.tr(player.ad?.canSkip == true ? "Skip" : "Next")) {
                if player.ad != nil { player.skipAd() } else { Task { await player.next() } }
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(player.ad.map { !$0.canSkip } ?? (player.nowPlaying == nil))
            Button(QTLoc.tr("Previous")) { Task { await player.previous() } }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(player.ad != nil || player.nowPlaying == nil)
            Divider()
            Button(QTLoc.tr(player.nowPlaying.map(player.isLiked) == true ? "Remove from Liked Songs" : "Like")) {
                if let t = player.nowPlaying { player.toggleLike(t) }
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(player.nowPlaying == nil)
            Toggle(QTLoc.tr("Shuffle"), isOn: Binding(get: { player.isShuffleOn }, set: { player.isShuffleOn = $0 }))
            Picker(QTLoc.tr("Repeat"), selection: Binding(get: { player.repeatMode }, set: { player.repeatMode = $0 })) {
                Text(QTLoc.tr("Off")).tag(QTRepeatMode.off)
                Text(QTLoc.tr("Repeat All", table: .desktop)).tag(QTRepeatMode.all)
                Text(QTLoc.tr("Repeat One", table: .player)).tag(QTRepeatMode.one)
            }
            Divider()
            Button(QTLoc.tr("Volume Up", table: .desktop)) { player.setVolume(min(1, player.state.volume + 0.1)) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button(QTLoc.tr("Volume Down", table: .desktop)) { player.setVolume(max(0, player.state.volume - 0.1)) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Divider()
            Button(QTLoc.tr("Song ⇄ Music Video")) { model.isVideoMode.toggle() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(player.nowPlaying?.hasVideo != true)
            // Native Picture in Picture of the music video (switches to Video first); checked while it floats.
            Toggle(QTLoc.tr("Picture in Picture", table: .desktop), isOn: Binding(
                get: { QTVideoModeService.shared.isPictureInPictureActive },
                set: { _ in QTVideoModeService.shared.togglePictureInPicture() }))
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!QTVideoModeService.shared.canTogglePictureInPicture)
            // A detached Stage (another display) counts as open; ⇧⌘F closes it instead of pulling it back.
            Toggle(QTLoc.tr("Stage"), isOn: Binding(get: { model.surface == .stage || stage.isDetached }, set: { _ in
                if model.surface == .mini { desktop.showMainWindow() }
                stage.toggleStage(model: model)
            }))
            .keyboardShortcut("f", modifiers: [.command, .shift])
            Toggle(QTLoc.tr("Mini Player"), isOn: Binding(get: { model.surface == .mini }, set: { _ in desktop.toggleMiniPlayer() }))
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Toggle(QTLoc.tr("Desktop Lyrics"), isOn: Binding(get: { model.isDesktopLyricsShown }, set: { model.isDesktopLyricsShown = $0 }))
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button(QTLoc.tr(model.settings.settings.desktopLyrics.isLocked ? "Unlock Desktop Lyrics" : "Lock Desktop Lyrics", table: .desktop)) {
                desktop.setDesktopLyricsLocked(!model.settings.settings.desktopLyrics.isLocked)
            }
            .disabled(!model.isDesktopLyricsShown)
            Divider()
            Button(QTLoc.tr("Lyrics Earlier")) { QTLyricsTiming.nudge(model, by: QTLyricsTiming.step) }
                .keyboardShortcut(.upArrow, modifiers: .option)
                .disabled(player.lyrics == nil)
            Button(QTLoc.tr("Lyrics Later")) { QTLyricsTiming.nudge(model, by: -QTLyricsTiming.step) }
                .keyboardShortcut(.downArrow, modifiers: .option)
                .disabled(player.lyrics == nil)
        }

        // Window: the main window scene lists itself with ⌘0 (set on the scene in the app target); bringing it
        // back leaves the mini player (QTDesktopCoordinator observes the window becoming key).

        // Help
        CommandGroup(replacing: .help) {
            Button(QTLoc.tr("Keyboard Shortcuts", table: .desktop)) { openWindow(id: QTKeyboardShortcutsView.sceneID) }
                .keyboardShortcut("/", modifiers: .command)
        }
    }

    private func section(_ item: QTSidebarItem, title: String, key: KeyEquivalent) -> some View {
        Button(title) {
            bringUpBrowsing()
            navigator.go(.section(item))
        }
        .keyboardShortcut(key, modifiers: .command)
    }

    /// Navigation targets the main window's content column: leave the mini player / in-window Stage first.
    private func bringUpBrowsing() {
        if model.surface == .mini || desktop.mainWindow?.isVisible != true { desktop.showMainWindow() }
        if model.surface == .stage { model.surface = .window }
    }

    /// ⌘K: the toolbar search field (QTMainWindowView observes `searchFocusRequest`).
    private func focusSearch() {
        bringUpBrowsing()
        navigator.requestSearchFocus()
    }

    /// ⌘F: the current list's filter field; from a page without one, Liked Songs first (prototype behaviour).
    private func focusFilter() {
        bringUpBrowsing()
        if !model.searchText.isEmpty || QTTrackCollection.listKey(for: navigator.current) == nil
            || navigator.current == .section(.history) {
            navigator.go(.section(.liked))
            Task { @MainActor in
                // Let the Liked table mount before its field takes focus.
                try? await Task.sleep(for: .milliseconds(120))
                navigator.requestFilterFocus()
            }
        } else {
            navigator.requestFilterFocus()
        }
    }
}

// MARK: - Keyboard Shortcuts window (Help › Keyboard Shortcuts, ⌘/)

/// A native, read-only list of every shortcut, grouped like the menus.
public struct QTKeyboardShortcutsView: View {
    public static let sceneID = "qt.window.keyboardShortcuts"

    public init() {}

    private struct Row: Identifiable {
        let title: String
        let keys: String
        var id: String { title + keys }
    }

    private var groups: [(String, [Row])] {
        [
            (QTLoc.tr("Playback", table: .desktop), [
                Row(title: QTLoc.tr("Play") + " / " + QTLoc.tr("Pause"), keys: QTLoc.tr("Space", table: .desktop)),
                Row(title: QTLoc.tr("Next"), keys: "⌘→"),
                Row(title: QTLoc.tr("Previous"), keys: "⌘←"),
                Row(title: QTLoc.tr("Like"), keys: "⌘L"),
                Row(title: QTLoc.tr("Volume Up", table: .desktop), keys: "⌘↑"),
                Row(title: QTLoc.tr("Volume Down", table: .desktop), keys: "⌘↓"),
                Row(title: QTLoc.tr("Song ⇄ Music Video"), keys: "⇧⌘V"),
                Row(title: QTLoc.tr("Lyrics Earlier"), keys: "⌥↑"),
                Row(title: QTLoc.tr("Lyrics Later"), keys: "⌥↓"),
            ]),
            (QTLoc.tr("Players", table: .desktop), [
                Row(title: QTLoc.tr("Stage"), keys: "⇧⌘F"),
                Row(title: QTLoc.tr("Close Stage", table: .desktop), keys: "Esc"),
                Row(title: QTLoc.tr("Mini Player"), keys: "⇧⌘M"),
                Row(title: QTLoc.tr("Desktop Lyrics"), keys: "⇧⌘L"),
                Row(title: QTLoc.tr("Picture in Picture", table: .desktop), keys: "⇧⌘P"),
            ]),
            (QTLoc.tr("Library"), [
                Row(title: QTLoc.tr("Search Music…", table: .desktop), keys: "⌘K"),
                Row(title: QTLoc.tr("Filter"), keys: "⌘F"),
                Row(title: QTLoc.tr("Play"), keys: "↩"),
                Row(title: QTLoc.tr("Play Next"), keys: "⌥↩"),
                Row(title: QTLoc.tr("Home"), keys: "⌘1"),
                Row(title: QTLoc.tr("Explore"), keys: "⌘2"),
                Row(title: QTLoc.tr("Songs"), keys: "⌘3"),
                Row(title: QTLoc.tr("Liked Songs"), keys: "⌘4"),
                Row(title: QTLoc.tr("Back"), keys: "⌘["),
                Row(title: QTLoc.tr("Forward"), keys: "⌘]"),
                Row(title: QTLoc.tr("Show panel"), keys: "⌥⌘N"),
                Row(title: QTLoc.tr("Show Main Window"), keys: "⌘0"),
            ]),
        ]
    }

    public var body: some View {
        Form {
            ForEach(groups, id: \.0) { title, rows in
                Section(title) {
                    ForEach(rows) { row in
                        LabeledContent(row.title) {
                            Text(verbatim: row.keys)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 680)
        .accessibilityIdentifier("qt.keyboardShortcuts")
    }
}
