import AppKit
import Observation
import QTCore
import SwiftUI

// Owner: builder "desktop". Keeps the window-less surfaces in sync with `QTAppModel`: the mini player panel,
// the click-through desktop lyrics overlay, the menu bar popover debug host, the Dock menu and the main-window
// show/hide that goes with the mini player. Nothing here activates the app on its own; only user actions do
// (e.g. "Show Main Window").

/// Launch arguments owned by the desktop area (session-only, never persisted). Listed in the desktop report.
public enum QTDesktopLaunchKey {
    /// `compact` | `art` — mini player mode.
    public static let miniMode = "qt.desktop.miniMode"
    /// bool — show the mini player's lyric line.
    public static let miniLyric = "qt.desktop.miniLyric"
    /// bool — draw the mini player as if hovered (screenshots of the hover controls).
    public static let miniHover = "qt.desktop.miniHover"
    /// bool — desktop lyrics unlocked (move mode).
    public static let lyricsUnlocked = "qt.desktop.lyricsUnlocked"
    /// bool — scroll the menu bar title.
    public static let menuBarScroll = "qt.desktop.menuBarScroll"
    /// `general` | `playback` | `lyrics` | `account` | `integrations` | `shortcuts` | `advanced` — Settings tab to open on.
    public static let settingsTab = "qt.settingsTab"
    /// Desktop lyrics size in points (screenshots).
    public static let lyricsSize = "qt.desktop.lyricsSize"
    /// DEBUG: `en-US` | `zh-CN` — switch the interface language 3 s after launch (tests live switching).
    public static let switchLanguage = "qt.desktop.switchLanguage"
    /// DEBUG: index of a main-menu item (e.g. `4` = Controls) to pop up on the test display once ready (screenshots).
    public static let popUpMenu = "qt.desktop.popUpMenu"
    /// DEBUG: bool — open Help › Keyboard Shortcuts at launch (screenshots).
    public static let showShortcuts = "qt.desktop.showShortcuts"
    /// DEBUG: bool — Settings › General shows Relaunch as if the system menus were in another language (screenshots).
    public static let staleMenus = "qt.desktop.staleMenus"
    /// DEBUG: path — run the AppleScript self-test (`QTScriptingProbe`) once ready and write its results there.
    public static let scriptProbe = "qt.desktop.scriptProbe"
    /// DEBUG: `suggested` — Settings › Shortcuts starts with the suggested set (session only; screenshots).
    public static let hotKeys = "qt.desktop.hotKeys"
    /// DEBUG: comma list of actions (`like`, `playPause`…) whose shortcut shows as used by another app (screenshots).
    public static let hotKeyTaken = "qt.desktop.hotKeyTaken"
    /// DEBUG: bool — register global shortcuts even in a launch with `-qt.*` arguments (those never do otherwise).
    public static let registerHotKeys = "qt.desktop.registerHotKeys"
}

@MainActor
public final class QTDesktopCoordinator {
    public static let shared = QTDesktopCoordinator()

    private(set) var model: QTAppModel?
    private var miniPanel: QTMiniPlayerPanel?
    private var lyricsPanel: QTDesktopLyricsPanel?
    private var menuBarPreview: QTPreviewPanel?
    private var observers: [NSObjectProtocol] = []
    /// SwiftUI's `openWindow`, captured from a scene so AppKit paths (Dock, reopen) can bring the main window back.
    private var openWindowAction: OpenWindowAction?

    /// Marquee clock for the menu bar title.
    public let menuBarTicker = QTMenuBarTicker()

