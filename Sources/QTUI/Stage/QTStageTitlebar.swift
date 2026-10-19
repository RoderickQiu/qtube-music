import AppKit

/// Keeps a real Mac title bar over the in-window Stage: the traffic lights stay where they belong, on the
/// window's own (transparent, full-size-content) title bar, while the browsing toolbar items — back/forward,
/// search, sidebar and inspector toggles — step aside.
///
/// How: the window keeps SwiftUI's toolbar, untouched (so its height, the lights' position and everything the
/// split view and inspector attach to it stay consistent). While the Stage is up every toolbar item is hidden
/// with `NSToolbarItem.isHidden` (macOS 15), including items SwiftUI adds later (the inspector's, a rebuilt
/// search field) — `NSToolbar.willAddItemNotification` catches those. On close exactly the items it hid come
/// back. An earlier version swapped in an empty `NSToolbar`; the inspector then attached its tracking separator to
/// a foreign toolbar and showing the panel under the Stage looped AppKit's constraint pass until it crashed.
@MainActor
final class QTStageTitlebar {
    private weak var window: NSWindow?
    /// Items this title bar hid (and so must show again), by identity.
    private var hiddenItems: [ObjectIdentifier: NSToolbarItem] = [:]
    private var observers: [NSObjectProtocol] = []
    private var toolbarObservation: NSKeyValueObservation?

    private(set) var isInstalled = false

    /// Hides the browsing toolbar items of `window` (no-op for a window without a title bar).
    func install(in window: NSWindow) {
        guard window.styleMask.contains(.titled) else { return }
        if isInstalled, self.window === window {
            hideItems()
            return
        }
        uninstall()
        self.window = window
        isInstalled = true
        hideItems()
        observers.append(NotificationCenter.default.addObserver(forName: NSToolbar.willAddItemNotification, object: nil,
                                                                queue: .main) { [weak self] note in
            let toolbar = note.object as? NSToolbar
            let item = note.userInfo?["item"] as? NSToolbarItem
            MainActor.assumeIsolated {
                guard let self, self.isInstalled, let toolbar, toolbar === self.window?.toolbar, let item else { return }
                self.hide(item)
            }
        })
        // SwiftUI may install a whole new toolbar (rebuilds); hide that one's items too.
        toolbarObservation = window.observe(\.toolbar, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.hideItems() }
        }
    }

    /// Shows exactly the items it hid.
    func uninstall() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        toolbarObservation?.invalidate()
        toolbarObservation = nil
        for item in hiddenItems.values { item.isHidden = false }
        hiddenItems = [:]
        isInstalled = false
        window = nil
    }

    private func hideItems() {
        guard isInstalled, let items = window?.toolbar?.items else { return }
        items.forEach(hide)
    }

    private func hide(_ item: NSToolbarItem) {
        guard !item.isHidden else { return }
        item.isHidden = true
        hiddenItems[ObjectIdentifier(item)] = item
    }

    /// Centre of the traffic lights, in points from the top of the window (nil when there are none).
    static func trafficLightsMidY(in window: NSWindow) -> CGFloat? {
        guard let close = window.standardWindowButton(.closeButton), !close.isHiddenOrHasHiddenAncestor,
              let content = window.contentView else { return nil }
        let frame = close.convert(close.bounds, to: nil)
        return content.frame.height - frame.midY
    }
}
