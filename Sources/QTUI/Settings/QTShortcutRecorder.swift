import AppKit
import QTCore
import SwiftUI

// Owner: builder "desktop". The shortcut field of Settings › Shortcuts, drawn like the system's: a rounded text
// field showing the combo (or "Record Shortcut"), with a clear button. Click it (or VoiceOver-press it, or press
// Space on it with Full Keyboard Access) to record; the next allowed combo (`QTKeyCombo.globalRefusal`: two
// modifiers with ⌘ or ⌃, ⌃ on a key that types nothing, or an F-key) is the shortcut. Esc cancels, ⌫ clears, Tab
// moves on, and ⌘ + one key (⌘W, ⌘Q…) ends recording and does its usual job. While it records, every global
// shortcut is off, and a local monitor takes the keys before the menus do.

struct QTShortcutRecorder: NSViewRepresentable {
    /// What the shortcut does (the field's VoiceOver label).
    let title: String
    let combo: QTKeyCombo?
    let display: String?
    let onChange: @MainActor (QTKeyCombo?) -> Void

    func makeNSView(context: Context) -> QTShortcutRecorderField {
        QTShortcutRecorderField()
    }

    func updateNSView(_ field: QTShortcutRecorderField, context: Context) {
        field.onChange = onChange
        field.update(title: title, combo: combo, display: display)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: QTShortcutRecorderField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? QTShortcutRecorderField.width, height: nsView.intrinsicContentSize.height)
    }
}

/// An NSControl with a text field cell (the system's bezel and focus ring) that records instead of editing.
final class QTShortcutRecorderField: NSControl {
    static let width: CGFloat = 150

    var onChange: (@MainActor (QTKeyCombo?) -> Void)?
    private(set) var isRecording = false
    private var combo: QTKeyCombo?
    private var display: String?
    private var title = ""
    /// Modifiers held while recording ("⌃⌥…"), or the reason the last key was refused.
    private var pending: String?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    /// This field's hold on `QTGlobalHotKeys` while it records.
    private var suspension: UUID?
    private let clearButton = NSButton()

    override class var cellClass: AnyClass? {
        get { NSTextFieldCell.self }
        set {}
    }

