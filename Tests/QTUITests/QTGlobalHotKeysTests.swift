import AppKit
import Foundation
import QTCore
import QTLyrics
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
        let inputSource = QTKeyCombo(keyCode: 49, modifiers: .control)
        #expect(QTHotKeyConflict.classify(inputSource, failure: .taken, environment: env) == .takenByAnotherApp)
        #expect(QTHotKeyConflict.classify(inputSource, failure: nil, environment: env) == .system)
        // ⌘ + one key (Spotlight's ⌘Space, ⌘L) can't be global at all: that comes first.
        let spotlight = QTKeyCombo(keyCode: 49, modifiers: .command)
        #expect(QTHotKeyConflict.classify(spotlight, failure: .notAllowed, environment: env) == .notAllowed(.needsAnotherModifier))
        // A disabled system shortcut is no conflict.
        #expect(QTHotKeyConflict.classify(QTKeyCombo(keyCode: 28, modifiers: ctrlOptCmd), failure: nil, environment: env) == nil)
        // Installed apps' defaults.
        #expect(QTHotKeyConflict.classify(QTKeyCombo(keyCode: 0x7C, modifiers: [.control, .option]), failure: nil, environment: env) == .app("Rectangle"))
        #expect(QTHotKeyConflict.classify(QTKeyCombo(keyCode: 0x7B, modifiers: ctrlOptCmd), failure: nil, environment: env) == .app("Rectangle"))
        #expect(QTHotKeyConflict.classify(QTKeyCombo(keyCode: 0x31, modifiers: [.control, .option]), failure: nil, environment: QTHotKeyEnvironment(apps: [QTPopularHotKey(appName: "Launcher", bundleID: "x", combo: QTKeyCombo(keyCode: 0x31, modifiers: [.control, .option]))])) == .app("Launcher"))
        // Raycast's ⌥Space can't be recorded at all (no ⌘ or ⌃).
        #expect(QTHotKeyConflict.classify(QTKeyCombo(keyCode: 49, modifiers: .option), failure: nil, environment: env) == .notAllowed(.needsCommandOrControl))
        // Our own menus: a warning (the hot key takes the key before the menu item can).
        let mini = QTHotKeyConflict.classify(QTKeyCombo(keyCode: 0x2E, modifiers: [.shift, .command]), failure: nil, environment: env)
        #expect(mini == .menu("Controls › Mini Player"))
        #expect(mini?.message == QTLoc.tr("Replaces %@ in the menu bar", table: .desktop, "Controls › Mini Player"))
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

    /// ⌘W while recording closes the window (recording ends, the key goes on); ⌃ + a letter is refused with a reason;
    /// two modifiers record.
    @Test func recorderLetsStandardCommandsThrough() {
        typealias Field = QTShortcutRecorderField
        #expect(Field.decision(for: QTKeyCombo(keyCode: 0x0D, modifiers: .command)) == .passThrough)   // ⌘W
        #expect(Field.decision(for: QTKeyCombo(keyCode: 0x0C, modifiers: .command)) == .passThrough)   // ⌘Q
        #expect(Field.decision(for: QTKeyCombo(keyCode: 0x7B, modifiers: .command)) == .passThrough)   // ⌘←
        #expect(Field.decision(for: QTKeyCombo(keyCode: 0x00, modifiers: .control))
                == .refuse(QTLoc.tr("Add another modifier key", table: .desktop)))
        #expect(Field.decision(for: QTKeyCombo(keyCode: 0x23, modifiers: .option)) == .refuse(QTLoc.tr("Include ⌘ or ⌃", table: .desktop)))
        #expect(Field.decision(for: QTKeyCombo(keyCode: 0x23, modifiers: ctrlOptCmd)) == .record)
        #expect(Field.decision(for: QTKeyCombo(keyCode: 0x69, modifiers: [])) == .record)
    }

    /// A ⌘-only binding that arrives through defaults is never registered, and Settings says why.
    @Test func disallowedStoredBindingsAreNotRegistered() {
        let bindings: [QTGlobalHotKeyAction: QTKeyCombo] = [.like: QTKeyCombo(keyCode: 0x25, modifiers: .command),
                                                            .next: QTKeyCombo(keyCode: 0x1E, modifiers: ctrlOptCmd)]
        #expect(QTGlobalHotKeys.registrable(bindings) == [.next: QTKeyCombo(keyCode: 0x1E, modifiers: ctrlOptCmd)])
        #expect(QTHotKeyConflict.classify(bindings[.like]!, failure: .notAllowed, environment: environment)
                == .notAllowed(.needsAnotherModifier))
    }

    /// Suspension is counted: one field ending can't turn hot keys back on under another, and a field released
    /// while recording gives its hold back.
    @Test func suspensionIsCountedAndReleasedOnDeinit() {
        let hotKeys = QTGlobalHotKeys.shared
        #expect(!hotKeys.isSuspended)
        let a = hotKeys.suspend(), b = hotKeys.suspend()
        hotKeys.resume(a)
        #expect(hotKeys.isSuspended)
        hotKeys.resume(b)
        #expect(!hotKeys.isSuspended)

        autoreleasepool {
            let field = QTShortcutRecorderField()
            field.startRecording()
            #expect(hotKeys.isSuspended)
        }
        #expect(!hotKeys.isSuspended)
    }

    /// The background Like says what happened, in the toast's words: the account or this Mac, or why nothing changed.
    @Test func likeHotKeyAnnouncesTheOutcome() {
        let song = QTTrack(videoId: "likeMe0001", title: "Song", artists: [QTArtistRef(name: "Artist")], duration: 200)
        let catalog = QTMockCatalog(tracks: [song], liked: QTPlaylist(id: "LM", title: .localized("Liked Songs"), kind: .liked, tracks: []))
        let player = QTPlayerModel(engine: QTUIStubEngine(), lyricsProvider: QTMockLyricsProvider(catalog: catalog))
        #expect(QTGlobalHotKeys.toggleLike(song, player: player, guest: false, savesToAccount: true) == QTLoc.tr("Added to Liked Songs"))
        #expect(QTGlobalHotKeys.toggleLike(song, player: player, guest: false, savesToAccount: false)
                == QTLoc.tr("Removed from Liked Songs on this Mac", table: .live))
        // Refused (nothing changed): the gate's reason, not a false "Added".
        player.likeHandler = { _, _ in }
        #expect(QTGlobalHotKeys.toggleLike(song, player: player, guest: true, savesToAccount: true)
                == QTLoc.tr("Sign in to like songs", table: .live))
    }

    @Test func settingsHasAShortcutsTabBeforeAdvanced() {
        let tabs = QTSettingsTab.allCases
        #expect(tabs.firstIndex(of: .shortcuts) == tabs.firstIndex(of: .integrations).map { $0 + 1 })
        #expect(tabs.last == .advanced)
    }
}
