import AppKit
import QTCore
import SwiftUI

// Owner: shared. Ends an in-place edit the way Finder and Music do: any click outside the field (content, another
// row, the toolbar, another window) or the window losing key ends it. AppKit alone doesn't: a click on a view that
// won't take first responder (empty content, a plain SwiftUI page) leaves the field editing.

extension View {
    /// Calls `action` once per click outside this view (the click still goes where it was aimed) and when its window
    /// stops being key. Only while `isActive`.
    func qtOnClickOutside(isActive: Bool = true, perform action: @escaping @MainActor () -> Void) -> some View {
        background(QTClickOutsideMonitor(isActive: isActive, action: action).allowsHitTesting(false))
    }
}

struct QTClickOutsideMonitor: NSViewRepresentable {
    var isActive: Bool
    var action: @MainActor () -> Void

    func makeNSView(context: Context) -> QTClickOutsideAnchor {
        let view = QTClickOutsideAnchor()
        view.action = action
        view.isActive = isActive
        return view
    }

    func updateNSView(_ view: QTClickOutsideAnchor, context: Context) {
        view.action = action
        view.isActive = isActive
    }

    static func dismantleNSView(_ view: QTClickOutsideAnchor, coordinator: ()) {
        view.isActive = false
    }

    /// A click (window coordinates) is outside the watched view: in another window, or off its frame in the same one.
    static func isOutside(click point: NSPoint, clickWindow: NSWindow?, frame: NSRect, frameWindow: NSWindow?) -> Bool {
        guard let frameWindow, clickWindow === frameWindow else { return true }
        return !frame.contains(point)
    }
}

/// The view behind the watched one: its frame is the "inside"; it owns the event monitor and the key observer.
final class QTClickOutsideAnchor: NSView {
    var action: (@MainActor () -> Void)?
    var isActive = false { didSet { if isActive != oldValue { refresh() } } }
    // Plain tokens, removed on the main thread (or in deinit, when nothing else can reach them).
    nonisolated(unsafe) private var monitor: Any?
    nonisolated(unsafe) private var resignObserver: NSObjectProtocol?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    private func refresh() {
        stop()
        guard isActive, let window else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            QTMainActorHop.onMainThread { self?.handle(event) }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                                                queue: .main) { [weak self] _ in
            QTMainActorHop.onMainThread { self?.fire() }
        }
    }

    private func handle(_ event: NSEvent) {
        guard isActive, window != nil else { return }
        let frame = convert(bounds, to: nil)
        if QTClickOutsideMonitor.isOutside(click: event.locationInWindow, clickWindow: event.window, frame: frame,
                                           frameWindow: window) {
            fire()
        }
    }

    private func fire() {
        guard isActive else { return }
        action?()
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}
