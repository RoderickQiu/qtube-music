import AppKit
import SwiftUI
import QTCore

/// Stable identifiers for every window the app creates. `rawValue` is the NSWindow identifier;
/// `captureTitle` is the (non-localized) NSWindow title Scripts/shoot.sh matches on.
public enum QTWindowID: String, Sendable, CaseIterable {
    case main = "qt.window.main"
    case miniPlayer = "qt.window.miniPlayer"
    case desktopLyrics = "qt.window.desktopLyrics"
    case menuBarPopover = "qt.window.menuBarPopover"
    case settings = "qt.window.settings"

    /// SwiftUI scene id.
    public var sceneID: String { rawValue }

    public var captureTitle: String {
        switch self {
        case .main: "QTube Music"
        case .miniPlayer: "QTube Music Mini Player"
        case .desktopLyrics: "QTube Music Desktop Lyrics"
        case .menuBarPopover: "QTube Music Menu Bar"
        case .settings: "QTube Music Settings"
        }
    }

    public var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }
}

/// Places windows on the requested display without activating the app.
@MainActor
public enum QTWindowPlacement {
    /// First screen whose name contains `name` (case-insensitive).
    public static func screen(named name: String?) -> NSScreen? {
        guard let name, !name.isEmpty else { return nil }
        return NSScreen.screens.first { $0.localizedName.range(of: name, options: .caseInsensitive) != nil }
    }

    /// Centers `window` on the screen (or keeps its current screen), sized to `size` clamped to the visible frame.
    public static func place(_ window: NSWindow, size: CGSize?, screenName: String?) {
        let target = screen(named: screenName) ?? window.screen ?? NSScreen.main
        guard let visible = target?.visibleFrame else { return }
        let want = size ?? window.frame.size
        let w = min(want.width, visible.width), h = min(want.height, visible.height)
        let frame = NSRect(x: visible.midX - w / 2, y: visible.midY - h / 2, width: w, height: h).integral
        window.setFrame(frame, display: true)
    }

    /// Moves `window` (keeping its size) to the center of the named screen.
    public static func center(_ window: NSWindow, screenName: String?) {
        guard let v = (screen(named: screenName) ?? window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let s = window.frame.size
        window.setFrameOrigin(NSPoint(x: (v.midX - s.width / 2).rounded(), y: (v.midY - s.height / 2).rounded()))
    }

    /// Positions a floating panel near a corner of the requested screen.
    public static func placePanel(_ panel: NSWindow, screenName: String?, corner: QTPanelCorner, inset: CGFloat = 28) {
        let target = screen(named: screenName) ?? NSScreen.main
        guard let v = target?.visibleFrame else { return }
        let s = panel.frame.size
        let origin: NSPoint = switch corner {
        case .bottomRight: NSPoint(x: v.maxX - s.width - inset, y: v.minY + inset)
        case .bottomCenter: NSPoint(x: v.midX - s.width / 2, y: v.minY + inset)
        case .topRight: NSPoint(x: v.maxX - s.width - inset, y: v.maxY - s.height - inset)
        }
        panel.setFrameOrigin(origin)
    }
}

public enum QTPanelCorner: Sendable { case bottomRight, bottomCenter, topRight }

/// Hands the hosting NSWindow to `onWindow` once, when the view lands in a window.
/// Use for identifiers, placement and AppKit-only window settings.
public struct QTWindowAccessor: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void

    public init(onWindow: @escaping @MainActor (NSWindow) -> Void) {
        self.onWindow = onWindow
    }

    public func makeNSView(context: Context) -> NSView { QTWindowAccessorView(onWindow: onWindow) }
    public func updateNSView(_ nsView: NSView, context: Context) {}
}

final class QTWindowAccessorView: NSView {
    private let onWindow: @MainActor (NSWindow) -> Void
    private var delivered = false

    init(onWindow: @escaping @MainActor (NSWindow) -> Void) {
        self.onWindow = onWindow
        super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !delivered else { return }
        delivered = true
        onWindow(window)
    }
}
