import Foundation
import QTCore

// Page-level results of the InnerTube client. Items are QTCore models; these wrappers add what a page needs
// beyond them (continuations, playlist ids for "Play all", Song⇄Video data, lyric browse ids).

/// An opaque continuation token for the next page of a list.
public struct QTContinuation: Sendable, Hashable, Codable {
    public var token: String
    public init(_ token: String) { self.token = token }
}

/// Home (also any filtered home via a mood chip).
public struct QTHomePage: Sendable, Hashable {
    public var feed: QTHomeFeed
    public var continuation: QTContinuation?

    public init(feed: QTHomeFeed, continuation: QTContinuation? = nil) {
        self.feed = feed
        self.continuation = continuation
    }
}

/// Explore: new releases, charts, moods & genres, new music videos (podcast shelves removed).
public struct QTExplorePage: Sendable, Hashable {
    /// Top navigation buttons (New releases, Charts, Moods & genres…) as browse targets.
    public var destinations: [QTMoodChip]
    public var moods: [QTMoodChip]
    public var shelves: [QTShelf]

    public init(destinations: [QTMoodChip] = [], moods: [QTMoodChip] = [], shelves: [QTShelf] = []) {
        self.destinations = destinations
        self.moods = moods
        self.shelves = shelves
    }
}

/// Moods & genres: grouped buttons ("Moods & moments", "Genres").
public struct QTMoodsPage: Sendable, Hashable {
    public struct Group: Sendable, Hashable, Identifiable {
        public var id: String { title }
        public var title: String
        public var moods: [QTMoodChip]
        public init(title: String, moods: [QTMoodChip]) {
            self.title = title
            self.moods = moods
        }
    }

    public var groups: [Group]
    public init(groups: [Group]) { self.groups = groups }
}

/// Sort order of a library list (the uploads lists take it). `params` are YouTube Music's own (its sort menu's
/// `browseEndpoint.params`, as ytmusicapi `prepare_order_params` reads them).
public enum QTLibraryOrder: String, Sendable, Hashable, CaseIterable {
    case aToZ, zToA, recentlyAdded

    public var params: String {
        switch self {
        case .aToZ: "ggMGKgQIARAA"
        case .zToA: "ggMGKgQIARAB"
        case .recentlyAdded: "ggMGKgQIABAB"
        }
    }
}

/// Search filters. `params` values are the ones YouTube Music's own chips send.
public enum QTSearchFilter: String, Sendable, Hashable, CaseIterable {
    case all, songs, videos, albums, artists, playlists, featuredPlaylists

    public var params: String? {
        switch self {
        case .all: nil
        case .songs: "EgWKAQIIAWoMEA4QChADEAQQCRAF"
        // HANDOFF §6: verified videos-only param.
        case .videos: "EgWKAQIQAWoKEAkQChAFEAMQBA%3D%3D"
        case .albums: "EgWKAQIYAWoMEA4QChADEAQQCRAF"
        case .artists: "EgWKAQIgAWoMEA4QChADEAQQCRAF"
        case .playlists: "EgeKAQQoAEABagwQDhAKEAMQBBAJEAU="
        case .featuredPlaylists: "EgeKAQQoADgBagwQDhAKEAMQBBAJEAU="
        }
    }
}

/// Search results, music only (episodes, podcasts and profiles removed).
public struct QTSearchResults: Sendable, Hashable {
    /// The highlighted top result ("musicCardShelfRenderer"), when YouTube Music shows one.
    public var topResult: QTShelfItem?
    /// Every result in server order (excluding the top result).
    public var items: [QTShelfItem]
    public var continuation: QTContinuation?

    public init(topResult: QTShelfItem? = nil, items: [QTShelfItem] = [], continuation: QTContinuation? = nil) {
        self.topResult = topResult
        self.items = items
        self.continuation = continuation
    }

    public var songs: [QTTrack] { items.compactMap { if case .track(let t) = $0 { t } else { nil } } }
    public var videos: [QTTrack] { items.compactMap { if case .video(let t) = $0 { t } else { nil } } }
    public var albums: [QTAlbum] { items.compactMap { if case .album(let a) = $0 { a } else { nil } } }
    public var artists: [QTArtist] { items.compactMap { if case .artist(let a) = $0 { a } else { nil } } }
    public var playlists: [QTPlaylist] { items.compactMap { if case .playlist(let p) = $0 { p } else { nil } } }
}

/// An album page.
public struct QTAlbumPage: Sendable, Hashable {
    /// `tracks` is filled; rows inherit the album's artists and artwork.
    public var album: QTAlbum
    /// Playlist id for "Play all" / shuffle (`OLAK5uy_…`).
    public var playlistId: String?
    /// Localized "10 songs • 42 minutes" line as YouTube Music sends it.
    public var summary: String?
    public var description: String?
    /// "More from …" / "Other versions" shelves.
    public var shelves: [QTShelf]
    /// The album is saved in the signed-in library (its header's save toggle); nil when the page doesn't say
    /// (signed out).
    public var isSaved: Bool?

