import AppKit
import Foundation
import QTCore
import Testing
@testable import QTUI

/// Global shortcuts: the conflict classifier against fixed lists (never the live system), symbolic hot key
/// parsing, menu key equivalents as combos, and the popular-defaults table vs the suggested set. Nothing here
/// registers a hot key.
@MainActor
@Suite struct QTGlobalHotKeysTests {
    private let ctrlOptCmd: QTKeyModifiers = [.control, .option, .command]
    private func us(_ c: String) -> UInt32? { ["p": 0x23, "l": 0x25, "m": 0x2E, "k": 0x28, "f": 0x03, "]": 0x1E, "[": 0x21, "0": 0x1D, "/": 0x2C][c] }

    /// A fixed snapshot of CopySymbolicHotKeys output: Spotlight ⌘Space, input source ⌃Space, Mission Control
    /// ⌃↑ (with the fn bit arrows carry), Invert Colours ⌃⌥⌘8 disabled, and an unset entry.
    private let symbolic: [[String: Any]] = [
        ["kHISymbolicHotKeyCode": 49, "kHISymbolicHotKeyModifiers": 256, "kHISymbolicHotKeyEnabled": 1],
        ["kHISymbolicHotKeyCode": 49, "kHISymbolicHotKeyModifiers": 4096, "kHISymbolicHotKeyEnabled": 1],
        ["kHISymbolicHotKeyCode": 126, "kHISymbolicHotKeyModifiers": 135168, "kHISymbolicHotKeyEnabled": 1],
        ["kHISymbolicHotKeyCode": 28, "kHISymbolicHotKeyModifiers": 6400, "kHISymbolicHotKeyEnabled": 0],
        ["kHISymbolicHotKeyCode": 65535, "kHISymbolicHotKeyModifiers": 0, "kHISymbolicHotKeyEnabled": 1],
    ]

