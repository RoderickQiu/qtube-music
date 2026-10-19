import Foundation
import QTCore

/// What we know about the playing track when looking for lyrics. Original spellings only — providers get these
/// verbatim; comparison keys are computed by the matcher.
public struct QTLyricsQuery: Sendable, Hashable, Codable {
    /// The playing video (cache key).
    public var videoId: String
    /// The id to ask YouTube Music for lyrics: the audio (ATV) counterpart of an official video, since OMVs have
    /// no lyrics tab.
    public var lyricsVideoId: String
    public var title: String
    public var subtitle: String?
    public var artists: [String]
    public var album: String?
    /// Seconds; 0 when unknown.
    public var duration: TimeInterval

    public init(videoId: String, lyricsVideoId: String? = nil, title: String, subtitle: String? = nil,
                artists: [String], album: String? = nil, duration: TimeInterval) {
        self.videoId = videoId
        self.lyricsVideoId = lyricsVideoId ?? videoId
        self.title = title
        self.subtitle = subtitle
        self.artists = artists
        self.album = album
        self.duration = duration
    }

    public init(track: QTTrack) {
        var lyricsId = track.videoId
        if track.musicVideoType.isVideo, let c = track.counterpart, c.musicVideoType == .atv { lyricsId = c.videoId }
        self.init(videoId: track.videoId, lyricsVideoId: lyricsId, title: track.title, subtitle: track.subtitle,
                  artists: track.artists.map(\.name), album: track.album?.title, duration: track.duration)
    }

    /// "Artist A, Artist B" for providers that take a single artist string.
    public var artistLine: String { artists.joined(separator: ", ") }
    public var primaryArtist: String { artists.first.map(QTTitleCleaner.cleanArtist) ?? "" }
    public var cleanTitle: QTCleanTitle { QTTitleCleaner.clean(title) }
}

/// One search hit from a provider, before its lyrics are fetched.
public struct QTLyricsCandidate: Sendable, Hashable, Codable, Identifiable {
    public var source: QTLyricsSource
    /// Provider-side id (NetEase song id, Kugou lyric id, LRCLIB id, AMLL file…).
    public var remoteID: String
    public var title: String
    /// Other titles the provider lists (NetEase `tns`/`alia`).
    public var titleAliases: [String]
    public var artists: [String]
    /// Other artist names the provider lists (NetEase `ar[].tns`/`alias`).
    public var artistAliases: [String]
    public var album: String?
    /// Seconds; nil when the provider doesn't say.
    public var duration: TimeInterval?
    /// Best timing the provider advertises before fetching, if any.
    public var syncHint: QTLyricsSyncKind?
    /// True when the candidate is keyed by the track itself (YouTube Music by videoId) — no fuzzy matching.
    public var isExactMatch: Bool
    /// Provider-specific fields needed to fetch (Kugou `accesskey`, QQ `mid`, AMLL folder…).
    public var extra: [String: String]

    public var id: String { source.id + ":" + remoteID }

    public init(source: QTLyricsSource, remoteID: String, title: String, titleAliases: [String] = [], artists: [String],
                artistAliases: [String] = [], album: String? = nil, duration: TimeInterval? = nil,
                syncHint: QTLyricsSyncKind? = nil, isExactMatch: Bool = false, extra: [String: String] = [:]) {
        self.source = source
        self.remoteID = remoteID
        self.title = title
        self.titleAliases = titleAliases
        self.artists = artists
        self.artistAliases = artistAliases
        self.album = album
        self.duration = duration
        self.syncHint = syncHint
        self.isExactMatch = isExactMatch
        self.extra = extra
    }
}
