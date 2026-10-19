import AppKit
import Observation
import QTCore

// Owner: lyrics-translate. AppKit text (accessibility labels, tooltips) that must follow a live interface-language
// switch. SwiftUI re-renders on its own when `QTLoc` changes; AppKit properties set once at init would keep the
// launch language for VoiceOver and tooltips, so they are re-applied on every switch.

@MainActor
enum QTLocalizedAppKitText {
    /// Calls `apply` now and again after every interface-language change, for as long as `owner` lives.
    static func follow<Owner: AnyObject>(_ owner: Owner, _ apply: @escaping @MainActor (Owner) -> Void) {
        apply(owner)
        observe(owner, apply)
    }

    private static func observe<Owner: AnyObject>(_ owner: Owner, _ apply: @escaping @MainActor (Owner) -> Void) {
        let box = QTWeakMainActorBox(owner, apply)
        withObservationTracking {
            _ = QTLoc.language
        } onChange: {
            Task { @MainActor in
                guard let owner = box.owner else { return }
                box.apply(owner)
                observe(owner, box.apply)
            }
        }
    }
}

/// Carries a weak AppKit owner and its apply closure into the observation callback; only touched on the main actor.
private final class QTWeakMainActorBox<Owner: AnyObject>: @unchecked Sendable {
    weak var owner: Owner?
    let apply: @MainActor (Owner) -> Void

    init(_ owner: Owner, _ apply: @escaping @MainActor (Owner) -> Void) {
        self.owner = owner
        self.apply = apply
    }
}

extension NSView {
    /// Accessibility label (and optionally tooltip) from a localization key, kept current across language switches.
    @MainActor
    func qtLocalizedAccessibility(_ key: String, table: QTStringTable = .shared, toolTip: Bool = false) {
        QTLocalizedAppKitText.follow(self) { view in
            let text = QTLoc.tr(key, table: table)
            view.setAccessibilityLabel(text)
            if toolTip { view.toolTip = text }
        }
    }
}

extension NSWindow {
    /// Accessibility label from a localization key, kept current across language switches.
    @MainActor
    func qtLocalizedAccessibility(_ key: String, table: QTStringTable = .shared) {
        QTLocalizedAppKitText.follow(self) { $0.setAccessibilityLabel(QTLoc.tr(key, table: table)) }
    }
}
