import Foundation
import QTCore
import QTInnerTube

// Owner: builder "window". Data for the browse pages (Explore and its sections, mood/genre pages, Search, Album,
// Artist) in the shapes `QTInnerTubeClient` returns (`QTSearchResults`, `QTAlbumPage`, `QTArtistPage`,
// `QTMoodsPage`, shelves). ONE set of pages (QTBrowsePages.swift, QTSearchResultsView.swift) reads them through
// `QTBrowse.service`, which is
//
//   - `QTMockBrowseService` for the demo catalog: derived from the 12 mock tracks, answers synchronously, so the
//     first frame already has the page;
//   - `QTLiveBrowseService` for the user's YouTube Music library: forwards to `QTLiveCatalogStore` (caching,
//     id resolution, page phases), so a page revisited through Back/Forward is on screen immediately.
//
// Album and artist pages are addressed by browse id (`MPREb_…`, `UC…`) whenever one is known, else by title / name
// (the mock catalog has no ids; the live store resolves a name through a search).

/// Explore's sub-pages (a segmented control at the top of Explore).
public enum QTExploreSection: String, Sendable, Hashable, CaseIterable {
    case overview, newReleases, charts, moods
}

/// Explore › Overview: shelves (new releases, charts, new music videos…), plus the server's own names for
/// Explore's sections where YouTube Music sends them.
public struct QTExploreContent: Sendable, Hashable {
    public var shelves: [QTShelf]
    public var sectionTitles: [QTExploreSection: String]

    public init(shelves: [QTShelf] = [], sectionTitles: [QTExploreSection: String] = [:]) {
        self.shelves = shelves
        self.sectionTitles = sectionTitles
    }

    public var isEmpty: Bool { shelves.isEmpty }
}

/// One browse page.
public enum QTBrowseRequest: Sendable, Hashable {
    /// Explore › Overview.
    case explore
    /// Explore › New releases / Charts: shelves.
    case exploreSection(QTExploreSection)
    /// Explore › Moods & genres: grouped chips.
    case moods
    /// A mood or genre page: shelves of playlists / songs.
    case mood(QTMoodChip)
    /// Grouped, music-only search results.
    case search(String)
    /// Album by browse id, else title.
    case album(String)
    /// Artist by channel id, else name.
    case artist(String)

    public var key: String {
        switch self {
        case .explore: "explore"
        case .exploreSection(let s): "explore:\(s.rawValue)"
        case .moods: "explore:moods"
        case .mood(let chip): "mood:\(chip.id)"
        case .search(let q): "search:\(q)"
        case .album(let k): "album:\(k)"
        case .artist(let k): "artist:\(k)"
        }
    }
}

/// What a browse request returns.
public enum QTBrowseResponse: Sendable, Hashable {
    case explore(QTExploreContent)
    case shelves([QTShelf])
    case moods(QTMoodsPage)
    case search(QTSearchResults)
    case album(QTAlbumPage)
    case artist(QTArtistPage)

    public var explore: QTExploreContent? { if case .explore(let v) = self { v } else { nil } }
    public var shelves: [QTShelf]? { if case .shelves(let v) = self { v } else { nil } }
    public var moods: QTMoodsPage? { if case .moods(let v) = self { v } else { nil } }
    public var search: QTSearchResults? { if case .search(let v) = self { v } else { nil } }
    public var album: QTAlbumPage? { if case .album(let v) = self { v } else { nil } }
    public var artist: QTArtistPage? { if case .artist(let v) = self { v } else { nil } }
}

/// A browse page that couldn't load, as the UI presents it (offline / signed out / unavailable).
public struct QTBrowseFailure: Error, Sendable, Hashable {
    public var failure: QTLiveFailure
    public init(_ failure: QTLiveFailure) { self.failure = failure }
}

