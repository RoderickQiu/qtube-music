import Foundation
import QTCore
import Testing
@testable import QTInnerTube

/// Library › Uploads (read-only): the three lists, their paging and sort, the upload album / artist pages routed by
/// browse-id prefix, and the privately-owned mark that keeps Song⇄Video, radio and links away from uploads.
/// Hand-built fixtures only (Fixtures/handbuilt-uploads-*.json, shaped after ytmusicapi `mixins/uploads.py` /
/// `parsers/uploads.py` and Metrolist; every id and title is made up): nothing reaches YouTube.
@Suite struct UploadsTests {
    static let creds = QTInnerTubeCredentials(cookieHeader: "SAPISID=FAKESAPISID123; SID=fake-sid",
                                              sapisid: "FAKESAPISID123")
    static let juniper = QTUploads.artistPrefix + "a_po_fakeJuniper"
    static let mara = QTUploads.artistPrefix + "a_po_fakeMara"
    static let lanterns = QTUploads.albumPrefix + "b_po_fakeLanterns"

    func makeClient(_ t: FakeTransport, signedIn: Bool = true) -> QTInnerTubeClient {
        QTInnerTubeClient(configuration: QTInnerTubeConfiguration(hl: "en", gl: "US"), transport: t,
                          credentials: signedIn ? FakeCredentials(Self.creds) : nil, retry: .none,
                          scrapesClientConfig: false)
    }

    // MARK: Lists

