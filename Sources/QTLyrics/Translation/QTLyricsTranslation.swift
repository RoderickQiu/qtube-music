import Foundation
import QTCore

/// The engines that can fill the translation line, in the order HANDOFF §4 prefers them.
public enum QTLyricsTranslationEngineKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// The lyrics provider's own translation lane (NetEase/QQ/Kugou zh-Hans, AMLL/TTML inline translations).
    case provider
    /// Foundation Models on macOS 26+ (toggle "Translate lyrics with Apple Intelligence", on by default).
    case appleIntelligence
    /// Translation framework (macOS 15+), needs a consented language download.
    case translationFramework

    public var source: QTLyricsSource? {
        switch self {
        case .provider: nil
        case .appleIntelligence: .appleIntelligenceEngine
        case .translationFramework: .translationFrameworkEngine
        }
    }
}

public enum QTLyricsTranslationAvailability: Sendable, Hashable {
    case available
    /// Supported, but the language model must be downloaded first — only after the user agrees.
    case needsDownload
    /// Not on this Mac / OS / language pair; `reason` is a stable identifier for the UI to localise.
    case unavailable(reason: String)
}

public struct QTLyricsTranslationContext: Sendable, Hashable {
    public var title: String
    public var artist: String
    public var sourceLanguage: String?
    public var targetLanguage: String

    public init(title: String, artist: String, sourceLanguage: String?, targetLanguage: String) {
        self.title = title
        self.artist = artist
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }
}

public enum QTLyricsTranslationError: Error, Sendable, Equatable {
    /// The engine returned a different number of lines — never shown (no partial/misaligned translations).
    case lineCountMismatch(expected: Int, got: Int)
    /// Safety guardrails refused (explicit lyrics) or the engine gave up.
    case refused
    case timedOut
    /// Most lines came back unchanged although the target is another language.
    case untranslated
    case unavailable(String)
}

/// A machine-translation engine. Implementations must return exactly one output line per input line.
public protocol QTLyricsTranslationEngine: Sendable {
    var kind: QTLyricsTranslationEngineKind { get }
    func availability(from source: String?, to target: String) async -> QTLyricsTranslationAvailability
    func translate(_ lines: [String], context: QTLyricsTranslationContext) async throws -> [String]
    /// False when the engine needs a session handed out by SwiftUI (`.translationTask`) to run.
    var translatesDirectly: Bool { get }
}

public extension QTLyricsTranslationEngine {
    var translatesDirectly: Bool { true }
}

/// What the lyrics popover should say about the translation line, and where it comes from.
public enum QTLyricsTranslationPlan: Sendable, Hashable {
    case none(QTLyricsTranslationSkipReason)
    /// Use the provider's lane (already in the document).
    case provider(QTLyricsSource)
    /// Run this engine.
    case engine(QTLyricsTranslationEngineKind)
    /// The Translation framework could do it after a consented model download ("Download {language}…").
    case needsDownload(language: String)

    public var engineKind: QTLyricsTranslationEngineKind? {
        switch self {
        case .provider: .provider
        case .engine(let k): k
        default: nil
        }
    }
}

public enum QTLyricsTranslationSkipReason: String, Sendable, Hashable {
    /// Lyrics translation is Off.
    case off
    /// No lyrics, or plain lyrics with nothing to align to.
    case noLyrics
    /// The song is already in the target language — no pointless translation.
    case alreadyInTargetLanguage
    /// No engine can translate this pair on this Mac.
    case noEngine
}

/// Provider-lane policy applied to every document the resolver hands out.
public enum QTLyricsTranslationPolicy {
    /// Keeps the provider's translation only when it is in `target` and the song isn't already in `target`.
    public static func applyProviderLane(to document: QTLyricsDocument, target: String?) -> QTLyricsDocument {
        guard document.hasTranslation else { return document }
        let keep = target != nil && QTLanguageCode.isSame(document.translationLanguage, target)
            && !QTLanguageCode.isSame(document.language, target)
        var d = document
        guard keep else {
            for i in d.lines.indices { d.lines[i].translation = nil }
            d.translationLanguage = nil
            d.translationSource = nil
            return d
        }
        // A Simplified lane for a Traditional target (or the reverse) is converted, so every surface shows the script
        // the user picked.
        if let target, let lane = document.translationLanguage,
           let transform = chineseTransform(from: QTLanguageCode.normalize(lane), to: QTLanguageCode.normalize(target)) {
            for i in d.lines.indices {
                d.lines[i].translation = d.lines[i].translation.map { $0.applyingTransform(transform, reverse: false) ?? $0 }
            }
            d.translationLanguage = QTLanguageCode.normalize(target)
        }
        return d
    }

