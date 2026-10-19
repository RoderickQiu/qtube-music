import Foundation
import QTCore

// Owner: data-layer builder (M3). See docs/architecture.md › QTInnerTube.
//
// Planned contents: `QTInnerTubeClient` for music.youtube.com/youtubei/v1 (WEB_REMIX context, hl = interface
// language, gl = account region), SAPISIDHASH auth headers, API-key scrape, TTL cache, parsers for home,
// explore, library, playlists, search, artist; the music-only filter (drop podcasts/episodes); Song⇄Video
// counterpart from `next`. It conforms to `QTCatalogService` (QTCore) so the UI never changes.

/// Client configuration. Values verified 2026-10-18 (HANDOFF.md §6).
public struct QTInnerTubeConfiguration: Sendable, Hashable {
    public var baseURL: URL
    public var clientName: String
    public var clientVersion: String
    /// `hl` — the interface language (`en`, `zh-CN`).
    public var hl: String
    /// `gl` — the account region; separate from language.
    public var gl: String

    public init(baseURL: URL = URL(string: "https://music.youtube.com/youtubei/v1/")!,
                clientName: String = "WEB_REMIX", clientVersion: String = "1.20251001.01.00",
                hl: String = "en", gl: String = "US") {
        self.baseURL = baseURL
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.hl = hl
        self.gl = gl
    }

    /// `hl` for an interface language.
    public static func hl(for language: QTResolvedInterfaceLanguage) -> String {
        language == .zhHans ? "zh-CN" : "en"
    }
}

/// Placeholder so the module has a public surface; replaced by the real client in M3.
public enum QTInnerTube {
    public static let musicVideoTypeKey = "musicVideoType"
}
