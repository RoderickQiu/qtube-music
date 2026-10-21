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

/// The pronunciation lane under lyrics in another script (pinyin, romaji, romanized Korean).
public enum QTLyricsPronunciation: String, Codable, Sendable, Hashable, CaseIterable {
    /// Only when no translation line is shown: a translation is preferred, pronunciation fills in without one.
    case automatic = "auto"
    /// Always, together with the translation.
    case on
    case off

    /// Whether the lane shows, given whether a translation line is (or is about to be) shown.
    public func shows(withTranslation hasTranslation: Bool) -> Bool {
        switch self {
        case .automatic: !hasTranslation
        case .on: true
        case .off: false
        }
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

/// Where the app's accent colour comes from: the playing song's artwork (default), or the system accent.
public enum QTAccentSource: String, Codable, Sendable, Hashable, CaseIterable {
    case song
    case system
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
    /// Locked = click-through (default). Unlocked = drag to move, with a lock button to finish.
    public var isLocked = true
    /// System font design for the overlay (SF Pro, SF Pro Rounded, New York). CJK falls back via the system cascade.
    public var fontDesign: QTLyricsFontDesign = .standard
    /// Horizontal centre as a fraction of the screen's visible width, relative to its centre (-0.5…0.5).
    public var horizontalOffset: Double = 0
    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = QTDesktopLyricsPrefs()
        isShown = (try? c.decodeIfPresent(Bool.self, forKey: .isShown)) ?? d.isShown
        fontSize = (try? c.decodeIfPresent(Double.self, forKey: .fontSize)) ?? d.fontSize
        showsTranslation = (try? c.decodeIfPresent(Bool.self, forKey: .showsTranslation)) ?? d.showsTranslation
        lineCount = (try? c.decodeIfPresent(Int.self, forKey: .lineCount)) ?? d.lineCount
        verticalPosition = (try? c.decodeIfPresent(Double.self, forKey: .verticalPosition)) ?? d.verticalPosition
        screenName = try? c.decodeIfPresent(String.self, forKey: .screenName)
        isLocked = (try? c.decodeIfPresent(Bool.self, forKey: .isLocked)) ?? d.isLocked
        fontDesign = (try? c.decodeIfPresent(QTLyricsFontDesign.self, forKey: .fontDesign)) ?? d.fontDesign
        horizontalOffset = (try? c.decodeIfPresent(Double.self, forKey: .horizontalOffset)) ?? d.horizontalOffset
    }
}

/// Every user preference. Codable with defaults for missing keys, so adding a field never breaks old data.
public struct QTSettings: Codable, Sendable, Hashable {
    public var interfaceLanguage: QTInterfaceLanguage = .automatic
    public var lyricsTranslation: QTLyricsTranslationTarget = .interfaceLanguage
    /// "Translate lyrics with Apple Intelligence" — on by default where available (macOS 26+).
    public var translateWithAppleIntelligence = true
    public var unofficialLyricsSources = QTUnofficialLyricsSources()
    /// Pronunciation lane (lyrics options popover); automatic = only without a translation line.
    public var lyricsPronunciation: QTLyricsPronunciation = .automatic
    /// "Prefer videos when available" — off by default.
    public var preferVideos = false
    public var stageLayout: QTStageLayout = .standard
    public var stageBackground: QTStageBackground = .blur
    public var theme: QTThemePreference = .automatic
    /// Settings › Accent colour: the playing song's artwork colour tints the whole app, or the system accent does.
    public var accentSource: QTAccentSource = .song
    /// Closing the main window keeps music playing (setting to quit instead).
    public var closeWindowKeepsPlaying = true
    public var showsTitleInMenuBar = true
    public var desktopLyrics = QTDesktopLyricsPrefs()
    /// Scroll long titles in the menu bar item (off by default; calm).
    public var menuBarScrollsTitle = false
    public var miniPlayer = QTMiniPlayerPrefs()
    /// Premium-engine features (greyed out for free accounts).
    public var playbackEffects = QTPlaybackEffectsPrefs()
    /// Settings › Shortcuts: system-wide shortcuts. None by default (media keys already work).
    public var globalHotKeys = QTHotKeyBindings()
    /// Settings › Account › "Sync likes and playlists to YouTube Music" (on by default): likes, playlist edits,
    /// subscriptions and saved albums change the signed-in account. Off: they stay on this Mac.
    public var syncsToYouTubeMusic = true

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = QTSettings()
        interfaceLanguage = (try? c.decodeIfPresent(QTInterfaceLanguage.self, forKey: .interfaceLanguage)) ?? d.interfaceLanguage
        lyricsTranslation = (try? c.decodeIfPresent(QTLyricsTranslationTarget.self, forKey: .lyricsTranslation)) ?? d.lyricsTranslation
        translateWithAppleIntelligence = (try? c.decodeIfPresent(Bool.self, forKey: .translateWithAppleIntelligence)) ?? d.translateWithAppleIntelligence
        unofficialLyricsSources = (try? c.decodeIfPresent(QTUnofficialLyricsSources.self, forKey: .unofficialLyricsSources)) ?? d.unofficialLyricsSources
        lyricsPronunciation = (try? c.decodeIfPresent(QTLyricsPronunciation.self, forKey: .lyricsPronunciation)) ?? d.lyricsPronunciation
        preferVideos = (try? c.decodeIfPresent(Bool.self, forKey: .preferVideos)) ?? d.preferVideos
        stageLayout = (try? c.decodeIfPresent(QTStageLayout.self, forKey: .stageLayout)) ?? d.stageLayout
        stageBackground = (try? c.decodeIfPresent(QTStageBackground.self, forKey: .stageBackground)) ?? d.stageBackground
        theme = (try? c.decodeIfPresent(QTThemePreference.self, forKey: .theme)) ?? d.theme
        accentSource = (try? c.decodeIfPresent(QTAccentSource.self, forKey: .accentSource)) ?? d.accentSource
        closeWindowKeepsPlaying = (try? c.decodeIfPresent(Bool.self, forKey: .closeWindowKeepsPlaying)) ?? d.closeWindowKeepsPlaying
        showsTitleInMenuBar = (try? c.decodeIfPresent(Bool.self, forKey: .showsTitleInMenuBar)) ?? d.showsTitleInMenuBar
        desktopLyrics = (try? c.decodeIfPresent(QTDesktopLyricsPrefs.self, forKey: .desktopLyrics)) ?? d.desktopLyrics
        menuBarScrollsTitle = (try? c.decodeIfPresent(Bool.self, forKey: .menuBarScrollsTitle)) ?? d.menuBarScrollsTitle
        miniPlayer = (try? c.decodeIfPresent(QTMiniPlayerPrefs.self, forKey: .miniPlayer)) ?? d.miniPlayer
        playbackEffects = (try? c.decodeIfPresent(QTPlaybackEffectsPrefs.self, forKey: .playbackEffects)) ?? d.playbackEffects
        globalHotKeys = (try? c.decodeIfPresent(QTHotKeyBindings.self, forKey: .globalHotKeys)) ?? d.globalHotKeys
        syncsToYouTubeMusic = (try? c.decodeIfPresent(Bool.self, forKey: .syncsToYouTubeMusic)) ?? d.syncsToYouTubeMusic
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