/// Read-only browse data for the content column. Interface-language dependent (InnerTube `hl`), so pages reload
/// when the language changes.
@MainActor
public protocol QTBrowseService {
    /// The page if it's already in hand (the mock: always; live: once loaded) — lets a page draw its first frame
    /// with content instead of a skeleton.
    func cached(_ request: QTBrowseRequest) -> QTBrowseResponse?
    /// Loads the page (`force` = the user pressed Try Again). nil = there is no such page. Throws
    /// `QTBrowseFailure` (or a network error) when it can't load.
    func load(_ request: QTBrowseRequest, force: Bool) async throws -> QTBrowseResponse?
}

public extension QTBrowseService {
    func album(_ key: String) async throws -> QTAlbumPage? { try await load(.album(key), force: false)?.album }
    func artist(_ key: String) async throws -> QTArtistPage? { try await load(.artist(key), force: false)?.artist }
    func search(_ query: String) async throws -> QTSearchResults? { try await load(.search(query), force: false)?.search }
}

/// The process-wide browse service: the user's YouTube Music library when it's live, else the demo catalog.
@MainActor
public enum QTBrowse {
    /// Tests / previews can pin a service.
    public static var override: (any QTBrowseService)?

    public static var service: any QTBrowseService {
        if let override { return override }
        if QTLiveCatalogStore.shared.isLive { return QTLiveBrowseService.shared }
        return QTMockBrowseService(catalog: QTAppModel.shared.catalog)
    }

    /// Changes whenever `service` would answer differently (demo ⇄ live library), for page identity.
    public static var sourceKey: String { override == nil ? QTLiveCatalogStore.shared.mode.rawValue : "override" }
}

// MARK: - Mock

/// Browse pages derived from the mock catalog: albums and artists come from the tracks, charts and videos
/// re-order the library, moods and genres are a fixed localized set.
public struct QTMockBrowseService: QTBrowseService {
    public let catalog: QTMockCatalog

    public init(catalog: QTMockCatalog) { self.catalog = catalog }

    public func cached(_ request: QTBrowseRequest) -> QTBrowseResponse? {
        switch request {
        case .explore: .explore(exploreNow())
        case .exploreSection(let s): .shelves(exploreSectionNow(s))
        case .moods: .moods(moodsNow())
        case .mood(let chip): .shelves(moodNow(chip))
        case .search(let q): .search(searchNow(q))
        case .album(let k): albumNow(k).map { .album($0) }
        case .artist(let k): artistNow(k).map { .artist($0) }
        }
    }

    public func load(_ request: QTBrowseRequest, force: Bool) async throws -> QTBrowseResponse? { cached(request) }

    // MARK: Explore

    private var newReleasesShelf: QTShelf {
        QTShelf(id: "explore.new", title: .verbatim(QTLoc.tr("New releases", table: .main)), style: .cards,
                items: Self.albums(catalog.tracks).reversed().map { .album($0) })
    }

    /// Top songs, in a stable pseudo-random order (so mock charts don't reshuffle between launches).
    private var chartsShelf: QTShelf {
        let ranked = catalog.tracks.filter(\.availability.isPlayable).sorted { Self.rank($0.videoId) < Self.rank($1.videoId) }
        return QTShelf(id: "explore.charts", title: .verbatim(QTLoc.tr("Charts", table: .main)), style: .quickPicks,
                       items: ranked.prefix(9).map { .track($0) })
    }

    private var videosShelf: QTShelf {
        QTShelf(id: "explore.videos", title: .verbatim(QTLoc.tr("New music videos", table: .main)), style: .videos,
                items: catalog.tracks.filter(\.hasVideo).map { .video($0) })
    }

    public func exploreNow() -> QTExploreContent {
        QTExploreContent(shelves: [newReleasesShelf, chartsShelf, videosShelf].filter { !$0.items.isEmpty })
    }