    public init(album: QTAlbum, playlistId: String? = nil, summary: String? = nil, description: String? = nil,
                shelves: [QTShelf] = [], isSaved: Bool? = nil) {
        self.album = album
        self.playlistId = playlistId
        self.summary = summary
        self.description = description
        self.shelves = shelves
        self.isSaved = isSaved
    }
}

/// A playlist page (first page of tracks; call `playlistContinuation` for more).
public struct QTPlaylistPage: Sendable, Hashable {
    public var playlist: QTPlaylist
    /// Localized "248 tracks • 19+ hours" line.
    public var summary: String?
    public var description: String?
    /// Total number of tracks if YouTube Music states it (the first page holds at most ~100).
    public var totalTrackCount: Int?
    public var continuation: QTContinuation?
    /// Someone else's playlist saved in the signed-in library (the header's save toggle); nil when the page doesn't
    /// say (signed out, or the account's own playlist).
    public var isSaved: Bool?

    public init(playlist: QTPlaylist, summary: String? = nil, description: String? = nil, totalTrackCount: Int? = nil,
                continuation: QTContinuation? = nil, isSaved: Bool? = nil) {
        self.playlist = playlist
        self.summary = summary
        self.description = description
        self.totalTrackCount = totalTrackCount
        self.continuation = continuation
        self.isSaved = isSaved
    }
}

/// One page of tracks from a continuation.
public struct QTTrackPage: Sendable, Hashable {
    public var tracks: [QTTrack]
    public var continuation: QTContinuation?

    public init(tracks: [QTTrack], continuation: QTContinuation? = nil) {
        self.tracks = tracks
        self.continuation = continuation
    }
}

/// An artist page.
public struct QTArtistPage: Sendable, Hashable {
    public var artist: QTArtist
    /// Localized audience line ("12.6M monthly audience", "每月听众：1260万").
    public var audience: String?
    public var description: String?
    /// Top songs (usually five).
    public var songs: [QTTrack]
    /// Browse id of the full songs playlist ("See all").
    public var songsPlaylistId: String?
    public var albums: [QTAlbum]
    public var singles: [QTAlbum]
    /// The "Videos" row.
    public var videos: [QTTrack]
    /// Browse id of the full videos playlist.
    public var videosPlaylistId: String?
    public var playlists: [QTPlaylist]
    public var relatedArtists: [QTArtist]
    /// Every carousel in server order (live performances, featured on…), music only.
    public var shelves: [QTShelf]
    /// The channel Subscribe acts on (`subscribeButtonRenderer.channelId`) and whether the account subscribes; nil
    /// when the page has no subscribe button (or doesn't say, signed out).
    public var channelId: String?
    public var isSubscribed: Bool?

    public init(artist: QTArtist, audience: String? = nil, description: String? = nil, songs: [QTTrack] = [],
                songsPlaylistId: String? = nil, albums: [QTAlbum] = [], singles: [QTAlbum] = [],
                videos: [QTTrack] = [], videosPlaylistId: String? = nil, playlists: [QTPlaylist] = [],
                relatedArtists: [QTArtist] = [], shelves: [QTShelf] = []) {
        self.artist = artist
        self.audience = audience
        self.description = description
        self.songs = songs
        self.songsPlaylistId = songsPlaylistId
        self.albums = albums
        self.singles = singles
        self.videos = videos
        self.videosPlaylistId = videosPlaylistId
        self.playlists = playlists
        self.relatedArtists = relatedArtists
        self.shelves = shelves
    }
}

/// The `next` response: the queue YouTube Music proposes plus per-track metadata.
public struct QTWatchNext: Sendable, Hashable {
    /// The Up Next list in order; for a radio/autoplay seed this is the autoplay queue (first = the seed).
    public var tracks: [QTTrack]
    /// Index of the selected (now playing) row in `tracks`.
    public var selectedIndex: Int?
    /// Playlist the queue plays from (`RDAMVM…` radio, album `OLAK…`).
    public var playlistId: String?
    /// Automix/radio continuation: play this playlist (with `params`) to keep going after `tracks`.
    public var automix: QTBrowseTarget?
    public var continuation: QTContinuation?
    /// `MPLY…` browse id of the Lyrics tab (absent for official music videos — map to the Song counterpart first).
    public var lyricsBrowseId: String?
    /// `MPTR…` browse id of the Related tab.
    public var relatedBrowseId: String?

    public init(tracks: [QTTrack] = [], selectedIndex: Int? = nil, playlistId: String? = nil,
                automix: QTBrowseTarget? = nil, continuation: QTContinuation? = nil, lyricsBrowseId: String? = nil,
                relatedBrowseId: String? = nil) {
        self.tracks = tracks
        self.selectedIndex = selectedIndex
        self.playlistId = playlistId
        self.automix = automix
        self.continuation = continuation
        self.lyricsBrowseId = lyricsBrowseId
        self.relatedBrowseId = relatedBrowseId
    }

