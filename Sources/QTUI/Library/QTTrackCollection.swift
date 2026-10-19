import Foundation
import Observation
import QTCore

/// What a track-table page shows: Liked Songs, a playlist, an album, an artist, all songs, or search results.
public struct QTTrackCollection: Identifiable, Sendable {
    public enum Kind: Sendable, Hashable { case liked, playlist, album, artist, songs, history, search }

    public var id: String
    public var kind: Kind
    public var title: String
    public var artwork: [QTArtworkImage]
    public var tracks: [QTTrack]
    /// Playlist id for drop targets / remove; nil for derived collections.
    public var playlistID: String?

    public init(id: String, kind: Kind, title: String, artwork: [QTArtworkImage] = [], tracks: [QTTrack], playlistID: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.artwork = artwork
        self.tracks = tracks
        self.playlistID = playlistID
    }

    /// Small label above the title ("Playlist", "Album"…).
    public var kindLabel: String {
        switch kind {
        case .liked, .playlist: QTLoc.tr("Playlist")
        case .album: QTLoc.tr("Album")
        case .artist: QTLoc.tr("Artist", table: .main)
        case .songs, .history: QTLoc.tr("Library")
        case .search: QTLoc.tr("Search music")
        }
    }

    public var filterPrompt: String {
        kind == .liked ? QTLoc.tr("Filter Liked Songs") : QTLoc.tr("Filter")
    }

    public var queueSource: QTQueueSource {
        switch kind {
        case .liked: QTQueueSource(kind: .playlist, id: playlistID, title: .localized("Liked Songs"))
        case .playlist: QTQueueSource(kind: .playlist, id: playlistID, title: .verbatim(title))
        case .album: QTQueueSource(kind: .album, title: .verbatim(title))
        case .artist: QTQueueSource(kind: .artist, title: .verbatim(title))
        case .songs: QTQueueSource(kind: .playlist, title: .localized("Songs"))
        case .history: QTQueueSource(kind: .playlist, title: .localized("History"))
        case .search: QTQueueSource(kind: .search, title: .verbatim(title))
        }
    }

    public var totalDuration: TimeInterval { tracks.reduce(0) { $0 + $1.duration } }

    /// The playlist's placeholder glyph when it has no artwork.
    var placeholderIcon: QTIcon {
        switch kind {
        case .liked: .heartFill
        case .album: .album
        case .artist: .mic
        case .songs: .note
        case .history: .clock
        case .playlist, .search: .playlist
        }
    }

    // MARK: Builders from the catalog

    @MainActor
    public static func liked(_ catalog: QTMockCatalog, edits: QTPlaylistEdits = .shared) -> QTTrackCollection {
        let p = catalog.liked
        return QTTrackCollection(id: "liked", kind: .liked, title: QTLoc.tr("Liked Songs"), artwork: [],
                                 tracks: edits.tracks(for: p, catalog: catalog), playlistID: p.id)
    }

    @MainActor
    public static func playlist(_ p: QTPlaylist, catalog: QTMockCatalog, edits: QTPlaylistEdits = .shared) -> QTTrackCollection {
        QTTrackCollection(id: "playlist:\(p.id)", kind: .playlist, title: p.title.resolved, artwork: p.artwork,
                          tracks: edits.tracks(for: p, catalog: catalog), playlistID: p.id)
    }

    public static func songs(_ catalog: QTMockCatalog) -> QTTrackCollection {
        QTTrackCollection(id: "songs", kind: .songs, title: QTLoc.tr("Songs"), tracks: catalog.tracks)
    }

    /// Recently played, newest first, without repeats.
    public static func history(_ items: [QTQueueItem]) -> QTTrackCollection {
        var seen = Set<String>()
        let tracks = items.reversed().map(\.track).filter { seen.insert($0.videoId).inserted }
        return QTTrackCollection(id: "history", kind: .history, title: QTLoc.tr("History"), tracks: tracks)
    }

    /// Track-list state key for a destination (matches the collection ids above); nil for non-list pages.
    public static func listKey(for destination: QTDestination) -> String? {
        switch destination {
        case .section(.liked): "liked"
        case .section(.songs): "songs"
        case .section(.history): "history"
        case .section(.playlist(let id)): "playlist:\(id)"
        case .album(let t): "album:\(t)"
        case .artist(let n): "artist:\(n)"
        case .section, .mood: nil
        }
    }

    public static func album(_ title: String, catalog: QTMockCatalog) -> QTTrackCollection {
        let tracks = catalog.tracks.filter { $0.album?.title == title }
        return QTTrackCollection(id: "album:\(title)", kind: .album, title: title, artwork: tracks.first?.artwork ?? [], tracks: tracks)
    }

    public static func artist(_ name: String, catalog: QTMockCatalog) -> QTTrackCollection {
        let tracks = catalog.tracks.filter { $0.artists.contains { $0.name == name } }
        return QTTrackCollection(id: "artist:\(name)", kind: .artist, title: name, artwork: tracks.first?.artwork ?? [], tracks: tracks)
    }

    public static func search(_ query: String, catalog: QTMockCatalog) -> QTTrackCollection {
        let tracks = catalog.tracks.filter { QTTextFolding.matches(query: query, in: $0.qtSearchText) }
        return QTTrackCollection(id: "search", kind: .search, title: query, tracks: tracks)
    }
}

/// Session-only playlist edits from drag-to-playlist / context menus. Nothing is written to the user's
/// YouTube Music account (ask-before item) — the M3 data layer replaces this with real edits.
@MainActor
@Observable
public final class QTPlaylistEdits {
    public static let shared = QTPlaylistEdits()

    /// Playlist id → tracks appended this session (in order).
    public private(set) var added: [String: [String]] = [:]

    public init() {}

    public func tracks(for playlist: QTPlaylist, catalog: QTMockCatalog) -> [QTTrack] {
        let base = playlist.tracks ?? []
        let extra = (added[playlist.id] ?? []).compactMap { catalog.track(id: $0) }
        return base + extra
    }

    /// Appends tracks not already in the playlist; returns the ids actually added (for Undo).
    @discardableResult
    public func add(_ trackIDs: [String], to playlist: QTPlaylist) -> [String] {
        let existing = Set((playlist.tracks ?? []).map(\.videoId) + (added[playlist.id] ?? []))
        var seen = existing
        let fresh = trackIDs.filter { seen.insert($0).inserted }
        guard !fresh.isEmpty else { return [] }
        added[playlist.id, default: []].append(contentsOf: fresh)
        return fresh
    }

    public func undoAdd(_ trackIDs: [String], to playlistID: String) {
        let drop = Set(trackIDs)
        added[playlistID]?.removeAll { drop.contains($0) }
    }
}
