import AppKit

/// Keeps a real Mac title bar over the in-window Stage: the traffic lights stay where they belong, on a
/// transparent full-size-content title bar, while the browsing toolbar (search, back/forward) steps aside.
///
/// The main window hides its toolbar while the Stage is up (`.toolbar(.hidden, for: .windowToolbar)` in Shell/),
/// which in SwiftUI also hides the window controls. On appear the Stage swaps in an empty unified toolbar (so the
/// title bar keeps its 52 pt height and the lights line up with the Stage's top bar) and shows the title bar
/// again; on disappear it hands the original toolbar back.
@MainActor
final class QTStageTitlebar {
    private weak var window: NSWindow?
    private var savedToolbar: NSToolbar?
    private var savedStyle: NSWindow.ToolbarStyle = .automatic
    private let stageToolbar: NSToolbar = {
        let toolbar = NSToolbar(identifier: "qt.stage.titlebarToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }()

    private(set) var isInstalled = false

    /// Installs the Stage title bar in `window` (no-op in full screen or for a borderless window).
    func install(in window: NSWindow) {
        guard window.styleMask.contains(.titled) else { return }
        if isInstalled, self.window === window {
            revealControls()
            return
        }
        uninstall()
        self.window = window
        savedToolbar = window.toolbar
        savedStyle = window.toolbarStyle
        window.toolbar = stageToolbar
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        isInstalled = true
        revealControls()
    }

    /// Restores the window's own toolbar.
    func uninstall() {
        guard isInstalled, let window else { isInstalled = false; return }
        if window.toolbar === stageToolbar {
            window.toolbar = savedToolbar
            window.toolbarStyle = savedStyle
        }
        savedToolbar = nil
        isInstalled = false
        self.window = nil
    }

    /// The SwiftUI toolbar modifier hides the whole title bar container; bring back the window controls.
    func revealControls() {
        guard let window, let container = Self.titlebarContainer(of: window) else { return }
        if container.isHidden { container.isHidden = false }
    }

    static func titlebarContainer(of window: NSWindow) -> NSView? {
        window.standardWindowButton(.closeButton)?.superview?.superview
    }

    /// Centre of the traffic lights, in points from the top of the window (nil when there are none).
    static func trafficLightsMidY(in window: NSWindow) -> CGFloat? {
        guard let close = window.standardWindowButton(.closeButton), !close.isHiddenOrHasHiddenAncestor,
              let content = window.contentView else { return nil }
        let frame = close.convert(close.bounds, to: nil)
        return content.frame.height - frame.midY
    }
}
