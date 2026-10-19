import QTCore
import QTUI
import SwiftUI

// Owner: builder "desktop" (app icon, dock menu, AppleScript, Sparkle later). Scenes: main Window, Settings,
// MenuBarExtra. Launch paths must never activate the app (no NSApp.activate) — see docs/architecture.md.

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
        .commands {
            QTCommands(model: model)
            QTNavigationCommands(model: model)
        }

        Settings {
            QTSettingsView()
                .environment(model)
                .environment(model.player)
        }

        MenuBarExtra(isInserted: Binding(get: { model.settings.settings.showsTitleInMenuBar }, set: { _ in })) {
            QTMenuBarContent()
                .environment(model)
                .environment(model.player)
        } label: {
            QTMenuBarLabel()
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !QTAppModel.shared.settings.settings.closeWindowKeepsPlaying
    }
}
