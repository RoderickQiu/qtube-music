import Foundation
import OSLog
import QTCore
#if canImport(FoundationModels)
import FoundationModels
#endif

// Owner: lyrics-translate (M6). Apple Intelligence lyric translation through the Foundation Models framework
// (macOS 26+, Apple silicon, Apple Intelligence on, target language supported). The model reads the song in
// context — title, artist and the lines before — so tone, slang and imagery survive ("Hạ Phỏm" stays a card-game
// metaphor), and guided generation returns exactly one string per source line so the result stays aligned with the
// timestamps. Refusals, a wrong line count, an untranslated echo or a timeout throw: the caller falls back to the
// Translation framework for the whole song and never shows a partial translation.

/// Apple Intelligence (Foundation Models) lyric translation.
public struct QTAppleIntelligenceTranslationEngine: QTLyricsTranslationEngine {
    public let kind = QTLyricsTranslationEngineKind.appleIntelligence
    /// Time limit for one chunk (the model is on device; a stuck request falls back instead of spinning).
    public var chunkTimeout: Duration
    /// Upper bounds for one request; the model's context window is small (4096 tokens on macOS 26).
    public var maxLinesPerChunk: Int
    public var maxCharactersPerChunk: Int

    public init(chunkTimeout: Duration = .seconds(45), maxLinesPerChunk: Int = 24, maxCharactersPerChunk: Int = 900) {
        self.chunkTimeout = chunkTimeout
        self.maxLinesPerChunk = maxLinesPerChunk
        self.maxCharactersPerChunk = maxCharactersPerChunk
    }

    public func availability(from source: String?, to target: String) async -> QTLyricsTranslationAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return QTFoundationModelsLyricsTranslator.availability(to: target)
        }
        #endif
        return .unavailable(reason: QTAppleIntelligenceUnavailableReason.requiresMacOS26)
    }

    public func translate(_ lines: [String], context: QTLyricsTranslationContext) async throws -> [String] {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let translator = QTFoundationModelsLyricsTranslator(chunkTimeout: chunkTimeout, maxLines: maxLinesPerChunk,
                                                                maxCharacters: maxCharactersPerChunk)
            return try await translator.translate(lines, context: context)
        }
        #endif
        throw QTLyricsTranslationError.unavailable(QTAppleIntelligenceUnavailableReason.requiresMacOS26)
    }
}

/// Stable reasons the Apple Intelligence engine reports through `QTLyricsTranslationAvailability.unavailable`.
public enum QTAppleIntelligenceUnavailableReason {
    public static let requiresMacOS26 = "requiresMacOS26"
    public static let deviceNotEligible = "deviceNotEligible"
    public static let notEnabled = "appleIntelligenceNotEnabled"
    public static let modelNotReady = "modelNotReady"
    public static let languageUnsupported = "languageUnsupported"
    public static let unavailable = "unavailable"
}

/// Prompt text for one chunk. Plain functions so the wording is testable on any macOS.
public enum QTLyricsTranslationPrompt {
    /// English name of a BCP-47 language for the model's instructions ("Korean", "Chinese (Simplified)").
    public static func languageName(_ code: String) -> String {
        let english = Locale(identifier: "en")
        switch QTLanguageCode.normalize(code) {
        case "zh-Hans": return "Simplified Chinese"
        case "zh-Hant": return "Traditional Chinese"
        case let c: return english.localizedString(forIdentifier: c) ?? c
        }
    }

    public static func instructions(target: String) -> String {
        let name = languageName(target)
        var out = """
        You translate song lyrics into \(name) for a music player that shows the translation under each sung line.
        Translate every numbered line into natural \(name) that keeps the song's tone, slang and imagery; read the \
        song as a whole, so metaphors and idioms keep their meaning instead of being translated word for word.
        Write the way song lyrics are written, not formal prose: a natural lyric register, short lines, and no full \
        stop at the end of a line unless the original line has one. Keep question and exclamation marks.
        """
        if let register = registerNote(target) { out += "\n" + register }
        out += """

        Return exactly one translation for each numbered line, in the same order. Never merge, split, skip, number, \
        explain or add lines. Keep personal names and place names as they are. If a line is only sounds or \
        vocables (such as "oh", "la la", "yeah"), copy it unchanged.
        """
        return out
    }

    /// Languages whose verb endings mark politeness: lyrics use the plain forms.
    static func registerNote(_ target: String) -> String? {
        switch QTLanguageCode.normalize(target) {
        case "ko": "Use the plain endings Korean lyrics use (such as -아/-어, -지, -네, -야), never the formal -습니다/-ㅂ니다 style."
        case "ja": "Use the plain forms Japanese lyrics use (such as 〜だ, 〜ない, 〜てる), not です/ます."
        default: nil
        }
    }

    /// - Parameters:
    ///   - lines: the chunk to translate.
    ///   - previous: up to a few earlier source lines with their translations, for continuity (not translated again).
    public static func prompt(lines: [String], previous: [(source: String, translation: String)],
                              context: QTLyricsTranslationContext) -> String {
        var out = "Song: \"\(context.title)\""
        if !context.artist.isEmpty { out += " by \(context.artist)" }
        if let source = context.sourceLanguage { out += "\nOriginal language: \(languageName(source))" }
        out += "\nTranslate into: \(languageName(context.targetLanguage))"
        if !previous.isEmpty {
            out += "\n\nThe lines just before (already translated, for context only):"
            for p in previous { out += "\n\(p.source) => \(p.translation)" }
        }
        out += "\n\nTranslate these \(lines.count) lines:"
        for (i, line) in lines.enumerated() { out += "\n\(i + 1). \(line)" }
        return out
    }
}

