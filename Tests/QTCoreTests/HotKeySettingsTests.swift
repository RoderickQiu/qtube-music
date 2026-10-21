import Foundation
import Testing
@testable import QTCore

/// Settings › Shortcuts data: combo encoding and display, the one-key-one-action bindings, the suggested set and
/// lenient decoding of stored settings.
@Suite struct HotKeySettingsTests {
    private let p = QTKeyCombo(keyCode: 0x23, modifiers: [.command, .option, .control])
    /// A fixed "layout": the US characters of a few keys.
    private func us(_ code: UInt32) -> String? {
        [0x23: "p", 0x1E: "]", 0x21: "[", 0x25: "l", 0x10: "y", 0x2E: "m", 0x00: "a", 0x12: "1"][code]
    }

    @Test func modifiersUseCarbonBitsAndMenuOrder() {
        #expect(QTKeyModifiers.command.rawValue == 0x100)
        #expect(QTKeyModifiers.shift.rawValue == 0x200)
        #expect(QTKeyModifiers.option.rawValue == 0x800)
        #expect(QTKeyModifiers.control.rawValue == 0x1000)
        #expect(QTKeyModifiers.all.symbols == "⌃⌥⇧⌘")
        #expect(QTKeyModifiers([.command, .shift]).symbols == "⇧⌘")
        // Bits outside the four (fn, caps lock) are dropped.
        #expect(QTKeyCombo(keyCode: 0x7E, modifiers: QTKeyModifiers(rawValue: 0x21000)).modifiers == .control)
    }

    @Test func displayUsesLayoutNamesAndFixedNames() {
        #expect(p.displayString(keyName: us) == "⌃⌥⌘P")
        #expect(QTKeyCombo(keyCode: 0x1E, modifiers: [.control, .option, .command]).displayString(keyName: us) == "⌃⌥⌘]")
        // Another layout names the same physical key differently (German: + where US has ]).
        #expect(QTKeyCombo(keyCode: 0x1E, modifiers: .command).displayString { $0 == 0x1E ? "+" : nil } == "⌘+")
        #expect(QTKeyCombo(keyCode: 0x7C, modifiers: [.command, .shift]).displayString(keyName: us) == "⇧⌘→")
        #expect(QTKeyCombo(keyCode: 0x24, modifiers: .control).displayString(keyName: us) == "⌃↩")
        #expect(QTKeyCombo(keyCode: 0x6F, modifiers: []).displayString(keyName: us) == "F12")
        #expect(QTKeyCombo(keyCode: 0x5A, modifiers: .command).displayString(keyName: us) == "⌘F20")
        #expect(QTKeyCombo(keyCode: 0x31, modifiers: .option).displayString(keyName: us) == "⌥" + QTLoc.tr("Space", table: .desktop))
        // A key the layout can't name still shows something.
        #expect(QTKeyCombo(keyCode: 0x6C, modifiers: .command).displayString(keyName: us) == "⌘#108")
    }

    @Test func globalCombosNeedCommandOrControl() {
        #expect(p.isAllowedAsGlobal)
        #expect(QTKeyCombo(keyCode: 0x23, modifiers: .control).isAllowedAsGlobal)
        #expect(QTKeyCombo(keyCode: 0x23, modifiers: .command).isAllowedAsGlobal)
        #expect(!QTKeyCombo(keyCode: 0x23, modifiers: []).isAllowedAsGlobal)
        #expect(!QTKeyCombo(keyCode: 0x23, modifiers: .shift).isAllowedAsGlobal)
        // ⌥ and ⌥⇧ alone: macOS 15+ doesn't deliver those to apps.
        #expect(!QTKeyCombo(keyCode: 0x31, modifiers: .option).isAllowedAsGlobal)
        #expect(!QTKeyCombo(keyCode: 0x23, modifiers: [.option, .shift]).isAllowedAsGlobal)
        // Function keys type nothing, so they may stand alone.
        #expect(QTKeyCombo(keyCode: 0x69, modifiers: []).isAllowedAsGlobal)
        #expect(QTKeyCombo(keyCode: 0x7A, modifiers: .shift).isAllowedAsGlobal)
    }

    @Test func comboEncodesAsKeyCodeAndCarbonMask() throws {
        let json = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        #expect(json.contains(#""keyCode":35"#))
        #expect(json.contains(#""modifiers":6400"#))
        #expect(try JSONDecoder().decode(QTKeyCombo.self, from: Data(json.utf8)) == p)
    }