    static func chineseTransform(from: String, to: String) -> StringTransform? {
        switch (from, to) {
        case ("zh-Hans", "zh-Hant"): StringTransform("Hans-Hant")
        case ("zh-Hant", "zh-Hans"): StringTransform("Hant-Hans")
        default: nil
        }
    }

    /// The plan for what `applyProviderLane` produced, without asking machine-translation engines (they arrive in
    /// M6): provider lane in the target, already in the target, Off, no lyrics, or nothing (`.none(.noEngine)`).
    /// - Parameter document: the full document (before the policy), so a provider lane can be recognised.
    public static func plan(for document: QTLyricsDocument?, target: String?) -> QTLyricsTranslationPlan {
        guard let target else { return .none(.off) }
        guard let document, !document.lines.isEmpty, document.syncKind != .plain || document.hasTranslation else {
            return .none(.noLyrics)
        }
        if QTLanguageCode.isSame(document.language, target) { return .none(.alreadyInTargetLanguage) }
        if document.hasTranslation, QTLanguageCode.isSame(document.translationLanguage, target) {
            return .provider(document.translationSource ?? document.source)
        }
        return .none(.noEngine)
    }
}

/// Picks the translation engine (HANDOFF §4): provider lane in the target language → Apple Intelligence
/// (if enabled and available) → Translation framework (available, or needs a consented download).
/// Skips when Off or when the song is already in the target language.
public struct QTLyricsTranslationSelector: Sendable {
    public var engines: [any QTLyricsTranslationEngine]

    public init(engines: [any QTLyricsTranslationEngine]) {
        self.engines = engines
    }

    public func plan(for document: QTLyricsDocument?, target: String?, appleIntelligenceEnabled: Bool) async -> QTLyricsTranslationPlan {
        guard let target else { return .none(.off) }
        guard let document, !document.lines.isEmpty else { return .none(.noLyrics) }
        if QTLanguageCode.isSame(document.language, target) { return .none(.alreadyInTargetLanguage) }
        if document.hasTranslation, QTLanguageCode.isSame(document.translationLanguage, target) {
            return .provider(document.translationSource ?? document.source)
        }
        var downloadable = false
        for kind in [QTLyricsTranslationEngineKind.appleIntelligence, .translationFramework] {
            if kind == .appleIntelligence, !appleIntelligenceEnabled { continue }
            guard let engine = engines.first(where: { $0.kind == kind }) else { continue }
            switch await engine.availability(from: document.language, to: target) {
            case .available: return .engine(kind)
            case .needsDownload: if kind == .translationFramework { downloadable = true }
            case .unavailable: continue
            }
        }
        return downloadable ? .needsDownload(language: target) : .none(.noEngine)
    }
}

/// Runs the plan: translates line-for-line with the chosen engine, falls back from Apple Intelligence to the

