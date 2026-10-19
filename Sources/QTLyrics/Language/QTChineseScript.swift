import Foundation
import OpenCC
import QTCore

/// The two Chinese scripts lyrics come in. Lyrics in the other script than the translation target are shown converted
/// (`QTLyricsScriptConversion`), never machine-translated: 繁體 and 简体 are one written language.
public enum QTChineseScript: String, Sendable, Hashable {
    case simplified = "zh-Hans"
    case traditional = "zh-Hant"

    /// The script a translation target asks for: `zh-Hans`, `zh-Hant` (and their regional forms); nil otherwise.
    public init?(target: String?) {
        guard let target, QTLanguageCode.normalize(target).hasPrefix("zh") else { return nil }
        self = QTLanguageCode.normalize(target) == "zh-Hant" ? .traditional : .simplified
    }

    /// The script of Han text, from what OpenCC would change: characters that only exist in Traditional (they change
    /// under Traditional → Simplified) against characters that only exist in Simplified (they change the other way).
    /// Works for Cantonese and Hokkien written in Han characters too (嘅, 喺, 閣, 毋 count as neither). Nil when the
    /// text has no Han characters or nothing tells the scripts apart (愛 vs 爱 does; 我是你的 doesn't).
    public static func detect(_ text: String) -> QTChineseScript? {
        let han = text.filter(\.qtIsHan)
        guard !han.isEmpty else { return nil }
        let region = QTChineseRegion.of(han)
        let traditional = changed(han, QTChineseConverter.shared.convert(han, to: .simplified, region: region))
        let simplified = changed(han, QTChineseConverter.shared.convert(han, to: .traditional, region: region))
        if traditional > simplified { return .traditional }
        if simplified > traditional { return .simplified }
        return nil
    }

    /// Characters that differ, position by position (Han-only strings convert one-to-one).
    private static func changed(_ a: String, _ b: String) -> Int {
        zip(a, b).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) } + abs(a.count - b.count)
    }
}

/// Regional standard for Traditional Chinese (variant characters such as 裡/裏, 着/著).
public enum QTChineseRegion: String, Sendable, Hashable {
    case taiwan
    case hongKong

    /// 繁體中文 follows the Mac's region: Hong Kong and Macau get the Hong Kong standard, everywhere else Taiwan's.
    public static var current: QTChineseRegion {
        switch Locale.current.region?.identifier {
        case "HK", "MO": .hongKong
        default: .taiwan
        }
    }

    /// Characters only written Cantonese uses: Hong Kong lyrics simplify through the Hong Kong variant table.
    static let cantoneseMarkers: Set<Character> = ["嘅", "咗", "喺", "冇", "啲", "嚟", "嘢", "咁", "㗎", "囉", "嗰", "哋", "攞", "睇", "諗", "瞓"]

    /// The source variant for Traditional → Simplified: Hong Kong for Cantonese lyrics, else Taiwan.
    static func of(_ text: String) -> QTChineseRegion {
        text.contains(where: cantoneseMarkers.contains) ? .hongKong : .taiwan
    }
}

/// OpenCC converters (SwiftyOpenCC), loaded once each on first use and shared. Script-only conversion: phrase-level
/// segmentation picks the right character (后 → 後 in 以后, not in 皇后), but no regional idioms (软件 ↛ 軟體) —
/// lyrics are sung, so the words must stay the ones in the recording.
///
/// - → Traditional: `s2tw` (Taiwan) or `s2hk` (Hong Kong), from `QTChineseRegion.current`.
/// - → Simplified: `tw2s`, or `hk2s` for Cantonese lyrics.
///
/// When OpenCC's dictionaries can't be loaded, ICU's character-level `Hant-Hans` / `Hans-Hant` transforms stand in.
public final class QTChineseConverter: @unchecked Sendable {
    public static let shared = QTChineseConverter()

    private struct Key: Hashable {
        var script: QTChineseScript
        var region: QTChineseRegion
    }

    // `ChineseConverter` is immutable and thread-safe once built; the lock guards the table only.
    private let lock = NSLock()
    private var converters: [Key: ChineseConverter?] = [:]

    private init() {}

    /// `text` written in `script` (regional variants per `region`).
    public func convert(_ text: String, to script: QTChineseScript, region: QTChineseRegion = .current) -> String {
        guard text.contains(where: \.qtIsHan) else { return text }
        if let converter = converter(Key(script: script, region: region)) { return converter.convert(text) }
        let transform = StringTransform(script == .simplified ? "Hant-Hans" : "Hans-Hant")
        return text.applyingTransform(transform, reverse: false) ?? text
    }

    /// Whether OpenCC loaded (false = the ICU fallback converts).
    public var usesOpenCC: Bool { converter(Key(script: .simplified, region: .taiwan)) != nil }

