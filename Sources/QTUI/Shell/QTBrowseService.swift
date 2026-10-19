import Foundation
import QTCore
import QTInnerTube

// Owner: builder "window". Data for the browse pages (Explore, mood/genre pages, Search, Album, Artist) in the
// shapes `QTInnerTubeClient` already returns (`QTSearchResults`, `QTAlbumPage`, `QTArtistPage`, `QTMoodsPage`,
// shelves). The UI reads them through `QTBrowseService`; M1 runs on `QTMockBrowseService` (derived from the
// mock catalog). The data layer swaps in an InnerTube-backed service without touching the views:
//
//   explore()      → client.newReleases() / charts() / moodsAndGenres() (+ explore() for the video shelf)
//   mood(_:)       → client.moodPlaylists(chip)
//   search(_:)     → client.search(query)            (music only — episodes/podcasts are already filtered)
//   album(_:)      → client.album(browseId)
//   artist(_:)     → client.artist(channelId)

/// Explore (draft §3): New releases, Charts, Moods & genres.
public struct QTExploreContent: Sendable, Hashable {
    /// New albums & singles (`.album` items).
    public var newReleases: [QTShelfItem]
    /// Top songs chart, ranked.
    public var topSongs: [QTTrack]
    /// Trending / new music videos.
    public var videos: [QTTrack]
    /// "Moods & moments", "Genres".
    public var moodGroups: [QTMoodsPage.Group]

    public init(newReleases: [QTShelfItem] = [], topSongs: [QTTrack] = [], videos: [QTTrack] = [],
                moodGroups: [QTMoodsPage.Group] = []) {
        self.newReleases = newReleases
        self.topSongs = topSongs
        self.videos = videos
        self.moodGroups = moodGroups
    }

    public var isEmpty: Bool { newReleases.isEmpty && topSongs.isEmpty && videos.isEmpty && moodGroups.isEmpty }
}

/// Read-only browse data for the content column. Interface-language dependent (InnerTube `hl`), so pages reload
/// when the language changes.
public protocol QTBrowseService: Sendable {
    func explore() async throws -> QTExploreContent
    /// A mood or genre page: shelves of playlists / songs.
    func mood(_ chip: QTMoodChip) async throws -> [QTShelf]
    func search(_ query: String) async throws -> QTSearchResults
    /// Album by browse id (the mock uses the album title).
    func album(_ id: String) async throws -> QTAlbumPage?
    /// Artist by channel id (the mock uses the artist name).
    func artist(_ id: String) async throws -> QTArtistPage?
}

/// The process-wide browse service (mock until the data layer replaces it).
@MainActor
public enum QTBrowse {
    public static var service: any QTBrowseService = QTMockBrowseService(catalog: QTAppModel.shared.catalog)
}

// MARK: - Mock

/// Browse pages derived from the 12-track mock catalog: albums and artists come from the tracks, charts and
/// videos re-order the library, moods and genres are a fixed localized set tinted with artwork colours.
public struct QTMockBrowseService: QTBrowseService {
    public let catalog: QTMockCatalog

    public init(catalog: QTMockCatalog) { self.catalog = catalog }

    // MARK: Explore

    public func explore() async throws -> QTExploreContent { exploreNow() }

    public func exploreNow() -> QTExploreContent {
        let albums = Self.albums(catalog.tracks)
        // "New" = reverse library order; charts = longest-liked first is meaningless, so rank by a stable hash.
        let ranked = catalog.tracks.filter(\.availability.isPlayable)
            .sorted { Self.rank($0.videoId) < Self.rank($1.videoId) }
        return QTExploreContent(
            newReleases: albums.reversed().map { .album($0) },
            topSongs: Array(ranked.prefix(9)),
            videos: catalog.tracks.filter(\.hasVideo),
            moodGroups: [
                QTMoodsPage.Group(title: QTLoc.tr("Moods & moments", table: .main), moods: catalog.home.moods),
                QTMoodsPage.Group(title: QTLoc.tr("Genres", table: .main), moods: Self.genres.map {
                    QTMoodChip(id: "genre:\($0)", title: .verbatim(QTLoc.tr($0, table: .main)))
                }),
            ])
    }

    static let genres = ["Pop", "V-Pop", "Mandopop", "Hip-hop", "R&B & soul", "Indie & alternative", "Rock",
                         "Electronic", "Folk & acoustic", "Classical", "Jazz", "Soundtracks"]

    public func mood(_ chip: QTMoodChip) async throws -> [QTShelf] { moodNow(chip) }

