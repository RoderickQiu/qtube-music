import Foundation
import QTCore
import Testing
@testable import QTLyrics

@Suite struct LanguageTests {
    @Test func detection() {
        #expect(QTLyricsLanguageDetector.detect(["Gió cứ rít réo rắc trong đêm", "Bao đêm qua em vẫn nghẹn ngào"]) == "vi")
        #expect(QTLyricsLanguageDetector.detect(["沈むように溶けてゆくように", "二人だけの空が広がる夜に"]) == "ja")
        #expect(QTLyricsLanguageDetector.detect(["故事的小黄花", "从出生那年就飘着"]) == "zh-Hans")
        #expect(QTLyricsLanguageDetector.detect(["故事的小黃花", "從出生那年就飄著"]) == "zh-Hant")
        #expect(QTLyricsLanguageDetector.detect(["사랑해요 정말로"]) == "ko")
        #expect(QTLyricsLanguageDetector.detect(["कायर जो थे, वो शायर बने"]) == "hi")
        #expect(QTLyricsLanguageDetector.detect(["Well, I found a girl, beautiful and sweet",
                                                 "Oh, I never knew you were the someone waiting for me"]) == "en")
        #expect(QTLyricsLanguageDetector.detect(["♪ ♪", "123"]) == nil)
    }

    @Test func normalisation() {
        #expect(QTLanguageCode.normalize("zh-CN") == "zh-Hans")
        #expect(QTLanguageCode.normalize("zh_TW") == "zh-Hant")
        #expect(QTLanguageCode.normalize("zh-Hant-HK") == "zh-Hant")
        #expect(QTLanguageCode.normalize("en-US") == "en")
        #expect(QTLanguageCode.normalize("ja-Latn") == "ja-Latn")
        #expect(QTLanguageCode.isSame("zh-Hant", "zh-Hans"))
        #expect(!QTLanguageCode.isSame("vi", "zh-Hans"))
    }

    @Test func romanization() {
        #expect(QTLyricsRomanizer.romanize("晴天", language: "zh-Hans") == "qíng tiān")
        #expect(QTLyricsRomanizer.romanize("夜に駆ける", language: "ja") == "yoru ni kakeru")
        #expect(QTLyricsRomanizer.romanize("사랑해", language: "ko")?.hasPrefix("sa") == true)
        #expect(QTLyricsRomanizer.romanize("किया है", language: "hi")?.contains("kiy") == true)
        #expect(QTLyricsRomanizer.romanize("Gió cứ rít", language: "vi") == nil)
        #expect(QTLyricsRomanizer.needsRomanization("ja"))
        #expect(!QTLyricsRomanizer.needsRomanization("vi"))
    }
}

/// Fake engine for selection/fallback tests.
struct QTFakeTranslationEngine: QTLyricsTranslationEngine {
    var kind: QTLyricsTranslationEngineKind
    var state: QTLyricsTranslationAvailability
    var behaviour: Behaviour = .prefix
    enum Behaviour: Sendable { case prefix, dropLine, refuse, echo }

    func availability(from source: String?, to target: String) async -> QTLyricsTranslationAvailability { state }

    func translate(_ lines: [String], context: QTLyricsTranslationContext) async throws -> [String] {
        switch behaviour {
        case .prefix: return lines.map { "\(kind.rawValue):\($0)" }
        case .dropLine: return Array(lines.dropLast())
        case .refuse: throw QTLyricsTranslationError.refused
        case .echo: return lines
        }
    }
}

@Suite struct TranslationSelectionTests {
    let vietnamese = QTLyricsDocument(lines: [QTLyricsLine(start: 1, text: "Gió cứ rít"), QTLyricsLine(start: 4, text: "Bao đêm qua")],
                                      syncKind: .line, source: .youtubeMusic, language: "vi")

    var withProviderLane: QTLyricsDocument {
        var d = vietnamese
        d.lines[0].translation = "风"
        d.translationLanguage = "zh-Hans"
        d.translationSource = .netease
        return d
    }

    func selector(ai: QTLyricsTranslationAvailability, tf: QTLyricsTranslationAvailability) -> QTLyricsTranslationSelector {
        QTLyricsTranslationSelector(engines: [QTFakeTranslationEngine(kind: .appleIntelligence, state: ai),
                                              QTFakeTranslationEngine(kind: .translationFramework, state: tf)])
    }

