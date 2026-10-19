import Foundation
import QTCore
import Translation

// Owner: lyrics-translate (M6). Apple's Translation framework (macOS 15+), labelled "On-device translation".
// Language models are downloaded only after the user agrees: this engine reports `.needsDownload` for a supported
// pair that isn't installed and never calls `prepareTranslation()` itself. On macOS 26+ an installed pair runs here
// directly (`TranslationSession(installedSource:target:)`); before that the framework hands sessions out only
// through SwiftUI's `.translationTask`, so the UI's translation center hosts the session instead.

/// Translation framework lyric translation.
public struct QTTranslationFrameworkEngine: QTLyricsTranslationEngine {
    public let kind = QTLyricsTranslationEngineKind.translationFramework
    public var timeout: Duration

    public init(timeout: Duration = .seconds(60)) {
        self.timeout = timeout
    }

    public var translatesDirectly: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    public func availability(from source: String?, to target: String) async -> QTLyricsTranslationAvailability {
        guard let source, !source.isEmpty else { return .unavailable(reason: "unknownSourceLanguage") }
        let status = await LanguageAvailability().status(from: Locale.Language(identifier: QTLanguageCode.normalize(source)),
                                                         to: Locale.Language(identifier: QTLanguageCode.normalize(target)))
        switch status {
        case .installed: return .available
        case .supported: return .needsDownload
        case .unsupported: return .unavailable(reason: "unsupportedPair")
        @unknown default: return .unavailable(reason: "unsupportedPair")
        }
    }

    public func translate(_ lines: [String], context: QTLyricsTranslationContext) async throws -> [String] {
        guard #available(macOS 26, *) else { throw QTLyricsTranslationError.unavailable("requiresHostedSession") }
        guard let source = context.sourceLanguage else { throw QTLyricsTranslationError.unavailable("unknownSourceLanguage") }
        let from = Locale.Language(identifier: QTLanguageCode.normalize(source))
        let to = Locale.Language(identifier: QTLanguageCode.normalize(context.targetLanguage))
        // Installed models only: a pair that needs a download throws instead of downloading.
        guard await LanguageAvailability().status(from: from, to: to) == .installed else {
            throw QTLyricsTranslationError.unavailable("notInstalled")
        }
        let items = QTTranslationFrameworkBatch.items(for: lines)
        let pairs = try await qtWithTranslationTimeout(timeout) {
            let session = TranslationSession(installedSource: from, target: to)
            let responses = try await session.translations(from: QTTranslationFrameworkBatch.requests(items))
            return responses.map { (id: $0.clientIdentifier, text: $0.targetText) }
        }
        return try QTTranslationFrameworkBatch.lines(from: pairs, count: lines.count, expected: items.count)
    }
}

/// Request/response bookkeeping shared by the direct engine and the SwiftUI-hosted session.
public enum QTTranslationFrameworkBatch {
    /// The lines worth translating (those with words in them), with their line index.
    public static func items(for lines: [String]) -> [(index: Int, text: String)] {
        lines.enumerated().compactMap { i, line in
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return QTLyricsTranslationInput.isTranslatable(text) ? (i, text) : nil
        }
    }

    /// One request per item, identified by its line index.
    public static func requests(_ items: [(index: Int, text: String)]) -> [TranslationSession.Request] {
        items.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.index)) }
    }

    /// Lines in source order ("" for lines that weren't sent). Throws unless every request came back.
    public static func lines(from responses: [(id: String?, text: String)], count: Int, expected: Int) throws -> [String] {
        var out = [String](repeating: "", count: count)
        var filled = 0
        for r in responses {
            guard let i = r.id.flatMap(Int.init), out.indices.contains(i) else { continue }
            out[i] = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            filled += 1
        }
        guard filled == expected else { throw QTLyricsTranslationError.lineCountMismatch(expected: expected, got: filled) }
        return out
    }
}
