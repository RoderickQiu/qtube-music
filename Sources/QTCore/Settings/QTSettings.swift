import Foundation
import Observation

/// Interface language. `.automatic` follows macOS (System Settings › Language & Region, incl. per-app language).
public enum QTInterfaceLanguage: String, Codable, Sendable, Hashable, CaseIterable {
    case automatic = "auto"
    case enUS = "en-US"
    case zhCN = "zh-CN"

    /// Parses launch-arg / prototype spellings: `auto`, `en`, `en-US`, `zh`, `zh-CN`, `zh-Hans`.
    public init?(argument: String) {
        switch argument.lowercased() {
        case "auto", "automatic", "system": self = .automatic
        case "en", "en-us": self = .enUS
        case "zh", "zh-cn", "zh-hans", "zh-hans-cn": self = .zhCN
        default: return nil
        }
    }
}

/// Lyrics translation target — its own setting, independent of the interface language (draft §7b).
public enum QTLyricsTranslationTarget: String, Codable, Sendable, Hashable, CaseIterable {
    /// Follow the interface language (default).
    case interfaceLanguage = "auto"
    case off
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en
    case ko
    case ja
    case vi
    case es
    case fr
    case de

    /// The concrete languages, in menu order.
    public static let languages: [QTLyricsTranslationTarget] = [.zhHans, .zhHant, .en, .ko, .ja, .vi, .es, .fr, .de]

    /// BCP-47 code to translate into, or nil for Off.
    public func resolvedLanguage(interface: QTResolvedInterfaceLanguage) -> String? {
        switch self {
        case .off: nil
        case .interfaceLanguage: interface == .zhHans ? "zh-Hans" : "en"
        default: rawValue
        }
    }

    /// The language's own name (never translated): 简体中文, 한국어, Tiếng Việt…
    public static func nativeName(for code: String) -> String {
        switch code {
        case "zh-Hans": "简体中文"
        case "zh-Hant": "繁體中文"
        case "en": "English"
        case "ko": "한국어"
        case "ja": "日本語"
        case "vi": "Tiếng Việt"
        case "es": "Español"
        case "fr": "Français"
        case "de": "Deutsch"
        default: Locale(identifier: code).localizedString(forIdentifier: code) ?? code
        }
    }

    /// True when lyrics in `songLanguage` need no translation into `target` (zh-Hans ≈ zh-Hant counts as same).
    public static func isSameLanguage(_ songLanguage: String, _ target: String) -> Bool {
        songLanguage == target || (songLanguage.hasPrefix("zh") && target.hasPrefix("zh"))
    }
}

public enum QTStageLayout: String, Codable, Sendable, Hashable, CaseIterable {
    /// Art left, lyrics right (NetEase "Standard").
    case standard
    case lyricsOnly = "lyrics-only"
    case artOnly = "art-only"
}

public enum QTStageBackground: String, Codable, Sendable, Hashable, CaseIterable {
    case blur
    case cover
    case vinyl
    case video
    /// Premium engine only.
    case visualizer = "visual"

    public init?(argument: String) {
        if let v = QTStageBackground(rawValue: argument) { self = v; return }
        if argument == "visualizer" { self = .visualizer; return }
        return nil
    }
}

public enum QTThemePreference: String, Codable, Sendable, Hashable, CaseIterable {
    case automatic = "auto"
    case light
    case dark
}

/// Opt-in unofficial lyric sources; all off by default.
public struct QTUnofficialLyricsSources: Codable, Sendable, Hashable {
    public var netease = false
    public var kugou = false
    public var qq = false
    public init(netease: Bool = false, kugou: Bool = false, qq: Bool = false) {
        self.netease = netease
        self.kugou = kugou
        self.qq = qq
    }
    public var anyEnabled: Bool { netease || kugou || qq }
}

public struct QTDesktopLyricsPrefs: Codable, Sendable, Hashable {
    public var isShown = false
    /// Points, main line. Translation line is ~55 %.
    public var fontSize: Double = 36
    public var showsTranslation = true
    /// 1 or 2 lines.
    public var lineCount = 2
    /// Vertical position as a fraction of the screen's visible height from the bottom (0…1).
    public var verticalPosition: Double = 0.14
    /// Localized name of the display it lives on; nil = the main window's screen.
    public var screenName: String?
    public init() {}
}

