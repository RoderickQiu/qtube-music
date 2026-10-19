import Foundation
import QTCore

// Owner: lyrics engine (M2). See docs/architecture.md › QTLyrics.
//
// - `QTLyricsResolver` (actor, conforms to `QTLyricsProviding`): the engine the app uses. `.standard(configuration:)`
//   builds the chain YouTube Music · AMLL TTML DB · LRCLIB (safe, on) + NetEase · Kugou · QQ (opt-in).
//   `resolve(_:)` → `QTLyricsResolution` (document, other versions, pin state, attribution); `pin`/`unpin`,
//   `setOffset(_:for:)` (persisted, positive = lyrics earlier).
// - Providers (`QTLyricsSourceProvider`) talk through `QTLyricsHTTPClient` / `QTInnerTubeLyricsRequesting`.
// - Parsers: `QTLRCParser`, `QTYRCParser`, `QTQRCParser`, `QTKRCParser`, `QTTTMLParser`; codecs `QTKRCCodec`,
//   `QTQRCCodec`. Matching: `QTLyricsMatchScorer`, `QTTitleCleaner`, `QTLyricsTextFolding`, `QTLyricsAliasBook`.
// - `QTLyricsCache` (SQLite), `QTLyricsLanguageDetector`, `QTLyricsRomanizer`, translation selection
//   (`QTLyricsTranslationSelector` / `QTLyricsTranslationCoordinator`; `QTAppleIntelligenceTranslationEngine`
//   (Foundation Models) and `QTTranslationFrameworkEngine` (M6)).

/// Anything that can produce lyrics for a track. The UI only depends on this.
public protocol QTLyricsProviding: Sendable {
    /// nil = no lyrics found (UI shows "No lyrics" / switches Stage to Art layout).
    func lyrics(for track: QTTrack) async throws -> QTLyricsDocument?
}

/// M1 provider: serves the lyrics bundled in the mock catalog.
public struct QTMockLyricsProvider: QTLyricsProviding {
    public let documents: [String: QTLyricsDocument]

    public init(catalog: QTMockCatalog) {
        documents = catalog.lyrics
    }

    public init(documents: [String: QTLyricsDocument]) {
        self.documents = documents
    }

    public func lyrics(for track: QTTrack) async throws -> QTLyricsDocument? {
        documents[track.videoId]
    }
}
