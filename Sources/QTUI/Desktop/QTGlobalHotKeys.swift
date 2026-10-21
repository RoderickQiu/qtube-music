import AppKit
import Carbon
import Observation
import QTCore

// Owner: builder "desktop". System-wide shortcuts (Settings › Shortcuts). Carbon's RegisterEventHotKey: no
// Accessibility permission, the key press is consumed, and a combo another app holds exclusively fails with
// eventHotKeyExistsErr. (NSEvent global monitors need Accessibility and can't consume the key.)
//
// None is set by default — media keys and the Shortcuts app already control playback. While a shortcut field
// records, every hot key is unregistered so the keys reach the field. Debug launches with `-qt.*` arguments
// (screenshots, scripted runs) never register any, so they can't take keys from the user's session.

@MainActor
@Observable
public final class QTGlobalHotKeys {
    public static let shared = QTGlobalHotKeys()

    /// Actions whose combo couldn't be registered (shown inline in Settings).
    public private(set) var failures: [QTGlobalHotKeyAction: QTHotKeyRegistrationFailure] = [:]
    /// What else on this Mac uses keys, for the conflict notes. Refreshed when Settings › Shortcuts shows.
    private(set) var environment = QTHotKeyEnvironment()
    /// True while a shortcut field records: hot keys are off so the keys reach the field.
    public var isSuspended: Bool { !suspensions.isEmpty }
    /// One token per field that records (`suspend()` / `resume(_:)`), so one field ending can't turn hot keys back
    /// on under another, and a field that goes away can't leave them off.
    private var suspensions: Set<UUID> = [] {
        didSet { if suspensions.isEmpty != oldValue.isEmpty { sync() } }
    }

    @ObservationIgnored private weak var model: QTAppModel?
    @ObservationIgnored private var registered: [QTGlobalHotKeyAction: (combo: QTKeyCombo, ref: EventHotKeyRef)] = [:]
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var registers = true
    @ObservationIgnored private var simulatedTaken: Set<QTGlobalHotKeyAction> = []

    /// 'QTHK': tells our hot key events apart from anyone else's on the dispatcher target.
    nonisolated static let signature: OSType = 0x5154_484B

    public func start(model: QTAppModel) {
        guard self.model == nil else { return }
        self.model = model
        #if DEBUG
        let launch = model.launch
        registers = launch.raw.isEmpty || launch.bool(QTDesktopLaunchKey.registerHotKeys) == true
        let preset = launch.string(QTDesktopLaunchKey.hotKeys)
        if preset == "suggested" || preset == "conflicts" {
            let suggested = QTKeyboardLayout.shared.suggested()
            model.settings.override {
                $0.globalHotKeys.applySuggested(suggested)
                // `conflicts`: one shortcut our menus use (⇧⌘M) and a stored ⌘-only one (⌘L), as if from defaults.
                if preset == "conflicts" {
                    $0.globalHotKeys[.miniPlayer] = QTKeyCombo(keyCode: QTKeyboardLayout.shared.keyCode(for: "m") ?? 0x2E,
                                                               modifiers: [.shift, .command])
                    $0.globalHotKeys[.showApp] = QTKeyCombo(keyCode: QTKeyboardLayout.shared.keyCode(for: "l") ?? 0x25, modifiers: .command)
                }
            }
        }
        simulatedTaken = Set((launch.string(QTDesktopLaunchKey.hotKeyTaken) ?? "").split(separator: ",")
            .compactMap { QTGlobalHotKeyAction(rawValue: String($0)) })
        #endif
        installHandler()
        observe()
    }

    // MARK: Registration

    /// Turns every hot key off until the token is handed back.
    func suspend() -> UUID {
        let token = UUID()
        suspensions.insert(token)
        return token
    }

    func resume(_ token: UUID) {
        suspensions.remove(token)
    }

    private func observe() {
        withObservationTracking {
            _ = model?.settings.settings.globalHotKeys
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        sync()
    }

    private func sync() {
        guard let model else { return }
        let bindings = model.settings.settings.globalHotKeys.all
        let wanted = isSuspended || !registers ? [:] : Self.registrable(bindings)
        for (action, entry) in registered where wanted[action] != entry.combo {
            UnregisterEventHotKey(entry.ref)
            registered[action] = nil
        }
        // Failures stay as they were while recording (nothing is registered then).
        guard !isSuspended else { return }
        var failed: [QTGlobalHotKeyAction: QTHotKeyRegistrationFailure] = [:]
        for (action, combo) in bindings where !combo.isAllowedAsGlobal { failed[action] = .notAllowed }
        for action in simulatedTaken where model.settings.settings.globalHotKeys[action] != nil { failed[action] = .taken }
        for (action, combo) in wanted where registered[action] == nil && failed[action] == nil {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: action.hotKeyID)
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers.rawValue, id, GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref {
                registered[action] = (combo, ref)
            } else {
                failed[action] = status == eventHotKeyExistsErr ? .taken : .rejected(status)
            }
        }
        if failed != failures { failures = failed }
    }

