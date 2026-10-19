import Foundation
import Observation
import Synchronization

/// The interface languages that ship (draft §7b). Adding one = adding an `.lproj` translation + a case here.
public enum QTResolvedInterfaceLanguage: String, Sendable, Hashable, CaseIterable {
    case en = "en"
    case zhHans = "zh-Hans"

    /// `.lproj` folder name inside the QTCore resource bundle.
    public var lprojName: String { rawValue }
}

/// String Catalog tables. Shared keys (everything ported from the prototype's i18n.jsx) live in `.shared`;
/// each UI area adds new keys only to its own table so parallel builders never conflict.
/// Files: `Sources/QTCore/Resources/Localization/<rawValue>.xcstrings`.
public enum QTStringTable: String, Sendable, CaseIterable {
    case shared = "Localizable"
    /// Shell, Sidebar, Home, Library (builder "window").
    case main = "Main"
    /// NowPlaying, PlayerBar, Queue (builder "player").
    case player = "Player"
    /// Lyrics UI + QTLyrics module messages (builders "lyrics-ui" / lyrics).
    case lyrics = "Lyrics"
    /// Stage (builder "stage").
    case stage = "Stage"
    /// Desktop (mini player, menu bar, desktop lyrics), Commands, Settings, app target (builder "desktop").
    case desktop = "Desktop"
    /// Live YouTube Music data: sign-in, signed-out / loading / error states, search, artist pages (builder "data-live").
    case live = "Live"
}

/// Runtime-switchable localization. Thread-safe; observable so SwiftUI bodies that call `QTLoc.tr`
/// re-render when the interface language changes (no restart).
public final class QTLocalizer: Observable, Sendable {
    public static let shared = QTLocalizer()

    private struct State {
        var preference: QTInterfaceLanguage
        var language: QTResolvedInterfaceLanguage
        var bundle: Bundle
    }

    private let registrar = ObservationRegistrar()
    private let state: Mutex<State>
    private let resources: Bundle
    /// Sentinel returned by `localizedString` for a missing key.
    private static let missing = "\u{1}qt-missing\u{1}"

    /// - Parameter resources: bundle containing the `.lproj` folders; nil = QTCore's resource bundle.
    public init(resources: Bundle? = nil, preference: QTInterfaceLanguage = .automatic) {
        let resources = resources ?? Bundle.module
        self.resources = resources
        let lang = Self.resolve(preference)
        state = Mutex(State(preference: preference, language: lang, bundle: Self.bundle(for: lang, in: resources)))
    }

    /// The user's choice (may be `.automatic`).
    public var preference: QTInterfaceLanguage {
        registrar.access(self, keyPath: \.language)
        return state.withLock { $0.preference }
    }

    /// The language strings are currently served in.
    public var language: QTResolvedInterfaceLanguage {
        registrar.access(self, keyPath: \.language)
        return state.withLock { $0.language }
    }

    /// Locale for formatting: the interface language + the user's region/calendar preferences.
    public var locale: Locale {
        let lang = language
        var comps = Locale.Components(locale: .current)
        comps.languageComponents = Locale.Language.Components(identifier: lang.rawValue)
        return Locale(components: comps)
    }

    public func setPreference(_ preference: QTInterfaceLanguage) {
        let lang = Self.resolve(preference)
        let current = state.withLock { ($0.preference, $0.language) }
        guard current != (preference, lang) else { return }
        let bundle = Self.bundle(for: lang, in: resources)
        registrar.withMutation(of: self, keyPath: \.language) {
            state.withLock { $0 = State(preference: preference, language: lang, bundle: bundle) }
        }
    }

    /// Looks `key` up in `table`, falling back to the shared table, then to the key itself (English source).
    public func string(_ key: String, table: QTStringTable = .shared) -> String {
        registrar.access(self, keyPath: \.language)
        let bundle = state.withLock { $0.bundle }
        let value = bundle.localizedString(forKey: key, value: Self.missing, table: table.rawValue)
        if value != Self.missing { return value }
        if table != .shared {
            let shared = bundle.localizedString(forKey: key, value: Self.missing, table: QTStringTable.shared.rawValue)
            if shared != Self.missing { return shared }
        }
        return key
    }

    /// Formats a localized format string. Plural variations from the catalog apply to integer arguments.
    public func format(_ key: String, table: QTStringTable = .shared, arguments: [any CVarArg]) -> String {
        let format = string(key, table: table)
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: locale, arguments: arguments)
    }

    /// Whether a key exists in the given table for a language (used by tests and the key-coverage check).
    public func hasTranslation(_ key: String, table: QTStringTable, language: QTResolvedInterfaceLanguage) -> Bool {
        Self.bundle(for: language, in: resources).localizedString(forKey: key, value: Self.missing, table: table.rawValue) != Self.missing
    }

    // MARK: Resolution

    /// `.automatic` walks the user's preferred languages (respects `-AppleLanguages` and per-app language).
    public static func resolve(_ preference: QTInterfaceLanguage, preferred: [String] = Locale.preferredLanguages) -> QTResolvedInterfaceLanguage {
        switch preference {
        case .enUS: return .en
        case .zhCN: return .zhHans
        case .automatic:
            for id in preferred {
                let l = id.lowercased()
                if l.hasPrefix("zh") { return .zhHans }
                if l.hasPrefix("en") { return .en }
            }
            return .en
        }
    }

    private static func bundle(for lang: QTResolvedInterfaceLanguage, in resources: Bundle) -> Bundle {
        resources.path(forResource: lang.lprojName, ofType: "lproj").flatMap(Bundle.init(path:)) ?? resources
    }
}

/// Short entry point used everywhere: `QTLoc.tr("Liked Songs")`, `QTLoc.tr("Skip in %lld", table: .shared, 5)`.
/// Keys are the en-US strings. Placeholders: `%@` for text, `%lld` for integers (plural variations in the catalog).
public enum QTLoc {
    public static func tr(_ key: String, table: QTStringTable = .shared) -> String {
        QTLocalizer.shared.string(key, table: table)
    }

    public static func tr(_ key: String, table: QTStringTable = .shared, _ arguments: any CVarArg...) -> String {
        QTLocalizer.shared.format(key, table: table, arguments: arguments)
    }

    public static var language: QTResolvedInterfaceLanguage { QTLocalizer.shared.language }
    public static var locale: Locale { QTLocalizer.shared.locale }

    public static func setInterfaceLanguage(_ preference: QTInterfaceLanguage) {
        QTLocalizer.shared.setPreference(preference)
    }
}