    public func start(model: QTAppModel) {
        guard self.model == nil else { return }
        self.model = model
        applyLaunchOverrides(model)
        QTInterfaceLanguageSync.syncAtLaunch(launch: model.launch)
        QTKeyRouting.install { [weak model] in
            guard let player = model?.player, player.nowPlaying != nil else { return }
            player.togglePlayPause()
        }
        observeMainWindowClose()
        observeMainWindowKey()
        observeMainWindowFrame()
        observe()
        observeScreens()
        QTIntegrationsCoordinator.shared.start(model: model)
        QTGlobalHotKeys.shared.start(model: model)
        if model.launch.surface == .mini { hideMainWindowAfterLaunch() }
        #if DEBUG
        if let lang = model.launch.string(QTDesktopLaunchKey.switchLanguage).flatMap(QTInterfaceLanguage.init(argument:)) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                model.settings.override { $0.interfaceLanguage = lang }
            }
        }
        if model.launch.bool(QTDesktopLaunchKey.showShortcuts) == true {
            Task { @MainActor in
                for _ in 0..<50 where openWindowAction == nil { try? await Task.sleep(for: .milliseconds(100)) }
                openWindowAction?(id: QTKeyboardShortcutsView.sceneID)
                try? await Task.sleep(for: .milliseconds(300))
                if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.contains(QTKeyboardShortcutsView.sceneID) == true }) {
                    QTWindowPlacement.center(w, screenName: model.launch.effectiveScreenName)
                }
            }
        }
        if let path = model.launch.string(QTDesktopLaunchKey.scriptProbe) {
            Task { @MainActor in
                while !QTReadiness.shared.isReady { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(500))
                await QTScriptingProbe.run(writingTo: path)
            }
        }
        if let index = model.launch.double(QTDesktopLaunchKey.popUpMenu).map(Int.init) {
            Task { @MainActor in
                while !QTReadiness.shared.isReady { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(300))
                guard let menu = NSApp.mainMenu, menu.items.indices.contains(index), let sub = menu.items[index].submenu,
                      let screen = QTWindowPlacement.screen(named: model.launch.effectiveScreenName) ?? NSScreen.main else { return }
                let v = screen.visibleFrame
                sub.popUp(positioning: nil, at: NSPoint(x: v.minX + 120, y: v.maxY - 60), in: nil)
            }
        }
        #endif
    }

    /// `-qt.surface mini` (the prototype's "desktop" surface): no main window, like after ⇧⌘M. Waits for the window
    /// to appear first so its launch work (playback, readiness) runs as usual.
    private func hideMainWindowAfterLaunch() {
        isLaunchingIntoMini = true
        Task { @MainActor in
            defer { isLaunchingIntoMini = false }
            for _ in 0..<100 {
                if let w = mainWindow, w.isVisible {
                    try? await Task.sleep(for: .milliseconds(200))
                    if model?.surface == .mini { w.orderOut(nil) }
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// True while a `-qt.surface mini` launch waits to hide the main window. If the app is activated meanwhile
    /// (a Dock click, `open` without -g, a script), the window SwiftUI just opened becomes key — that is not the
    /// user asking for the window, so it must not end the mini player (which used to be ordered out: the launch
    /// showed neither the mini player nor, after the hide, any window: onScreen=false).
    private var isLaunchingIntoMini = false

    /// Called from scenes (Commands, menu bar label) so AppKit code paths can reopen the main window.
    public func register(openWindow: OpenWindowAction) {
        openWindowAction = openWindow
    }

    // MARK: Launch overrides

    private func applyLaunchOverrides(_ model: QTAppModel) {
        let l = model.launch
        model.settings.override { s in
            if let m = l.string(QTDesktopLaunchKey.miniMode).flatMap(QTMiniPlayerMode.init(rawValue:)) { s.miniPlayer.mode = m }
            if let v = l.bool(QTDesktopLaunchKey.miniLyric) { s.miniPlayer.showsLyricLine = v }
            if let v = l.bool(QTDesktopLaunchKey.lyricsUnlocked) { s.desktopLyrics.isLocked = !v }
            if let v = l.bool(QTDesktopLaunchKey.menuBarScroll) { s.menuBarScrollsTitle = v }
            if let v = l.double(QTDesktopLaunchKey.lyricsSize) { s.desktopLyrics.fontSize = v }
        }
    }

    var forcesMiniHover: Bool { model?.launch.bool(QTDesktopLaunchKey.miniHover) ?? false }

    // MARK: Observation

    private func observe() {
        withObservationTracking {
            sync()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func sync() {
        guard let model else { return }
        let settings = model.settings.settings
        let extra = model.launch.extraWindows
        let screenName = model.launch.screen ?? model.launch.effectiveScreenName

        // Mini player
        let showMini = model.surface == .mini || extra.contains(.mini)
        if showMini {
            let panel = miniPanel ?? makeMiniPanel(model: model, screenName: screenName)
            panel.apply(mode: settings.miniPlayer.mode, showsLyricLine: settings.miniPlayer.showsLyricLine)
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else {
            miniPanel?.orderOut(nil)
        }

        // Desktop lyrics: hidden while the Stage is up, in the main window or detached on another display.
        let showLyrics = settings.desktopLyrics.isShown && model.surface != .stage && !QTStageCoordinator.shared.isDetached
        if showLyrics {
            let panel = lyricsPanel ?? makeLyricsPanel(model: model)
            panel.apply(prefs: settings.desktopLyrics, preferredScreenName: screenName, avoiding: visibleMainWindowFrame)
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else {
            lyricsPanel?.orderOut(nil)
        }

        // Debug host for the menu bar popover (a MenuBarExtra can't be opened without a click).
        if extra.contains(.menuBarPopover) {
            if menuBarPreview == nil { menuBarPreview = makeMenuBarPreview(model: model, screenName: screenName) }
            menuBarPreview?.orderFrontRegardless()
            if let p = menuBarPreview { placeMenuBarPreview(p, screenName: screenName) }
        }

        // Menu bar marquee only runs when it has something to do.
        let title = model.player.nowPlaying.map { QTMenuBarLabel.titleLine(for: $0) }
        menuBarTicker.configure(text: settings.showsTitleInMenuBar ? title : nil,
                                scrolls: settings.menuBarScrollsTitle && model.player.isPlaying)
    }

    // MARK: Mini player

    private func makeMiniPanel(model: QTAppModel, screenName: String?) -> QTMiniPlayerPanel {
        let root = QTMiniPlayerView()
            .environment(model)
            .environment(model.player)
        let prefs = model.settings.settings.miniPlayer
        let panel = QTMiniPlayerPanel(content: root, mode: prefs.mode, showsLyricLine: prefs.showsLyricLine)
        let screen = QTWindowPlacement.screen(named: screenName) ?? mainWindow?.screen ?? NSScreen.main
        panel.restoreFrame(on: screen, mode: model.settings.settings.miniPlayer.mode)
        miniPanel = panel
        return panel
    }

    /// ⇧⌘M: switch between the main window and the mini player (the main window steps aside, like Music.app).
    public func toggleMiniPlayer() {
        guard let model else { return }
        if model.surface == .mini { showMainWindow() } else { enterMiniPlayer() }
    }

    public func enterMiniPlayer() {
        guard let model else { return }
        model.surface = .mini
        mainWindow?.orderOut(nil)
    }

    /// Closes the mini player without bringing the main window back (music keeps playing; the Dock, ⌘0 and the
    /// menu bar item reopen it).
    public func closeMiniPlayer() {
        guard let model else { return }
        if model.surface == .mini { model.surface = .window }
        miniPanel?.orderOut(nil)
    }

    /// Double-click / context menu: compact strip ⇄ square artwork.
    public func toggleMiniMode() {
        guard let model else { return }
        let next: QTMiniPlayerMode = model.settings.settings.miniPlayer.mode == .compact ? .art : .compact
        model.settings.update { $0.miniPlayer.mode = next }
    }

    // MARK: Main window

    var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier == QTWindowID.main.identifier }
    }

    /// User-initiated: leaves the mini player and brings the main window forward.
    /// - Parameter activate: false only for DEBUG acceptance hooks (reopen the window without taking focus).
    public func showMainWindow(activate: Bool = true) {
        guard let model else { return }
        if model.surface == .mini { model.surface = .window }
        if let window = mainWindow {
            if activate { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
        } else {
            openWindowAction?(id: QTWindowID.main.sceneID)
        }
        if activate { NSApp.activate() }
    }

    private func observeMainWindowKey() {
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            QTMainActorHop.onMainThread {
                // ⌘0 / Window › QTube Music / Dock click while in the mini player: back to the window.
                let c = QTDesktopCoordinator.shared
                guard window?.identifier == QTWindowID.main.identifier,
                      let model = c.model, model.surface == .mini else { return }
                // hideMainWindowAfterLaunch orders it out in a moment.
                guard !c.isLaunchingIntoMini else { return }
                model.surface = .window
            }
        })
    }

    private func observeMainWindowClose() {
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            QTMainActorHop.onMainThread {
                guard window?.identifier == QTWindowID.main.identifier,
                      let model = QTDesktopCoordinator.shared.model else { return }
                if !model.settings.settings.closeWindowKeepsPlaying {
                    NSApp.terminate(nil)
                } else if model.surface == .stage {
                    model.surface = .window
                }
            }
        })
    }

    // MARK: Desktop lyrics

    private func makeLyricsPanel(model: QTAppModel) -> QTDesktopLyricsPanel {
        let root = QTDesktopLyricsView()
            .environment(model)
            .environment(model.player)
        let panel = QTDesktopLyricsPanel(content: root)
        panel.onMoved = { [weak model] prefs in
            model?.settings.update {
                $0.desktopLyrics.verticalPosition = prefs.verticalPosition
                $0.desktopLyrics.horizontalOffset = prefs.horizontalOffset
                $0.desktopLyrics.screenName = prefs.screenName
            }
        }
        lyricsPanel = panel
        return panel
    }

    /// The main window's frame while it is on screen (desktop lyrics keep out of its way by default).
    var visibleMainWindowFrame: NSRect? {
        guard let w = mainWindow, w.isVisible, !w.isMiniaturized, model?.surface != .mini else { return nil }
        return w.frame
    }

    /// Main window moved, resized, minimised or came back: re-place the overlay if it sits at its default spot.
    private func observeMainWindowFrame() {
        let names: [Notification.Name] = [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification,
                                          NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                                          NSWindow.didChangeOcclusionStateNotification]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                let window = note.object as? NSWindow
                QTMainActorHop.onMainThread {
                    let c = QTDesktopCoordinator.shared
                    guard window?.identifier == QTWindowID.main.identifier, let model = c.model,
                          let panel = c.lyricsPanel, panel.isVisible else { return }
                    let screenName = model.launch.screen ?? model.launch.effectiveScreenName
                    panel.apply(prefs: model.settings.settings.desktopLyrics, preferredScreenName: screenName,
                                avoiding: c.visibleMainWindowFrame)
                }
            })
        }
    }

    public func toggleDesktopLyrics() {
        model?.isDesktopLyricsShown.toggle()
    }

    /// Unlocked = the overlay takes the mouse so it can be dragged; locked = click-through.
    public func setDesktopLyricsLocked(_ locked: Bool) {
        guard let model else { return }
        if !locked { model.isDesktopLyricsShown = true }
        model.settings.update { $0.desktopLyrics.isLocked = locked }
    }

    public func resetDesktopLyricsPosition() {
        model?.settings.update {
            let d = QTDesktopLyricsPrefs()
            $0.desktopLyrics.verticalPosition = d.verticalPosition
            $0.desktopLyrics.horizontalOffset = d.horizontalOffset
            $0.desktopLyrics.screenName = nil
        }
    }

    public func nudgeDesktopLyricsSize(by delta: Double) {
        model?.settings.update {
            $0.desktopLyrics.fontSize = min(QTDesktopLyricsPanel.sizeRange.upperBound,
                                            max(QTDesktopLyricsPanel.sizeRange.lowerBound, $0.desktopLyrics.fontSize + delta))
        }
    }

    // MARK: Menu bar popover preview

    private func makeMenuBarPreview(model: QTAppModel, screenName: String?) -> QTPreviewPanel {
        let root = QTMenuBarContent()
            .environment(model)
            .environment(model.player)
        let panel = QTDesktopPanels.makePreviewPanel(id: .menuBarPopover, content: root)
        // The hosting controller sizes the panel after the first layout (and again when the lyric section
        // collapses), so re-anchor on every size change instead of once at creation.
        panel.onSizeChange = { [weak panel] in
            guard let panel else { return }
            QTDesktopCoordinator.shared.placeMenuBarPreview(panel, screenName: screenName)
        }
        placeMenuBarPreview(panel, screenName: screenName)
        return panel
    }

    /// Like the real menu bar extra window: hangs under the status item when it is on that display, otherwise
    /// under the menu bar at the trailing edge; always inside the display's visible frame.
    func placeMenuBarPreview(_ panel: NSWindow, screenName: String?) {
        guard let screen = QTWindowPlacement.screen(named: screenName) ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        let size = panel.frame.size
        let statusItem = NSApp.windows.first { w in
            w !== panel && w.className.contains("StatusBarWindow") && w.isVisible && w.screen == screen
        }
        var origin: NSPoint
        if let item = statusItem?.frame {
            origin = NSPoint(x: item.midX - size.width / 2, y: item.minY - 5 - size.height)
        } else {
            origin = NSPoint(x: v.maxX - size.width - 12, y: v.maxY - 5 - size.height)
        }
        origin.x = min(max(origin.x, v.minX + 8), v.maxX - size.width - 8)
        origin.y = min(max(origin.y, v.minY + 8), v.maxY - size.height)
        let frame = NSRect(origin: origin, size: size).integral
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    // MARK: Screens

    private func observeScreens() {
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { _ in
            QTMainActorHop.onMainThread {
                let c = QTDesktopCoordinator.shared
                // DEBUG: the dev/scripted run's display went away → quit rather than sit on the user's screen.
                if let launch = c.model?.launch { QTScreenGuard.screensChanged(launch) }
                c.miniPanel?.clampToScreen()
                if let model = c.model, let panel = c.lyricsPanel, panel.isVisible {
                    panel.apply(prefs: model.settings.settings.desktopLyrics, preferredScreenName: model.launch.screen,
                                avoiding: c.visibleMainWindowFrame, force: true)
                }
            }
        })
    }

    // MARK: Dock menu

    public func dockMenu() -> NSMenu {
        QTDockMenuBuilder.menu(model: model)
    }
}

