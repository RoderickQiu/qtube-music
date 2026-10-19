import AppKit
import QTCore

/// Keeps the docked panel (the `.inspector` column) at one stable width: the design's ideal (384 pt) the first time,
/// then whatever the user last dragged it to (persisted in `qt.window.panelWidth`).
///
/// Why this exists: SwiftUI's `inspectorColumnWidth(ideal:)` reaches AppKit as the split view's preferred-size
/// constraint (`NSSplitView.PreferredSize`, priority 261) only when the inspector's split item is first added. Later
/// updates that make SwiftUI re-set the split view items (the live library streaming in: sidebar playlists, window
/// title, Liked pages) re-add the item *without* it, and the split view then holds whatever width layout lands on —
/// the 320 pt minimum with the user's library, 384 pt with the demo one. So the panel's view gets a width constraint
/// of our own at 262, one above the split view's holding priority for the inspector (261). A divider drag lifts it for
/// the drag (a mouse-down resize of that split view) and adopts the new width on mouse-up. Nothing here is
/// required-priority, so a narrow window still squeezes the panel to its minimum without a constraint conflict (see
/// "No content minimum width" in docs/architecture.md).
@MainActor
final class QTInspectorWidthKeeper {
    static let defaultsKey = "qt.window.panelWidth"
    static let priority = NSLayoutConstraint.Priority(262)
    /// The main window's keeper (there is one main window).
    static var main: QTInspectorWidthKeeper?

    static func attach(to window: NSWindow, launch: QTLaunchOptions) {
        guard main?.window !== window else { return }
        main = QTInspectorWidthKeeper(window: window, launch: launch)
    }

    private weak var window: NSWindow?
    private var constraint: NSLayoutConstraint?
    private var observers: [any NSObjectProtocol] = []
    private var mouseUpMonitor: Any?
    private let defaults: UserDefaults
    /// Dev / screenshot launches (`-qt.screen`, `-qt.window`) always use the design width and never save one.
    private let persists: Bool
    private(set) var width: CGFloat

    init(window: NSWindow, launch: QTLaunchOptions, defaults: UserDefaults = .standard) {
        self.window = window
        self.defaults = defaults
        persists = launch.screen == nil && launch.windowSize == nil
        width = Self.clamped(persists ? defaults.double(forKey: Self.defaultsKey) : 0)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSSplitView.willResizeSubviewsNotification, object: nil, queue: nil) { [weak self] note in
                let splitView = note.object as? NSSplitView
                MainActor.assumeIsolated { self?.splitViewWillResize(splitView) }
            },
            center.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: nil) { [weak self] note in
                let splitView = note.object as? NSSplitView
                MainActor.assumeIsolated { self?.splitViewDidResize(splitView) }
            },
        ]
        // The split view exists once SwiftUI has laid the window out.
        DispatchQueue.main.async { [weak self] in self?.installOnCurrentPanel() }
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
    }

    /// 0 / missing → the design width; anything else within the column's min…max.
    static func clamped(_ stored: Double) -> CGFloat {
        guard stored > 0 else { return QTTheme.Metrics.panelWidth }
        return min(max(CGFloat(stored), QTTheme.Metrics.panelMinWidth), QTTheme.Metrics.panelMaxWidth)
    }

    // MARK: Split view events

    private func panelItem(of splitView: NSSplitView?) -> NSSplitViewItem? {
        guard let window, let splitView, splitView.window === window else { return nil }
        return Self.inspectorItem(of: splitView)
    }

    /// The user is dragging the divider: let go of the width until the mouse comes up.
    private func splitViewWillResize(_ splitView: NSSplitView?) {
        guard mouseUpMonitor == nil, let window, panelItem(of: splitView) != nil,
              NSEvent.pressedMouseButtons & 1 != 0, !window.inLiveResize else { return }
        constraint?.priority = .fittingSizeCompression
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            DispatchQueue.main.async { self?.dragEnded() }
            return event
        }
    }

    private func dragEnded() {
        if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
        mouseUpMonitor = nil
        guard let content = window?.contentView, let item = Self.inspectorItem(in: content) else { return }
        let view = item.viewController.view
        if !item.isCollapsed, view.frame.width > 0 {
            width = Self.clamped(Double(view.frame.width))
            if persists { defaults.set(Double(width), forKey: Self.defaultsKey) }
        }
        install(on: view)
    }

    /// SwiftUI may have handed the split item a new view: follow it. Never touches constraints inside AppKit's layout
    /// pass — the next turn of the run loop is soon enough.
    private func splitViewDidResize(_ splitView: NSSplitView?) {
        guard mouseUpMonitor == nil, let item = panelItem(of: splitView) else { return }
        let view = item.viewController.view
        guard constraint?.firstItem !== view || constraint?.isActive != true else { return }
        DispatchQueue.main.async { [weak self, weak view] in
            if let view { self?.install(on: view) }
        }
    }

    // MARK: Constraint

    private func installOnCurrentPanel() {
        guard let content = window?.contentView, let item = Self.inspectorItem(in: content) else { return }
        install(on: item.viewController.view)
    }

    private func install(on view: NSView) {
        if let constraint, constraint.firstItem === view, constraint.isActive {
            if constraint.constant != width { constraint.constant = width }
            if constraint.priority != Self.priority { constraint.priority = Self.priority }
            return
        }
        constraint?.isActive = false
        let c = view.widthAnchor.constraint(equalToConstant: width)
        c.priority = Self.priority
        c.identifier = "qt.window.panelWidth"
        c.isActive = true
        constraint = c
    }

    // MARK: Finding the inspector

    static func inspectorItem(of splitView: NSSplitView) -> NSSplitViewItem? {
        (splitView.delegate as? NSSplitViewController)?.splitViewItems.first { $0.behavior == .inspector }
    }

    static func inspectorItem(in view: NSView) -> NSSplitViewItem? {
        if let s = view as? NSSplitView, let item = inspectorItem(of: s) { return item }
        for sub in view.subviews {
            if let item = inspectorItem(in: sub) { return item }
        }
        return nil
    }
}
