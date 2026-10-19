import AppKit
import QTCore

// Owner: builder "desktop". The app's own strings switch language live (QTLocalizer), but AppKit's menus
// (Edit › Undo, Window › Minimize, Services, Hide, Quit…) are localized once, at launch, from the app's
// `AppleLanguages`. So a language picked in Settings is also written there — the same key System Settings ›
// Language & Region › Applications writes — and applies to the system menus on the next launch; Auto removes it
// (follow macOS). Settings offers a quiet Relaunch beside the picker while the menus are still in the old language.

@MainActor
enum QTInterfaceLanguageSync {
    static let appleLanguagesKey = "AppleLanguages"

    /// The language AppKit localized the menus in at launch (the bundle's best match for `AppleLanguages`).
    static let launchMenuLanguage: QTResolvedInterfaceLanguage = menuLanguage(for: Bundle.main.preferredLocalizations)

    static func menuLanguage(for localizations: [String]) -> QTResolvedInterfaceLanguage {
        localizations.first.map { $0.lowercased().hasPrefix("zh") ? .zhHans : .en } ?? .en
    }

    /// `AppleLanguages` for an interface choice; nil = remove the key (follow the system).
    static func appleLanguages(for preference: QTInterfaceLanguage) -> [String]? {
        switch preference {
        case .automatic: nil
        case .enUS: ["en"]
        case .zhCN: ["zh-Hans"]
        }
    }

    /// Writes (or removes) the app's `AppleLanguages`. Call before the settings store switches the interface, so
    /// `.automatic` resolves against the system languages again.
    static func write(_ preference: QTInterfaceLanguage, to defaults: UserDefaults = .standard) {
        if let languages = appleLanguages(for: preference) {
            defaults.set(languages, forKey: appleLanguagesKey)
        } else {
            defaults.removeObject(forKey: appleLanguagesKey)
        }
    }

    /// A user's choice from Settings: system menus follow next launch, the app's strings follow now.
    static func choose(_ preference: QTInterfaceLanguage, store: QTSettingsStore, defaults: UserDefaults = .standard) {
        write(preference, to: defaults)
        store.update { $0.interfaceLanguage = preference }
    }

    /// Launch: an explicit language saved before this sync existed still reaches the system menus (next launch).
    /// Auto never removes anything here — a per-app language set in System Settings lives in the same key. Skipped
    /// when the language comes from launch arguments (`-qt.lang`, `-AppleLanguages`) — those are session-only.
    static func syncAtLaunch(launch: QTLaunchOptions, defaults: UserDefaults = .standard,
                             domain: String? = Bundle.main.bundleIdentifier) {
        guard !isSessionOverride(launch), let domain else { return }
        guard let data = defaults.data(forKey: QTSettingsStore.defaultsKey),
              let saved = try? JSONDecoder().decode(QTSettings.self, from: data),
              let wanted = appleLanguages(for: saved.interfaceLanguage) else { return }
        let current = defaults.persistentDomain(forName: domain)?[appleLanguagesKey] as? [String]
        if current != wanted { write(saved.interfaceLanguage, to: defaults) }
    }

    static func isSessionOverride(_ launch: QTLaunchOptions) -> Bool {
        launch.string("qt.lang") != nil || launch.string("qt.readyFile") != nil
            || ProcessInfo.processInfo.arguments.contains("-AppleLanguages")
    }

    /// True while AppKit's menus are in another language than the interface (Settings shows Relaunch).
    static func menusAreStale(interface: QTResolvedInterfaceLanguage, launch: QTLaunchOptions) -> Bool {
        !isSessionOverride(launch) && interface != launchMenuLanguage
    }

    /// Quits and opens the app again once this process has exited (so the queue is saved before the new one
    /// restores it). User-initiated only.
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                          "qt-relaunch", String(pid), Bundle.main.bundleURL.path]
        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            NSSound.beep()
        }
    }
}