    @Test func symbolicHotKeysKeepEnabledOnesWithFourModifiers() {
        let combos = QTSymbolicHotKeys.combos(from: symbolic)
        #expect(combos == [
            QTKeyCombo(keyCode: 49, modifiers: .command),
            QTKeyCombo(keyCode: 49, modifiers: .control),
            QTKeyCombo(keyCode: 126, modifiers: .control),
        ])
    }

    private var environment: QTHotKeyEnvironment {
        QTHotKeyEnvironment(
            system: QTSymbolicHotKeys.combos(from: symbolic),
            menu: [QTMenuShortcut(combo: QTKeyCombo(keyCode: 0x25, modifiers: .command), path: "Controls › Like"),
                   QTMenuShortcut(combo: QTKeyCombo(keyCode: 0x2E, modifiers: [.shift, .command]), path: "Controls › Mini Player")],
            apps: QTPopularHotKeys.table.filter { $0.appName == "Rectangle" || $0.appName == "Raycast" })
    }

    @Test func classifierOrder() {
        let env = environment
        let free = QTKeyCombo(keyCode: 0x23, modifiers: ctrlOptCmd)
        #expect(QTHotKeyConflict.classify(free, failure: nil, environment: env) == nil)
        // Registration failures come first, whatever else matches.
        #expect(QTHotKeyConflict.classify(free, failure: .taken, environment: env) == .takenByAnotherApp)
        #expect(QTHotKeyConflict.classify(free, failure: .rejected(-9868), environment: env) == .rejected)
        let spotlight = QTKeyCombo(keyCode: 49, modifiers: .command)
        #expect(QTHotKeyConflict.classify(spotlight, failure: .taken, environment: env) == .takenByAnotherApp)
        #expect(QTHotKeyConflict.classify(spotlight, failure: nil, environment: env) == .system)
        // A disabled system shortcut is no conflict.
        #expect(QTHotKeyConflict.classify(QTKeyCombo(keyCode: 28, modifiers: ctrlOptCmd), failure: nil, environment: env) == nil)
        // Installed apps' defaults.
        #expect(QTHotKeyConflict.classify(QTKeyCombo(keyCode: 0x7C, modifiers: [.control, .option]), failure: nil, environment: env) == .app("Rectangle"))
        #expect(QTHotKeyConflict.classify(QTKeyCombo(keyCode: 0x7B, modifiers: ctrlOptCmd), failure: nil, environment: env) == .app("Rectangle"))
        #expect(QTHotKeyConflict.classify(QTKeyCombo(keyCode: 49, modifiers: .option), failure: nil, environment: env) == .app("Raycast"))
        // Our own menus: a note, not a warning.
        let like = QTHotKeyConflict.classify(QTKeyCombo(keyCode: 0x25, modifiers: .command), failure: nil, environment: env)
        #expect(like == .menu("Controls › Like"))
        #expect(like?.isWarning == false)
        #expect(QTHotKeyConflict.takenByAnotherApp.isWarning)
        #expect(QTHotKeyConflict.takenByAnotherApp.message == QTLoc.tr("Used by another app", table: .desktop))
        #expect(QTHotKeyConflict.menu("Controls › Like").message.contains("Controls › Like"))
    }

    @Test func suggestedSetIsClearOfKnownDefaults() {
        let env = QTHotKeyEnvironment(system: QTSymbolicHotKeys.combos(from: symbolic), menu: [], apps: QTPopularHotKeys.table)
        for (_, combo) in QTHotKeyBindings.suggested() {
            #expect(QTHotKeyConflict.classify(combo, failure: nil, environment: env) == nil)
        }
    }

    @Test func menuKeyEquivalentsBecomeCombos() {
        let combo = { (key: String, mods: NSEvent.ModifierFlags) in QTMenuShortcuts.combo(keyEquivalent: key, modifiers: mods, keyCode: us) }
        #expect(combo("l", .command) == QTKeyCombo(keyCode: 0x25, modifiers: .command))
        // Uppercase means ⇧ (AppKit's convention), whether or not the mask says so.
        #expect(combo("M", .command) == QTKeyCombo(keyCode: 0x2E, modifiers: [.shift, .command]))
        #expect(combo("m", [.command, .shift]) == QTKeyCombo(keyCode: 0x2E, modifiers: [.shift, .command]))
        #expect(combo(String(UnicodeScalar(0xF703)!), .command) == QTKeyCombo(keyCode: 0x7C, modifiers: .command))
        #expect(combo(String(UnicodeScalar(0xF700)!), .option) == QTKeyCombo(keyCode: 0x7E, modifiers: .option))
        #expect(combo(" ", []) == QTKeyCombo(keyCode: 0x31, modifiers: []))
        #expect(combo(String(UnicodeScalar(0xF704)!), .command) == QTKeyCombo(keyCode: 0x7A, modifiers: .command)) // F1
        #expect(combo("", .command) == nil)
        #expect(combo("é", .command) == nil)   // not on this layout
    }

    @Test func menuWalkReportsPaths() {
        let main = NSMenu()
        let controlsItem = NSMenuItem(title: "Controls", action: nil, keyEquivalent: "")
        let controls = NSMenu(title: "Controls")
        controls.addItem(NSMenuItem(title: "Like", action: nil, keyEquivalent: "l"))
        controls.addItem(.separator())
        let mini = NSMenuItem(title: "Mini Player", action: nil, keyEquivalent: "m")
        mini.keyEquivalentModifierMask = [.command, .shift]
        controls.addItem(mini)
        controls.addItem(NSMenuItem(title: "Shuffle", action: nil, keyEquivalent: ""))
        controlsItem.submenu = controls
        main.addItem(controlsItem)
        let found = QTMenuShortcuts.collect(main, keyCode: us)
        #expect(found == [
            QTMenuShortcut(combo: QTKeyCombo(keyCode: 0x25, modifiers: .command), path: "Controls › Like"),
            QTMenuShortcut(combo: QTKeyCombo(keyCode: 0x2E, modifiers: [.shift, .command]), path: "Controls › Mini Player"),
        ])
    }

    @Test func everyActionHasATitleAndAStableID() {
        let ids = QTGlobalHotKeyAction.allCases.map(\.hotKeyID)
        #expect(ids == Array(1...UInt32(ids.count)))
        for action in QTGlobalHotKeyAction.allCases { #expect(!QTGlobalHotKeys.title(for: action).isEmpty) }
    }

    @Test func settingsHasAShortcutsTabBeforeAdvanced() {
        let tabs = QTSettingsTab.allCases
        #expect(tabs.firstIndex(of: .shortcuts) == tabs.firstIndex(of: .integrations).map { $0 + 1 })
        #expect(tabs.last == .advanced)
    }
}