    /// The bindings that may be registered. Combos the recorder refuses can still arrive through defaults or an
    /// older build: never registered (Settings shows why).
    static func registrable(_ bindings: [QTGlobalHotKeyAction: QTKeyCombo]) -> [QTGlobalHotKeyAction: QTKeyCombo] {
        bindings.filter { $0.value.isAllowedAsGlobal }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var id = EventHotKeyID()
            guard let event,
                  GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == QTGlobalHotKeys.signature else { return OSStatus(eventNotHandledErr) }
            let raw = id.id
            // Carbon delivers hot keys on the main thread, from the app's event loop.
            QTMainActorHop.run { QTGlobalHotKeys.shared.fire(raw) }
            return noErr
        }, 1, &type, nil, &handler)
    }

    private func fire(_ id: UInt32) {
        guard !isSuspended, let action = QTGlobalHotKeyAction.allCases.first(where: { $0.hotKeyID == id }) else { return }
        perform(action)
    }

    // MARK: Actions

    /// Runs `action` the way its menu item does. Nothing here activates the app except Show QTube Music and leaving
    /// the mini player (both bring the main window, as the user asked).
    public func perform(_ action: QTGlobalHotKeyAction) {
        guard let model else { return }
        let player = model.player
        let desktop = QTDesktopCoordinator.shared
        switch action {
        case .playPause: QTScripting.perform(.playPause)
        case .next: QTScripting.perform(.next)
        case .previous: QTScripting.perform(.previous)
        case .like:
            // Controls › Like's path (the account when Sync is on, else this Mac; in guest mode the gate shows its
            // sign-in toast). The app is usually in the background, so VoiceOver hears what happened, in the same
            // words as the toast; the menu bar extra and the Dock menu show the heart.
            guard let track = player.nowPlaying, player.ad == nil else { return }
            announce(Self.toggleLike(track, player: player, guest: QTLiveCatalogStore.shared.isGuest,
                                     savesToAccount: QTAccountWriter.shared.savesToAccount))
        case .desktopLyrics: desktop.toggleDesktopLyrics()
        case .miniPlayer: desktop.toggleMiniPlayer()
        case .showApp:
            // A toggle, like a launcher's app hot key: brings the window, or hides the app when it's already in front.
            if NSApp.isActive, model.surface != .mini, let w = desktop.mainWindow, w.isVisible, w.isKeyWindow {
                NSApp.hide(nil)
            } else {
                desktop.showMainWindow()
            }
        }
    }

    /// Toggles the like and says what happened: where the like went, or why nothing changed (guest mode).
    static func toggleLike(_ track: QTTrack, player: QTPlayerModel, guest: Bool, savesToAccount: Bool) -> String {
        let wasLiked = player.isLiked(track)
        player.toggleLike(track)
        guard player.isLiked(track) != wasLiked else {
            return guest ? QTLoc.tr("Sign in to like songs", table: .live)
                : QTLoc.tr(wasLiked ? "Couldn’t remove “%@” from Liked Songs" : "Couldn’t like “%@”", table: .live, track.title)
        }
        return savesToAccount
            ? QTLoc.tr(wasLiked ? "Removed from Liked Songs" : "Added to Liked Songs")
            : QTLoc.tr(wasLiked ? "Removed from Liked Songs on this Mac" : "Liked on this Mac", table: .live)
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    public static func title(for action: QTGlobalHotKeyAction) -> String {
        switch action {
        case .playPause: QTLoc.tr("Play/Pause", table: .desktop)
        case .next: QTLoc.tr("Next Song", table: .desktop)
        case .previous: QTLoc.tr("Previous Song", table: .desktop)
        case .like: QTLoc.tr("Like/Unlike", table: .desktop)
        case .desktopLyrics: QTLoc.tr("Show/Hide Desktop Lyrics", table: .desktop)
        case .miniPlayer: QTLoc.tr("Show/Hide Mini Player", table: .desktop)
        case .showApp: QTLoc.tr("Show QTube Music", table: .desktop)
        }
    }

    // MARK: Conflicts

    /// Re-reads the system's shortcuts, our menus and which known apps are installed.
    public func refreshEnvironment() {
        let layout = QTKeyboardLayout.shared
        environment = QTHotKeyEnvironment(system: QTSymbolicHotKeys.enabled(),
                                          menu: QTMenuShortcuts.collect(NSApp.mainMenu, keyCode: layout.keyCode(for:)),
                                          apps: QTPopularHotKeys.installed())
    }

    /// What, if anything, gets in the way of `action`'s shortcut.
    public func conflict(for action: QTGlobalHotKeyAction) -> QTHotKeyConflict? {
        guard let combo = model?.settings.settings.globalHotKeys[action] else { return nil }
        return QTHotKeyConflict.classify(combo, failure: failures[action], environment: environment)
    }
}

