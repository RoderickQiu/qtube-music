import Foundation
import QTCore

/// `QTCatalogService` backed by YouTube Music, so the UI moves from `QTMockCatalog` to real data without changing.
/// Library calls need a signed-in session (QTAuth); anonymous they throw `QTInnerTubeError.notSignedIn`.
public struct QTInnerTubeCatalog: QTCatalogService {
    public let client: QTInnerTubeClient
    /// How many Home continuation pages to fold into one feed (each adds ~3 shelves).
    public var homePages: Int
    /// Upper bound for following playlist continuations in `playlist(id:)` / `likedSongs()`.
    public var maxPlaylistPages: Int

    public init(client: QTInnerTubeClient, homePages: Int = 3, maxPlaylistPages: Int = 50) {
        self.client = client
        self.homePages = homePages
        self.maxPlaylistPages = maxPlaylistPages
    }

    public func homeFeed() async throws -> QTHomeFeed {
        let first = try await client.home()
        var feed = first.feed
        var token = first.continuation
        var pages = 1
        while let t = token, pages < homePages {
            guard let more = try? await client.homeContinuation(t) else { break }
            feed.shelves += more.feed.shelves
            token = more.continuation
            pages += 1
        }
        return feed
    }

    public func likedSongs() async throws -> QTPlaylist {
        var liked = try await client.playlistAllTracks("LM", maxPages: maxPlaylistPages)
        liked.id = "LM"
        liked.kind = .liked
        return liked
    }

    public func libraryPlaylists() async throws -> [QTPlaylist] {
        var page = try await client.libraryPlaylists()
        var playlists = page.items
        var pages = 1
        while let t = page.continuation, pages < 10 {
            let more = try await client.libraryContinuation(t)
            playlists += more.items.compactMap { if case .playlist(let p) = $0 { p } else { nil } }
            page = QTLibraryPage(items: [], continuation: more.continuation)
            pages += 1
        }
        // Liked Music is shown on its own; drop its tile and any duplicates.
        var seen = Set<String>()
        // "SE" is Episodes for Later (podcasts): music only.
        return playlists.filter {
            let raw = QTParse.rawPlaylistId($0.id)
            return $0.kind != .liked && raw != "LM" && raw != "SE" && seen.insert($0.id).inserted
        }
    }

    public func playlist(id: String) async throws -> QTPlaylist? {
        do {
            return try await client.playlistAllTracks(id, maxPages: maxPlaylistPages)
        } catch QTInnerTubeError.parse {
            return nil
        }
    }

    public func track(videoId: String) async throws -> QTTrack? {
        try await client.queue(videoIds: [videoId]).first
    }
}
