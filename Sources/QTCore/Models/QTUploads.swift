import Foundation

/// The user's uploads (YouTube Music › Library › Uploads): the songs they uploaded, and the albums and artists the
/// files' tags make of them. Read-only here — uploading and deleting are writes to the account's upload storage.
public struct QTUploads: Sendable, Hashable {
    public var songs: [QTTrack]
    public var albums: [QTAlbum]
    public var artists: [QTArtist]

    public init(songs: [QTTrack] = [], albums: [QTAlbum] = [], artists: [QTArtist] = []) {
        self.songs = songs
        self.albums = albums
        self.artists = artists
    }

    public static let empty = QTUploads()

    public var isEmpty: Bool { songs.isEmpty && albums.isEmpty && artists.isEmpty }

    // MARK: Browse ids (ytmusicapi `mixins/uploads.py`)

    /// Every uploads page and detail page starts with this.
    public static let browsePrefix = "FEmusic_library_privately_owned"
    public static let songsBrowseId = "FEmusic_library_privately_owned_tracks"
    public static let albumsBrowseId = "FEmusic_library_privately_owned_releases"
    public static let artistsBrowseId = "FEmusic_library_privately_owned_artists"
    /// An uploaded album's page: `…_release_detail` + the album's entity id (`b_po_…`).
    public static let albumPrefix = "FEmusic_library_privately_owned_release_detail"
    /// An uploads artist's page (only the songs uploaded for that artist): `…_artist_detail` + `a_po_…`.
    public static let artistPrefix = "FEmusic_library_privately_owned_artist_detail"

    public static func isUploadID(_ browseId: String) -> Bool { browseId.hasPrefix(browsePrefix) }
    public static func isAlbumID(_ browseId: String) -> Bool { browseId.hasPrefix(albumPrefix) }
    public static func isArtistID(_ browseId: String) -> Bool { browseId.hasPrefix(artistPrefix) }
}