extension QTGlobalHotKeyAction {
    /// Carbon hot key id: 1-based position (0 is never sent).
    var hotKeyID: UInt32 { UInt32((Self.allCases.firstIndex(of: self) ?? 0) + 1) }
}

public enum QTHotKeyRegistrationFailure: Equatable, Sendable {
    /// eventHotKeyExistsErr: another app registered it exclusively.
    case taken
    case rejected(OSStatus)
    /// Not registered: the combo isn't allowed as a global shortcut (`QTKeyCombo.globalRefusal`; a stored binding
    /// from defaults or an older build).
    case notAllowed
}

// MARK: - Conflict classifier

/// Everything the classifier compares against (plain data, so tests pass fixed lists).
struct QTHotKeyEnvironment: Equatable, Sendable {
    /// Enabled system shortcuts (System Settings › Keyboard › Keyboard Shortcuts).
    var system: [QTKeyCombo] = []
    /// Our menu key equivalents with their "Menu › Item" path.
    var menu: [QTMenuShortcut] = []
    /// Defaults of installed launcher / window-manager apps.
    var apps: [QTPopularHotKey] = []
}

struct QTMenuShortcut: Equatable, Sendable {
    var combo: QTKeyCombo
    var path: String
}

public enum QTHotKeyConflict: Equatable, Sendable {
    case notAllowed(QTKeyCombo.GlobalRefusal)
    case takenByAnotherApp
    case rejected
    case system
    case app(String)
    case menu(String)

    /// The first that applies, most certain first: the combo can't be global at all, our registration failed, macOS
    /// has it, an installed app has it by default, our own menus use it.
    static func classify(_ combo: QTKeyCombo, failure: QTHotKeyRegistrationFailure?, environment: QTHotKeyEnvironment) -> QTHotKeyConflict? {
        if let refusal = combo.globalRefusal { return .notAllowed(refusal) }
        switch failure {
        case .taken: return .takenByAnotherApp
        case .rejected: return .rejected
        case .notAllowed, nil: break
        }
        if environment.system.contains(combo) { return .system }
        if let app = environment.apps.first(where: { $0.combo == combo }) { return .app(app.appName) }
        if let item = environment.menu.first(where: { $0.combo == combo }) { return .menu(item.path) }
        return nil
    }

    /// Shown as a warning, a menu clash too: the hot key is taken before our menus see the key, so that menu item
    /// loses its shortcut.
    public var message: String {
        switch self {
        case .notAllowed(.needsCommandOrControl): QTLoc.tr("Include ⌘ or ⌃", table: .desktop)
        case .notAllowed(.needsAnotherModifier): QTLoc.tr("Add another modifier key", table: .desktop)
        case .takenByAnotherApp: QTLoc.tr("Used by another app", table: .desktop)
        case .rejected: QTLoc.tr("macOS didn’t accept this shortcut", table: .desktop)
        case .system: QTLoc.tr("Used by macOS (System Settings › Keyboard › Keyboard Shortcuts)", table: .desktop)
        case .app(let name): QTLoc.tr("%@ uses this by default", table: .desktop, name)
        case .menu(let path): QTLoc.tr("Replaces %@ in the menu bar", table: .desktop, path)
        }
    }
}

// MARK: - Popular defaults

/// Default global shortcuts of popular launchers, window managers and utilities, checked only when the app is
/// installed. Their own registrations don't always make ours fail (only exclusive ones do), so they're listed here.
struct QTPopularHotKey: Equatable, Sendable {
    var appName: String
    var bundleID: String
    var combo: QTKeyCombo
}

