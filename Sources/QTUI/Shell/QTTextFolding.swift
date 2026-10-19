import Foundation
import QTCore

/// Comparison keys for search, filter, sorting and the A–Z strip (draft §6 matching, §7b search).
/// "ha phom", "Hạ Phỏm" find the same song; 現在的我們 finds 现在的我们; "The Beatles" sorts under B;
/// 蓝色夜曲 sorts and jumps under L (pinyin), like Music.app in Chinese.
/// Always display and send the original spelling — these keys are only for matching.
public enum QTTextFolding {
    /// Lowercased, diacritics stripped, đ→d, Traditional→Simplified Chinese, katakana→hiragana, width-folded.
    public static func searchKey(_ s: String) -> String {
        var out = s.precomposedStringWithCompatibilityMapping // NFKC: full-width → ASCII, ligatures
        if out.unicodeScalars.contains(where: isHan) {
            out = out.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? out
        }
        if out.unicodeScalars.contains(where: isKana) {
            out = out.applyingTransform(.hiraganaToKatakana, reverse: true) ?? out
        }
        out = out.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return out.replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "d")
    }

    /// True when every whitespace-separated token of `query` occurs in `haystack` (both folded).
    /// Token matching lets "kim ngoc" find "Kim Ny Ngọc"; Han text also matches its pinyin ("li jian", "lijian" → 李健).
    public static func matches(query: String, in haystack: String) -> Bool {
        let tokens = searchKey(query).split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return true }
        var keys = [searchKey(haystack)]
        if haystack.unicodeScalars.contains(where: isHan) {
            let pinyin = searchKey(romanized(haystack))
            keys.append(pinyin)
            keys.append(pinyin.replacingOccurrences(of: " ", with: ""))
        }
        return tokens.allSatisfy { t in keys.contains { $0.contains(t) } }
    }

    /// Sort key: leading English article dropped ("The", "A", "An"), Han/kana romanized, then folded.
    public static func sortKey(_ s: String) -> String {
        searchKey(romanized(droppingArticle(s)))
    }

    /// A–Z strip letter: "A"…"Z", or "#" for digits/symbols.
    public static func indexLetter(_ s: String) -> String {
        guard let c = sortKey(s).unicodeScalars.first(where: { !CharacterSet.whitespaces.contains($0) }) else { return "#" }
        let u = Character(c).uppercased()
        return ("A"..."Z").contains(u) ? u : "#"
    }

    public static let indexLetters: [String] = (65...90).map { String(UnicodeScalar($0)!) } + ["#"]

    static func droppingArticle(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        for article in ["the ", "a ", "an "] where trimmed.lowercased().hasPrefix(article) && trimmed.count > article.count {
            return String(trimmed.dropFirst(article.count))
        }
        return trimmed
    }

    static func romanized(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { isHan($0) || isKana($0) || isHangul($0) }) else { return s }
        return s.applyingTransform(.toLatin, reverse: false) ?? s
    }

    private static func isHan(_ u: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(u.value) || (0x3400...0x4DBF).contains(u.value) || (0xF900...0xFAFF).contains(u.value)
    }

    private static func isKana(_ u: Unicode.Scalar) -> Bool { (0x3040...0x30FF).contains(u.value) }
    private static func isHangul(_ u: Unicode.Scalar) -> Bool { (0xAC00...0xD7AF).contains(u.value) }
}

public extension QTTrack {
    /// Everything the filter / search matches against (title, subtitle, artists, album).
    var qtSearchText: String {
        [title, subtitle ?? "", artists.map(\.name).joined(separator: " "), album?.title ?? ""].joined(separator: " ")
    }
}
