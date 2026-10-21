import Foundation
import QTCore
import QTInnerTube
import Testing
@testable import QTUI

/// Library › Uploads in the app: the sidebar place and its launch argument, the demo catalog's invented uploads
/// routed like live ones, and the privately-owned mark reaching the rest of the app (no Song⇄Video, no link sent to
/// ListenBrainz).
@MainActor
@Suite struct QTUploadsTests {
    @Test func uploadsIsALibraryPlaceAfterHistory() {
        #expect(QTSidebarItem(argument: "uploads") == .uploads)
        #expect(QTSidebarItem.uploads.argument == "uploads")
        #expect(QTSidebarView.icon(for: .uploads) == .upload)
        #expect(QTCommands.sidebarShortcutOrder.firstIndex(of: .uploads) == 7, "⌘8")
        #expect(QTTrackCollection.listKey(for: .section(.uploads)) == "uploads")
        #expect(QTWindowTitle.isBrowseID(QTUploads.albumPrefix + "b_po_x"))
    }

    @Test func demoUploadsAreInventedOwnedAndApartFromTheLibrary() {
        let demo = QTMockUploads.demo
        #expect(!demo.songs.isEmpty && !demo.albums.isEmpty && !demo.artists.isEmpty)
        #expect(demo.songs.allSatisfy { $0.isPrivatelyOwned && !$0.hasVideo && $0.artwork.isEmpty })
        #expect(demo.albums.allSatisfy { QTUploads.isAlbumID($0.id) })
        #expect(demo.artists.allSatisfy { QTUploads.isArtistID($0.id) })
        // Every song's album and artist exist on the other two lists.
        let albumIDs = Set(demo.albums.map(\.id))
        let artistIDs = Set(demo.artists.map(\.id))
        #expect(demo.songs.allSatisfy { $0.album.map { albumIDs.contains($0.id ?? "") } ?? true })
        #expect(demo.songs.allSatisfy { $0.artists.allSatisfy { artistIDs.contains($0.id ?? "") } })
    }

    @Test func demoUploadPagesOpenByIdOnly() throws {
        // A library album named like an upload one: titles still open the library's.
        let library = QTTrack(videoId: "a", title: "Porch Light", artists: [QTArtistRef(name: "Someone")],
                              album: QTAlbumRef(title: "Paper Lanterns"), duration: 200)
        let catalog = QTMockCatalog(tracks: [library], liked: QTPlaylist(id: "LM", title: .verbatim("Liked Songs")),
                                    uploads: QTMockUploads.demo)
        let service = QTMockBrowseService(catalog: catalog)
        let album = try #require(QTMockUploads.demo.albums.first)
        let page = try #require(service.albumNow(album.id))
        #expect(page.album.tracks?.map { $0.videoId } == album.tracks?.map { $0.videoId })
        #expect(page.album.tracks?.allSatisfy { $0.isPrivatelyOwned } == true)
        // An upload's title never opens it (the library's albums are looked up by title).
        #expect(service.albumNow(album.title)?.album.tracks?.map(\.videoId) == ["a"])
        #expect(QTAlbumPageView.collection(page, key: album.id).libraryID == nil, "nothing to add: it's the user's own")

        let artist = try #require(QTMockUploads.demo.artists.first)
        let artistPage = try #require(service.artistNow(artist.id))
        #expect(artistPage.artist.name == artist.name)
        #expect(!artistPage.songs.isEmpty && artistPage.songs.allSatisfy { $0.artists.contains { $0.id == artist.id } })
        #expect(artistPage.shelves.isEmpty)
    }

    @Test func listensOfUploadsCarryTheMark() {
        let upload = QTTrack(videoId: "upl0adVid01", title: "Porch Light", artists: [QTArtistRef(name: "Juniper Field")],
                             duration: 214, isPrivatelyOwned: true)
        let song = QTTrack(videoId: "abcdefghijk", title: "Song", artists: [QTArtistRef(name: "A")], duration: 200)
        #expect(QTIntegrationsCoordinator.scrobble(upload).isPrivatelyOwned)
        #expect(!QTIntegrationsCoordinator.scrobble(song).isPrivatelyOwned)
        #expect(!upload.hasVideo)
    }
}