    @Test func oneComboBelongsToOneAction() {
        var b = QTHotKeyBindings()
        b[.playPause] = p
        b[.next] = p
        #expect(b[.playPause] == nil)
        #expect(b[.next] == p)
        #expect(b.action(for: p) == .next)
        b[.next] = nil
        #expect(b.isEmpty)
    }

    @Test func suggestedSetFillsOnlyEmptyActions() {
        let suggested = QTHotKeyBindings.suggested()
        #expect(suggested.count == 6)
        #expect(suggested[.showApp] == nil)
        #expect(suggested.values.allSatisfy { $0.modifiers == [.control, .option, .command] && $0.isAllowedAsGlobal })
        #expect(Set(suggested.values).count == 6)
        #expect(suggested[.playPause]?.displayString(keyName: us) == "⌃⌥⌘P")
        #expect(suggested[.next]?.displayString(keyName: us) == "⌃⌥⌘]")
        #expect(suggested[.previous]?.displayString(keyName: us) == "⌃⌥⌘[")
        #expect(suggested[.like]?.displayString(keyName: us) == "⌃⌥⌘L")
        #expect(suggested[.desktopLyrics]?.displayString(keyName: us) == "⌃⌥⌘Y")
        #expect(suggested[.miniPlayer]?.displayString(keyName: us) == "⌃⌥⌘M")

        var b = QTHotKeyBindings()
        let mine = QTKeyCombo(keyCode: 0x00, modifiers: [.control, .command])
        b[.like] = mine
        b[.next] = suggested[.playPause]   // the user put ⌃⌥⌘P on Next
        #expect(b.canApplySuggested(suggested))
        let changed = b.applySuggested(suggested)
        #expect(changed)
        #expect(b[.like] == mine)                         // kept
        #expect(b[.next] == suggested[.playPause])        // kept
        #expect(b[.playPause] == nil)                     // its suggestion is taken: left empty
        #expect(b[.previous] == suggested[.previous])
        #expect(b[.miniPlayer] == suggested[.miniPlayer])
        #expect(!b.canApplySuggested(suggested))
    }

    @Test func suggestedKeysFollowTheLayout() {
        // AZERTY: M is where US has ;. The suggestion follows the letter, not the position.
        let azerty: (String) -> UInt32? = { ["m": 0x29, "p": 0x23][$0] }
        let s = QTHotKeyBindings.suggested(keyCode: azerty)
        #expect(s[.miniPlayer]?.keyCode == 0x29)
        #expect(s[.playPause]?.keyCode == 0x23)
        #expect(s[.like]?.keyCode == 0x25)   // not in that layout's map: the US position
    }

    @Test func oldSettingsWithoutShortcutsStillLoad() throws {
        let json = #"{"theme":"dark","miniPlayer":{"mode":"art"}}"#
        let s = try JSONDecoder().decode(QTSettings.self, from: Data(json.utf8))
        #expect(s.theme == .dark)
        #expect(s.miniPlayer.mode == .art)
        #expect(s.globalHotKeys.isEmpty)
    }

    @Test func shortcutsRoundTripAndBadEntriesAreDropped() throws {
        var s = QTSettings()
        s.globalHotKeys[.playPause] = p
        s.globalHotKeys[.showApp] = QTKeyCombo(keyCode: 0x69, modifiers: [])
        let back = try JSONDecoder().decode(QTSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)

        // An action from a newer version and a broken entry: the rest still loads.
        let json = #"{"globalHotKeys":{"playPause":{"keyCode":35,"modifiers":6400},"teleport":{"keyCode":1,"modifiers":256},"next":{"keyCode":"x"}},"theme":"light"}"#
        let loaded = try JSONDecoder().decode(QTSettings.self, from: Data(json.utf8))
        #expect(loaded.globalHotKeys[.playPause] == p)
        #expect(loaded.globalHotKeys[.next] == nil)
        #expect(loaded.globalHotKeys.all.count == 1)
        #expect(loaded.theme == .light)

        // Not an object at all: no shortcuts, other settings intact.
        let wrong = try JSONDecoder().decode(QTSettings.self, from: Data(#"{"globalHotKeys":[1,2],"theme":"dark"}"#.utf8))
        #expect(wrong.globalHotKeys.isEmpty)
        #expect(wrong.theme == .dark)
    }
}