    @Test func order() async {
        let s = selector(ai: .available, tf: .available)
        #expect(await s.plan(for: vietnamese, target: nil, appleIntelligenceEnabled: true) == .none(.off))
        #expect(await s.plan(for: nil, target: "en", appleIntelligenceEnabled: true) == .none(.noLyrics))
        // 1. Provider lane in the target language.
        #expect(await s.plan(for: withProviderLane, target: "zh-Hans", appleIntelligenceEnabled: true) == .provider(.netease))
        // 2. Apple Intelligence when enabled.
        #expect(await s.plan(for: withProviderLane, target: "en", appleIntelligenceEnabled: true) == .engine(.appleIntelligence))
        // 3. Translation framework when AI is off or unavailable.
        #expect(await s.plan(for: vietnamese, target: "en", appleIntelligenceEnabled: false) == .engine(.translationFramework))
        #expect(await selector(ai: .unavailable(reason: "x"), tf: .available).plan(for: vietnamese, target: "en", appleIntelligenceEnabled: true)
            == .engine(.translationFramework))
        // Model not installed: ask for consent, never download silently.
        #expect(await selector(ai: .unavailable(reason: "x"), tf: .needsDownload).plan(for: vietnamese, target: "ko", appleIntelligenceEnabled: true)
            == .needsDownload(language: "ko"))
        #expect(await selector(ai: .unavailable(reason: "x"), tf: .unavailable(reason: "y")).plan(for: vietnamese, target: "ko", appleIntelligenceEnabled: true)
            == .none(.noEngine))
    }

    @Test func skipsWhenAlreadyInTargetLanguage() async {
        var chinese = vietnamese
        chinese.language = "zh-Hant"
        #expect(await selector(ai: .available, tf: .available).plan(for: chinese, target: "zh-Hans", appleIntelligenceEnabled: true)
            == .none(.alreadyInTargetLanguage))
        // …and the provider-lane policy strips a Chinese lane from Chinese lyrics.
        var lane = withProviderLane
        lane.language = "zh-Hans"
        #expect(!QTLyricsTranslationPolicy.applyProviderLane(to: lane, target: "zh-Hans").hasTranslation)
        #expect(QTLyricsTranslationPolicy.applyProviderLane(to: withProviderLane, target: "zh-Hans").hasTranslation)
        #expect(!QTLyricsTranslationPolicy.applyProviderLane(to: withProviderLane, target: "en").hasTranslation)
    }

    @Test func coordinatorTranslatesAndCaches() async throws {
        let cache = try QTLyricsCache(url: nil)
        let c = QTLyricsTranslationCoordinator(engines: [QTFakeTranslationEngine(kind: .appleIntelligence, state: .available)], cache: cache)
        let (doc, plan) = await c.translate(vietnamese, videoId: "v", title: "t", artist: "a", target: "en", appleIntelligenceEnabled: true)
        #expect(plan == .engine(.appleIntelligence))
        #expect(doc.lines.map(\.translation) == ["appleIntelligence:Gió cứ rít", "appleIntelligence:Bao đêm qua"])
        #expect(doc.translationSource == .appleIntelligenceEngine)
        #expect(await cache.translation(videoId: "v", language: "en", engine: "appleIntelligence")?.count == 2)
    }

    @Test func appleIntelligenceFallsBackOnMismatchOrRefusal() async {
        for behaviour in [QTFakeTranslationEngine.Behaviour.dropLine, .refuse] {
            let c = QTLyricsTranslationCoordinator(engines: [
                QTFakeTranslationEngine(kind: .appleIntelligence, state: .available, behaviour: behaviour),
                QTFakeTranslationEngine(kind: .translationFramework, state: .available),
            ], cache: nil)
            let (doc, plan) = await c.translate(vietnamese, videoId: "v", title: "t", artist: "a", target: "en", appleIntelligenceEnabled: true)
            #expect(plan == .engine(.translationFramework))
            #expect(doc.lines.allSatisfy { $0.translation?.hasPrefix("translationFramework:") == true })
        }
        // Nothing usable: the document comes back untouched (never a partial translation).
        let none = QTLyricsTranslationCoordinator(engines: [
            QTFakeTranslationEngine(kind: .appleIntelligence, state: .available, behaviour: .dropLine),
        ], cache: nil)
        let (doc, plan) = await none.translate(vietnamese, videoId: "v", title: "t", artist: "a", target: "en", appleIntelligenceEnabled: true)
        #expect(plan == .none(.noEngine))
        #expect(!doc.hasTranslation)
    }

    @Test func untranslatedEchoFallsBack() async {
        let threeLines = QTLyricsDocument(lines: ["Gió cứ rít", "Bao đêm qua", "Em không còn"].enumerated().map {
            QTLyricsLine(start: Double($0.offset), text: $0.element)
        }, syncKind: .line, source: .youtubeMusic, language: "vi")
        let c = QTLyricsTranslationCoordinator(engines: [
            QTFakeTranslationEngine(kind: .appleIntelligence, state: .available, behaviour: .echo),
            QTFakeTranslationEngine(kind: .translationFramework, state: .available),
        ], cache: nil)
        let (doc, plan) = await c.translate(threeLines, videoId: "v", title: "t", artist: "a", target: "en", appleIntelligenceEnabled: true)
        #expect(plan == .engine(.translationFramework))
        #expect(doc.lines.allSatisfy { $0.translation?.hasPrefix("translationFramework:") == true })
    }

    @Test func runUsesTheCachePerEngineAndLanguage() async throws {
        let cache = try QTLyricsCache(url: nil)
        let c = QTLyricsTranslationCoordinator(engines: [QTFakeTranslationEngine(kind: .appleIntelligence, state: .available)], cache: cache)
        let context = QTLyricsTranslationContext(title: "t", artist: "a", sourceLanguage: "vi", targetLanguage: "ko")
        await c.storeTranslation(["바람", "밤"], key: "k", target: "ko", engine: .appleIntelligence)
        #expect(try await c.run(.appleIntelligence, lines: ["Gió", "Đêm"], key: "k", context: context) == ["바람", "밤"])
        // Another language isn't served from that entry; a stale entry with another line count is ignored.
        let en = QTLyricsTranslationContext(title: "t", artist: "a", sourceLanguage: "vi", targetLanguage: "en")
        #expect(try await c.run(.appleIntelligence, lines: ["Gió", "Đêm"], key: "k", context: en) == ["appleIntelligence:Gió", "appleIntelligence:Đêm"])
        #expect(await c.cachedTranslation(key: "k", target: "ko", engine: .appleIntelligence, lineCount: 3) == nil)
        await #expect(throws: QTLyricsTranslationError.refused) {
            _ = try await QTLyricsTranslationCoordinator(engines: [
                QTFakeTranslationEngine(kind: .appleIntelligence, state: .available, behaviour: .refuse),
            ], cache: cache).run(.appleIntelligence, lines: ["x"], key: "other", context: context)
        }
    }

    /// The real engines answer without hanging and never claim a model that would need a download is ready.
    @Test func realEnginesReportAvailabilityHonestly() async {
        let ai = await QTAppleIntelligenceTranslationEngine().availability(from: "vi", to: "en")
        #expect(ai != .needsDownload)
        if #unavailable(macOS 26) { #expect(ai == .unavailable(reason: QTAppleIntelligenceUnavailableReason.requiresMacOS26)) }
        #expect(await QTTranslationFrameworkEngine().availability(from: nil, to: "en") == .unavailable(reason: "unknownSourceLanguage"))
    }
}