    /// The selected (now playing) track.
    public var current: QTTrack? { selectedIndex.flatMap { tracks.indices.contains($0) ? tracks[$0] : nil } }
}

/// Playability and metadata from `player` (stream resolution is the playback engine's job).
public struct QTPlayerInfo: Sendable, Hashable {
    public enum Status: String, Sendable, Hashable {
        case ok = "OK"
        case unplayable = "UNPLAYABLE"
        case loginRequired = "LOGIN_REQUIRED"
        case ageRestricted = "AGE_CHECK_REQUIRED"
        case contentCheckRequired = "CONTENT_CHECK_REQUIRED"
        case error = "ERROR"
        case liveStreamOffline = "LIVE_STREAM_OFFLINE"
        case unknown
    }

    public var videoId: String
    public var title: String
    public var author: String
    public var channelId: String?
    public var duration: TimeInterval
    public var musicVideoType: QTMusicVideoType
    public var artwork: [QTArtworkImage]
    public var status: Status
    /// Server-provided reason (localized by `hl`).
    public var reason: String?

    public init(videoId: String, title: String, author: String, channelId: String? = nil, duration: TimeInterval,
                musicVideoType: QTMusicVideoType, artwork: [QTArtworkImage] = [], status: Status,
                reason: String? = nil) {
        self.videoId = videoId
        self.title = title
        self.author = author
        self.channelId = channelId
        self.duration = duration
        self.musicVideoType = musicVideoType
        self.artwork = artwork
        self.status = status
        self.reason = reason
    }

    /// A minimal track for the queue.
    public var track: QTTrack {
        QTTrack(videoId: videoId, title: title, artists: [QTArtistRef(id: channelId, name: author)],
                duration: duration, artwork: artwork, musicVideoType: musicVideoType,
                availability: status == .ok ? .playable : status == .loginRequired ? .premiumOnly : .removed)
    }
}

/// Plain lyrics from the WEB_REMIX Lyrics tab (`MPLY…`). Timed lyrics are the lyrics module's job.
public struct QTPlainLyrics: Sendable, Hashable {
    public var text: String
    /// "Source: LyricFind" line.
    public var source: String?

    public init(text: String, source: String? = nil) {
        self.text = text
        self.source = source
    }
}

/// A page of library items (playlists, albums, artists, songs) with paging.
public struct QTLibraryPage<Item: Sendable & Hashable>: Sendable, Hashable {
    public var items: [Item]
    public var continuation: QTContinuation?

    public init(items: [Item], continuation: QTContinuation? = nil) {
        self.items = items
        self.continuation = continuation
    }
}

/// Signed-in account summary (`account/account_menu`).
public struct QTAccountInfo: Sendable, Hashable, Codable {
    public var name: String
    public var handle: String?
    public var photo: [QTArtworkImage]
    /// Best effort: YouTube Music doesn't flag Premium explicitly in the account menu.
    public var isPremium: Bool?

    public init(name: String, handle: String? = nil, photo: [QTArtworkImage] = [], isPremium: Bool? = nil) {
        self.name = name
        self.handle = handle
        self.photo = photo
        self.isPremium = isPremium
    }
}

/// Account facts from the signed-in web client's `ytcfg` (see `QTInnerTubeClient.accountContext()`).
public struct QTAccountContext: Sendable, Hashable {
    /// `IS_SUBSCRIBER`: true for YouTube Music Premium / YouTube Premium members (verified on a Premium account
    /// 2026-10-18; the anonymous page has no such key).
    public var isSubscriber: Bool?
    /// `INNERTUBE_CONTEXT_GL`: the region YouTube uses for this account (its location setting, else a guess).
    public var gl: String?
    /// `INNERTUBE_CONTEXT_HL`: the account's own language preference (the app's `hl` follows the interface language).
    public var hl: String?
    /// `LOGGED_IN`.
    public var isLoggedIn: Bool?

    public init(isSubscriber: Bool? = nil, gl: String? = nil, hl: String? = nil, isLoggedIn: Bool? = nil) {
        self.isSubscriber = isSubscriber
        self.gl = gl
        self.hl = hl
        self.isLoggedIn = isLoggedIn
    }

    /// Reads the first `"KEY": value` of each key from the page HTML.
    public static func scrape(html: String) -> QTAccountContext {
        func raw(_ key: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: "\"\(key)\"\\s*:\\s*(\"[^\"]*\"|true|false)"),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[range])
        }
        func bool(_ key: String) -> Bool? {
            switch raw(key) {
            case "true": true
            case "false": false
            default: nil
            }
        }
        func string(_ key: String) -> String? {
            guard let v = raw(key), v.hasPrefix("\""), v.count > 2 else { return nil }
            return String(v.dropFirst().dropLast())
        }
        return QTAccountContext(isSubscriber: bool("IS_SUBSCRIBER"), gl: string("INNERTUBE_CONTEXT_GL") ?? string("GL"),
                                hl: string("INNERTUBE_CONTEXT_HL") ?? string("HL"), isLoggedIn: bool("LOGGED_IN"))
    }
}