enum QTPopularHotKeys {
    static let table: [QTPopularHotKey] = {
        let ctrlOpt: QTKeyModifiers = [.control, .option]
        let ctrlOptCmd: QTKeyModifiers = [.control, .option, .command]
        // Rectangle's recommended set and Magnet: halves (arrows), maximize (↩), centre (C), restore (⌫), thirds
        // (D F G E T), quarters (U I J K), next/previous display (⌃⌥⌘ ←/→).
        let windowKeys: [UInt32] = [0x7B, 0x7C, 0x7E, 0x7D, 0x24, 0x08, 0x33, 0x02, 0x03, 0x05, 0x0E, 0x11, 0x20, 0x22, 0x26, 0x28]
        func windows(_ name: String, _ id: String) -> [QTPopularHotKey] {
            windowKeys.map { QTPopularHotKey(appName: name, bundleID: id, combo: QTKeyCombo(keyCode: $0, modifiers: ctrlOpt)) }
                + [0x7B, 0x7C].map { QTPopularHotKey(appName: name, bundleID: id, combo: QTKeyCombo(keyCode: $0, modifiers: ctrlOptCmd)) }
        }
        let space = QTKeyCombo.space
        return [
            QTPopularHotKey(appName: "Raycast", bundleID: "com.raycast.macos", combo: QTKeyCombo(keyCode: space, modifiers: .option)),
            QTPopularHotKey(appName: "Alfred", bundleID: "com.runningwithcrayons.Alfred", combo: QTKeyCombo(keyCode: space, modifiers: .option)),
            QTPopularHotKey(appName: "Alfred", bundleID: "com.runningwithcrayons.Alfred", combo: QTKeyCombo(keyCode: 0x08, modifiers: [.option, .command])),
            QTPopularHotKey(appName: "ChatGPT", bundleID: "com.openai.chat", combo: QTKeyCombo(keyCode: space, modifiers: .option)),
            QTPopularHotKey(appName: "1Password", bundleID: "com.1password.1password", combo: QTKeyCombo(keyCode: space, modifiers: [.shift, .command])),
            QTPopularHotKey(appName: "Maccy", bundleID: "org.p0deje.Maccy", combo: QTKeyCombo(keyCode: 0x08, modifiers: [.shift, .command])),
        ] + windows("Rectangle", "com.knollsoft.Rectangle") + windows("Magnet", "com.crowdcafe.windowmagnet")
    }()

    @MainActor static func installed() -> [QTPopularHotKey] {
        let ids = Set(table.map(\.bundleID)).filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        return table.filter { ids.contains($0.bundleID) }
    }
}

// MARK: - System shortcuts

enum QTSymbolicHotKeys {
    private typealias Copy = @convention(c) (UnsafeMutablePointer<Unmanaged<CFArray>?>) -> OSStatus

    /// The enabled shortcuts in System Settings › Keyboard › Keyboard Shortcuts. `CopySymbolicHotKeys` is exported
    /// by HIToolbox but no longer declared in the SDK's headers, so it's looked up at run time; its dictionary keys
    /// are the names of the old `kHISymbolicHotKey…` constants.
    static func enabled() -> [QTKeyCombo] {
        guard let lib = dlopen("/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/HIToolbox", RTLD_LAZY),
              let symbol = dlsym(lib, "CopySymbolicHotKeys") else { return [] }
        var out: Unmanaged<CFArray>?
        guard unsafeBitCast(symbol, to: Copy.self)(&out) == noErr,
              let entries = out?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return combos(from: entries)
    }

    static func combos(from entries: [[String: Any]]) -> [QTKeyCombo] {
        entries.compactMap { entry in
            guard (entry["kHISymbolicHotKeyEnabled"] as? NSNumber)?.boolValue == true,
                  let code = (entry["kHISymbolicHotKeyCode"] as? NSNumber)?.intValue, (0..<0xFFFF).contains(code),
                  let mods = (entry["kHISymbolicHotKeyModifiers"] as? NSNumber)?.uint32Value else { return nil }
            // Arrow and F-key entries carry the fn bit; only the four modifiers matter here.
            return QTKeyCombo(keyCode: UInt32(code), modifiers: QTKeyModifiers(rawValue: mods))
        }
    }
}

// MARK: - Our menus

enum QTMenuShortcuts {
    /// Every key equivalent in `menu`, as "Menu › Item".
    @MainActor static func collect(_ menu: NSMenu?, keyCode: (String) -> UInt32?) -> [QTMenuShortcut] {
        guard let menu else { return [] }
        var result: [QTMenuShortcut] = []
        func walk(_ menu: NSMenu, path: [String]) {
            for item in menu.items where !item.isSeparatorItem {
                let title = item.title.isEmpty ? (item.submenu?.title ?? "") : item.title
                if let sub = item.submenu {
                    walk(sub, path: path + [title])
                } else if let combo = combo(keyEquivalent: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask, keyCode: keyCode) {
                    result.append(QTMenuShortcut(combo: combo, path: (path + [title]).joined(separator: " › ")))
                }
            }
        }
        walk(menu, path: [])
        return result
    }

