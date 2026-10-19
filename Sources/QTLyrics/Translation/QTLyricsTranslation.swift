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
    case unavailable(String)
}

/// A machine-translation engine. Implementations must return exactly one output line per input line.
public protocol QTLyricsTranslationEngine: Sendable {
    var kind: QTLyricsTranslationEngineKind { get }
    func availability(from source: String?, to target: String) async -> QTLyricsTranslationAvailability
    func translate(_ lines: [String], context: QTLyricsTranslationContext) async throws -> [String]
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
/// Translation framework on refusal / mismatch / timeout, never shows a partial result, caches per song +
/// language + engine.
public actor QTLyricsTranslationCoordinator {
    private let selector: QTLyricsTranslationSelector
    private let cache: QTLyricsCache?

    public init(engines: [any QTLyricsTranslationEngine], cache: QTLyricsCache?) {
        selector = QTLyricsTranslationSelector(engines: engines)
        self.cache = cache
    }

    /// Default engines: the M6 stubs (unavailable until implemented).
    public static func standard(cache: QTLyricsCache?) -> QTLyricsTranslationCoordinator {
        QTLyricsTranslationCoordinator(engines: [QTAppleIntelligenceTranslationEngine(), QTTranslationFrameworkEngine()],
                                       cache: cache)
    }

    public func plan(for document: QTLyricsDocument?, target: String?, appleIntelligenceEnabled: Bool) async -> QTLyricsTranslationPlan {
        await selector.plan(for: document, target: target, appleIntelligenceEnabled: appleIntelligenceEnabled)
    }

    /// Returns the document with a translation lane in `target` (or unchanged) and the plan that produced it.
    public func translate(_ document: QTLyricsDocument, videoId: String, title: String, artist: String, target: String?,
                          appleIntelligenceEnabled: Bool) async -> (QTLyricsDocument, QTLyricsTranslationPlan) {
        let plan = await selector.plan(for: document, target: target, appleIntelligenceEnabled: appleIntelligenceEnabled)
        guard case .engine(let first) = plan, let target else { return (document, plan) }
        var order = [first]
        if first == .appleIntelligence { order.append(.translationFramework) }
        let sourceLines = document.lines.map(\.text)
        for kind in order {
            guard let engine = selector.engines.first(where: { $0.kind == kind }) else { continue }
            if kind != first, await engine.availability(from: document.language, to: target) != .available { continue }
            let translated: [String]
            if let cached = await cache?.translation(videoId: videoId, language: target, engine: kind.rawValue),
               cached.count == sourceLines.count {
                translated = cached
            } else {
                let context = QTLyricsTranslationContext(title: title, artist: artist, sourceLanguage: document.language,
                                                         targetLanguage: target)
                guard let out = try? await engine.translate(sourceLines, context: context), out.count == sourceLines.count
                else { continue }
                translated = out
                await cache?.storeTranslation(out, videoId: videoId, language: target, engine: kind.rawValue)
            }
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
}

// MARK: - M6 stubs

/// Apple Intelligence (Foundation Models) lyric translation — **stub until M6**. The real engine checks
/// `SystemLanguageModel.default.availability` behind `#available(macOS 26, *)`, uses guided generation with one
/// output string per input line, chunks to the context window with title/artist/previous lines as context.
public struct QTAppleIntelligenceTranslationEngine: QTLyricsTranslationEngine {
    public let kind = QTLyricsTranslationEngineKind.appleIntelligence
    public init() {}

    public func availability(from source: String?, to target: String) async -> QTLyricsTranslationAvailability {
        if #available(macOS 26, *) { return .unavailable(reason: "notImplemented") }
        return .unavailable(reason: "requiresMacOS26")
    }

    public func translate(_ lines: [String], context: QTLyricsTranslationContext) async throws -> [String] {
        throw QTLyricsTranslationError.unavailable("notImplemented")
    }
}

/// Translation framework lyric translation — **stub until M6**. The real engine uses `TranslationSession`
/// (macOS 15+), reports `.needsDownload` from `LanguageAvailability` and never downloads without consent.
public struct QTTranslationFrameworkEngine: QTLyricsTranslationEngine {
    public let kind = QTLyricsTranslationEngineKind.translationFramework
    public init() {}

    public func availability(from source: String?, to target: String) async -> QTLyricsTranslationAvailability {
        .unavailable(reason: "notImplemented")
    }

    public func translate(_ lines: [String], context: QTLyricsTranslationContext) async throws -> [String] {
        throw QTLyricsTranslationError.unavailable("notImplemented")
    }
}