    @Test func songsDropTheShuffleRowAndAreMarkedPrivatelyOwned() throws {
        let page = QTInnerTubeParser.uploads(try Fixture.json("handbuilt-uploads-songs"))
        let songs = page.items.compactMap(\.track)
        #expect(songs.count == page.items.count)
        // "Shuffle all" links a real video id but has no menu: it is not a song.
        #expect(songs.map(\.title) == ["Porch Light", "Kites Over Harbour Street", "Kitchen Demo (Take 2)"])
        #expect(songs.allSatisfy { $0.isPrivatelyOwned }, "the mark comes from the page, not only the video type")
        #expect(songs.allSatisfy { !$0.hasVideo && $0.counterpart == nil && $0.musicVideoType == .atv })
        #expect(page.continuation == QTContinuation("FAKEUPLOADSCONT1"))

        let porch = songs[0]
        #expect(porch.videoId == "upl0adVid01")
        #expect(porch.duration == 214)
        #expect(porch.likeStatus == .like)
        #expect(porch.artists == [QTArtistRef(id: Self.juniper, name: "Juniper Field")])
        #expect(porch.album == QTAlbumRef(id: Self.lanterns, title: "Paper Lanterns"),
                "an upload album link without a page type still counts as the album")
    }

    @Test func aRowWithoutAPlayLinkTakesItsVideoIdFromTheQueueMenu() throws {
        let songs = QTInnerTubeParser.uploads(try Fixture.json("handbuilt-uploads-songs")).items.compactMap(\.track)
        #expect(songs[1].videoId == "upl0adVid02", "no overlay / watch endpoint: queueAddEndpoint.queueTarget")
        #expect(songs[1].artists.first?.id == Self.juniper, "artist link without a page type")
        // Unlinked artist, no album, no artwork: shown as it is.
        #expect(songs[2].videoId == "upl0adVid03")
        #expect(songs[2].artists == [QTArtistRef(name: "Mara Sol")])
        #expect(songs[2].album == nil && songs[2].artwork.isEmpty)
    }

    @Test func theQueueMenuFallbackNeverRevivesAGreyedOutRow() throws {
        let greyed: QTJSON = ["musicResponsiveListItemRenderer": [
            "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Gone"]]]]]],
            "musicItemRendererDisplayPolicy": "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT",
            "menu": ["menuRenderer": ["items": [["menuServiceItemRenderer": ["serviceEndpoint": [
                "queueAddEndpoint": ["queueTarget": ["videoId": "gone0000001"]]]]]]]],
        ]]
        let track = QTItemParser.tracks([greyed]).first
        #expect(track?.availability.isPlayable == false)
        #expect(track?.videoId.hasPrefix("unavailable:") == true)
    }

    @Test func albumsAndArtistsKeepTheirUploadIds() throws {
        let albums = QTInnerTubeParser.uploads(try Fixture.json("handbuilt-uploads-albums")).items.compactMap {
            if case .album(let a) = $0 { a } else { nil }
        }
        #expect(albums.map(\.title) == ["Paper Lanterns", "Night Ferry"])
        #expect(albums.allSatisfy { QTUploads.isAlbumID($0.id) })
        #expect(albums[0].artists == [QTArtistRef(id: Self.juniper, name: "Juniper Field")])
        #expect(albums[0].year == 2024)
        #expect(albums[1].artists.map(\.name) == ["The Quiet Hours"])

        // Artist rows have no menu; only songs need one.
        let artists = QTInnerTubeParser.uploads(try Fixture.json("handbuilt-uploads-artists")).items.compactMap {
            if case .artist(let a) = $0 { a } else { nil }
        }
        #expect(artists.map(\.name) == ["Juniper Field", "Mara Sol"])
        #expect(artists.map(\.id) == [Self.juniper, Self.mara])
    }

    @Test func noUploadsIsAnEmptyList() throws {
        let page = QTInnerTubeParser.uploads(try Fixture.json("handbuilt-uploads-empty"))
        #expect(page.items.isEmpty && page.continuation == nil)
    }

    // MARK: Client

    @Test func listsPageOnAndTakeASortOrder() async throws {
        let t = FakeTransport()
        let client = makeClient(t)
        t.enqueue("browse", data: try Fixture.data("handbuilt-uploads-songs"))
        t.enqueue("browse", data: try Fixture.data("handbuilt-uploads-songs-continuation"))
        let first = try await client.uploadedSongs(order: .recentlyAdded)
        #expect(first.items.count == 3)
        let more = try await client.uploadsContinuation(try #require(first.continuation))
        let next = more.items.compactMap(\.track)
        #expect(next.map(\.videoId) == ["upl0adVid04"])
        #expect(next.allSatisfy { $0.isPrivatelyOwned }, "continuation pages keep the mark")
        #expect(more.continuation == nil)

        let r = t.recorded
        #expect(r[0].jsonBody["browseId"].string == QTUploads.songsBrowseId)
        #expect(r[0].jsonBody["params"].string == "ggMGKgQIABAB")
        #expect(r[1].jsonBody["continuation"].string == "FAKEUPLOADSCONT1")
        #expect(r.allSatisfy { $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("SAPISIDHASH ") == true })

        t.enqueue("browse", data: try Fixture.data("handbuilt-uploads-albums"))
        t.enqueue("browse", data: try Fixture.data("handbuilt-uploads-artists"))
        let albums = try await client.uploadedAlbums()
        let artists = try await client.uploadedArtists(order: .aToZ)
        #expect(albums.items.count == 2 && artists.items.count == 2)
        #expect(t.recorded[2].jsonBody["browseId"].string == QTUploads.albumsBrowseId)
        #expect(t.recorded[2].jsonBody["params"].isNull, "no order = YouTube Music's default")
        #expect(t.recorded[3].jsonBody["browseId"].string == QTUploads.artistsBrowseId)
        #expect(t.recorded[3].jsonBody["params"].string == "ggMGKgQIARAA")
    }

    @Test func uploadsAreRefusedWithoutASession() async throws {
        let t = FakeTransport()
        let client = makeClient(t, signedIn: false)
        await #expect(throws: QTInnerTubeError.notSignedIn) { try await client.uploadedSongs() }
        await #expect(throws: QTInnerTubeError.notSignedIn) { try await client.album(Self.lanterns) }
        await #expect(throws: QTInnerTubeError.notSignedIn) { try await client.artist(Self.mara) }
        #expect(t.recorded.isEmpty, "nothing is sent anonymously")
    }

    @Test func uploadAlbumRoutesByPrefixAndFillsRowsFromTheHeader() async throws {
        let t = FakeTransport()
        let client = makeClient(t)
        t.enqueue("browse", data: try Fixture.data("handbuilt-uploads-album"))
        let page = try await client.album(Self.lanterns)
        #expect(t.recorded[0].jsonBody["browseId"].string == Self.lanterns)
        #expect(page.album.title == "Paper Lanterns")
        #expect(page.album.year == 2024)
        #expect(page.playlistId == "MLPRb_po_fakeLanterns", "from the older detail header's Play button")
        #expect(page.isSaved == nil)
        let tracks = try #require(page.album.tracks)
        #expect(tracks.map(\.videoId) == ["upl0adVid01", "upl0adVid02", "upl0adVid05"])
        // Rows have no artist or artwork: the album's.
        #expect(tracks.allSatisfy { $0.artists == [QTArtistRef(id: Self.juniper, name: "Juniper Field")] })
        #expect(tracks.allSatisfy { $0.artwork == page.album.artwork && !$0.artwork.isEmpty })
        #expect(tracks.allSatisfy { $0.album?.id == Self.lanterns && $0.isPrivatelyOwned })
        #expect(tracks.map(\.duration) == [214, 247, 192])
    }

    @Test func uploadArtistRoutesByPrefixAndReadsEveryPage() async throws {
        let t = FakeTransport()
        let client = makeClient(t)
        t.enqueue("browse", data: try Fixture.data("handbuilt-uploads-artist"))
        t.enqueue("browse", data: try Fixture.data("handbuilt-uploads-songs-continuation"))
        let page = try await client.artist(Self.mara)
        #expect(t.recorded[0].jsonBody["browseId"].string == Self.mara, "not unwrapped like an MPLA id")
        #expect(t.recorded[1].jsonBody["continuation"].string == "FAKEUPLOADARTISTCONT1")
        #expect(page.artist.name == "Mara Sol")
        #expect(page.songs.map(\.title) == ["Kitchen Demo (Take 2)", "Voice Memo, March"], "shuffle row dropped")
        #expect(page.songs.allSatisfy { $0.isPrivatelyOwned && $0.artists.first?.id == Self.mara })
        #expect(page.channelId == nil && page.albums.isEmpty)
    }

    @Test func uploadPagesAreMusicNotProfiles() {
        // Whatever page type an upload link names, it is never dropped by the music-only filter.
        let nav = QTNavigation.browse(browseId: Self.mara, params: nil, pageType: "MUSIC_PAGE_TYPE_USER_CHANNEL")
        #expect(!QTParse.isNonMusic(nav))
        #expect(nav.pageType == .libraryArtist)
        #expect(QTNavigation.browse(browseId: Self.lanterns, params: nil, pageType: nil).pageType == .album)
    }

    // MARK: Privately owned elsewhere

    @Test func queueRowsOfUploadsAreMarked() {
        let row: QTJSON = ["playlistPanelVideoRenderer": [
            "videoId": "upl0adVid01", "title": ["runs": [["text": "Porch Light"]]],
            "longBylineText": ["runs": [["text": "Juniper Field"]]], "lengthText": ["runs": [["text": "3:34"]]],
            "navigationEndpoint": ["watchEndpoint": ["videoId": "upl0adVid01", "watchEndpointMusicSupportedConfigs": [
                "watchEndpointMusicConfig": ["musicVideoType": "MUSIC_VIDEO_TYPE_PRIVATELY_OWNED_TRACK"]]]],
        ]]
        guard case .item(let item) = QTItemParser.parse(row), let track = item.track else {
            Issue.record("not parsed")
            return
        }
        #expect(track.isPrivatelyOwned && !track.hasVideo)
        #expect(track.musicVideoType == .atv)
    }

    @Test func noCounterpartIsLookedUpForAnUpload() async throws {
        let t = FakeTransport()
        let client = makeClient(t)
        let upload = QTTrack(videoId: "upl0adVid01", title: "Porch Light", artists: [QTArtistRef(name: "Juniper Field")],
                             duration: 214, isPrivatelyOwned: true)
        let found = try await client.counterpart(for: upload)
        #expect(found == nil)
        #expect(t.recorded.isEmpty, "neither `next` nor a search: no one else's video stands in for the user's file")
    }

    @Test func theMarkSurvivesSavedQueuesAndOldOnesStillLoad() throws {
        let upload = QTTrack(videoId: "upl0adVid01", title: "Porch Light", artists: [], duration: 214,
                             isPrivatelyOwned: true)
        let decoded = try JSONDecoder().decode(QTTrack.self, from: JSONEncoder().encode(upload))
        #expect(decoded.isPrivatelyOwned)
        // A track saved before uploads existed has no key at all.
        let plain = try JSONEncoder().encode(QTTrack(videoId: "abcdefghijk", title: "Song", artists: [], duration: 1))
        #expect(String(decoding: plain, as: UTF8.self).contains("privatelyOwned") == false)
        let old = try JSONDecoder().decode(QTTrack.self, from: plain)
        #expect(old.isPrivatelyOwned == false)
    }
}