@Suite struct TranslationEngineHelperTests {
    @Test func validatorRejectsMisalignedOrEchoedOutput() throws {
        let context = QTLyricsTranslationContext(title: "t", artist: "a", sourceLanguage: "vi", targetLanguage: "en")
        let source = ["Gió cứ rít réo rắc", "Bao đêm qua", "Em không còn cảm giác", "♪"]
        #expect(throws: QTLyricsTranslationError.lineCountMismatch(expected: 4, got: 3)) {
            try QTLyricsTranslationValidator.validate(["a", "b", "c"], source: source, context: context)
        }
        #expect(throws: QTLyricsTranslationError.untranslated) {
            try QTLyricsTranslationValidator.validate(["Gio cu rit reo rac", "Bao đêm qua", "Em không còn cảm giác", ""], source: source, context: context)
        }
        try QTLyricsTranslationValidator.validate(["The wind howls", "So many nights", "I feel nothing anymore", ""],
                                                  source: source, context: context)
        // A chorus left as is (names, "oh oh") is fine when most lines are translated.
        try QTLyricsTranslationValidator.validate(["The wind howls", "Bao đêm qua", "I feel nothing anymore", ""],
                                                  source: source, context: context)
    }

    @Test func chunksCoverEveryLineInOrder() {
        let lines = (0..<50).map { "line \($0) " + String(repeating: "x", count: $0 % 7 * 10) }
        let chunks = QTLyricsTranslationInput.chunks(lines, maxLines: 12, maxCharacters: 300)
        #expect(chunks.first?.lowerBound == 0)
        #expect(chunks.last?.upperBound == 50)
        for (a, b) in zip(chunks, chunks.dropFirst()) { #expect(a.upperBound == b.lowerBound) }
        #expect(chunks.allSatisfy { $0.count <= 12 && !$0.isEmpty })
        // One very long line still gets its own chunk.
        #expect(QTLyricsTranslationInput.chunks([String(repeating: "y", count: 2000), "z"], maxLines: 10, maxCharacters: 100) == [0..<1, 1..<2])
        #expect(QTLyricsTranslationInput.chunks([], maxLines: 10, maxCharacters: 100).isEmpty)
        #expect(!QTLyricsTranslationInput.isTranslatable("♪ ♪"))
        #expect(QTLyricsTranslationInput.isTranslatable("出牌"))
    }

    @Test func promptCarriesSongContextAndNumberedLines() {
        let context = QTLyricsTranslationContext(title: "Hạ Phỏm", artist: "Kim Ny Ngọc", sourceLanguage: "vi", targetLanguage: "ko")
        let prompt = QTLyricsTranslationPrompt.prompt(lines: ["Gió cứ rít", "Bao đêm qua"],
                                                      previous: [(source: "Em ơi", translation: "그대여")], context: context)
        #expect(prompt.contains("Song: \"Hạ Phỏm\" by Kim Ny Ngọc"))
        #expect(prompt.contains("Original language: Vietnamese"))
        #expect(prompt.contains("Translate into: Korean"))
        #expect(prompt.contains("Em ơi => 그대여"))
        #expect(prompt.contains("Translate these 2 lines:\n1. Gió cứ rít\n2. Bao đêm qua"))
        #expect(QTLyricsTranslationPrompt.instructions(target: "zh-Hans").contains("Simplified Chinese"))
        #expect(QTLyricsTranslationPrompt.languageName("zh-TW") == "Traditional Chinese")
    }

    @Test func translationFrameworkBatchKeepsLinesAligned() throws {
        let lines = ["Gió cứ rít", "", "♪", "Bao đêm qua"]
        let items = QTTranslationFrameworkBatch.items(for: lines)
        #expect(items.map(\.index) == [0, 3])
        let out = try QTTranslationFrameworkBatch.lines(from: [(id: "3", text: "So many nights"), (id: "0", text: "The wind")],
                                                        count: lines.count, expected: items.count)
        #expect(out == ["The wind", "", "", "So many nights"])
        #expect(throws: QTLyricsTranslationError.lineCountMismatch(expected: 2, got: 1)) {
            try QTTranslationFrameworkBatch.lines(from: [(id: "0", text: "The wind")], count: lines.count, expected: items.count)
        }
    }
}

