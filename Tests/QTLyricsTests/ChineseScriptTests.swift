import Foundation
import QTCore
import Testing
@testable import QTLyrics

/// Traditional ⇄ Simplified: detection, OpenCC conversion, and lyrics shown in the target's script.
@Suite struct ChineseScriptTests {
    /// 愛情你比我想的閣較偉大 (EggPlantEgg): Taiwanese Hokkien written in Traditional characters.
    static let hokkien = ["愛情你比我想的閣較偉大", "你是我的未來", "希望你會了解", "雖然江山易改", "但本性難移",
                          "(我其實毋是毋願離開)", "(攏怪你行入了我的人生)", "你予我這世人最後的期待"]

    @Test func openCCLoads() {
        #expect(QTChineseConverter.shared.usesOpenCC)
    }

    @Test func detectsScript() {
        #expect(QTChineseScript.detect("故事的小黄花从出生那年就飘着") == .simplified)
        #expect(QTChineseScript.detect("故事的小黃花從出生那年就飄著") == .traditional)
        #expect(QTChineseScript.detect(Self.hokkien.joined()) == .traditional)
        // Cantonese (嘅, 喺, 咗 are the same in both scripts; 這 and 説 decide).
        #expect(QTChineseScript.detect("我哋喺呢度等咗你好耐 點解你仲未嚟 這次你說會返嚟") == .traditional)
        #expect(QTChineseScript.detect("我是你的") == nil)
        #expect(QTChineseScript.detect("Hello") == nil)
        // Mostly Simplified with one Traditional character still reads as Simplified.
        #expect(QTChineseScript.detect("我们一起走过的日子 你还记得吗 愛") == .simplified)
    }

    @Test func languageDetection() {
        #expect(QTLyricsLanguageDetector.detect(Self.hokkien) == "zh-Hant")
        #expect(QTLyricsLanguageDetector.detect(["故事的小黄花", "从出生那年就飘着"]) == "zh-Hans")
        // Japanese with kanji is never taken for Chinese, nor converted.
        #expect(QTLyricsLanguageDetector.detect(["夜に駆ける", "沈むように溶けてゆくように"]) == "ja")
        let ja = QTLyricsDocument(lines: [QTLyricsLine(start: 1, text: "沈むように溶けてゆくように")], syncKind: .line,
                                  source: .lrclib, language: "ja")
        #expect(QTLyricsScriptConversion.apply(to: ja, target: "zh-Hans") == ja)
    }

    @Test func phraseLevelConversion() {
        let c = QTChineseConverter.shared
        #expect(c.convert("以后的皇后", to: .traditional, region: .taiwan) == "以後的皇后")
        #expect(c.convert("头发", to: .traditional, region: .taiwan) == "頭髮")
        #expect(c.convert("愛情你比我想的閣較偉大", to: .simplified, region: .taiwan) == "爱情你比我想的阁较伟大")
        // Script only: no regional vocabulary swaps (软件 stays 軟件, not 軟體).
        #expect(c.convert("软件", to: .traditional, region: .taiwan) == "軟件")
    }

    @Test func traditionalLyricsShownSimplified() {
        let doc = QTLyricsDocument(lines: Self.hokkien.enumerated().map { QTLyricsLine(start: Double($0.offset) * 4, text: $0.element) },
                                   syncKind: .line, source: .youtubeMusic, language: "zh-Hant")
        let shown = QTLyricsTranslationPolicy.applyProviderLane(to: doc, target: "zh-Hans")
        #expect(shown.lines[0].text == "爱情你比我想的阁较伟大")
        #expect(shown.lines[3].text == "虽然江山易改")
        #expect(shown.lines.map(\.start) == doc.lines.map(\.start))
        #expect(shown.language == "zh-Hans")
        #expect(shown.scriptConvertedFrom == "zh-Hant")
        // Already in the target script, or a non-Chinese target: as written.
        #expect(QTLyricsTranslationPolicy.applyProviderLane(to: doc, target: "zh-Hant") == doc)
        #expect(QTLyricsTranslationPolicy.applyProviderLane(to: doc, target: "en").lines == doc.lines)
        #expect(QTLyricsTranslationPolicy.applyProviderLane(to: doc, target: nil) == doc)
        // Applying again doesn't convert twice.
        #expect(QTLyricsTranslationPolicy.applyProviderLane(to: shown, target: "zh-Hans") == shown)
        // No language tag: detected from the text.
        var untagged = doc
        untagged.language = nil
        #expect(QTLyricsScriptConversion.apply(to: untagged, target: "zh-Hans").scriptConvertedFrom == "zh-Hant")
    }

    @Test func simplifiedLyricsShownTraditional() {
        let doc = QTLyricsDocument(lines: [QTLyricsLine(start: 1, text: "故事的小黄花"), QTLyricsLine(start: 4, text: "从出生那年就飘着")],
                                   syncKind: .line, source: .netease, language: "zh-Hans")
        let shown = QTLyricsScriptConversion.apply(to: doc, target: "zh-Hant", region: .taiwan)
        #expect(shown.lines.map(\.text) == ["故事的小黃花", "從出生那年就飄著"])
        #expect(shown.scriptConvertedFrom == "zh-Hans")
    }

    /// Word timing survives: every word keeps its timing and gets its own characters back.
    @Test func wordTimedLines() {
        let words = [QTLyricsWord(start: 10, duration: 0.4, text: "愛情"), QTLyricsWord(start: 10.4, duration: 0.3, text: "你比我想的 "),
                     QTLyricsWord(start: 10.7, duration: 0.5, text: "閣較"), QTLyricsWord(start: 11.2, duration: 0.6, text: "偉大")]
        let line = QTLyricsLine(start: 10, duration: 1.8, text: words.map(\.text).joined(), words: words)
        let doc = QTLyricsDocument(lines: [line], syncKind: .word, source: .amll, language: "zh-Hant")
        let shown = QTLyricsScriptConversion.apply(to: doc, target: "zh-Hans")
        let out = try! #require(shown.lines[0].words)
        #expect(out.map(\.text) == ["爱情", "你比我想的 ", "阁较", "伟大"])
        #expect(out.map(\.start) == words.map(\.start))
        #expect(out.map(\.duration) == words.map(\.duration))
        #expect(shown.lines[0].text == out.map(\.text).joined())
    }

    /// NetEase's Simplified lane under a Traditional target comes out Traditional (OpenCC, phrase-level).
    @Test func translationLaneConverted() {
        let doc = QTLyricsDocument(lines: [QTLyricsLine(start: 1, text: "Gió cứ rít réo rắc trong đêm", translation: "午夜的风你尽管呼啸")],
                                   syncKind: .line, source: .netease, language: "vi", translationLanguage: "zh-Hans",
                                   translationSource: .netease)
        let shown = QTLyricsTranslationPolicy.applyProviderLane(to: doc, target: "zh-Hant")
        #expect(shown.translationLanguage == "zh-Hant")
        #expect(shown.lines[0].translation == "午夜的風你儘管呼嘯")
        #expect(shown.lines[0].text == doc.lines[0].text)
        #expect(shown.scriptConvertedFrom == nil)
    }
}