    public func exploreSectionNow(_ section: QTExploreSection) -> [QTShelf] {
        switch section {
        case .overview: exploreNow().shelves
        case .newReleases: [newReleasesShelf, videosShelf].filter { !$0.items.isEmpty }
        case .charts: [chartsShelf].filter { !$0.items.isEmpty }
        case .moods: []
        }
    }

    public func moodsNow() -> QTMoodsPage {
        QTMoodsPage(groups: [
            QTMoodsPage.Group(title: QTLoc.tr("Moods & moments", table: .main), moods: catalog.home.moods),
            QTMoodsPage.Group(title: QTLoc.tr("Genres", table: .main), moods: Self.genres.map {
                QTMoodChip(id: "genre:\($0)", title: .verbatim(QTLoc.tr($0, table: .main)))
            }),
        ].filter { !$0.moods.isEmpty })
    }

    static let genres = ["Pop", "V-Pop", "Mandopop", "Hip-hop", "R&B & soul", "Indie & alternative", "Rock",
                         "Electronic", "Folk & acoustic", "Classical", "Jazz", "Soundtracks"]

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
        ].filter { !$0.items.isEmpty }
    }

    // MARK: Search

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

    /// Album by id or title (mock albums use their title as id).
    public func albumNow(_ key: String) -> QTAlbumPage? {
        // Uploads by id only (an upload album may share its title with a library one).
        let tracks = QTUploads.isAlbumID(key) ? catalog.uploads.songs.filter { $0.album?.id == key }
            : catalog.tracks.filter { $0.album?.id == key || $0.album?.title == key }
        guard let first = tracks.first, let ref = first.album else { return nil }
        let album = QTAlbum(id: ref.id ?? ref.title, title: ref.title, artists: first.artists,
                            kind: tracks.count > 3 ? .album : .single, artwork: first.artwork, tracks: tracks)
        return QTAlbumPage(album: album)
    }

    /// Artist by id or name. `shelves` holds the page's rows in display order, like the live parser.
    public func artistNow(_ key: String) -> QTArtistPage? {
        if QTUploads.isArtistID(key) {
            let songs = catalog.uploads.songs.filter { $0.artists.contains { $0.id == key } }
            guard let ref = songs.first?.artists.first(where: { $0.id == key }) else { return nil }
            return QTArtistPage(artist: QTArtist(id: key, name: ref.name), songs: songs)
        }
        let tracks = catalog.tracks.filter { $0.artists.contains { $0.id == key || $0.name == key } }
        guard let first = tracks.first, let ref = first.artists.first(where: { $0.id == key || $0.name == key }) else { return nil }
        let artist = QTArtist(id: ref.id ?? ref.name, name: ref.name, artwork: first.artwork)
        let albums = Self.albums(tracks)
        var page = QTArtistPage(artist: artist, songs: tracks, albums: albums.filter { $0.kind == .album },
                                singles: albums.filter { $0.kind != .album }, videos: tracks.filter(\.hasVideo),
                                relatedArtists: Self.related(to: ref.name, in: catalog.tracks))
        func shelf(_ id: String, _ title: String, _ style: QTShelfStyle, _ items: [QTShelfItem]) {
            guard !items.isEmpty else { return }
            page.shelves.append(QTShelf(id: "artist.\(id)", title: .verbatim(title), style: style, items: items))
        }
        shelf("albums", QTLoc.tr("Albums"), .cards, page.albums.map { .album($0) })
        shelf("singles", QTLoc.tr("Singles", table: .main), .cards, page.singles.map { .album($0) })
        shelf("videos", QTLoc.tr("Videos", table: .main), .videos, page.videos.map { .video($0) })
        shelf("related", QTLoc.tr("Fans also like", table: .main), .cards, page.relatedArtists.map { .artist($0) })
        return page
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
            return QTAlbum(id: ts.first?.album?.id ?? title, title: title, artists: ts.first?.artists ?? [], kind: kind,
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

    /// Stable pseudo-random order (FNV-1a).
    static func rank(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}