/// Runs the plan: translates line-for-line with the chosen engine, falls back from Apple Intelligence to the
/// Translation framework on refusal / mismatch / timeout, never shows a partial result, caches per song +
/// language + engine (SQLite `translations` table).
public actor QTLyricsTranslationCoordinator {
    private let selector: QTLyricsTranslationSelector
    private let cache: QTLyricsCache?

    public init(engines: [any QTLyricsTranslationEngine], cache: QTLyricsCache?) {
        selector = QTLyricsTranslationSelector(engines: engines)
        self.cache = cache
    }

    /// The real engines: Apple Intelligence (Foundation Models, macOS 26+) and the Translation framework.
    public static func standard(cache: QTLyricsCache?) -> QTLyricsTranslationCoordinator {
        QTLyricsTranslationCoordinator(engines: [QTAppleIntelligenceTranslationEngine(), QTTranslationFrameworkEngine()],
                                       cache: cache)
    }

    public func plan(for document: QTLyricsDocument?, target: String?, appleIntelligenceEnabled: Bool) async -> QTLyricsTranslationPlan {
        await selector.plan(for: document, target: target, appleIntelligenceEnabled: appleIntelligenceEnabled)
    }

    /// Whether `kind` can translate `source` → `target` on this Mac right now.
    public func availability(of kind: QTLyricsTranslationEngineKind, from source: String?, to target: String) async
        -> QTLyricsTranslationAvailability {
        guard let engine = engine(kind) else { return .unavailable(reason: "noEngine") }
        return await engine.availability(from: source, to: target)
    }

    /// True when `kind` can run here without a SwiftUI-hosted session (Translation framework before macOS 26 hands
    /// sessions out only through `.translationTask`).
    public func translatesDirectly(_ kind: QTLyricsTranslationEngineKind) -> Bool {
        engine(kind)?.translatesDirectly ?? false
    }

    /// A translation stored earlier for this song + language + engine, if its line count still matches.
    /// - Parameter source: the sung lines, for the lyric polish (`QTLyricsTranslationPolish`); empty = unknown.
    public func cachedTranslation(key: String, target: String, engine kind: QTLyricsTranslationEngineKind,
                                  lineCount: Int, source: [String] = []) async -> [String]? {
        guard let cached = await cache?.translation(videoId: key, language: target, engine: kind.rawValue),
              cached.count == lineCount else { return nil }
        // Entries stored before the lyric polish existed get it on the way out.
        return QTLyricsTranslationPolish.lines(cached, source: source)
    }

    /// Stores a complete translation (one entry per source line) for this song + language + engine.
    public func storeTranslation(_ lines: [String], key: String, target: String, engine kind: QTLyricsTranslationEngineKind) async {
        await cache?.storeTranslation(lines, videoId: key, language: target, engine: kind.rawValue)
    }

    /// Translates every line with one engine: cache first, then the engine. Throws on refusal, timeout, a line-count
    /// mismatch or an untranslated result — callers never see a partial or misaligned translation.
    /// - Parameter key: the song's cache key (videoId, or a lyrics fingerprint).
    public func run(_ kind: QTLyricsTranslationEngineKind, lines: [String], key: String,
                    context: QTLyricsTranslationContext) async throws -> [String] {
        if let cached = await cachedTranslation(key: key, target: context.targetLanguage, engine: kind, lineCount: lines.count,
                                                source: lines) {
            return cached
        }
        guard let engine = engine(kind) else { throw QTLyricsTranslationError.unavailable("noEngine") }
        var out = try await engine.translate(lines, context: context)
        try QTLyricsTranslationValidator.validate(out, source: lines, context: context)
        out = QTLyricsTranslationPolish.lines(out, source: lines)
        // Blank lines and "♪" markers never get a translation line, whatever the engine echoed.
        for i in out.indices where !QTLyricsTranslationInput.isTranslatable(lines[i]) { out[i] = "" }
        await storeTranslation(out, key: key, target: context.targetLanguage, engine: kind)
        return out
    }

    /// Returns the document with a translation lane in `target` (or unchanged) and the plan that produced it.
    public func translate(_ document: QTLyricsDocument, videoId: String, title: String, artist: String, target: String?,
                          appleIntelligenceEnabled: Bool) async -> (QTLyricsDocument, QTLyricsTranslationPlan) {
        let plan = await selector.plan(for: document, target: target, appleIntelligenceEnabled: appleIntelligenceEnabled)
        guard case .engine(let first) = plan, let target else { return (document, plan) }
        var order = [first]
        if first == .appleIntelligence { order.append(.translationFramework) }
        let sourceLines = document.lines.map(\.text)
        let context = QTLyricsTranslationContext(title: title, artist: artist, sourceLanguage: document.language,
                                                 targetLanguage: target)
        for kind in order {
            if kind != first, await availability(of: kind, from: document.language, to: target) != .available { continue }
            guard let translated = try? await run(kind, lines: sourceLines, key: videoId, context: context) else { continue }
            var d = document
            for i in d.lines.indices {
                let t = translated[i].trimmingCharacters(in: .whitespaces)
                d.lines[i].translation = t.isEmpty ? nil : t
            }
            d.translationLanguage = target
            d.translationSource = kind.source
            return (d, .engine(kind))
        }
        return (document, .none(.noEngine))
    }

    private func engine(_ kind: QTLyricsTranslationEngineKind) -> (any QTLyricsTranslationEngine)? {
        selector.engines.first { $0.kind == kind }
    }
}