@Suite struct CacheTests {
    @Test func persistsAcrossInstances() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qt-lyrics-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Lyrics.sqlite")
        do {
            let cache = try QTLyricsCache(url: url)
            let doc = QTLyricsDocument(lines: [QTLyricsLine(start: 1, text: "x", translation: "甲")], syncKind: .line, source: .lrclib)
            await cache.store(QTLyricsCacheEntry(videoId: "v1", document: doc, versions: [], chosenID: "lrclib:1",
                                                 attribution: nil, sourcesKey: "k"))
            await cache.setOffset(-0.2, for: "v1")
            await cache.setPinnedVersionID("lrclib:1", for: "v1")
            await cache.addAlias("周杰伦", "Jay Chou", origin: "netease")
            await cache.setBlob(Data([1, 2, 3]), named: "b")
        }
        let reopened = try QTLyricsCache(url: url)
        let entry = try #require(await reopened.entry(for: "v1"))
        #expect(entry.document?.lines.first?.translation == "甲")
        #expect(entry.chosenID == "lrclib:1")
        #expect(await reopened.offset(for: "v1") == -0.2)
        #expect(await reopened.pinnedVersionID(for: "v1") == "lrclib:1")
        #expect(await reopened.aliasPairs().first! == ("周杰伦", "Jay Chou"))
        #expect(await reopened.blob(named: "b")?.data == Data([1, 2, 3]))
        await reopened.setOffset(0, for: "v1")
        #expect(await reopened.offset(for: "v1") == nil)
        #expect(await reopened.entry(for: "missing") == nil)
    }
}
