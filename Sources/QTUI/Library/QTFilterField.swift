import AppKit
import SwiftUI

/// Native NSSearchField for ⌘F filtering inside a list (magnifier, clear button, Esc clears, ↓ moves to the table).
/// `focusRequest` changes → takes focus when `isFocusTarget`.
struct QTFilterField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String
    var focusRequest: Int
    var isFocusTarget: Bool
    var identifier: String
    var onMoveDown: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.delegate = context.coordinator
        f.controlSize = .regular
        f.sendsSearchStringImmediately = true
        f.sendsWholeSearchString = false
        f.focusRingType = .default
        f.setAccessibilityIdentifier(identifier)
        f.target = context.coordinator
        f.action = #selector(Coordinator.changed(_:))
        context.coordinator.lastFocusRequest = focusRequest
        return f
    }

    func updateNSView(_ f: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
        f.placeholderString = prompt
        f.toolTip = "\(prompt)  ⌘F"
        f.setAccessibilityLabel(prompt)
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            if isFocusTarget {
                DispatchQueue.main.async { f.window?.makeFirstResponder(f) }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: QTFilterField
        var lastFocusRequest = 0

        init(_ parent: QTFilterField) { self.parent = parent }

        @objc func changed(_ sender: NSSearchField) {
            if parent.text != sender.stringValue { parent.text = sender.stringValue }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSSearchField else { return }
            changed(f)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                if parent.text.isEmpty {
                    control.window?.makeFirstResponder(nil)
                } else {
                    parent.text = ""
                    (control as? NSSearchField)?.stringValue = ""
                }
                return true
            case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:)):
                parent.onMoveDown?()
                return parent.onMoveDown != nil
            default:
                return false
            }
        }
    }
}
