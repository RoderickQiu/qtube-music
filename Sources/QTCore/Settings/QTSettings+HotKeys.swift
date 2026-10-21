import Foundation

// System-wide shortcuts (Settings › Shortcuts). Pure data: the key combo, its display, the stored bindings and the
// suggested set. Registration (Carbon) and key names from the keyboard layout live in QTUI/Desktop/QTGlobalHotKeys.

/// What a global shortcut does. Raw values are the stored keys: never rename one.
public enum QTGlobalHotKeyAction: String, Codable, Sendable, Hashable, CaseIterable {
    case playPause
    case next
    case previous
    case like
    case desktopLyrics
    case miniPlayer
    case showApp
}

/// Modifier keys with Carbon's bit values (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`), so a combo goes to
/// `RegisterEventHotKey` and comes back from `CopySymbolicHotKeys` unchanged.
public struct QTKeyModifiers: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let command = QTKeyModifiers(rawValue: 1 << 8)
    public static let shift = QTKeyModifiers(rawValue: 1 << 9)
    public static let option = QTKeyModifiers(rawValue: 1 << 11)
    public static let control = QTKeyModifiers(rawValue: 1 << 12)
    public static let all: QTKeyModifiers = [.control, .option, .shift, .command]

    /// "⌃⌥⇧⌘", in the order macOS menus show them.
    public var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

/// One key plus modifiers. `keyCode` is the virtual key code (`kVK_*`): the physical key, whatever the layout.
public struct QTKeyCombo: Codable, Sendable, Hashable {
    public var keyCode: UInt32
    public var modifiers: QTKeyModifiers

    public init(keyCode: UInt32, modifiers: QTKeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(.all)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(keyCode: try c.decode(UInt32.self, forKey: .keyCode),
                  modifiers: QTKeyModifiers(rawValue: try c.decode(UInt32.self, forKey: .modifiers)))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(keyCode, forKey: .keyCode)
        try c.encode(modifiers.rawValue, forKey: .modifiers)
    }

    private enum CodingKeys: String, CodingKey { case keyCode, modifiers }

    /// F1–F20: fine on their own (they type nothing).
    public var isFunctionKey: Bool { QTKeyCombo.functionKeyNumbers[keyCode] != nil }

    /// Why a combo can't be a global shortcut.
    public enum GlobalRefusal: Sendable, Hashable {
        /// Neither ⌘ nor ⌃: it would swallow typing everywhere, and since macOS 15 the system no longer delivers ⌥ /
        /// ⌥⇧-only hot keys to apps (they still register without an error).
        case needsCommandOrControl
        /// ⌘ alone is every app's own commands (⌘Q, ⌘W, ⌘L, ⌘←…), ⌃ alone on a key that types is text editing
        /// (⌃A, ⌃E, ⌃K in every text field): taking those system-wide breaks other apps.
        case needsAnotherModifier
    }

    /// nil when the combo may be a global shortcut: an F-key (with or without modifiers); two or more modifiers, one
    /// of them ⌘ or ⌃; or ⌃ alone on a key that types nothing (arrows, Return, Space…).
    public var globalRefusal: GlobalRefusal? {
        if isFunctionKey { return nil }
        guard !modifiers.isDisjoint(with: [.command, .control]) else { return .needsCommandOrControl }
        if modifiers == .command { return .needsAnotherModifier }
        if modifiers == .control, QTKeyCombo.fixedKeyName(keyCode) == nil { return .needsAnotherModifier }
        return nil
    }

    public var isAllowedAsGlobal: Bool { globalRefusal == nil }

    /// "⌃⌥⌘P". `keyName` gives the character the key types in the current layout (QTUI asks UCKeyTranslate); keys
    /// that type nothing (arrows, F-keys, Return…) have fixed names.
    public func displayString(keyName: (UInt32) -> String?) -> String {
        modifiers.symbols + (QTKeyCombo.fixedKeyName(keyCode) ?? keyName(keyCode)?.uppercased() ?? "#\(keyCode)")
    }

    // MARK: Key codes (Carbon `kVK_*`; the ANSI ones name the key's position on a US keyboard)

    public static let returnKey: UInt32 = 0x24
    public static let tab: UInt32 = 0x30
    public static let space: UInt32 = 0x31
    public static let delete: UInt32 = 0x33
    public static let escape: UInt32 = 0x35
    public static let forwardDelete: UInt32 = 0x75

    public static let functionKeyNumbers: [UInt32: Int] = [
        0x7A: 1, 0x78: 2, 0x63: 3, 0x76: 4, 0x60: 5, 0x61: 6, 0x62: 7, 0x64: 8, 0x65: 9, 0x6D: 10,
        0x67: 11, 0x6F: 12, 0x69: 13, 0x6B: 14, 0x71: 15, 0x6A: 16, 0x40: 17, 0x4F: 18, 0x50: 19, 0x5A: 20,
    ]

