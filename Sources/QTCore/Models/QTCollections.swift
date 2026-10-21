import Foundation

/// Text that is either already localized by the source (YouTube Music sends `hl`-localized titles)
/// or a key the app localizes itself (mock catalog shelves, built-in collections).
public enum QTDisplayText: Codable, Sendable, Hashable {
    case verbatim(String)
    /// A key in the shared `Localizable` table.
    case localized(String)

    public var resolved: String {
        switch self {
        case .verbatim(let s): s
        case .localized(let key): QTLoc.tr(key)
        }
    }

    private enum CodingKeys: String, CodingKey { case verbatim, key }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer().decode(String.self) {
            self = .verbatim(single)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let key = try c.decodeIfPresent(String.self, forKey: .key) {
            self = .localized(key)
        } else {
            self = .verbatim(try c.decode(String.self, forKey: .verbatim))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .verbatim(let s): try c.encode(s, forKey: .verbatim)
        case .localized(let k): try c.encode(k, forKey: .key)
        }
    }
}

public struct QTArtist: Codable, Sendable, Hashable, Identifiable {
    /// Channel / browse id.
    public var id: String
    public var name: String
    public var artwork: [QTArtworkImage]

    public init(id: String, name: String, artwork: [QTArtworkImage] = []) {
        self.id = id
        self.name = name
        self.artwork = artwork
    }
}

public enum QTAlbumKind: String, Codable, Sendable, Hashable {
    case album, single, ep
}

public struct QTAlbum: Codable, Sendable, Hashable, Identifiable {
    /// Browse id (`MPREb_…`).
    public var id: String
    public var title: String
    public var artists: [QTArtistRef]
    public var year: Int?
    public var kind: QTAlbumKind
    public var artwork: [QTArtworkImage]
    /// nil until the album page is loaded.
    public var tracks: [QTTrack]?

    public init(id: String, title: String, artists: [QTArtistRef], year: Int? = nil, kind: QTAlbumKind = .album,
                artwork: [QTArtworkImage] = [], tracks: [QTTrack]? = nil) {
        self.id = id
        self.title = title
        self.artists = artists
        self.year = year
        self.kind = kind
        self.artwork = artwork
        self.tracks = tracks
    }
}

public enum QTPlaylistKind: String, Codable, Sendable, Hashable {
    /// The user's Liked Songs (`LM`).
    case liked
    /// A playlist the user owns or saved.
    case user
    /// Auto-generated mixes and radios.
    case mix
}

/// Who can see a playlist (YouTube's `privacyStatus`).
public enum QTPlaylistPrivacy: String, Codable, Sendable, Hashable, CaseIterable {
    case `private` = "PRIVATE"
    case unlisted = "UNLISTED"
    case `public` = "PUBLIC"
}

public struct QTPlaylist: Codable, Sendable, Hashable, Identifiable {
    /// Playlist id (`VL…` / `LM` / mock ids like `pl-sugar`).
    public var id: String
    public var title: QTDisplayText
    public var kind: QTPlaylistKind
    public var owner: String?
    public var artwork: [QTArtworkImage]
    /// nil until the playlist page is loaded.
    public var tracks: [QTTrack]?
    /// The account owns the playlist and may edit it (its page has the editable header). nil = not known yet.
    public var isEditable: Bool?
    public var privacy: QTPlaylistPrivacy?
    public var description: String?

    public init(id: String, title: QTDisplayText, kind: QTPlaylistKind = .user, owner: String? = nil,
                artwork: [QTArtworkImage] = [], tracks: [QTTrack]? = nil, isEditable: Bool? = nil,
                privacy: QTPlaylistPrivacy? = nil, description: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.owner = owner
        self.artwork = artwork
        self.tracks = tracks
        self.isEditable = isEditable
        self.privacy = privacy
        self.description = description
    }

    public var trackCount: Int { tracks?.count ?? 0 }

    /// Sum of track durations in seconds.
    public var totalDuration: TimeInterval { tracks?.reduce(0) { $0 + $1.duration } ?? 0 }
}

/// How a Home shelf lays out its items (mirrors the prototype's shelves).
public enum QTShelfStyle: String, Codable, Sendable, Hashable {
    /// Horizontal row of square cards ("Listen again", "Your playlists").
    case cards
    /// Three-column list of compact rows ("Quick picks").
    case quickPicks
    /// Horizontal row of 16:9 video cards ("Music videos").
    case videos
}

public enum QTShelfItem: Codable, Sendable, Hashable, Identifiable {
    case track(QTTrack)
    /// A track presented by its video (plays in video mode).
    case video(QTTrack)
    case album(QTAlbum)
    case playlist(QTPlaylist)
    case artist(QTArtist)

    public var id: String {
        switch self {
        case .track(let t): "track:\(t.id)"
        case .video(let t): "video:\(t.id)"
        case .album(let a): "album:\(a.id)"
        case .playlist(let p): "playlist:\(p.id)"
        case .artist(let a): "artist:\(a.id)"
        }
    }
}

public struct QTShelf: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: QTDisplayText
    public var style: QTShelfStyle
    public var items: [QTShelfItem]

    public init(id: String, title: QTDisplayText, style: QTShelfStyle, items: [QTShelfItem]) {
        self.id = id
        self.title = title
        self.style = style
        self.items = items
    }
}

public struct QTMoodChip: Codable, Sendable, Hashable, Identifiable {
    /// Browse params for the mood page (empty in the mock catalog).
    public var id: String
    public var title: QTDisplayText

    public init(id: String, title: QTDisplayText) {
        self.id = id
        self.title = title
    }
}

/// The Home page: mood chips + shelves. Built only from the user's library and YouTube Music's real shelves.
public struct QTHomeFeed: Codable, Sendable, Hashable {
    public var moods: [QTMoodChip]
    public var shelves: [QTShelf]

    public init(moods: [QTMoodChip] = [], shelves: [QTShelf] = []) {
        self.moods = moods
        self.shelves = shelves
    }
}
