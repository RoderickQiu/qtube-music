import Foundation
import Testing

/// Siri / Shortcuts phrases → App Intents (`Sources/QTubeMusicApp/QTAppIntents.swift`, `QTAppShortcuts`). The app
/// target can't be imported into tests and `AppShortcut` exposes neither its intent nor its phrases, so this reads the
/// source: every phrase belongs to exactly one shortcut, and what it says is what the intent does.
@Suite struct AppShortcutPhraseTests {
    static func source() throws -> String {
        try String(contentsOf: Fixture.repoRoot.appendingPathComponent("Sources/QTubeMusicApp/QTAppIntents.swift"),
                   encoding: .utf8)
    }

    /// phrase (with `${applicationName}`) → intent type name.
    static func phraseMap() throws -> [(phrase: String, intent: String)] {
        let src = try source()
        let shortcut = try Regex(#"AppShortcut\(intent:\s*(QT\w+)\(\),\s*phrases:\s*\[([^\]]*)\]"#)
        let literal = try Regex(#""((?:[^"\\]|\\.)*)""#)
        var out: [(String, String)] = []
        for m in src.matches(of: shortcut) {
            let intent = String(m.output[1].substring ?? "")
            let list = String(m.output[2].substring ?? "")
            for p in list.matches(of: literal) {
                let phrase = String(p.output[1].substring ?? "")
                    .replacingOccurrences(of: #"\(.applicationName)"#, with: "${applicationName}")
                out.append((phrase, intent))
            }
        }
        return out
    }

    /// The `QTScripting.perform(.x)` action an intent's `perform()` runs.
    static func action(of intent: String) throws -> String? {
        let src = try source()
        guard let start = src.range(of: "struct \(intent): AppIntent") else { return nil }
        let rest = src[start.upperBound...]
        let body = rest.range(of: "\nstruct ").map { rest[..<$0.lowerBound] } ?? rest
        let call = try Regex(#"QTScripting\.perform\(\.(\w+)\)"#)
        return body.firstMatch(of: call).map { String($0.output[1].substring ?? "") }
    }

    @Test func pausePhrasePausesAndNeverToggles() throws {
        let map = try Self.phraseMap()
        let pause = map.filter { $0.phrase == "Pause ${applicationName}" }
        #expect(pause.map(\.intent) == ["QTPauseIntent"])
        #expect(try Self.action(of: "QTPauseIntent") == "pause")
        #expect(map.first { $0.phrase == "Resume ${applicationName}" }?.intent == "QTPlayIntent")
        #expect(try Self.action(of: "QTPlayIntent") == "play")
        #expect(map.first { $0.phrase == "Play or pause ${applicationName}" }?.intent == "QTPlayPauseIntent")
        #expect(try Self.action(of: "QTPlayPauseIntent") == "playPause")
    }

    @Test func everyPhraseHasOneIntentAndTogglesSayPlayOrPause() throws {
        let map = try Self.phraseMap()
        #expect(map.count >= 8)
        #expect(Set(map.map(\.phrase)).count == map.count, "a phrase is bound to two shortcuts")
        for (phrase, intent) in map {
            guard let action = try Self.action(of: intent) else { continue }
            let p = phrase.lowercased()
            switch action {
            case "playPause": #expect(p.contains("play or pause"), "“\(phrase)” toggles")
            case "pause": #expect(p.hasPrefix("pause"), "“\(phrase)” pauses")
            case "play": #expect(!p.hasPrefix("pause"), "“\(phrase)” plays")
            case "next": #expect(p.contains("next") || p.contains("skip"), "“\(phrase)” skips")
            case "previous": #expect(p.contains("previous"), "“\(phrase)” goes back")
            default: break
            }
        }
    }
}

/// Sparkle stays dormant until the user turns updates on (signing + an appcast, user-gated): the bundle has no feed
/// or key and no automatic checks, and `QTUpdater` never starts an updater without a feed.
@Suite struct QTUpdaterDormancyTests {
    @Test func noFeedNoKeyNoAutomaticChecks() throws {
        let script = try String(contentsOf: Fixture.repoRoot.appendingPathComponent("Scripts/build-app.sh"), encoding: .utf8)
        #expect(!script.contains("<key>SUFeedURL</key>"))
        #expect(!script.contains("<key>SUPublicEDKey</key>"))
        for key in ["SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates"] {
            #expect(script.contains("<key>\(key)</key><false/>"), "\(key) must be NO")
        }
        let updater = try String(contentsOf: Fixture.repoRoot.appendingPathComponent("Sources/QTubeMusicApp/QTUpdater.swift"),
                                 encoding: .utf8)
        #expect(updater.contains("guard controller == nil, Self.feedURL != nil else { return }"))
        #expect(updater.contains(".disabled(!updater.canCheckForUpdates)"))
    }
}