/// Checks an engine's output before anything is shown or cached.
public enum QTLyricsTranslationValidator {
    /// - Throws: `.lineCountMismatch` when the count differs; `.untranslated` when most lines came back unchanged
    ///   although the target is a different language (the model echoed the input instead of translating).
    public static func validate(_ output: [String], source: [String], context: QTLyricsTranslationContext) throws {
        guard output.count == source.count else {
            throw QTLyricsTranslationError.lineCountMismatch(expected: source.count, got: output.count)
        }
        let pairs = zip(source, output).filter { QTLyricsTranslationInput.isTranslatable($0.0) }
        guard pairs.count >= 3 else { return }
        let unchanged = pairs.filter { fold($0.0) == fold($0.1) }.count
        if Double(unchanged) / Double(pairs.count) > 0.6 { throw QTLyricsTranslationError.untranslated }
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}

/// Machine translation reads like prose; lyrics don't. Every engine's output (and every cached result) passes
/// through here before it is shown: trimmed, and the sentence-final full stop an engine adds ("저는 여전히 숨이
/// 막혔습니다.", "I can't breathe.") dropped — unless the sung line itself ends with one. "?" and "!" stay (they carry
/// the tone), and so does an ellipsis ("...", "…", "。。。"), which is a pause rather than a full stop.
///
/// Register: the Translation framework has no formality or register option, so its Korean comes in the formal
/// 습니다 style and its Japanese in です/ます; nothing here rewrites endings (a wrong guess would change the meaning).
/// Apple Intelligence is asked for the plain register lyrics use instead (`QTLyricsTranslationPrompt.instructions`).
public enum QTLyricsTranslationPolish {
    /// ASCII, ideographic, fullwidth and halfwidth full stops.
    static let fullStops: Set<Character> = [".", "。", "．", "｡"]
    /// Closing quotes and brackets a full stop may sit inside ("그래.”").
    static let closers: Set<Character> = ["\"", "'", "”", "’", "」", "』", ")", "）", "»", "›"]

    /// - Parameters:
    ///   - translation: one engine output line.
    ///   - source: the sung line it translates; nil when unknown (cached results), treated as "no full stop".
    public static func line(_ translation: String, source: String?) -> String {
        let t = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        // A line the engine left as it was (solfège, names, vocables, an English line in a Chinese song) would only
        // repeat itself under itself: no translation line for it.
        if let source, !t.isEmpty {
            let key = QTLyricsTextFolding.comparisonKey(t)
            if key.count > 1, key == QTLyricsTextFolding.comparisonKey(source) { return "" }
        }
        if let source, endsWithFullStop(source.trimmingCharacters(in: .whitespacesAndNewlines)) { return t }
        var chars = Array(t)
        var end = chars.count
        while end > 0, closers.contains(chars[end - 1]) { end -= 1 }
        guard end > 1, fullStops.contains(chars[end - 1]), !fullStops.contains(chars[end - 2]) else { return t }
        chars.remove(at: end - 1)
        return String(chars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `line(_:source:)` for a whole song; `source` aligned with `translations` (shorter = unknown source).
    public static func lines(_ translations: [String], source: [String]) -> [String] {
        translations.enumerated().map { i, t in line(t, source: source.indices.contains(i) ? source[i] : nil) }
    }

    /// A single full stop at the end (an ellipsis doesn't count).
    static func endsWithFullStop(_ text: String) -> Bool {
        var chars = Array(text)
        while let last = chars.last, closers.contains(last) { chars.removeLast() }
        guard let last = chars.last, fullStops.contains(last) else { return false }
        return chars.count < 2 || !fullStops.contains(chars[chars.count - 2])
    }
}

/// Which lyric lines are worth sending to an engine, and how lines are grouped into requests.
public enum QTLyricsTranslationInput {
    /// Lines with words in them. Blank lines, "♪" markers and bare punctuation stay untranslated ("").
    public static func isTranslatable(_ line: String) -> Bool {
        line.contains { $0.isLetter }
    }

    /// Splits `lines` into consecutive chunks of at most `maxLines` lines and about `maxCharacters` characters, so a
    /// chunk plus its instructions and context fits a small context window. Every index appears in exactly one
    /// chunk, in order.
    public static func chunks(_ lines: [String], maxLines: Int, maxCharacters: Int) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0, chars = 0
        for (i, line) in lines.enumerated() {
            let n = line.count + 4
            if i > start, i - start >= maxLines || chars + n > maxCharacters {
                out.append(start..<i)
                start = i
                chars = 0
            }
            chars += n
        }
        if start < lines.count { out.append(start..<lines.count) }
        return out
    }
}

/// Runs `operation`, throwing `.timedOut` if it takes longer than `limit`.
func qtWithTranslationTimeout<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw QTLyricsTranslationError.timedOut
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw QTLyricsTranslationError.timedOut }
        return first
    }
}
