import AppKit
import QTCore
import SwiftUI

// Owner: builder "desktop". The full menu bar (draft §8, HANDOFF §5 keyboard map):
//   QTube Music (system + Check for Updates… from the app target) · File (Close Window ⌘W) · Edit (+ Search Music ⌘K, Filter ⌘F) · View (panel ⌥⌘N,
//   sections ⌘1–8 in sidebar order, Back ⌘[ / Forward ⌘] through QTNavigator, system sidebar / full screen) · Controls (Space, ⌘←/→, ⌘L, shuffle, repeat, ⌘↑/↓ volume,
//   Playback Speed › ⌥⌘. / ⌥⌘, / ⌥⌘0, ⇧⌘V, ⇧⌘P, ⇧⌘F, ⇧⌘M, ⇧⌘L, ⌥↑/↓, Lyrics Source ›) · Window (system + "QTube Music" ⌘0) ·
//   Help (Keyboard Shortcuts ⌘/).
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

        // File: New Playlist ⌘N (like Music) and Close Window ⌘W; no document model, so no Open/Print.
        // (An empty File menu makes SwiftUI drop it and move Close into the Window menu.)
        CommandGroup(replacing: .newItem) {
            Button(QTLoc.tr("New Playlist…", table: .main)) {
                bringUpBrowsing()
                QTPlaylistActions.newPlaylist(model: model)
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(replacing: .saveItem) {
            Button(QTLoc.tr("Close Window", table: .desktop)) { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: .command)
        }
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
            Button(QTLoc.tr(model.isPanelShown ? "Hide Panel" : "Show Panel", table: .desktop)) { model.isPanelShown.toggle() }
                .keyboardShortcut("n", modifiers: [.command, .option])
            // An inline picker brings its own separators — no Divider next to it (that doubled them).
            Picker(QTLoc.tr("Panel", table: .desktop), selection: Binding(get: { model.panelTab }, set: { tab in
                model.panelTab = tab
                model.isPanelShown = true
            })) {
                Text(QTLoc.tr("Now Playing")).tag(QTPanelTab.nowPlaying)
                Text(QTLoc.tr("Queue")).tag(QTPanelTab.queue)
            }
            .pickerStyle(.inline)
            ForEach(Array(Self.sidebarShortcutOrder.enumerated()), id: \.offset) { index, item in
                section(item, title: QTSidebarView.title(for: item), key: KeyEquivalent(Character("\(index + 1)")))
            }
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
            Button(QTLoc.tr(player.isPlaybackRequested ? "Pause" : "Play")) { player.togglePlayPause() }
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
            // A setting for everything that plays, so it stays available with nothing playing (and through ads,
            // which play at 1× regardless).
            Menu(QTLoc.tr("Playback Speed", table: .player)) {
                QTPlaybackSpeedMenuContent(player: player, showsShortcuts: true)
            }
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
            // The same choices as the lyrics options popover: Automatic, the versions found, No Lyrics for This Song,
            // Report Wrong Lyrics.
            Menu(QTLoc.tr("Lyrics Source", table: .lyrics)) {
                QTLyricsSourceMenu(model: model)
            }
            .disabled(player.nowPlaying == nil)
        }

        // Account (like Music's): who you are, the brand accounts to switch to, Sync, Settings › Account.
        CommandMenu(QTLoc.tr("Account", table: .desktop)) {
            QTAccountMenuContent(model: model)
        }

        // Window: the main window scene lists itself with ⌘0 (set on the scene in the app target); bringing it
        // back leaves the mini player (QTDesktopCoordinator observes the window becoming key).

        // Help
        CommandGroup(replacing: .help) {
            Button(QTLoc.tr("Keyboard Shortcuts", table: .desktop)) { openWindow(id: QTKeyboardShortcutsView.sceneID) }
                .keyboardShortcut("/", modifiers: .command)
        }
    }

    /// ⌘1… follow the sidebar from the top: Home, Explore, then Library (Songs, Albums, Artists, Liked Songs,
    /// History, Uploads). Playlists have no number.
    static let sidebarShortcutOrder: [QTSidebarItem] = [.home, .explore, .songs, .albums, .artists, .liked, .history,
                                                        .uploads]

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
/// The Account menu: the signed-in name, the brand accounts to act as (checked = in use), Sync, Account Settings….
struct QTAccountMenuContent: View {
    let model: QTAppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let store = QTLiveCatalogStore.shared
        let auth = store.auth
        if auth.isSignedIn {
            Text(verbatim: auth.account?.name ?? QTLoc.tr("YouTube Music", table: .desktop))
            if store.identities.count > 1 {
                Picker(QTLoc.tr("Account", table: .desktop), selection: Binding(
                    get: { store.switchingIdentity?.id ?? auth.brandAccountId ?? "primary" },
                    set: { id in
                        guard let target = store.identities.first(where: { $0.id == id }) else { return }
                        Task { await store.switchIdentity(to: target) }
                    })) {
                    ForEach(store.identities) { identity in
                        Text(verbatim: QTIdentityPicker.title(identity, among: store.identities)).tag(identity.id)
                    }
                }
                .pickerStyle(.inline)
                .disabled(store.switchingIdentity != nil)
            }
            Divider()
            Toggle(QTLoc.tr("Sync Likes and Playlists", table: .desktop), isOn: Binding(
                get: { model.settings.settings.syncsToYouTubeMusic },
                set: { on in QTAccountWriter.shared.setSync(on) }))
        } else {
            Button(QTLoc.tr("Sign In…", table: .desktop)) { store.signIn() }
                .disabled(auth.state == .signingIn || store.mode == .mock)
        }
        Divider()
        Button(QTLoc.tr("Account Settings…", table: .desktop)) {
            QTSettingsNavigation.shared.open(.account, with: openSettings)
        }
    }
}

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
                Row(title: QTLoc.tr("Speed Up", table: .player), keys: "⌥⌘."),
                Row(title: QTLoc.tr("Slow Down", table: .player), keys: "⌥⌘,"),
                Row(title: QTLoc.tr("Normal Speed", table: .player), keys: "⌥⌘0"),
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
            ] + QTCommands.sidebarShortcutOrder.enumerated().map { i, item in
                Row(title: QTSidebarView.title(for: item), keys: "⌘\(i + 1)")
            } + [
                Row(title: QTLoc.tr("New Playlist…", table: .main), keys: "⌘N"),
                Row(title: QTLoc.tr("Remove from Playlist", table: .main), keys: "⌫"),
                Row(title: QTLoc.tr("Back"), keys: "⌘["),
                Row(title: QTLoc.tr("Forward"), keys: "⌘]"),
                Row(title: QTLoc.tr("Show Panel", table: .desktop), keys: "⌥⌘N"),
                Row(title: QTLoc.tr("Show Main Window"), keys: "⌘0"),
            ]),
        ]
    }

    @Environment(\.openSettings) private var openSettings

    /// Settings › Shortcuts: the ones set, in action order.
    private var globalRows: [Row] {
        let bindings = QTAppModel.shared.settings.settings.globalHotKeys
        return QTGlobalHotKeyAction.allCases.compactMap { action in
            bindings[action].map { Row(title: QTGlobalHotKeys.title(for: action), keys: QTKeyboardLayout.shared.display($0)) }
        }
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
            // Global shortcuts work in any app (Settings › Shortcuts); none until the user sets them.
            Section(QTLoc.tr("Global Shortcuts", table: .desktop)) {
                ForEach(globalRows) { row in
                    LabeledContent(row.title) {
                        Text(verbatim: row.keys)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent(globalRows.isEmpty ? QTLoc.tr("None", table: .desktop) : "") {
                    Button(QTLoc.tr(globalRows.isEmpty ? "Set Up…" : "Edit…", table: .desktop)) {
                        QTSettingsNavigation.shared.open(.shortcuts, with: openSettings)
                    }
                    .accessibilityIdentifier("qt.keyboardShortcuts.global")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 760)
        .accessibilityIdentifier("qt.keyboardShortcuts")
    }
}
