import AppKit

// Owner: builder "desktop". Playback shortcuts that collide with text editing and keyboard navigation (Space,
// ⌘← / ⌘→, ⌘↑ / ⌘↓, ⌥↑ / ⌥↓) are real menu key equivalents, so they show in the Controls menu — but a menu key
// equivalent wins over the focused view, so this monitor decides first:
//
// - Bare Space in any of our windows: whatever has keyboard focus gets it first (a text field types it; with Full
//   Keyboard Access a focused button, switch, stepper, pop-up, segmented control or SwiftUI control presses
//   itself). Only when nothing in the responder chain uses it does Space play/pause. A table, outline (sidebar,
//   track lists) or nothing focused at all means "no control": Space plays/pauses at once, like Music.
// - ⌘←→ / ⌘↑↓ / ⌥↑↓ go to a text field being edited; otherwise the menu fires.
//
// The main window has no other Space handler (`QTWindowKeyMonitor` forwards here).

@MainActor
enum QTKeyRouting {
    private static var monitor: Any?
    /// Set by `install(togglePlayback:)`; the Controls menu's Play/Pause action.
    private static var togglePlayback: (@MainActor () -> Void)?

    /// Installs the app-wide key monitor once. `togglePlayback` is what an unused Space does.
    static func install(togglePlayback: (@MainActor () -> Void)? = nil) {
        if let togglePlayback { self.togglePlayback = togglePlayback }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let consumed = MainActor.assumeIsolated { route(event) }
            return consumed ? nil : event
        }
    }

    /// True when the event was handled here (and must not reach the menus).
    private static func route(_ event: NSEvent) -> Bool {
        guard let window = event.window, collidesWithTextEditing(event) else { return false }
        if isBareSpace(event) {
            switch spaceDecision(for: window.firstResponder, in: window) {
            case .playback:
                togglePlayback?()
                return togglePlayback != nil
            case .responderChainFirst:
                // The focused view gets the key; if it falls off the end of the chain unused, it's play/pause.
                if !deliver(event, to: window) { togglePlayback?() }
                return true
            }
        }
        guard isEditingText(in: window) else { return false }
        window.sendEvent(event)
        return true
    }

    enum QTSpaceDecision: Equatable {
        /// Nothing that uses Space has focus: play/pause right away.
        case playback
        /// Something focused may use Space: offer it first.
        case responderChainFirst
    }

    /// No control has keyboard focus when the first responder is nothing, a window, a table or outline (track
    /// lists, the sidebar), a collection view or a bare scroll/clip view. Anything else — a text view, any
    /// `NSControl` (button, switch, stepper, slider, pop-up, segmented control), SwiftUI's focus proxy for a
    /// focused SwiftUI control — is offered the key first.
    static func spaceDecision(for responder: NSResponder?, in window: NSWindow?) -> QTSpaceDecision {
        guard let responder, responder !== window else { return .playback }
        if responder is NSWindow { return .playback }
        if responder is NSTableView || responder is NSCollectionView { return .playback }
        if responder is NSText { return .responderChainFirst }
        if responder is NSControl { return .responderChainFirst }
        if responder is NSClipView || responder is NSScrollView { return .playback }
        return .responderChainFirst
    }

    /// Sends `event` straight to the window (no menu key equivalents) with a catcher at the end of the
    /// responder chain. Returns true if a responder used it.
    static func deliver(_ event: NSEvent, to window: NSWindow) -> Bool {
        let catcher = QTUnusedKeyCatcher()
        var tail: NSResponder = window.firstResponder ?? window
        var hops = 0
        while let next = tail.nextResponder, hops < 256 {
            tail = next
            hops += 1
        }
        tail.nextResponder = catcher
        window.sendEvent(event)
        if tail.nextResponder === catcher { tail.nextResponder = nil }
        return !catcher.caught
    }

    static func isBareSpace(_ event: NSEvent) -> Bool {
        event.keyCode == 49 && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }

    static func isEditingText(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if let text = responder as? NSTextView { return text.isEditable || text.isFieldEditor }
        return responder is NSTextField
    }

    static func collidesWithTextEditing(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 49: // Space
            return mods.isEmpty
        case 123, 124, 125, 126: // ← → ↓ ↑
            return mods == .command || mods == .option
        default:
            return false
        }
    }
}

/// End-of-chain responder for one key event: records that nobody before it used the key (instead of beeping).
final class QTUnusedKeyCatcher: NSResponder {
    private(set) var caught = false
    override func keyDown(with event: NSEvent) { caught = true }
    override func noResponder(for eventSelector: Selector) { caught = true }
}
