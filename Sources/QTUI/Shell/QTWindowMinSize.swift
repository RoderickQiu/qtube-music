import AppKit

/// Keeps the main window from being dragged smaller than its minimum size, without telling the layout.
///
/// Why not `.frame(minWidth: 960, minHeight: 600)` on the root view, or `NSWindow.contentMinSize`: the split view
/// won't shrink the detail column below about the window's minimum content width, however that minimum is set
/// (measured: a SwiftUI frame, a sibling spacer and a raised `contentMinSize` all do it). In a window narrower than
/// that minimum + the sidebar, showing the sidebar then couldn't shrink the detail column, and the content, the
/// docked panel and the player bar slid past the window's trailing edge for the length of the animation (GitHub #1).
/// So the layout's own minimum stays small (nothing in the window declares one), and this object, standing in front
/// of the window's delegate, only clamps the size while the user drags an edge.
@MainActor
final class QTWindowMinSize: NSObject, NSWindowDelegate {
    private static var keepers: [ObjectIdentifier: QTWindowMinSize] = [:]

    static func keep(_ size: CGSize, on window: NSWindow) {
        guard keepers[ObjectIdentifier(window)] == nil else { return }
        let keeper = QTWindowMinSize(size, inner: window.delegate)
        keepers[ObjectIdentifier(window)] = keeper
        window.delegate = keeper
    }

    private let size: CGSize
    /// The delegate SwiftUI installed; everything else goes to it.
    private weak var inner: (any NSWindowDelegate)?

    private init(_ size: CGSize, inner: (any NSWindowDelegate)?) {
        self.size = size
        self.inner = inner
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        var proposed = frameSize
        if let inner, inner.responds(to: #selector(NSWindowDelegate.windowWillResize(_:to:))) {
            proposed = inner.windowWillResize?(sender, to: frameSize) ?? frameSize
        }
        let minFrame = sender.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        return NSSize(width: max(proposed.width, minFrame.width), height: max(proposed.height, minFrame.height))
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (inner?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if let inner, inner.responds(to: selector) { return inner }
        return super.forwardingTarget(for: selector)
    }
}
