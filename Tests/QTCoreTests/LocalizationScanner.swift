import Foundation
import Testing
@testable import QTCore

/// Quote- and paren-aware scan of `QTLoc.tr(…)` calls: every string literal in the first argument (both arms of a
/// ternary, commas inside the literal included) paired with the `table:` argument. Interpolated literals are
/// skipped (their key isn't static). Used by `LocalizationTests.everyKeyUsedInSourcesIsLocalized`.
enum QTSwiftCallScanner {
    static func locKeys(in text: String) -> [(String, QTStringTable)] {
        let chars = Array(text.unicodeScalars)
        let marker = Array("QTLoc.tr(".unicodeScalars)
        var result: [(String, QTStringTable)] = []
        var i = 0
        while i + marker.count <= chars.count {
            guard chars[i] == marker[0], Array(chars[i..<(i + marker.count)]) == marker else { i += 1; continue }
            let args = arguments(chars, from: i + marker.count).args
            if let first = args.first {
                let table = args.dropFirst().compactMap { arg -> QTStringTable? in
                    let a = string(arg).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard a.hasPrefix("table:") else { return nil }
                    let name = a.dropFirst("table:".count).trimmingCharacters(in: .whitespaces).drop { $0 == "." }
                    return QTStringTable.allCases.first { "\($0)" == name }
                }.first ?? .shared
                for literal in literals(in: first) { result.append((literal, table)) }
            }
            i += marker.count
        }
        return result
    }

    private static func string(_ scalars: some Sequence<Unicode.Scalar>) -> String {
        var s = String.UnicodeScalarView()
        s.append(contentsOf: scalars)
        return String(s)
    }

    /// Splits a call's argument list (starting just after its `(`) at top-level commas; `end` is past the `)`.
    static func arguments(_ c: [Unicode.Scalar], from start: Int) -> (args: [[Unicode.Scalar]], end: Int) {
        var args: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        var depth = 0
        var i = start
        while i < c.count {
            let ch = c[i]
            if ch == "\"" {
                let end = skipLiteral(c, from: i)
                current.append(contentsOf: c[i..<end])
                i = end
                continue
            }
            if ch == "(" || ch == "[" || ch == "{" { depth += 1 }
            if ch == ")" || ch == "]" || ch == "}" {
                if depth == 0 { args.append(current); return (args, i + 1) }
                depth -= 1
            }
            if ch == ",", depth == 0 {
                args.append(current)
                current = []
                i += 1
                continue
            }
            current.append(ch)
            i += 1
        }
        args.append(current)
        return (args, i)
    }

    /// Index just past the string literal opening at `start` (escapes and `\( … )` interpolation handled).
    static func skipLiteral(_ c: [Unicode.Scalar], from start: Int) -> Int {
        var i = start + 1
        while i < c.count {
            if c[i] == "\\", i + 1 < c.count {
                if c[i + 1] == "(" {
                    i = arguments(c, from: i + 2).end
                    continue
                }
                i += 2
                continue
            }
            if c[i] == "\"" { return i + 1 }
            if c[i] == "\n" { return i } // unterminated: multi-line literals are never keys
            i += 1
        }
        return i
    }

