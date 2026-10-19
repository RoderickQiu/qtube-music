import Foundation
import Observation
import Testing
@testable import QTCore

@Suite struct LocalizationTests {
    @Test func zhHansIsServedAtRuntimeWithoutRestart() {
        let loc = QTLocalizer(preference: .enUS)
        #expect(loc.string("Liked Songs") == "Liked Songs")
        loc.setPreference(.zhCN)
        #expect(loc.language == .zhHans)
        #expect(loc.string("Liked Songs") == "喜欢的音乐")
        #expect(loc.string("Song ⇄ Music Video") == "歌曲 ⇄ MV")
        loc.setPreference(.enUS)
        #expect(loc.string("Liked Songs") == "Liked Songs")
    }

    @Test func pluralsAndPlaceholders() {
        let loc = QTLocalizer(preference: .enUS)
        #expect(loc.format("%lld songs · %lld min", arguments: [1, 3]) == "1 song · 3 min")
        #expect(loc.format("%lld songs · %lld min", arguments: [12, 50]) == "12 songs · 50 min")
        #expect(loc.format("Added “%@” to %@", arguments: ["Perfect", "Sugar"]) == "Added “Perfect” to Sugar")
        loc.setPreference(.zhCN)
        #expect(loc.format("%lld songs · %lld min", arguments: [12, 50]) == "12 首 · 50 分钟")
        #expect(loc.format("Added “%@” to %@", arguments: ["Perfect", "Sugar"]) == "已将“Perfect”添加到Sugar")
        #expect(loc.format("Skip in %lld", arguments: [5]) == "5 秒后可跳过")
    }

    @Test func areaTablesFallBackToSharedThenKey() {
        let loc = QTLocalizer(preference: .zhCN)
        #expect(loc.string("Stage", table: .stage) == "沉浸播放")
        #expect(loc.string("Not a real key", table: .player) == "Not a real key")
    }

    @Test func automaticFollowsPreferredLanguages() {
        #expect(QTLocalizer.resolve(.automatic, preferred: ["zh-Hans-CN", "en-US"]) == .zhHans)
        #expect(QTLocalizer.resolve(.automatic, preferred: ["vi-VN", "zh-Hant-TW", "en"]) == .zhHans)
        #expect(QTLocalizer.resolve(.automatic, preferred: ["fr-FR", "en-GB"]) == .en)
        #expect(QTLocalizer.resolve(.automatic, preferred: ["fr-FR"]) == .en)
        #expect(QTLocalizer.resolve(.zhCN, preferred: ["en"]) == .zhHans)
    }

    @Test func languageChangesNotifyObservers() async {
        let loc = QTLocalizer(preference: .enUS)
        let fired = Fired()
        withObservationTracking { _ = loc.string("Home") } onChange: { fired.value = true }
        loc.setPreference(.zhCN)
        #expect(fired.value)
    }

    @Test func formattingUsesTheInterfaceLocale() {
        let en = Locale(identifier: "en_US"), zh = Locale(identifier: "zh-Hans_CN")
        #expect(QTFormat.duration(257, locale: en) == "4:17")
        #expect(QTFormat.duration(3725, locale: en) == "1:02:05")
        #expect(QTFormat.remaining(222, locale: en) == "-3:42")
        #expect(QTFormat.duration(-5, locale: en) == "0:00")
        #expect(QTFormat.signedOffset(0.1, locale: en) == "+0.1")
        #expect(QTFormat.signedOffset(-0.3, locale: en) == "-0.3")
        #expect(QTFormat.totalMinutes(3000) == 50)
        let date = Date(timeIntervalSince1970: 1_792_316_460) // 2026-10-18 (UTC)
        #expect(QTFormat.clock(date, locale: zh).contains("周"))
        #expect(!QTFormat.clock(date, locale: en).contains("周"))
    }
}

final class Fired: @unchecked Sendable { var value = false }

/// Guards the String Catalogs: every key the code uses is translated, and every prototype key was ported.
@Suite struct StringCatalogCoverageTests {
    static let catalogs = Fixture.repoRoot.appendingPathComponent("Sources/QTCore/Resources/Localization")

    static func catalog(_ table: QTStringTable) throws -> [String: Any] {
        let url = catalogs.appendingPathComponent("\(table.rawValue).xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return json?["strings"] as? [String: Any] ?? [:]
    }

    static func zhValue(_ entry: Any?) -> String? {
        guard let e = entry as? [String: Any], let l = e["localizations"] as? [String: Any],
              let zh = l["zh-Hans"] as? [String: Any], let unit = zh["stringUnit"] as? [String: Any] else { return nil }
        return unit["value"] as? String
    }

    @Test func everyCatalogKeyHasAChineseTranslation() throws {
        for table in QTStringTable.allCases {
            for (key, entry) in try Self.catalog(table) {
                #expect(Self.zhValue(entry)?.isEmpty == false, "\(table.rawValue).xcstrings: “\(key)” has no zh-Hans translation")
            }
        }
    }

    @Test func everyKeyUsedInSourcesIsLocalized() throws {
        let loc = QTLocalizer(preference: .zhCN)
        let sources = Fixture.repoRoot.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        let localized = try Regex(#"\.localized\("((?:[^"\\]|\\.)+)"\)"#)
        var checked = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            var uses: [(String, QTStringTable)] = QTSwiftCallScanner.locKeys(in: text)
            for m in text.matches(of: localized) { uses.append((String(m.output[1].substring ?? ""), .shared)) }
            for (key, table) in uses {
                checked += 1
                let ok = loc.hasTranslation(key, table: table, language: .zhHans) || loc.hasTranslation(key, table: .shared, language: .zhHans)
                #expect(ok, "\(file.lastPathComponent): “\(key)” is missing from \(table.rawValue).xcstrings (zh-Hans)")
            }
        }
        #expect(checked > 50)
    }

    @Test func everyPrototypeKeyWasPorted() throws {
        let jsx = try String(contentsOf: Fixture.repoRoot.appendingPathComponent("design/prototype/i18n.jsx"), encoding: .utf8)
        guard let start = jsx.range(of: #""zh-CN": {"#), let end = jsx.range(of: "},\n};") else {
            Issue.record("i18n.jsx layout changed")
            return
        }
        let body = jsx[start.upperBound..<end.lowerBound]
        let pair = try Regex(#""((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)""#)
        let placeholder = try Regex(#"\{(\w+)\}"#)
        let shared = try Self.catalog(.shared)
        var count = 0
        for m in body.matches(of: pair) {
            let en = String(m.output[1].substring ?? "")
            let key = en.replacing(placeholder) { p in p.output[1].substring == "n" || p.output[1].substring == "m" ? "%lld" : "%@" }
            count += 1
            #expect(Self.zhValue(shared[key]) != nil, "prototype key “\(en)” → “\(key)” missing from Localizable.xcstrings")
        }
        #expect(count == 160)
    }
}
