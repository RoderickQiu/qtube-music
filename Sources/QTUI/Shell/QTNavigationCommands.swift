import AppKit
import QTCore
import SwiftUI

/// Menu commands for the main window's navigation (draft §8 keys): ⌘1–4 sections, ⌘[ / ⌘] back/forward,
/// ⌘K search, ⌘F filter. Add next to `QTCommands` in the app's `.commands { }`.
public struct QTNavigationCommands: Commands {
    private let model: QTAppModel

    public init(model: QTAppModel) {
        self.model = model
    }

    public var body: some Commands {
        let navigator = QTNavigator.shared
        CommandGroup(before: .sidebar) {
            Button(QTLoc.tr("Home")) { show(.home) }
                .keyboardShortcut("1", modifiers: .command)
            Button(QTLoc.tr("Explore")) { show(.explore) }
                .keyboardShortcut("2", modifiers: .command)
            Button(QTLoc.tr("Songs")) { show(.songs) }
                .keyboardShortcut("3", modifiers: .command)
            Button(QTLoc.tr("Liked Songs")) { show(.liked) }
                .keyboardShortcut("4", modifiers: .command)
            Divider()
            Button(QTLoc.tr("Back")) { navigator.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!navigator.canGoBack)
            Button(QTLoc.tr("Forward")) { navigator.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!navigator.canGoForward)
            Divider()
        }
        CommandGroup(after: .textEditing) {
            Button(QTLoc.tr("Search music")) {
                surfaceToWindow()
                navigator.requestSearchFocus()
            }
            .keyboardShortcut("k", modifiers: .command)
            Button(QTLoc.tr("Filter")) { focusFilter() }
                .keyboardShortcut("f", modifiers: .command)
        }
    }

    @MainActor
    private func show(_ item: QTSidebarItem) {
        surfaceToWindow()
        QTNavigator.shared.go(.section(item))
    }

    @MainActor
    private func surfaceToWindow() {
        if model.surface == .stage { model.surface = .window }
    }

    /// ⌘F: the current list's filter field; from a page without one, Liked Songs (prototype behaviour).
    @MainActor
    private func focusFilter() {
        surfaceToWindow()
        let navigator = QTNavigator.shared
        if !model.searchText.isEmpty || QTTrackCollection.listKey(for: navigator.current) == nil
            || navigator.current == .section(.history) {
            navigator.go(.section(.liked))
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                navigator.requestFilterFocus()
            }
        } else {
            navigator.requestFilterFocus()
        }
    }
}
