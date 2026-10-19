import AppKit
import Observation
import QTCore
import SwiftUI

/// Where a `QTStageView` lives.
public enum QTStagePresentation: Sendable, Hashable {
    /// Overlay inside the main window (`model.surface == .stage`).
    case inline
    /// Its own window, usually on another display ("Show Stage on U270CA").
    case detached
}

/// Owns the detached Stage window and moves the Stage between the main window and other displays.
/// The main window keeps browsing while the Stage plays on the second display.
@MainActor
@Observable
public final class QTStageCoordinator {
    public static let shared = QTStageCoordinator()

    /// NSWindow identifier / capture title of the detached Stage window (Scripts: `qt-window-id --title`).
    public static let windowIdentifier = NSUserInterfaceItemIdentifier("qt.window.stage")
    public static let captureTitle = "QTube Music Stage"

    public private(set) var isDetached = false
    /// Display name of the detached Stage window.
    public private(set) var detachedScreenName: String?

    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var closeObserver: NSObjectProtocol?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var exitObserver: NSObjectProtocol?

    private init() {}

    /// ⇧⌘F: closes the detached Stage if there is one, otherwise toggles the in-window Stage.
    /// (Recommended for `QTCommands`' Stage item.)
    public func toggleStage(model: QTAppModel) {
        if isDetached {
            closeDetached()
        } else {
            withAnimation(QTTheme.Motion.ui) { model.surface = model.surface == .stage ? .window : .stage }
        }
    }

    /// Displays other than the one `window` is on — targets for "Show Stage on …".
    public func otherScreens(than window: NSWindow?) -> [NSScreen] {
        let current = window?.screen
        return NSScreen.screens.filter { $0 != current }
    }

    /// Opens the Stage in its own window filling `screen`'s visible frame, and returns the main window to browsing.
    /// - Parameter activate: false for launch paths (never take focus), true for a user's menu choice.
    public func showDetached(on screen: NSScreen, model: QTAppModel, activate: Bool) {
        let window = self.window ?? makeWindow(model: model)
        self.window = window
        window.setFrame(screen.visibleFrame, display: true)
        if activate {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
        isDetached = true
        detachedScreenName = screen.localizedName
        if model.surface == .stage {
            withAnimation(QTTheme.Motion.ui) { model.surface = .window }
        }
    }

    /// Returns the Stage to the main window.
    public func returnToMainWindow(model: QTAppModel) {
        closeDetached()
        withAnimation(QTTheme.Motion.ui) { model.surface = .stage }
    }

    public func closeDetached() {
        guard let window else { return }
        if window.styleMask.contains(.fullScreen) {
            // Leave the full-screen Space first, then close.
            if let exitObserver { NotificationCenter.default.removeObserver(exitObserver) }
            exitObserver = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                                                  object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let exitObserver = self.exitObserver { NotificationCenter.default.removeObserver(exitObserver) }
                    self.exitObserver = nil
                    self.window?.close()
                }
            }
            window.toggleFullScreen(nil)
        } else {
            window.close()
        }
    }

    private func makeWindow(model: QTAppModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.identifier = Self.windowIdentifier
        window.title = Self.captureTitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 720, height: 480)
        let root = QTStageView(presentation: .detached)
            .environment(model)
            .environment(model.player)
            .qtArtworkTint(model.palette)
        window.contentView = NSHostingView(rootView: root)
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didClose() }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged(model: model) }
        }
        return window
    }

    private func didClose() {
        isDetached = false
        detachedScreenName = nil
        // Drop the hosting view so its timers and layers stop; a fresh one is built next time.
        window?.contentView = nil
        window = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        closeObserver = nil
        screenObserver = nil
    }

    /// The display holding the detached Stage went away: bring the Stage back into the main window.
    private func screensChanged(model: QTAppModel) {
        guard let window, isDetached else { return }
        if window.screen == nil || !NSScreen.screens.contains(where: { $0.localizedName == detachedScreenName }) {
            returnToMainWindow(model: model)
        }
    }
}

/// Tracks the hosting NSWindow (unlike `QTWindowAccessor`, keeps reporting if the view moves windows) and its
/// full-screen state.
struct QTStageWindowReader: NSViewRepresentable {
    let onChange: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> QTStageWindowReaderView { QTStageWindowReaderView(onChange: onChange) }
    func updateNSView(_ nsView: QTStageWindowReaderView, context: Context) {}
}

final class QTStageWindowReaderView: NSView {
    private let onChange: @MainActor (NSWindow?) -> Void

    init(onChange: @escaping @MainActor (NSWindow?) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let window = self.window
        DispatchQueue.main.async { [onChange] in MainActor.assumeIsolated { onChange(window) } }
    }
}