    /// Static string literals in an expression (interpolated ones skipped), unescaped.
    static func literals(in c: [Unicode.Scalar]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < c.count {
            guard c[i] == "\"" else { i += 1; continue }
            let end = skipLiteral(c, from: i)
            let raw = string(c[(i + 1)..<max(i + 1, end - 1)])
            if !raw.contains("\\("), !raw.isEmpty {
                out.append(raw.replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\\\", with: "\\"))
            }
            i = end
        }
        return out
    }
}

@Suite struct LocalizationScannerTests {
    @Test func scannerKeepsCommasInsideKeysAndReadsTheTable() {
        let src = #"""
        Text(QTLoc.tr("Unofficial, may stop working", table: .lyrics))
        Button(QTLoc.tr(a ? "Hide Panel" : "Show Panel", table: .desktop)) {}
        .help("\(QTLoc.tr(p ? "Pause" : "Play"))  Space")
        Text(QTLoc.tr("Skip in %lld", 5))
        Text(QTLoc.tr("Then: %@", x ?? ""))
        Text(QTLoc.tr("Say \"hi\", then go", table: .main))
        """#
        let keys = QTSwiftCallScanner.locKeys(in: src)
        #expect(keys.contains { $0.0 == "Unofficial, may stop working" && $0.1 == .lyrics })
        #expect(keys.contains { $0.0 == "Show Panel" && $0.1 == .desktop })
        #expect(keys.contains { $0.0 == "Hide Panel" && $0.1 == .desktop })
        #expect(keys.contains { $0.0 == "Pause" && $0.1 == .shared })
        #expect(keys.contains { $0.0 == "Play" && $0.1 == .shared })
        #expect(keys.contains { $0.0 == "Skip in %lld" && $0.1 == .shared })
        #expect(keys.contains { $0.0 == "Then: %@" })
        #expect(keys.contains { $0.0 == "Say \"hi\", then go" && $0.1 == .main })
        #expect(!keys.contains { $0.0.isEmpty })
        #expect(keys.count == 8)
    }
}

/// The app target's App Intents strings (`Sources/QTubeMusicApp/Resources/AppIntents.xcstrings`, and phrases in
/// `AppShortcuts.xcstrings`) are compiled into the bundle for Shortcuts; they need zh-Hans too.
@Suite struct AppIntentsLocalizationTests {
    static let resources = Fixture.repoRoot.appendingPathComponent("Sources/QTubeMusicApp/Resources")

    static func strings(_ name: String) throws -> [String: Any] {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent(name)))
        return (json as? [String: Any])?["strings"] as? [String: Any] ?? [:]
    }

    static func hasChinese(_ entry: Any?) -> Bool {
        guard let zh = ((entry as? [String: Any])?["localizations"] as? [String: Any])?["zh-Hans"] as? [String: Any] else { return false }
        if let unit = zh["stringUnit"] as? [String: Any] { return (unit["value"] as? String)?.isEmpty == false }
        if let set = zh["stringSet"] as? [String: Any] { return (set["values"] as? [String])?.isEmpty == false }
        return false
    }

    @Test func everyIntentTitleAndPhraseHasChinese() throws {
        let intents = try Self.strings("AppIntents.xcstrings")
        let phrases = try Self.strings("AppShortcuts.xcstrings")
        for (key, entry) in intents { #expect(Self.hasChinese(entry), "AppIntents.xcstrings: “\(key)” has no zh-Hans") }
        for (key, entry) in phrases { #expect(Self.hasChinese(entry), "AppShortcuts.xcstrings: “\(key)” has no zh-Hans") }

        let source = try String(contentsOf: Fixture.repoRoot.appendingPathComponent("Sources/QTubeMusicApp/QTAppIntents.swift"),
                                encoding: .utf8)
        let resource = try Regex(#"LocalizedStringResource\("((?:[^"\\]|\\.)+)", table: "AppIntents"\)"#)
        var used = 0
        for m in source.matches(of: resource) {
            var key = String(m.output[1].substring ?? "")
            key = key.replacing(try Regex(#"\\\([^)]*\)"#), with: "%@")
            used += 1
            #expect(intents[key] != nil, "QTAppIntents.swift: “\(key)” is missing from AppIntents.xcstrings")
        }
        #expect(used > 10)
        // Phrases: "Play or pause \(.applicationName)" → "Play or pause ${applicationName}".
        let phrase = try Regex(#""((?:[^"\\]|\\.)*\\\(\.applicationName\)(?:[^"\\]|\\.)*)""#)
        for m in source.matches(of: phrase) {
            let key = String(m.output[1].substring ?? "")
                .replacingOccurrences(of: #"\(.applicationName)"#, with: "${applicationName}")
                .replacingOccurrences(of: #"\(\.$playlist)"#, with: "${playlist}")
            #expect(phrases[key] != nil, "AppShortcuts phrase “\(key)” is missing from AppShortcuts.xcstrings")
        }
    }
}