    /// An NSMenuItem key equivalent as a combo: an uppercase letter means ⇧, function-key characters (arrows,
    /// F-keys) and control characters map to their keys, the rest is looked up in the layout.
    static func combo(keyEquivalent: String, modifiers: NSEvent.ModifierFlags, keyCode: (String) -> UInt32?) -> QTKeyCombo? {
        guard let scalar = keyEquivalent.unicodeScalars.first else { return nil }
        var mods = QTKeyModifiers(modifiers)
        let fixed: [UInt32: UInt32] = [
            0xF700: 0x7E, 0xF701: 0x7D, 0xF702: 0x7B, 0xF703: 0x7C, 0xF728: QTKeyCombo.forwardDelete,
            0xF729: 0x73, 0xF72B: 0x77, 0xF72C: 0x74, 0xF72D: 0x79, 0x0D: QTKeyCombo.returnKey, 0x03: 0x4C,
            0x09: QTKeyCombo.tab, 0x20: QTKeyCombo.space, 0x08: QTKeyCombo.delete, 0x7F: QTKeyCombo.delete, 0x1B: QTKeyCombo.escape,
        ]
        if let code = fixed[scalar.value] { return QTKeyCombo(keyCode: code, modifiers: mods) }
        if (0xF704...0xF717).contains(scalar.value) {   // NSF1FunctionKey…NSF20FunctionKey
            let n = Int(scalar.value - 0xF704) + 1
            guard let code = QTKeyCombo.functionKeyNumbers.first(where: { $0.value == n })?.key else { return nil }
            return QTKeyCombo(keyCode: code, modifiers: mods)
        }
        let lower = keyEquivalent.lowercased()
        if lower != keyEquivalent { mods.insert(.shift) }
        guard let code = keyCode(lower) else { return nil }
        return QTKeyCombo(keyCode: code, modifiers: mods)
    }
}

extension QTKeyModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.shift) { insert(.shift) }
    }
}

// MARK: - Keyboard layout

/// Key names from the current keyboard layout (UCKeyTranslate), so ⌃⌥⌘] reads ⌃⌥⌘+ on a German keyboard.
/// Observable: views that show combos redraw when the input source changes.
@MainActor
@Observable
public final class QTKeyboardLayout {
    public static let shared = QTKeyboardLayout()

    /// Bumped when the input source changes.
    public private(set) var revision = 0
    @ObservationIgnored private var names: [UInt32: String] = [:]
    @ObservationIgnored private var codes: [String: UInt32]?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { _ in
            QTMainActorHop.run { QTKeyboardLayout.shared.reset() }
        }
    }

    private func reset() {
        names = [:]
        codes = nil
        revision += 1
    }

    /// "⌃⌥⌘P".
    public func display(_ combo: QTKeyCombo) -> String {
        _ = revision
        return combo.displayString { name(for: $0) }
    }

    /// The character `keyCode` types without modifiers, or nil for keys that type nothing.
    public func name(for keyCode: UInt32) -> String? {
        if let n = names[keyCode] { return n.isEmpty ? nil : n }
        let n = Self.translate(keyCode)
        names[keyCode] = n ?? ""
        return n
    }

    /// The key that types `character` (lowercase) without modifiers in this layout.
    public func keyCode(for character: String) -> UInt32? {
        if codes == nil {
            var map: [String: UInt32] = [:]
            // Lower codes first: the main block wins over the keypad for digits.
            for code in (0..<UInt32(0x7F)).reversed() where QTKeyCombo.fixedKeyName(code) == nil {
                if let n = name(for: code), !n.isEmpty { map[n.lowercased()] = code }
            }
            codes = map
        }
        return codes?[character.lowercased()]
    }

    /// The suggested set, with keys placed for this layout.
    public func suggested() -> [QTGlobalHotKeyAction: QTKeyCombo] {
        QTHotKeyBindings.suggested(keyCode: keyCode(for:))
    }

    private static func translate(_ keyCode: UInt32) -> String? {
        // Input methods (Pinyin, Japanese) have no key layout data of their own; their ASCII layout does.
        let sources = [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()]
        for case let source? in sources.map({ $0?.takeRetainedValue() }) {
            guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
            guard let bytes = CFDataGetBytePtr(data) else { continue }
            return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                            OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
                guard status == noErr, length > 0 else { return nil }
                let s = String(utf16CodeUnits: chars, count: length)
                return s.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespaces.contains($0) }) ? nil : s
            }
        }
        return nil
    }
}