    private func converter(_ key: Key) -> ChineseConverter? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = converters[key] { return cached }
        let options: ChineseConverter.Options = switch (key.script, key.region) {
        case (.traditional, .taiwan): [.traditionalize, .twStandard]
        case (.traditional, .hongKong): [.traditionalize, .hkStandard]
        case (.simplified, .taiwan): [.simplify, .twStandard]
        case (.simplified, .hongKong): [.simplify, .hkStandard]
        }
        let made = Self.dictionariesPresent ? try? ChineseConverter(options: options) : nil
        converters[key] = .some(made)
        return made
    }

    /// Whether SwiftyOpenCC's resource bundle (its dictionaries) can be found. `ChineseConverter(options:)` reaches it
    /// through SwiftPM's generated `Bundle.module`, which calls `fatalError` when the bundle is missing — a broken or
    /// hand-trimmed app bundle would crash on the first Chinese lyric instead of falling back to ICU. Same candidates,
    /// in the same order, as the generated accessor.
    static let dictionariesPresent: Bool = {
        let name = "SwiftyOpenCC_OpenCC.bundle"
        var candidates: [URL?] = []
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"]
            ?? ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_URL"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        #endif
        // OpenCC is linked statically into the same image as this module, so `Bundle(for:)` matches its finder.
        candidates += [Bundle.main.resourceURL, Bundle(for: QTChineseConverter.self).resourceURL, Bundle.main.bundleURL]
        return candidates.contains { url in
            guard let url else { return false }
            return Bundle(url: url.appendingPathComponent(name)) != nil
        }
    }()
}

/// Shows Chinese lyrics in the script of the translation target: Traditional lyrics with 简体中文 as the target come
/// out in Simplified, Simplified lyrics with 繁體中文 in Traditional. The lines are converted in place (no second lane);
/// word timing survives because each word keeps its own characters. Results are cached per lyrics + script.
public enum QTLyricsScriptConversion {
    /// Languages written in Han characters whose lyrics are converted (Mandarin, Cantonese, Hokkien, Hakka, Classical).
    static let hanLanguages: Set<String> = ["zh-Hans", "zh-Hant", "yue", "nan", "hak", "lzh", "cmn"]

    /// `document` in `target`'s script, or unchanged (not Chinese, already in that script, or the target isn't
    /// Chinese). A converted Mandarin document takes the target as its language and records where it came from in
    /// `scriptConvertedFrom`.
    public static func apply(to document: QTLyricsDocument, target: String?,
                             region: QTChineseRegion = .current) -> QTLyricsDocument {
        guard let script = QTChineseScript(target: target), document.scriptConvertedFrom == nil else { return document }
        let language = document.language.map(QTLanguageCode.normalize)
        if let language, !hanLanguages.contains(language) { return document }
        let sample = document.lines.prefix(60).map(\.text).joined()
        guard let from = QTChineseScript.detect(sample), from != script else { return document }
        guard let lines = convertedLines(document.lines, to: script, from: from, region: region) else { return document }
        var d = document
        d.lines = lines
        if language == nil || language?.hasPrefix("zh") == true { d.language = script.rawValue }
        d.scriptConvertedFrom = from.rawValue
        return d
    }

    // MARK: Lines

    private struct CacheKey: Hashable {
        var lines: [QTLyricsLine]
        var script: QTChineseScript
        var region: QTChineseRegion
    }

    private static let cache = QTScriptConversionCache()

    /// The converted lines, nil when nothing changed.
    static func convertedLines(_ lines: [QTLyricsLine], to script: QTChineseScript, from: QTChineseScript,
                               region: QTChineseRegion) -> [QTLyricsLine]? {
        let key = CacheKey(lines: lines, script: script, region: region)
        if let hit = cache.value(for: key) { return hit.changed ? hit.lines : nil }
        // Traditional → Simplified reads the source's regional variants; → Traditional writes the Mac's.
        let convertRegion = script == .simplified ? QTChineseRegion.of(lines.map(\.text).joined()) : region
        var changed = false
        let out = lines.map { line -> QTLyricsLine in
            var l = line
            l.text = QTChineseConverter.shared.convert(line.text, to: script, region: convertRegion)
            if let words = line.words {
                l.words = convertWords(words, line: line.text, converted: l.text, to: script, region: convertRegion)
            }
            if l != line { changed = true }
            return l
        }
        cache.store((out, changed), for: key)
        return changed ? out : nil
    }

    /// Word texts in the new script, timings untouched. The whole line is converted (phrases span words), then cut back
    /// at the original word boundaries when the character count held — script conversion is one character for one.
    /// Otherwise each word converts on its own.
    static func convertWords(_ words: [QTLyricsWord], line: String, converted: String, to script: QTChineseScript,
                             region: QTChineseRegion) -> [QTLyricsWord] {
        let joined = words.map(\.text).joined()
        let whole = joined == line ? converted : QTChineseConverter.shared.convert(joined, to: script, region: region)
        if whole.count == joined.count {
            var out = words
            var rest = Substring(whole)
            for i in out.indices {
                let n = words[i].text.count
                out[i].text = String(rest.prefix(n))
                rest = rest.dropFirst(n)
            }
            return out
        }
        return words.map { w in
            var w = w
            w.text = QTChineseConverter.shared.convert(w.text, to: script, region: region)
            return w
        }
    }
}

/// A small most-recent-first cache of converted lyrics (a song is presented again on every target change, version
/// pick and Song⇄Video switch).
private final class QTScriptConversionCache: @unchecked Sendable {
    typealias Value = (lines: [QTLyricsLine], changed: Bool)
    private let lock = NSLock()
    private var entries: [(key: AnyHashable, value: Value)] = []
    private let limit = 8

    func value(for key: AnyHashable) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let i = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let e = entries.remove(at: i)
        entries.insert(e, at: 0)
        return e.value
    }

    func store(_ value: Value, for key: AnyHashable) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.key == key }
        entries.insert((key, value), at: 0)
        if entries.count > limit { entries.removeLast() }
    }
}

extension Character {
    /// CJK Unified Ideographs (with extension A and the supplementary planes' B–F).
    var qtIsHan: Bool {
        guard let s = unicodeScalars.first else { return false }
        switch s.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2FFFF, 0xF900...0xFAFF: return true
        default: return false
        }
    }
}