#if canImport(FoundationModels)
/// The guided-generation result: exactly one translated string per source line (the count is enforced by the
/// schema the request is made with, see `QTFoundationModelsLyricsTranslator.schema(lineCount:)`).
@available(macOS 26, *)
@Generable(description: "Translated song lyrics")
struct QTGeneratedLyricsTranslation {
    @Guide(description: "One translated line for each numbered source line, in the same order")
    var lines: [String]
}

@available(macOS 26, *)
struct QTFoundationModelsLyricsTranslator {
    let chunkTimeout: Duration
    let maxLines: Int
    let maxCharacters: Int
    private static let log = Logger(subsystem: "com.roderickqiu.qtube", category: "lyrics-translate")
    /// Lines of earlier context passed with each chunk.
    private static let contextLines = 4

    static func model() -> SystemLanguageModel {
        // Lyrics are user content being transformed, not generated: the permissive transformation guardrails keep
        // ordinary songs (drinking, heartbreak, mild language) from being refused.
        SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
    }

    static func availability(to target: String) -> QTLyricsTranslationAvailability {
        let model = model()
        switch model.availability {
        case .available:
            guard model.supportsLocale(Locale(identifier: QTLanguageCode.normalize(target))) else {
                return .unavailable(reason: QTAppleIntelligenceUnavailableReason.languageUnsupported)
            }
            return .available
        case .unavailable(.deviceNotEligible): return .unavailable(reason: QTAppleIntelligenceUnavailableReason.deviceNotEligible)
        case .unavailable(.appleIntelligenceNotEnabled): return .unavailable(reason: QTAppleIntelligenceUnavailableReason.notEnabled)
        case .unavailable(.modelNotReady): return .unavailable(reason: QTAppleIntelligenceUnavailableReason.modelNotReady)
        case .unavailable: return .unavailable(reason: QTAppleIntelligenceUnavailableReason.unavailable)
        }
    }

    /// The response schema for `lineCount` lines: an object with a `lines` array of exactly that many strings.
    static func schema(lineCount: Int) throws -> GenerationSchema {
        let root = DynamicGenerationSchema(
            name: "QTGeneratedLyricsTranslation",
            description: "Translated song lyrics",
            properties: [
                .init(name: "lines", description: "One translated line for each numbered source line, in the same order",
                      schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self),
                                                      minimumElements: lineCount, maximumElements: lineCount)),
            ])
        return try GenerationSchema(root: root, dependencies: [])
    }

    func translate(_ lines: [String], context: QTLyricsTranslationContext) async throws -> [String] {
        // Only lines with words go to the model; blank lines and "♪" markers stay empty.
        let indices = lines.indices.filter { QTLyricsTranslationInput.isTranslatable(lines[$0]) }
        var out = [String](repeating: "", count: lines.count)
        guard !indices.isEmpty else { return out }
        let texts = indices.map { lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) }
        var translated: [String] = []
        translated.reserveCapacity(texts.count)
        for range in QTLyricsTranslationInput.chunks(texts, maxLines: maxLines, maxCharacters: maxCharacters) {
            try Task.checkCancellation()
            let chunk = Array(texts[range])
            let previous = (max(range.lowerBound - Self.contextLines, 0)..<range.lowerBound).map { (texts[$0], translated[$0]) }
            translated += try await translateChunk(chunk, previous: previous, context: context, allowSplit: true)
        }
        guard translated.count == indices.count else {
            throw QTLyricsTranslationError.lineCountMismatch(expected: indices.count, got: translated.count)
        }
        for (i, index) in indices.enumerated() { out[index] = translated[i] }
        return out
    }

    /// The request didn't fit the context window (macOS 26 and 27 report it through different error types).
    static func exceededContext(_ error: any Error) -> Bool {
        if #available(macOS 27, *), let e = error as? LanguageModelError, case .contextSizeExceeded = e { return true }
        if let e = error as? LanguageModelSession.GenerationError, case .exceededContextWindowSize = e { return true }
        return false
    }

    private func translateChunk(_ chunk: [String], previous: [(String, String)], context: QTLyricsTranslationContext,
                                allowSplit: Bool) async throws -> [String] {
        let instructions = QTLyricsTranslationPrompt.instructions(target: context.targetLanguage)
        let prompt = QTLyricsTranslationPrompt.prompt(lines: chunk, previous: previous.map { (source: $0.0, translation: $0.1) },
                                                      context: context)
        let schema = try Self.schema(lineCount: chunk.count)
        do {
            let lines = try await qtWithTranslationTimeout(chunkTimeout) {
                // A fresh session per chunk: the transcript never outgrows the context window.
                let session = LanguageModelSession(model: Self.model(), instructions: instructions)
                let response = try await session.respond(to: prompt, schema: schema,
                                                         options: GenerationOptions(samplingMode: .greedy))
                return try QTGeneratedLyricsTranslation(response.content).lines
            }
            guard lines.count == chunk.count else {
                throw QTLyricsTranslationError.lineCountMismatch(expected: chunk.count, got: lines.count)
            }
            return lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        } catch let error as QTLyricsTranslationError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Self.exceededContext(error), allowSplit, chunk.count > 1 {
                // Too long after all (dense scripts tokenise worse): halve once and carry on.
                let mid = chunk.count / 2
                let first = try await translateChunk(Array(chunk[..<mid]), previous: previous, context: context, allowSplit: false)
                let tail = Array(zip(chunk[..<mid], first).suffix(Self.contextLines))
                let second = try await translateChunk(Array(chunk[mid...]), previous: tail, context: context, allowSplit: false)
                return first + second
            }
            // Guardrail refusals, decoding failures, rate limits, assets going away: the caller falls back.
            Self.log.info("Apple Intelligence declined or failed: \(String(describing: type(of: error)), privacy: .public)")
            throw QTLyricsTranslationError.refused
        }
    }
}
#endif
