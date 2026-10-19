import AppKit

// Owner: builder "desktop". Playback shortcuts that collide with text editing (Space, ⌘← / ⌘→, ⌘↑ / ⌘↓,
// ⌥↑ / ⌥↓) are real menu key equivalents, so they show in the Controls menu and work everywhere — except while
// the user is typing: then the key goes straight to the text field (menu key equivalents would otherwise win).

@MainActor
enum QTKeyRouting {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let delivered = MainActor.assumeIsolated { deliverToTextField(event) }
            return delivered ? nil : event
        }
    }

    /// True when the event was delivered to the focused text view directly (and must not reach the menus).
    private static func deliverToTextField(_ event: NSEvent) -> Bool {
        guard let window = event.window, collidesWithTextEditing(event) else { return false }
        let isBareSpace = event.keyCode == 49
        guard isEditingText(in: window) || (isBareSpace && focusedControlUsesSpace(in: window)) else { return false }
        window.sendEvent(event)
        return true
    }

    /// Full Keyboard Access: a focused button, segmented control, pop-up or slider uses Space itself.
    static func focusedControlUsesSpace(in window: NSWindow) -> Bool {
        guard let view = window.firstResponder as? NSView else { return false }
        return view is NSButton || view is NSSegmentedControl || view is NSPopUpButton || view is NSSlider
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