/// Shared AppKit plumbing for the floating panels.
@MainActor
enum QTDesktopPanels {
    /// A system-material panel hosting `content`, resizing with it (used for the menu bar popover debug host).
    static func makePreviewPanel<Content: View>(id: QTWindowID, content: Content) -> QTPreviewPanel {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let root = content
            .background(QTPanelGlassBackground(cornerRadius: 14))
            .clipShape(shape)
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = [.preferredContentSize]
        let panel = QTPreviewPanel(contentRect: NSRect(origin: .zero, size: controller.view.fittingSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentViewController = controller
        panel.identifier = id.identifier
        panel.title = id.captureTitle
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        return panel
    }
}

/// Borderless panel that reports size changes however they happen (the hosting controller resizes it through
/// `setContentSize`, which doesn't always post `didResizeNotification` before the first display).
final class QTPreviewPanel: NSPanel {
    var onSizeChange: (@MainActor () -> Void)?
    private var isReporting = false

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        let old = frame.size
        super.setFrame(frameRect, display: flag)
        report(from: old)
    }

    override func setContentSize(_ size: NSSize) {
        let old = frame.size
        super.setContentSize(size)
        report(from: old)
    }

    private func report(from old: NSSize) {
        guard frame.size != old, !isReporting else { return }
        isReporting = true
        onSizeChange?()
        isReporting = false
    }
}

/// Hosting view that takes the first click even when the app is inactive (non-activating panels).
final class QTFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Mouse enter/exit tracking that works in non-key panels of an inactive app (SwiftUI's `onHover` doesn't
/// always fire there). Doesn't take part in hit testing.
struct QTHoverTracking: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> QTHoverTrackingView {
        let v = QTHoverTrackingView()
        v.onChange = onChange
        return v
    }

    func updateNSView(_ nsView: QTHoverTrackingView, context: Context) {
        nsView.onChange = onChange
    }
}

final class QTHoverTrackingView: NSView {
    var onChange: (@MainActor (Bool) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { onChange?(true) }
    override func mouseExited(with event: NSEvent) { onChange?(false) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
