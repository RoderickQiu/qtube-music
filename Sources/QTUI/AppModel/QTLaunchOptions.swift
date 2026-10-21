import Foundation
import QTCore

/// Which surface the player is on (prototype `?surface=`; `desktop` is accepted as an alias of `mini`).
public enum QTSurface: String, Sendable, Hashable, CaseIterable {
    case window
    case stage
    /// Mini player + menu bar + desktop lyrics.
    case mini

    public init?(argument: String) {
        if argument == "desktop" { self = .mini; return }
        self.init(rawValue: argument)
    }
}

/// Sidebar destinations. `qt.section` accepts the raw names plus `playlist:<id>`.
public enum QTSidebarItem: Hashable, Sendable {
    case home, explore, songs, albums, artists, liked, history, uploads
    case playlist(String)

    public init?(argument: String) {
        switch argument {
        case "home": self = .home
        case "explore": self = .explore
        case "songs": self = .songs
        case "albums": self = .albums
        case "artists": self = .artists
        case "liked": self = .liked
        case "history": self = .history
        case "uploads": self = .uploads
        default:
            guard argument.hasPrefix("playlist:") else { return nil }
            self = .playlist(String(argument.dropFirst("playlist:".count)))
        }
    }

    public var argument: String {
        switch self {
        case .home: "home"
        case .explore: "explore"
        case .songs: "songs"
        case .albums: "albums"
        case .artists: "artists"
        case .liked: "liked"
        case .history: "history"
        case .uploads: "uploads"
        case .playlist(let id): "playlist:\(id)"
        }
    }
}

public enum QTPanelTab: String, Sendable, Hashable, CaseIterable {
    case nowPlaying = "now-playing"
    case queue

    public init?(argument: String) {
        switch argument.lowercased() {
        case "now-playing", "nowplaying", "now playing", "lyrics": self = .nowPlaying
        case "queue": self = .queue
        default: return nil
        }
    }
}

public enum QTAccountKind: String, Sendable, Hashable, CaseIterable {
    case premium, free
}

/// Extra windows to open at launch for screenshots (`-qt.show mini,desktopLyrics`).
public enum QTExtraWindow: String, Sendable, Hashable, CaseIterable {
    case mini
    case desktopLyrics
    case menuBarPopover
    case settings
}

/// Launch arguments, UserDefaults-style (`-qt.surface stage -qt.paused YES`), mirroring the prototype's URL params.
/// They override state for this session only and are never persisted. Builders add their own `qt.<area>.<name>`
/// keys and read them with `string(_:)` / `bool(_:)` / `double(_:)`. Full list: docs/architecture.md › Launch arguments.
public struct QTLaunchOptions: Sendable, Equatable {
    /// Every `qt.*` argument as a string.
    public var raw: [String: String]

    public init(arguments: [String: String]) {
        raw = arguments.filter { $0.key.hasPrefix("qt.") }
    }

    /// Reads the process's argument domain.
    public static var current: QTLaunchOptions {
        let domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var args: [String: String] = [:]
        for (k, v) in domain {
            switch v {
            case let s as String: args[k] = s
            case let n as NSNumber: args[k] = n.stringValue
            case let a as [Any]: args[k] = a.map { "\($0)" }.joined(separator: ",")
            default: args[k] = "\(v)"
            }
        }
        return QTLaunchOptions(arguments: args)
    }

    // MARK: Generic accessors (for builder-specific args)

    public func string(_ key: String) -> String? {
        raw[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// YES/NO, true/false, 1/0. A present key with an empty value counts as true.
    public func bool(_ key: String) -> Bool? {
        guard let v = raw[key] else { return nil }
        switch v.lowercased() {
        case "", "yes", "true", "1", "on": return true
        case "no", "false", "0", "off": return false
        default: return nil
        }
    }

    public func double(_ key: String) -> Double? {
        raw[key].flatMap(Double.init)
    }

    // MARK: Shared keys

    public var surface: QTSurface? { string("qt.surface").flatMap(QTSurface.init(argument:)) }
    public var section: QTSidebarItem? { string("qt.section").flatMap(QTSidebarItem.init(argument:)) }
    public var stageLayout: QTStageLayout? { string("qt.stageLayout").flatMap(QTStageLayout.init(rawValue:)) }
    public var stageBackground: QTStageBackground? { string("qt.stageBackground").flatMap(QTStageBackground.init(argument:)) }
    public var theme: QTThemePreference? {
        string("qt.theme").flatMap { $0 == "system" ? .automatic : QTThemePreference(rawValue: $0) }
    }
    public var account: QTAccountKind? { string("qt.account").flatMap(QTAccountKind.init(rawValue:)) }
    public var translation: QTLyricsTranslationTarget? {
        string("qt.translation").flatMap { $0 == "interface" ? .interfaceLanguage : QTLyricsTranslationTarget(rawValue: $0) }
    }
    /// Track to load (mock ids like `ne34516548`).
    public var trackID: String? { string("qt.track") }
    /// Start position in seconds.
    public var time: TimeInterval? { double("qt.time") }
    public var paused: Bool? { bool("qt.paused") }
    public var panelTab: QTPanelTab? { string("qt.panelTab").flatMap(QTPanelTab.init(argument:)) }
    public var panelHidden: Bool? { bool("qt.panelHidden") }
    public var videoMode: Bool? { bool("qt.videoMode") }
    /// Force the ad state now (simulated engine).
    public var forceAd: Bool { bool("qt.ad") ?? false }
    public var language: QTInterfaceLanguage? { string("qt.lang").flatMap(QTInterfaceLanguage.init(argument:)) }
    /// `-qt.screen <display-name substring>`, DEBUG builds only (release builds ignore it). `main` / `any` / `none`
    /// ask for no particular display.
    public var screen: String? {
        #if DEBUG
        guard let s = string("qt.screen"), !Self.anyScreenValues.contains(s.lowercased()) else { return nil }
        return s
        #else
        return nil
        #endif
    }

    static let anyScreenValues: Set<String> = ["main", "any", "none"]
    /// The test display a dev/scripted DEBUG launch uses when it names none.
    public static let defaultTestScreen = "U270CA"
    /// `1440x900`.
    public var windowSize: CGSize? {
        guard let s = string("qt.window") else { return nil }
        let parts = s.lowercased().split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }
    /// Path the app writes a JSON "ready" file to once the first frame is settled (used by Scripts/shoot.sh).
    public var readyFile: String? { string("qt.readyFile") }
    /// Mock catalog folder override.
    public var catalogPath: String? { string("qt.catalog") }
    /// Extra windows to open: `-qt.show mini,desktopLyrics,menuBarPopover,settings`.
    public var extraWindows: Set<QTExtraWindow> {
        Set((string("qt.show") ?? "").split(separator: ",").compactMap {
            QTExtraWindow(rawValue: $0.trimmingCharacters(in: .whitespaces))
        })
    }

    /// The display windows must go on (DEBUG builds only): `-qt.screen`, else U270CA for a dev/scripted launch (any
    /// `-qt.*` argument). A plain launch (Finder, Dock, `open` without arguments) and release builds name none.
    /// When the named display isn't connected a DEBUG launch refuses to start (`QTScreenGuard`) instead of putting
    /// its windows on the user's main display.
    public var effectiveScreenName: String? {
        #if DEBUG
        if let s = screen { return s }
        if let s = string("qt.screen"), Self.anyScreenValues.contains(s.lowercased()) { return nil }
        return raw.isEmpty ? nil : Self.defaultTestScreen
        #else
        return nil
        #endif
    }
}