    private var textCell: NSTextFieldCell { cell as! NSTextFieldCell }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 22))
        let c = textCell
        c.isBezeled = true
        c.bezelStyle = .roundedBezel
        c.drawsBackground = true
        c.backgroundColor = .textBackgroundColor
        c.isEditable = false
        c.isSelectable = false
        c.alignment = .center
        c.lineBreakMode = .byTruncatingTail
        c.usesSingleLineMode = true
        c.font = .systemFont(ofSize: NSFont.systemFontSize)
        focusRingType = .exterior

        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        clearButton.isBordered = false
        clearButton.imagePosition = .imageOnly
        clearButton.contentTintColor = .tertiaryLabelColor
        clearButton.refusesFirstResponder = true
        clearButton.target = self
        clearButton.action = #selector(clear)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clearButton)
        NSLayoutConstraint.activate([
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 14),
            clearButton.heightAnchor.constraint(equalToConstant: 14),
        ])
        refresh()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// A field torn down mid-recording (Settings closed some other way) still turns the hot keys back on.
    isolated deinit {
        endMonitoring()
        if let suspension { QTGlobalHotKeys.shared.resume(suspension) }
    }

    func update(title: String, combo: QTKeyCombo?, display: String?) {
        self.title = title
        self.combo = combo
        self.display = display
        refresh()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.width, height: max(22, textCell.cellSize.height))
    }

    /// The text's baseline from the top (centred system-font line), for lining the field up with a Form label:
    /// SwiftUI takes an NSView's top edge as its baseline.
    static var baselineFromTop: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return ((22 - (font.ascender - font.descender + font.leading)) / 2 + font.ascender).rounded()
    }

    // MARK: Look

    private func refresh() {
        let c = textCell
        if isRecording {
            c.stringValue = pending ?? ""
            c.placeholderString = QTLoc.tr("Type Shortcut", table: .desktop)
            c.textColor = .secondaryLabelColor
        } else {
            c.stringValue = display ?? ""
            c.placeholderString = QTLoc.tr("Record Shortcut", table: .desktop)
            c.textColor = .labelColor
        }
        clearButton.isHidden = isRecording || combo == nil
        clearButton.setAccessibilityLabel(QTLoc.tr("Clear Shortcut", table: .desktop))
        clearButton.toolTip = QTLoc.tr("Clear Shortcut", table: .desktop)
        setAccessibilityLabel(title)
        setAccessibilityValue(display ?? QTLoc.tr("None", table: .desktop))
        setAccessibilityHelp(QTLoc.tr("Records a shortcut that works in any app", table: .desktop))
        toolTip = isRecording ? nil : QTLoc.tr("Click to record a shortcut", table: .desktop)
        needsDisplay = true
    }

    override func drawFocusRingMask() {
        textCell.drawFocusRingMask(withFrame: bounds, in: self)
    }

    override var focusRingMaskBounds: NSRect { bounds }

    // MARK: Accessibility (a button that starts recording)

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool {
        beginRecording()
        return true
    }

    // MARK: Recording

    override var acceptsFirstResponder: Bool { isEnabled }
    /// In the Tab loop only with Full Keyboard Access, like a button, so opening Settings never focuses it.
    override var canBecomeKeyView: Bool { isEnabled && NSApp.isFullKeyboardAccessEnabled }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, !isRecording else { return }
        beginRecording()
    }

    /// Recording starts on a click, a VoiceOver press, or Space / Return while focused — never just from focus.
    private func beginRecording() {
        guard isEnabled, window?.firstResponder === self || window?.makeFirstResponder(self) == true else { return }
        startRecording()
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        stopRecording()
        return true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        pending = nil
        if suspension == nil { suspension = QTGlobalHotKeys.shared.suspend() }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            return QTMainActorHop.onMainThread { self.handle(event) } ? nil : event
        }
        // Switching to another app or window ends recording, like clicking elsewhere.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            QTMainActorHop.onMainThread { self?.finish() }
        }
        refresh()
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        pending = nil
        endMonitoring()
        if let suspension { QTGlobalHotKeys.shared.resume(suspension) }
        suspension = nil
        QTGlobalHotKeys.shared.refreshEnvironment()
        refresh()
    }

    private func endMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    /// Gives up first responder (ends recording).
    private func finish() {
        if window?.firstResponder === self { window?.makeFirstResponder(nil) } else { stopRecording() }
    }

    override func keyDown(with event: NSEvent) {
        // While recording, reached when another monitor (Space routing) hands the key to the focused view.
        if isRecording, handle(event) { return }
        if !isRecording, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           [QTKeyCombo.space, QTKeyCombo.returnKey].contains(UInt32(event.keyCode)) {
            beginRecording()
            return
        }
        super.keyDown(with: event)
    }

    /// True when the event was used here (and must go no further).
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            // A click anywhere but on the field ends recording; the click itself goes on as usual.
            if event.window !== window || !bounds.contains(convert(event.locationInWindow, from: nil)) { finish() }
            return false
        case .flagsChanged:
            let mods = QTKeyModifiers(event.modifierFlags)
            pending = mods.isEmpty ? nil : mods.symbols
            refresh()
            return false
        case .keyDown:
            guard event.window === window else { return false }
            let mods = QTKeyModifiers(event.modifierFlags)
            let code = UInt32(event.keyCode)
            if mods.isEmpty, code == QTKeyCombo.escape {
                finish()
                return true
            }
            if mods.isEmpty, code == QTKeyCombo.delete || code == QTKeyCombo.forwardDelete {
                onChange?(nil)
                finish()
                return true
            }
            if mods.subtracting(.shift).isEmpty, code == QTKeyCombo.tab { return false }   // move focus on
            let combo = QTKeyCombo(keyCode: code, modifiers: mods)
            switch Self.decision(for: combo) {
            case .record:
                onChange?(combo)
                finish()
                return true
            case .passThrough:
                // ⌘W closes the window, ⌘Q quits, ⌘, … as anywhere else: recording just ends.
                finish()
                return false
            case .refuse(let reason):
                NSSound.beep()
                pending = reason
                refresh()
                return true
            }
        default:
            return false
        }
    }

    @objc private func clear() {
        onChange?(nil)
    }

    enum KeyDecision: Equatable {
        case record
        /// A standard app or window command (⌘ + one key): never a global shortcut, so it does its usual job.
        case passThrough
        /// Beep and say why ("Include ⌘ or ⌃", "Add another modifier key").
        case refuse(String)
    }

    /// What a key pressed while recording does (Esc, ⌫ and Tab are handled before this).
    static func decision(for combo: QTKeyCombo) -> KeyDecision {
        switch combo.globalRefusal {
        case nil: .record
        case .needsAnotherModifier where combo.modifiers == .command: .passThrough
        case .needsAnotherModifier: .refuse(QTLoc.tr("Add another modifier key", table: .desktop))
        case .needsCommandOrControl: .refuse(QTLoc.tr("Include ⌘ or ⌃", table: .desktop))
        }
    }
}
