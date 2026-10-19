import Foundation
import NaturalLanguage
import QTCore

/// BCP-47 normalisation for lyric languages: Chinese keeps its script (`zh-Hans` / `zh-Hant`), everything else
/// collapses to the language code (`en-US` → `en`, `ja-JP` → `ja`).
public enum QTLanguageCode {
    public static func normalize(_ raw: String) -> String {
        let code = raw.replacingOccurrences(of: "_", with: "-").trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { return code }
        let parts = code.split(separator: "-").map(String.init)
        let base = parts[0].lowercased()
        if base == "zh" {
            let rest = parts.dropFirst().map { $0.lowercased() }
            if rest.contains("hant") || rest.contains("tw") || rest.contains("hk") || rest.contains("mo") { return "zh-Hant" }
            return "zh-Hans"
        }
        if parts.count > 1, parts[1].lowercased() == "latn" { return base + "-Latn" }
        return base
    }

    /// True when text in `a` needs no translation into `b` (zh-Hans ≈ zh-Hant, see `QTLyricsTranslationTarget`).
    public static func isSame(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return QTLyricsTranslationTarget.isSameLanguage(normalize(a), normalize(b))
    }
}

/// Detects the language of lyric lines on device. Script heuristics first (kana ⇒ Japanese, hangul ⇒ Korean,
/// Han only ⇒ Chinese with Traditional/Simplified decided by the T→S table), then `NLLanguageRecognizer`.
public enum QTLyricsLanguageDetector {
    public static func detect(_ lines: [String]) -> String? {
        let text = lines.joined(separator: "\n")
        guard text.contains(where: { $0.isLetter }) else { return nil }
        var kana = 0, hangul = 0, han = 0, letters = 0, devanagari = 0, thai = 0
        for s in text.unicodeScalars where s.properties.isAlphabetic {
            letters += 1
            switch s.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: kana += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: hangul += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2FFFF: han += 1
            case 0x0900...0x097F: devanagari += 1
            case 0x0E00...0x0E7F: thai += 1
            default: break
            }
        }
        guard letters > 0 else { return nil }
        let share = { (n: Int) in Double(n) / Double(letters) }
        if kana > 0, share(kana + han) > 0.3, share(kana) > 0.05 { return "ja" }
        if share(hangul) > 0.3 { return "ko" }
        if share(han) > 0.3 { return QTHanziConversion.isMostlyTraditional(text) ? "zh-Hant" : "zh-Hans" }
        if share(devanagari) > 0.3 { return "hi" }
        if share(thai) > 0.3 { return "th" }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let lang = recognizer.dominantLanguage, lang != .undetermined else { return nil }
        return QTLanguageCode.normalize(lang.rawValue)
    }
}

/// On-device romanization through ICU transforms (no network): pinyin for Chinese, Hepburn-style romaji for
/// Japanese (kanji readings via `CFStringTokenizer`), Hangul, Devanagari, Thai, Cyrillic, Greek, Arabic, Hebrew.
public enum QTLyricsRomanizer {
    /// Languages whose script is not Latin and that benefit from a romanization lane.
    public static func needsRomanization(_ language: String?) -> Bool {
        guard let language else { return false }
        let base = QTLanguageCode.normalize(language)
        return ["zh-Hans", "zh-Hant", "ja", "ko", "hi", "mr", "ne", "th", "ru", "uk", "bg", "sr", "el", "ar", "fa", "he"]
            .contains(base)
    }

    public static func romanize(_ text: String, language: String?) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let language else { return nil }
        let out: String?
        switch QTLanguageCode.normalize(language) {
        case "ja": out = japanese(trimmed)
        case "zh-Hans", "zh-Hant": out = transform(trimmed, "Han-Latin")
        case "ko": out = transform(trimmed, "Hangul-Latin")
        case "hi", "mr", "ne": out = transform(trimmed, "Devanagari-Latin")
        case "th": out = transform(trimmed, "Thai-Latin")
        case "ru", "uk", "bg", "sr": out = transform(trimmed, "Cyrillic-Latin")
        case "el": out = transform(trimmed, "Greek-Latin")
        case "ar", "fa": out = transform(trimmed, "Arabic-Latin")
        case "he": out = transform(trimmed, "Hebrew-Latin")
        default: out = nil
        }
        guard let result = out?.qtCollapsedWhitespace, !result.isEmpty, result != trimmed else { return nil }
        return result
    }

    private static func transform(_ text: String, _ id: String) -> String? {
        text.applyingTransform(StringTransform(id), reverse: false)
    }

    /// Word-segmented romaji: the tokenizer supplies readings for kanji; anything without a transcription
    /// (Latin words, punctuation) is kept as written.
    private static func japanese(_ text: String) -> String? {
        let cf = text as CFString
        let length = CFStringGetLength(cf)
        guard let tokenizer = CFStringTokenizerCreate(nil, cf, CFRange(location: 0, length: length),
                                                      kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale)
        else { return nil }
        var parts: [String] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let token = (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
            if token.allSatisfy(\.isWhitespace) { continue }
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String,
               !latin.isEmpty {
                parts.append(latin)
            } else {
                parts.append(token)
            }
        }
        return parts.joined(separator: " ")
    }
}
