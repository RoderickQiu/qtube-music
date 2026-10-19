import Foundation
import QTInnerTube
import QTLyrics

// Owner: builder "lyrics-live". QTLyrics doesn't depend on QTInnerTube; this adapter hands the YouTube Music lyrics
// provider the InnerTube ANDROID_MUSIC requests and maps InnerTube errors onto lyrics errors, so the resolver can
// tell "offline / rate-limited" (retry later, don't cache) from "no lyrics".

/// `QTInnerTubeLyricsRequesting` over `QTInnerTubeLyricsClient`.
public struct QTInnerTubeLyricsBridge: QTInnerTubeLyricsRequesting {
    public let client: QTInnerTubeLyricsClient

    public init(client: QTInnerTubeLyricsClient) {
        self.client = client
    }

    public func post(endpoint: String, payload: [String: String]) async throws -> Data {
        do {
            return try await client.post(endpoint, payload: payload)
        } catch let error as QTInnerTubeError {
            throw Self.lyricsError(error)
        }
    }

    static func lyricsError(_ error: QTInnerTubeError) -> QTLyricsError {
        switch error {
        case .network(let code): .transport("InnerTube network error \(code)")
        case .rateLimited(let after): .rateLimited(retryAfter: after ?? 30)
        case .http(let status), .api(let status, _): .http(status: status)
        case .invalidResponse, .parse: .decoding("InnerTube")
        case .notSignedIn, .sessionExpired, .writesDisabled: .http(status: 403)
        // Google's bot check: back off like a rate limit (lyrics retry later, nothing hammers the check).
        case .botCheck: .rateLimited(retryAfter: 300)
        @unknown default: .transport(String(describing: error))
        }
    }
}
