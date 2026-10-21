import Foundation

/// How YouTube Music classifies a video. Drives Song⇄Video (an ATV has an OMV counterpart and vice versa).
public enum QTMusicVideoType: String, Codable, Sendable, CaseIterable {
    /// Audio track ("Art Track"), the song version with static artwork.
    case atv = "MUSIC_VIDEO_TYPE_ATV"
    /// Official music video.
    case omv = "MUSIC_VIDEO_TYPE_OMV"
    /// User-generated content (lyric videos, live uploads…).
    case ugc = "MUSIC_VIDEO_TYPE_UGC"
    /// Podcast episodes and anything else; filtered out of the app (music only).
    case other = "MUSIC_VIDEO_TYPE_OTHER"

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = QTMusicVideoType(rawValue: raw) ?? .other
    }

    /// True for the version that is a video (shown in the Video slot of Song⇄Video).
    public var isVideo: Bool { self == .omv || self == .ugc }
}

/// Whether a track can be played, and why not.
public enum QTAvailability: String, Codable, Sendable, Hashable {
    case playable
    case regionLocked
    case removed
    case premiumOnly

    public var isPlayable: Bool { self == .playable }
}

/// Whether the account likes a song (YouTube Music's `likeStatus`, from row menus and `next`).
public enum QTLikeStatus: String, Codable, Sendable, Hashable {
    case like = "LIKE"
    case indifferent = "INDIFFERENT"
    case dislike = "DISLIKE"
}

/// A lightweight reference to an artist as it appears on a track or album.
public struct QTArtistRef: Codable, Sendable, Hashable {
    /// Channel / browse id (`UC…`), nil when YouTube Music doesn't link the name.
    public var id: String?
    public var name: String

    public init(id: String? = nil, name: String) {
        self.id = id
        self.name = name
    }
}

/// A lightweight reference to an album as it appears on a track.
public struct QTAlbumRef: Codable, Sendable, Hashable {
    /// Browse id (`MPREb_…`).
    public var id: String?
    public var title: String

    public init(id: String? = nil, title: String) {
        self.id = id
        self.title = title
    }
}

/// One rendition of an artwork image. Lists of these are ordered smallest → largest.
public struct QTArtworkImage: Codable, Sendable, Hashable {
    public var url: URL
    public var width: Int?
    public var height: Int?

    public init(url: URL, width: Int? = nil, height: Int? = nil) {
        self.url = url
        self.width = width
        self.height = height
    }
}

public extension Array where Element == QTArtworkImage {
    /// The smallest image at least `pixels` wide, else the largest available.
    func best(forPixelWidth pixels: Int) -> QTArtworkImage? {
        let sorted = self.sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        return sorted.first { ($0.width ?? 0) >= pixels } ?? sorted.last
    }
}

/// The linked version of a track for Song⇄Video: the official MV of an audio track, or the audio track of an MV.
public struct QTCounterpart: Codable, Sendable, Hashable {
    public var videoId: String
    public var musicVideoType: QTMusicVideoType
    /// Still/thumbnail of the counterpart (16:9 for videos).
    public var artwork: [QTArtworkImage]

    public init(videoId: String, musicVideoType: QTMusicVideoType, artwork: [QTArtworkImage] = []) {
        self.videoId = videoId
        self.musicVideoType = musicVideoType
        self.artwork = artwork
    }
}

/// A playable song or music video.
public struct QTTrack: Codable, Sendable, Hashable, Identifiable {
    public var id: String { videoId }

    /// YouTube video id. Mock catalog tracks use the prototype ids (e.g. `ne34516548`).
    public var videoId: String
    public var title: String
    /// Secondary title shown dimmed after the title, e.g. "Hạ Phỏm (出牌)".
    public var subtitle: String?
    public var artists: [QTArtistRef]
    public var album: QTAlbumRef?
    /// Seconds.
    public var duration: TimeInterval
    /// Square artwork, smallest → largest.
    public var artwork: [QTArtworkImage]
    public var musicVideoType: QTMusicVideoType
    /// Song⇄Video counterpart, if YouTube Music links one.
    public var counterpart: QTCounterpart?
    public var isExplicit: Bool
    public var availability: QTAvailability
    /// Colours sampled from the artwork; drives the accent tint and Stage backgrounds.
    public var palette: QTArtworkPalette?
    /// Best known lyrics timing for list badges ("Word lyrics"). nil = unknown until lyrics are fetched.
    public var lyricsHint: QTLyricsSyncKind?
    /// This row's entry id in a playlist (`playlistSetVideoId`): what removing or moving the row needs. Only on rows
    /// of a playlist page; nil elsewhere.
    public var setVideoId: String?
    /// Whether the account likes the song, when the row said so (signed-in pages only).
    public var likeStatus: QTLikeStatus?

    public init(
        videoId: String,
        title: String,
        subtitle: String? = nil,
        artists: [QTArtistRef],
        album: QTAlbumRef? = nil,
        duration: TimeInterval,
        artwork: [QTArtworkImage] = [],
        musicVideoType: QTMusicVideoType = .atv,
        counterpart: QTCounterpart? = nil,
        isExplicit: Bool = false,
        availability: QTAvailability = .playable,
        palette: QTArtworkPalette? = nil,
        lyricsHint: QTLyricsSyncKind? = nil,
        setVideoId: String? = nil,
        likeStatus: QTLikeStatus? = nil
    ) {
        self.videoId = videoId
        self.title = title
        self.subtitle = subtitle
        self.artists = artists
        self.album = album
        self.duration = duration
        self.artwork = artwork
        self.musicVideoType = musicVideoType
        self.counterpart = counterpart
        self.isExplicit = isExplicit
        self.availability = availability
        self.palette = palette
        self.lyricsHint = lyricsHint
        self.setVideoId = setVideoId
        self.likeStatus = likeStatus
    }

    /// "Artist A, Artist B" — joined with the locale's list format.
    public var artistLine: String {
        artists.map(\.name).formatted(.list(type: .and, width: .narrow).locale(QTLoc.locale))
    }

    /// Whether Song⇄Video can switch to a video for this track.
    public var hasVideo: Bool {
        musicVideoType.isVideo || counterpart?.musicVideoType.isVideo == true
    }

    /// Still image for the video version (the track's own artwork if it already is the video).
    public var videoArtwork: [QTArtworkImage] {
        if musicVideoType.isVideo { return artwork }
        return counterpart?.artwork ?? []
    }
}