    /// Names of keys that don't type a character, as macOS menus draw them.
    public static func fixedKeyName(_ keyCode: UInt32) -> String? {
        if let n = functionKeyNumbers[keyCode] { return "F\(n)" }
        switch keyCode {
        case returnKey: return "↩"
        case tab: return "⇥"
        case space: return QTLoc.tr("Space", table: .desktop)
        case delete: return "⌫"
        case escape: return "⎋"
        case forwardDelete: return "⌦"
        case 0x4C: return "⌤"   // keypad Enter
        case 0x47: return "⌧"   // keypad Clear
        case 0x72: return "?⃝"  // Help
        case 0x73: return "↖"   // Home
        case 0x77: return "↘"   // End
        case 0x74: return "⇞"   // Page Up
        case 0x79: return "⇟"   // Page Down
        case 0x7B: return "←"
        case 0x7C: return "→"
        case 0x7D: return "↓"
        case 0x7E: return "↑"
        default: return nil
        }
    }
}

/// The user's global shortcuts: at most one combo per action, and a combo belongs to one action only.
/// Stored as `{"playPause": {"keyCode": 35, "modifiers": 6400}, …}`; unknown actions and broken entries are dropped
/// on load, so the rest still loads.
public struct QTHotKeyBindings: Codable, Sendable, Hashable {
    private var combos: [QTGlobalHotKeyAction: QTKeyCombo] = [:]

    public init(_ combos: [QTGlobalHotKeyAction: QTKeyCombo] = [:]) {
        for action in QTGlobalHotKeyAction.allCases {
            if let combo = combos[action] { self[action] = combo }
        }
    }

    /// Setting a combo takes it away from any other action that had it (one key, one action).
    public subscript(action: QTGlobalHotKeyAction) -> QTKeyCombo? {
        get { combos[action] }
        set {
            if let newValue {
                for (other, combo) in combos where other != action && combo == newValue { combos[other] = nil }
            }
            combos[action] = newValue
        }
    }

    public var isEmpty: Bool { combos.isEmpty }
    public var all: [QTGlobalHotKeyAction: QTKeyCombo] { combos }

    public func action(for combo: QTKeyCombo) -> QTGlobalHotKeyAction? {
        combos.first { $0.value == combo }?.key
    }

    // MARK: Suggested set (none is active until the user asks: media keys already work)

    /// ⌃⌥⌘ + a mnemonic key. Clear of Spotlight (⌘Space), input sources (⌃Space), launchers (⌥Space), Rectangle /
    /// Magnet (⌃⌥ + arrows or letters, ⌃⌥⌘ + ←/→) and the system's ⌃⌥⌘ accessibility keys (8, comma, period).
    /// Keyed by character so they follow the layout; `fallbackKeyCode` is the US position.
    public static let suggestedKeys: [(action: QTGlobalHotKeyAction, character: String, fallbackKeyCode: UInt32)] = [
        (.playPause, "p", 0x23),
        (.next, "]", 0x1E),
        (.previous, "[", 0x21),
        (.like, "l", 0x25),
        (.desktopLyrics, "y", 0x10),
        (.miniPlayer, "m", 0x2E),
    ]

    public static let suggestedModifiers: QTKeyModifiers = [.control, .option, .command]

    /// The suggested combos, with each key found in the current layout by `keyCode(character)` when it has one.
    public static func suggested(keyCode: (String) -> UInt32? = { _ in nil }) -> [QTGlobalHotKeyAction: QTKeyCombo] {
        Dictionary(uniqueKeysWithValues: suggestedKeys.map { entry in
            (entry.action, QTKeyCombo(keyCode: keyCode(entry.character) ?? entry.fallbackKeyCode, modifiers: suggestedModifiers))
        })
    }

    /// Fills in the actions that have no shortcut yet; never replaces one the user chose or takes a combo they
    /// already use. Returns whether anything changed.
    @discardableResult
    public mutating func applySuggested(_ suggested: [QTGlobalHotKeyAction: QTKeyCombo]) -> Bool {
        var changed = false
        for action in QTGlobalHotKeyAction.allCases {
            guard combos[action] == nil, let combo = suggested[action], self.action(for: combo) == nil else { continue }
            combos[action] = combo
            changed = true
        }
        return changed
    }

    /// True when `applySuggested` would change something.
    public func canApplySuggested(_ suggested: [QTGlobalHotKeyAction: QTKeyCombo]) -> Bool {
        var copy = self
        return copy.applySuggested(suggested)
    }

    // MARK: Codable

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        for key in c.allKeys {
            guard let action = QTGlobalHotKeyAction(rawValue: key.stringValue),
                  let combo = try? c.decode(QTKeyCombo.self, forKey: key) else { continue }
            self[action] = combo
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (action, combo) in combos { try c.encode(combo, forKey: AnyKey(stringValue: action.rawValue)) }
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
