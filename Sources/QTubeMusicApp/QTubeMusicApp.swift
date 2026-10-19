import AppKit
import QTCore
import QTUI
import SwiftUI

// Owner: builder "desktop". Scenes: the main Window (⌘0), Settings, Keyboard Shortcuts, and the MenuBarExtra.
// The app delegate adds the Dock menu, reopen handling, the desktop surfaces and AppleScript's application
// properties; the app menu gets Check for Updates… (Sparkle, QTUpdater.swift). Launch paths never activate the
// app (no NSApp.activate) — see docs/architecture.md.

@main
struct QTubeMusicApp: App {
    @NSApplicationDelegateAdaptor(QTAppDelegate.self) private var appDelegate
    @State private var model = QTAppModel.shared

    var body: some Scene {
        Window("QTube Music", id: QTWindowID.main.sceneID) {
            QTMainWindowView()
                .environment(model)
                .environment(model.player)
        }
        .defaultSize(QTTheme.Metrics.defaultWindow)
        .windowToolbarStyle(.unified)
        .keyboardShortcut("0", modifiers: .command)
        .commands {
            SidebarCommands()
            QTCommands(model: model)
            QTUpdaterCommands(updater: QTUpdater.shared)
        }

        Settings {
            QTSettingsView()
                .environment(model)
                .environment(model.player)
        }

        Window(QTLoc.tr("Keyboard Shortcuts", table: .desktop), id: QTKeyboardShortcutsView.sceneID) {
            QTKeyboardShortcutsView()
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .commandsRemoved() // opened from Help › Keyboard Shortcuts, not listed in the Window menu

        MenuBarExtra {
            QTMenuBarContent()
                .environment(model)
                .environment(model.player)
        } label: {
            QTMenuBarLabel()
                .environment(model)
                .environment(model.player)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class QTAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = QTAppModel.shared
        model.applyAppearance()
        QTDesktopCoordinator.shared.start(model: model)
        QTUpdater.shared.start()
    }

    /// Closing the main window keeps music playing (menu bar, Dock and mini player stay); the "quit instead"
    /// setting is handled when the main window closes (QTDesktopCoordinator).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with no main window brings it back (and leaves the mini player).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let coordinator = QTDesktopCoordinator.shared
        if QTAppModel.shared.surface == .mini || !(NSApp.windows.contains { $0.identifier == QTWindowID.main.identifier && $0.isVisible }) {
            coordinator.showMainWindow()
            return false
        }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        QTDesktopCoordinator.shared.dockMenu()
    }

    // MARK: AppleScript (QTubeMusic.sdef › application properties; Cocoa Scripting reads them through KVC)

    func application(_ sender: NSApplication, delegateHandlesKey key: String) -> Bool {
        QTScripting.handles(key)
    }

    @objc var playerState: NSNumber { QTScripting.playerStateValue }
    @objc var currentTrack: QTScriptTrack? { QTScripting.currentTrack }
    @objc var playerPosition: Double {
        get { QTScripting.playerPosition }
        set { QTScripting.playerPosition = newValue }
    }
    @objc var soundVolume: Int {
        get { QTScripting.soundVolume }
        set { QTScripting.soundVolume = newValue }
    }
}
