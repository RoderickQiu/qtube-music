import Foundation
import QTCore

// Owner: lyrics builder (M2). See docs/architecture.md › QTLyrics.
//
// Planned contents: provider chain (YouTube Music, LRCLIB, AMLL TTML DB; opt-in NetEase/Kugou/QQ via LyricsKit),
// parsers (LRC incl. enhanced word tags, YRC, QRC, KRC, TTML), matcher + scorer (draft §6), SQLite cache keyed by
// videoId, translation engines (provider lane, Apple Intelligence on macOS 26+, Translation framework).

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
