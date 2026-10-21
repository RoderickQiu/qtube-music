import Foundation

/// The demo catalog's uploads (DEBUG `-qt.catalog mock`): invented songs, albums and artists, so Library › Uploads
/// renders offline. Every title and name is made up; no artwork (uploads often have none, and the demo's covers
/// belong to real songs). Ids use the real uploads browse-id prefixes, so pages route like live ones.
public enum QTMockUploads {
    static let fieldID = QTUploads.artistPrefix + "a_po_mockJuniperField"
    static let hoursID = QTUploads.artistPrefix + "a_po_mockQuietHours"
    static let maraID = QTUploads.artistPrefix + "a_po_mockMaraSol"
    static let lanternsID = QTUploads.albumPrefix + "b_po_mockPaperLanterns"
    static let ferryID = QTUploads.albumPrefix + "b_po_mockNightFerry"

    public static let demo: QTUploads = {
        let field = QTArtistRef(id: fieldID, name: "Juniper Field")
        let hours = QTArtistRef(id: hoursID, name: "The Quiet Hours")
        let mara = QTArtistRef(id: maraID, name: "Mara Sol")
        let lanterns = QTAlbumRef(id: lanternsID, title: "Paper Lanterns")
        let ferry = QTAlbumRef(id: ferryID, title: "Night Ferry")
        func song(_ n: Int, _ title: String, _ artist: QTArtistRef, _ album: QTAlbumRef?, _ seconds: TimeInterval,
                  liked: Bool = false) -> QTTrack {
            QTTrack(videoId: String(format: "qtUpload%03d", n), title: title, artists: [artist], album: album,
                    duration: seconds, likeStatus: liked ? .like : .indifferent, isPrivatelyOwned: true)
        }
        let songs = [
            song(1, "Porch Light", field, lanterns, 214, liked: true),
            song(2, "Kites Over Harbour Street", field, lanterns, 247),
            song(3, "Slow Tide", field, lanterns, 192),
            song(4, "Paper Lanterns", field, lanterns, 281),
            song(5, "Last Ferry Out", hours, ferry, 305),
            song(6, "Lighthouse Keeper", hours, ferry, 238, liked: true),
            song(7, "Fog Horn Waltz", hours, ferry, 176),
            song(8, "Kitchen Demo (Take 2)", mara, nil, 143),
            song(9, "Voice Memo, March", mara, nil, 97),
        ]
        let albums = [
            QTAlbum(id: lanternsID, title: lanterns.title, artists: [field], year: 2024,
                    tracks: songs.filter { $0.album == lanterns }),
            QTAlbum(id: ferryID, title: ferry.title, artists: [hours], year: 2023,
                    tracks: songs.filter { $0.album == ferry }),
        ]
        let artists = [field, mara, hours].map { QTArtist(id: $0.id ?? $0.name, name: $0.name) }
        return QTUploads(songs: songs, albums: albums, artists: artists)
    }()
}
