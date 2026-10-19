import Foundation
import QTCore

// QTInnerTube — YouTube Music's InnerTube API (music.youtube.com/youtubei/v1) for QTube Music.
//
// - `QTInnerTubeClient` (actor): requests, auth headers, client-config scrape, cache, retries, typed errors.
// - `QTInnerTubeParser`: responses → QTCore models, music only (podcasts/episodes/profiles dropped).
// - `QTInnerTubeCatalog`: `QTCatalogService` over the client, so the UI swaps the mock catalog for the real one.
// See docs/architecture.md › QTInnerTube and HANDOFF.md §6.

/// Client configuration. Values verified 2026-10-18 (HANDOFF.md §6); the live `clientVersion` is scraped from the
/// web client's `ytcfg` at runtime and these are the fallbacks.
public struct QTInnerTubeConfiguration: Sendable, Hashable {
    public var baseURL: URL
    public var clientName: String
    public var clientVersion: String
    /// `hl` — the interface language (`en`, `zh-CN`).
    public var hl: String
    /// `gl` — the account region; separate from language.
    public var gl: String
    /// Web client page scraped for `INNERTUBE_API_KEY` / `INNERTUBE_CLIENT_VERSION` / `VISITOR_DATA`.
    public var webClientURL: URL
    public var userAgent: String

    public static let origin = "https://music.youtube.com"
    /// `X-YouTube-Client-Name` for WEB_REMIX.
    public static let clientNameID = "67"
    public static let defaultUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    public init(baseURL: URL = URL(string: "https://music.youtube.com/youtubei/v1/")!,
                clientName: String = "WEB_REMIX", clientVersion: String = "1.20251001.01.00",
                hl: String = "en", gl: String = "US",
                webClientURL: URL = URL(string: "https://music.youtube.com/")!,
                userAgent: String = QTInnerTubeConfiguration.defaultUserAgent) {
        self.baseURL = baseURL
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.hl = hl
        self.gl = gl
        self.webClientURL = webClientURL
        self.userAgent = userAgent
    }

    /// `hl` for an interface language.
    public static func hl(for language: QTResolvedInterfaceLanguage) -> String {
        language == .zhHans ? "zh-CN" : "en"
    }

    /// `gl` from a locale's region (fallback until the account region is known).
    public static func gl(for locale: Locale = .current) -> String {
        locale.region?.identifier ?? "US"
    }
}

/// Keys and constants shared with other modules.
public enum QTInnerTube {
    public static let musicVideoTypeKey = "musicVideoType"
    /// Browse id of Liked Music.
    public static let likedSongsBrowseId = "VLLM"
}