    public func moodNow(_ chip: QTMoodChip) -> [QTShelf] {
        let seed = Self.rank(chip.id)
        let lists = catalog.playlists.sorted { Self.rank($0.id + "\(seed)") < Self.rank($1.id + "\(seed)") }
        let songs = catalog.tracks.filter(\.availability.isPlayable)
            .sorted { Self.rank($0.videoId + "\(seed)") < Self.rank($1.videoId + "\(seed)") }
        return [
            QTShelf(id: "\(chip.id).playlists", title: .verbatim(QTLoc.tr("Playlists")), style: .cards,
                    items: lists.prefix(6).map { .playlist($0) }),
            QTShelf(id: "\(chip.id).songs", title: .verbatim(QTLoc.tr("Songs")), style: .quickPicks,
                    items: songs.prefix(6).map { .track($0) }),
        ]
    }

    // MARK: Search

    public func search(_ query: String) async throws -> QTSearchResults { searchNow(query) }

    /// Music-only grouped results. Matching folds diacritics and Traditional/Simplified Chinese.
    public func searchNow(_ query: String) -> QTSearchResults {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return QTSearchResults() }
        let songs = catalog.tracks.filter { QTTextFolding.matches(query: q, in: $0.qtSearchText) }
        let videos = songs.filter(\.hasVideo)
        let albums = Self.albums(catalog.tracks).filter {
            QTTextFolding.matches(query: q, in: "\($0.title) \($0.artists.map(\.name).joined(separator: " "))")
        }
        let artists = Self.artists(catalog.tracks).filter { QTTextFolding.matches(query: q, in: $0.name) }
        let playlists = ([catalog.liked] + catalog.playlists).filter { QTTextFolding.matches(query: q, in: $0.title.resolved) }
        // Top result: an artist whose name is the query, else the best song.
        let folded = QTTextFolding.sortKey(q)
        let top: QTShelfItem? = artists.first { QTTextFolding.sortKey($0.name) == folded }.map { .artist($0) }
            ?? songs.first.map { .track($0) }
            ?? albums.first.map { .album($0) }
            ?? artists.first.map { .artist($0) }
        var items: [QTShelfItem] = songs.map { .track($0) } + videos.map { .video($0) } + albums.map { .album($0) }
            + artists.map { .artist($0) } + playlists.map { .playlist($0) }
        if let top { items.removeAll { $0 == top } }
        return QTSearchResults(topResult: top, items: items)
    }

    // MARK: Album / Artist

    public func album(_ id: String) async throws -> QTAlbumPage? { albumNow(id) }

    public func albumNow(_ title: String) -> QTAlbumPage? {
        let tracks = catalog.tracks.filter { $0.album?.title == title }
        guard let first = tracks.first else { return nil }
        let album = QTAlbum(id: title, title: title, artists: first.artists, kind: tracks.count > 3 ? .album : .single,
                            artwork: first.artwork, tracks: tracks)
        return QTAlbumPage(album: album)
    }

    public func artist(_ id: String) async throws -> QTArtistPage? { artistNow(id) }

    public func artistNow(_ name: String) -> QTArtistPage? {
        let tracks = catalog.tracks.filter { $0.artists.contains { $0.name == name } }
        guard let first = tracks.first else { return nil }
        let ref = first.artists.first { $0.name == name }
        let artist = QTArtist(id: ref?.id ?? name, name: name, artwork: first.artwork)
        let albums = Self.albums(tracks)
        return QTArtistPage(artist: artist, songs: tracks, albums: albums.filter { $0.kind == .album },
                            singles: albums.filter { $0.kind != .album }, videos: tracks.filter(\.hasVideo),
                            relatedArtists: Self.related(to: name, in: catalog.tracks))
    }

    // MARK: Derivation

    /// Albums in library order, with the album's tracks.
    static func albums(_ tracks: [QTTrack]) -> [QTAlbum] {
        var order: [String] = []
        var byTitle: [String: [QTTrack]] = [:]
        for t in tracks {
            guard let a = t.album?.title else { continue }
            if byTitle[a] == nil { order.append(a) }
            byTitle[a, default: []].append(t)
        }
        return order.map { title in
            let ts = byTitle[title] ?? []
            // Every mock "album" holds one or two songs, so call them singles unless the title differs from the song.
            let kind: QTAlbumKind = ts.count == 1 && ts[0].title == title ? .single : .album
            return QTAlbum(id: title, title: title, artists: ts.first?.artists ?? [], kind: kind,
                           artwork: ts.first?.artwork ?? [], tracks: ts)
        }
    }

    static func artists(_ tracks: [QTTrack]) -> [QTArtist] {
        var seen = Set<String>()
        return tracks.flatMap { t in t.artists.map { (ref: $0, art: t.artwork) } }
            .filter { seen.insert($0.ref.name).inserted }
            .map { QTArtist(id: $0.ref.id ?? $0.ref.name, name: $0.ref.name, artwork: $0.art) }
    }

    static func related(to name: String, in tracks: [QTTrack]) -> [QTArtist] {
        artists(tracks).filter { $0.name != name }
            .sorted { rank($0.name + name) < rank($1.name + name) }
            .prefix(6).map { $0 }
    }

    /// Stable pseudo-random order (FNV-1a), so mock charts don't reshuffle between launches.
    static func rank(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}
