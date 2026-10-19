import AppKit
import SwiftUI
import QTCore
import os

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
    /// First screen whose name contains `name` (case-insensitive). Logs (once per name) when a named screen isn't
    /// connected; callers then fall back to the window's own screen. A DEBUG launch never gets that far for its
    /// `-qt.screen` display: `QTScreenGuard` refuses the launch, and quits if the display goes away.
    public static func screen(named name: String?) -> NSScreen? {
        guard let name, !name.isEmpty else { return nil }
        if let match = QTScreenGuard.screen(named: name) { return match }
        if !loggedMissing.contains(name) {
            loggedMissing.insert(name)
            QTScreenGuard.log.error("Requested screen “\(name, privacy: .public)” is not connected (connected: \(QTScreenGuard.connectedNames.joined(separator: ", "), privacy: .public))")
        }
        return nil
    }

    private static var loggedMissing: Set<String> = []

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

/// Keeps dev and scripted runs off the user's own display. A DEBUG launch that names a display (`-qt.screen`, or
/// U270CA by default for any `-qt.*` launch — `QTLaunchOptions.effectiveScreenName`) refuses to start when that
/// display isn't connected, and quits if it disappears mid-run, instead of letting AppKit put its windows on the
/// main display. The refusal is printed to stderr, logged, and written to `-qt.readyFile` as
/// `{"error": "screenMissing", "screen": …, "screens": […], "pid": …}` so scripts fail at once.
/// Release builds ignore `-qt.screen` and never refuse.
@MainActor
public enum QTScreenGuard {
    nonisolated static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.roderickqiu.qtube", category: "screen")

    /// First connected display whose localized name contains `name` (case-insensitive).
    public static func screen(named name: String) -> NSScreen? {
        NSScreen.screens.first { $0.localizedName.range(of: name, options: .caseInsensitive) != nil }
    }

    static var connectedNames: [String] { NSScreen.screens.map(\.localizedName) }

    /// The display this launch requires but which isn't connected (nil: nothing required, or it is there).
    public static func missingScreen(for launch: QTLaunchOptions, connected: [String]? = nil) -> String? {
        guard let name = launch.effectiveScreenName else { return nil }
        let names = connected ?? connectedNames
        return names.contains { $0.range(of: name, options: .caseInsensitive) != nil } ? nil : name
    }

    /// Call before any window exists (`QTAppModel.bootstrap`). Exits the process when the required display is missing.
    public static func refuseLaunchIfScreenMissing(_ launch: QTLaunchOptions) {
        #if DEBUG
        guard let name = missingScreen(for: launch) else { return }
        report(missing: name, launch: launch, when: "at launch")
        exit(69) // EX_UNAVAILABLE
        #endif
    }

    /// Displays changed: a DEBUG run whose display went away hides its windows and quits.
    public static func screensChanged(_ launch: QTLaunchOptions) {
        #if DEBUG
        guard let name = missingScreen(for: launch) else { return }
        report(missing: name, launch: launch, when: "mid-run")
        for window in NSApp.windows { window.orderOut(nil) }
        NSApp.terminate(nil)
        #endif
    }

    private static func report(missing name: String, launch: QTLaunchOptions, when: String) {
        let connected = connectedNames
        let message = "QTube Music: display “\(name)” is not connected (\(when)); refusing to show windows on "
            + "another display. Connected: \(connected.joined(separator: ", ")). Pass -qt.screen <name> "
            + "(e.g. \"Built-in\") or -qt.screen main.\n"
        FileHandle.standardError.write(Data(message.utf8))
        log.error("\(message, privacy: .public)")
        guard let path = launch.readyFile else { return }
        let info: [String: Any] = ["error": "screenMissing", "screen": name, "screens": connected,
                                   "pid": ProcessInfo.processInfo.processIdentifier]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

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