/// Every user preference. Codable with defaults for missing keys, so adding a field never breaks old data.
public struct QTSettings: Codable, Sendable, Hashable {
    public var interfaceLanguage: QTInterfaceLanguage = .automatic
    public var lyricsTranslation: QTLyricsTranslationTarget = .interfaceLanguage
    /// "Translate lyrics with Apple Intelligence" — on by default where available (macOS 26+).
    public var translateWithAppleIntelligence = true
    public var unofficialLyricsSources = QTUnofficialLyricsSources()
    /// "Prefer videos when available" — off by default.
    public var preferVideos = false
    public var stageLayout: QTStageLayout = .standard
    public var stageBackground: QTStageBackground = .blur
    public var theme: QTThemePreference = .automatic
    /// Closing the main window keeps music playing (setting to quit instead).
    public var closeWindowKeepsPlaying = true
    public var showsTitleInMenuBar = true
    public var desktopLyrics = QTDesktopLyricsPrefs()

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = QTSettings()
        interfaceLanguage = (try? c.decodeIfPresent(QTInterfaceLanguage.self, forKey: .interfaceLanguage)) ?? d.interfaceLanguage
        lyricsTranslation = (try? c.decodeIfPresent(QTLyricsTranslationTarget.self, forKey: .lyricsTranslation)) ?? d.lyricsTranslation
        translateWithAppleIntelligence = (try? c.decodeIfPresent(Bool.self, forKey: .translateWithAppleIntelligence)) ?? d.translateWithAppleIntelligence
        unofficialLyricsSources = (try? c.decodeIfPresent(QTUnofficialLyricsSources.self, forKey: .unofficialLyricsSources)) ?? d.unofficialLyricsSources
        preferVideos = (try? c.decodeIfPresent(Bool.self, forKey: .preferVideos)) ?? d.preferVideos
        stageLayout = (try? c.decodeIfPresent(QTStageLayout.self, forKey: .stageLayout)) ?? d.stageLayout
        stageBackground = (try? c.decodeIfPresent(QTStageBackground.self, forKey: .stageBackground)) ?? d.stageBackground
        theme = (try? c.decodeIfPresent(QTThemePreference.self, forKey: .theme)) ?? d.theme
        closeWindowKeepsPlaying = (try? c.decodeIfPresent(Bool.self, forKey: .closeWindowKeepsPlaying)) ?? d.closeWindowKeepsPlaying
        showsTitleInMenuBar = (try? c.decodeIfPresent(Bool.self, forKey: .showsTitleInMenuBar)) ?? d.showsTitleInMenuBar
        desktopLyrics = (try? c.decodeIfPresent(QTDesktopLyricsPrefs.self, forKey: .desktopLyrics)) ?? d.desktopLyrics
    }
}

/// Owns the persisted settings. Views read `store.settings.x` and write through `store.update { $0.x = … }`.
/// Launch-argument overrides (`-qt.theme dark`, …) are applied to `settings` but never persisted.
@MainActor
@Observable
public final class QTSettingsStore {
    public private(set) var settings: QTSettings

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    @ObservationIgnored private var persisted: QTSettings

    public static let defaultsKey = "qt.settings.v1"

    public init(defaults: UserDefaults = .standard, key: String = QTSettingsStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
        let loaded = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(QTSettings.self, from: $0) } ?? QTSettings()
        self.settings = loaded
        self.persisted = loaded
        QTLoc.setInterfaceLanguage(loaded.interfaceLanguage)
    }

    /// Persisted change.
    public func update(_ change: (inout QTSettings) -> Void) {
        change(&settings)
        change(&persisted)
        if let data = try? JSONEncoder().encode(persisted) { defaults.set(data, forKey: key) }
        QTLoc.setInterfaceLanguage(settings.interfaceLanguage)
    }

    /// Session-only change (launch arguments, previews, screenshots).
    public func override(_ change: (inout QTSettings) -> Void) {
        change(&settings)
        QTLoc.setInterfaceLanguage(settings.interfaceLanguage)
    }
}
