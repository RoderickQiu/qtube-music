import Foundation
import QTCore
import Testing
@testable import QTInnerTube

/// Account writes (likes, playlists, subscriptions, saved albums) and the account list: request shapes, never a
/// retry, YouTube's status checked, cached pages dropped — and the parsers for the signed-in shapes (entry ids, like
/// status, owned playlists, add-to-playlist options, brand accounts). Fake transport and hand-built fixtures only
/// (Fixtures/handbuilt-*.json, shaped after ytmusicapi and Kaset; every id is made up): nothing reaches YouTube.
@Suite struct WritesTests {
    static let creds = QTInnerTubeCredentials(cookieHeader: "SAPISID=FAKESAPISID123; SID=fake-sid",
                                              sapisid: "FAKESAPISID123")
    static let ok: QTJSON = ["status": "STATUS_SUCCEEDED"]

    /// A recorded (anonymous) page answered as the signed-in account would, or the client reads a lost session.
    static func signedIn(_ fixture: String) throws -> QTJSON {
        guard case .object(var o) = try Fixture.json(fixture) else { return .null }
        o["responseContext"] = [:]
        return .object(o)
    }

    func makeClient(_ t: FakeTransport, retry: QTRetryPolicy = .default, sleeps: SleepRecorder = SleepRecorder(),
                    signedIn: Bool = true, writes: Bool = true) async -> QTInnerTubeClient {
        let client = QTInnerTubeClient(configuration: QTInnerTubeConfiguration(hl: "en", gl: "US"), transport: t,
                                       credentials: signedIn ? FakeCredentials(Self.creds) : nil, retry: retry,
                                       scrapesClientConfig: false, sleep: { sleeps.record($0) })
        await client.setAllowsAccountWrites(writes)
        return client
    }

    // MARK: Request shapes

    @Test func likesAndLibraryWrites() async throws {
        let t = FakeTransport()
        let client = await makeClient(t)
        t.enqueue("like/like", json: [:])
        try await client.rate(videoId: "vidOwned001", .like)
        t.enqueue("like/removelike", json: [:])
        try await client.rate(videoId: "vidOwned001", .none)
        t.enqueue("like/like", json: [:])
        try await client.rate(playlistId: "VLOLAK5uy_fakeAlbum", .like)
        t.enqueue("subscription/subscribe", json: [:])
        try await client.setSubscribed(true, channelId: "MPLAUCartistA0000000000000000")
        t.enqueue("subscription/unsubscribe", json: [:])
        try await client.setSubscribed(false, channelId: "UCartistA0000000000000000")

        let r = t.recorded
        #expect(r.map { $0.url!.lastPathComponent } == ["like", "removelike", "like", "subscribe", "unsubscribe"])
        #expect(r[0].jsonBody[path: "target", "videoId"].string == "vidOwned001")
        #expect(r[2].jsonBody[path: "target", "playlistId"].string == "OLAK5uy_fakeAlbum", "albums save as their playlist")
        #expect(r[3].jsonBody["channelIds"].array.map(\.string) == ["UCartistA0000000000000000"], "library wrapper unwrapped")
        // Every write carries the session.
        #expect(r.allSatisfy { $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("SAPISIDHASH ") == true })
    }

    @Test func playlistEditsAndTheirResults() async throws {
        let t = FakeTransport()
        let client = await makeClient(t)
        t.enqueue("browse/edit_playlist", data: try Fixture.data("handbuilt-edit-playlist-add"))
        let added = try await client.addToPlaylist("VLPLowned", videoIds: ["vidNew001", "vidNew002"])
        #expect(added == [QTPlaylistAddResult(videoId: "vidNew001", setVideoId: "SETNEW001"),
                          QTPlaylistAddResult(videoId: "vidNew002", setVideoId: "SETNEW002")])
        let add = t.recorded[0].jsonBody
        #expect(add["playlistId"].string == "PLowned")
        #expect(add["actions"].array.map { $0["action"].string } == ["ACTION_ADD_VIDEO", "ACTION_ADD_VIDEO"])
        #expect(add["actions"][0]["addedVideoId"].string == "vidNew001")
        #expect(add["actions"][0]["dedupeOption"].isNull, "no dedupe override: YouTube refuses duplicates")

        t.enqueue("browse/edit_playlist", json: Self.ok)
        try await client.movePlaylistItem("PLowned", setVideoId: "SETID003", before: "SETID001")
        t.enqueue("browse/edit_playlist", json: Self.ok)
        try await client.movePlaylistItem("PLowned", setVideoId: "SETID001", before: nil)
        let move = t.recorded[1].jsonBody["actions"][0]
        #expect(move["action"].string == "ACTION_MOVE_VIDEO_BEFORE")
        #expect(move["setVideoId"].string == "SETID003")
        #expect(move["movedSetVideoIdSuccessor"].string == "SETID001")
        #expect(t.recorded[2].jsonBody["actions"][0]["movedSetVideoIdSuccessor"].isNull, "nil successor = to the end")

        t.enqueue("browse/edit_playlist", json: Self.ok)
        try await client.editPlaylistDetails("PLowned", title: "Road Trip 2", description: "", privacy: .public)
        let edit = t.recorded[3].jsonBody["actions"].array
        #expect(edit.map { $0["action"].string } == ["ACTION_SET_PLAYLIST_NAME", "ACTION_SET_PLAYLIST_DESCRIPTION",
                                                     "ACTION_SET_PLAYLIST_PRIVACY"])
        #expect(edit[0]["playlistName"].string == "Road Trip 2")
        #expect(edit[2]["playlistPrivacy"].string == "PUBLIC")
        // Nothing to change sends nothing.
        try await client.editPlaylistDetails("PLowned")
        #expect(t.recorded.count == 4)

        t.enqueue("playlist/create", json: ["playlistId": "PLcreated"])
        let id = try await client.createPlaylist(title: "Queue · Oct 20", description: "", privacy: .private,
                                                 videoIds: ["vidNew001"])
        #expect(id == "PLcreated")
        let create = t.recorded[4].jsonBody
        #expect(create["title"].string == "Queue · Oct 20")
        #expect(create["privacyStatus"].string == "PRIVATE")
        #expect(create["videoIds"].array.map(\.string) == ["vidNew001"])

        t.enqueue("playlist/delete", json: [:])
        try await client.deletePlaylist("VLPLcreated")
        #expect(t.recorded[5].jsonBody["playlistId"].string == "PLcreated")
    }

    // MARK: Safety

    @Test func writesAreNeverRetried() async throws {
        let t = FakeTransport()
        let sleeps = SleepRecorder()
        let client = await makeClient(t, sleeps: sleeps)
        t.enqueue("playlist/create", status: 503, json: [:])
        t.enqueue("playlist/create", json: ["playlistId": "PLsecond"])
        await #expect(throws: QTInnerTubeError.rateLimited(retryAfter: nil)) {
            _ = try await client.createPlaylist(title: "Once")
        }
        #expect(t.recorded.count == 1, "a create that may have landed is never sent twice")
        t.enqueue("browse/edit_playlist", status: 500, json: [:])
        await #expect(throws: QTInnerTubeError.http(status: 500)) {
            try await client.addToPlaylist("PLowned", videoIds: ["vidNew001"])
        }
        #expect(t.recorded.count == 2)
        #expect(sleeps.delays.isEmpty)
        // Reads still retry.
        t.enqueue("browse", status: 503, json: [:])
        t.enqueue("browse", json: try Self.signedIn("explore-en"))
        _ = try await client.explore()
        #expect(t.recorded.count == 4)
    }

    @Test func onlySucceededCounts() async throws {
        let t = FakeTransport()
        let client = await makeClient(t)
        t.enqueue("browse/edit_playlist", json: ["status": "STATUS_FAILED"])
        await #expect(throws: QTInnerTubeError.writeRejected(status: "STATUS_FAILED")) {
            try await client.removeFromPlaylist("PLowned", items: [(videoId: "vidOwned001", setVideoId: "SETID001")])
        }
        // An edit always states its status; none is a failure too.
        t.enqueue("browse/edit_playlist", json: [:])
        await #expect(throws: QTInnerTubeError.writeRejected(status: "none")) {
            try await client.addToPlaylist("PLowned", videoIds: ["vidNew001"])
        }
        t.enqueue("like/like", json: ["status": "STATUS_FAILED"])
        await #expect(throws: QTInnerTubeError.writeRejected(status: "STATUS_FAILED")) {
            try await client.rate(videoId: "vidOwned001", .like)
        }
        t.enqueue("playlist/create", json: ["status": "STATUS_SUCCEEDED"])
        await #expect(throws: QTInnerTubeError.parse("playlist/create")) { _ = try await client.createPlaylist(title: "x") }
    }

    @Test func writesNeedTheSwitchAndTheSession() async throws {
        let t = FakeTransport()
        let off = await makeClient(t, writes: false)
        await #expect(throws: QTInnerTubeError.writesDisabled) { try await off.setSubscribed(true, channelId: "UCx") }
        await #expect(throws: QTInnerTubeError.writesDisabled) { try await off.deletePlaylist("PLowned") }
        let guest = await makeClient(t, signedIn: false)
        await #expect(throws: QTInnerTubeError.notSignedIn) { try await guest.rate(videoId: "vidOwned001", .like) }
        await #expect(throws: QTInnerTubeError.notSignedIn) { _ = try await guest.accounts() }
        await #expect(throws: QTInnerTubeError.notSignedIn) { _ = try await guest.addToPlaylistOptions(videoIds: ["v"]) }
        #expect(t.recorded.isEmpty)
    }

    @Test func aWriteDropsTheCachedPagesItChanges() async throws {
        let t = FakeTransport()
        let client = await makeClient(t)
        t.enqueue("browse", data: try Fixture.data("handbuilt-playlist-owned"))
        t.enqueue("browse", json: try Self.signedIn("explore-en"))
        _ = try await client.playlist("PLowned")
        _ = try await client.explore()
        #expect(await client.cachedResponseCount == 2)
        t.enqueue("browse/edit_playlist", json: Self.ok)
        try await client.removeFromPlaylist("PLowned", items: [(videoId: "vidOwned001", setVideoId: "SETID001")])
        #expect(await client.cachedResponseCount == 1, "the playlist's page goes, Explore stays")
        // A failed write keeps the cache.
        t.enqueue("browse", data: try Fixture.data("handbuilt-playlist-owned"))
        _ = try await client.playlist("PLowned")
        t.enqueue("browse/edit_playlist", json: ["status": "STATUS_FAILED"])
        _ = try? await client.removeFromPlaylist("PLowned", items: [(videoId: "vidOwned002", setVideoId: "SETID002")])
        #expect(await client.cachedResponseCount == 2)
    }

    // MARK: Parsers

    @Test func ownedPlaylistRows() throws {
        let page = try #require(QTInnerTubeParser.playlist(try Fixture.json("handbuilt-playlist-owned"), browseId: "VLPLowned"))
        #expect(page.playlist.title == .verbatim("Road Trip"))
        #expect(page.playlist.isEditable == true)
        #expect(page.playlist.privacy == .unlisted)
        #expect(page.playlist.description == "Songs for the drive")
        #expect(page.isSaved == nil, "the account's own playlist isn't 'saved'")
        let tracks = try #require(page.playlist.tracks)
        #expect(tracks.map(\.videoId) == ["vidOwned001", "vidOwned002", "vidOwned003"])
        // Entry ids: playlistItemData, else the "Remove from playlist" menu item.
        #expect(tracks.map(\.setVideoId) == ["SETID001", "SETID002", "SETID003"])
        // Like status: the like button, else the toggle (whose default action is the opposite state); none = nil.
        #expect(tracks.map(\.likeStatus) == [.like, .indifferent, nil])
    }

    @Test func someoneElsesPlaylistAndPublicPages() throws {
        let saved = try #require(QTInnerTubeParser.playlist(try Fixture.json("handbuilt-playlist-saved"), browseId: "VLPLsaved"))
        #expect(saved.playlist.isEditable == false)
        #expect(saved.isSaved == true)
        #expect(saved.playlist.tracks?.first?.setVideoId == nil)
        // Anonymous recorded pages: not editable, no saved state, no like status.
        let anon = try #require(QTInnerTubeParser.playlist(try Fixture.json("playlist-classic-rock-en"),
                                                         browseId: "VLPL0GvsLQil0MmYC96KEs_7dTNsLm1PS6JX"))
        #expect(anon.playlist.isEditable == false)
        #expect(anon.isSaved == nil)
        #expect(anon.playlist.tracks?.allSatisfy { $0.likeStatus == nil } == true)
        #expect(QTInnerTubeParser.playlist(try Fixture.json("playlist-classic-rock-en"), browseId: "VLLM")?
            .playlist.isEditable == false, "Liked Music is never edited as a playlist")
    }

    @Test func albumSavedStateAndArtistSubscription() throws {
        let header: QTJSON = [
            "musicResponsiveHeaderRenderer": [
                "title": ["runs": [["text": "Album A"]]],
                "buttons": [["toggleButtonRenderer": [
                    "defaultServiceEndpoint": ["likeEndpoint": ["status": "INDIFFERENT", "target": ["playlistId": "OLAK5uy_fakeAlbum"]]],
                ]]],
            ],
        ]
        let album: QTJSON = ["contents": ["twoColumnBrowseResultsRenderer": ["tabs": [["tabRenderer": ["content": [
            "sectionListRenderer": ["contents": [header]]]]]]]]]
        #expect(QTInnerTubeParser.album(album, browseId: "MPREb_albumA")?.isSaved == true,
                "a toggle whose action removes it means it's saved")
        #expect(QTInnerTubeParser.album(try Fixture.json("album-hkt-en"), browseId: "MPREb_JR856gupBGZ")?.isSaved == nil)

        let artist: QTJSON = ["header": ["musicImmersiveHeaderRenderer": [
            "title": ["runs": [["text": "Artist A"]]],
            "subscriptionButton": ["subscribeButtonRenderer": ["channelId": "UCartistA0000000000000000", "subscribed": true]],
        ]]]
        let page = try #require(QTInnerTubeParser.artist(artist, browseId: "UCartistA0000000000000000"))
        #expect(page.channelId == "UCartistA0000000000000000")
        #expect(page.isSubscribed == true)
    }

    @Test func nextRowsCarryLikeStatus() {
        let row: QTJSON = ["playlistPanelVideoRenderer": [
            "videoId": "vidOwned002", "title": ["runs": [["text": "Song Two"]]],
            "longBylineText": ["runs": [["text": "Artist B"]]],
            "menu": ["menuRenderer": ["items": [["toggleMenuServiceItemRenderer": [
                "defaultServiceEndpoint": ["likeEndpoint": ["status": "INDIFFERENT", "target": ["videoId": "vidOwned002"]]],
            ]]]]],
        ]]
        guard case .item(let item) = QTItemParser.parse(row) else { Issue.record("row"); return }
        #expect(item.track?.likeStatus == .like)
    }

    @Test func addToPlaylistOptions() throws {
        let options = QTWriteParser.playlistOptions(try Fixture.json("handbuilt-add-to-playlist"))
        #expect(options.map(\.id) == ["PLowned", "PLsecond"], "one per playlist, first wins")
        #expect(options.map(\.title) == ["Road Trip", "Focus"])
        #expect(options.map(\.containsVideos) == [true, false])
        #expect(options.map(\.privacy) == [.unlisted, .private])
        // Kaset's shapes: an edit endpoint on the item, a `selected` flag.
        let kaset: QTJSON = ["addToPlaylistRenderer": ["contents": [["playlistAddToOptionRenderer": [
            "title": ["runs": [["text": "Workout"]]], "selected": true,
            "serviceEndpoint": ["playlistEditEndpoint": ["playlistId": "PLWORKOUT"]],
        ]]]]]
        #expect(QTWriteParser.playlistOptions(kaset) == [QTPlaylistOption(id: "PLWORKOUT", title: "Workout", containsVideos: true)])
    }

    @Test func accountsList() throws {
        let accounts = QTWriteParser.accounts(try Fixture.json("handbuilt-accounts-list"))
        #expect(accounts.map(\.name) == ["Alex Rivera", "Alex Rivera Music", "Spoofed"])
        #expect(accounts.map(\.brandId) == [nil, "100000000000000000001", "100000000000000000002"])
        #expect(accounts.map(\.isSelected) == [true, false, false])
        #expect(accounts[1].handle == "@alexriveramusic")
        #expect(accounts[0].signinURL?.absoluteString
            == "https://www.youtube.com/signin?action_handle_signin=true&authuser=0&next=https%3A%2F%2Fmusic.youtube.com%2F")
        #expect(accounts[1].signinURL?.query?.contains("pageid=100000000000000000001") == true)
        #expect(accounts[2].signinURL == nil, "a switch link anywhere but www.youtube.com/signin is refused")
        #expect(accounts[0].id == "primary" && accounts[1].id == "100000000000000000001")
    }

    @Test func accountsRequest() async throws {
        let t = FakeTransport()
        let client = await makeClient(t, writes: false)
        t.enqueue("account/accounts_list", data: try Fixture.data("handbuilt-accounts-list"))
        let accounts = try await client.accounts()
        #expect(accounts.count == 3)
        #expect(t.recorded.first?.url?.path.hasSuffix("/account/accounts_list") == true)
    }

    @Test func dataSyncIdNamesTheIdentity() {
        #expect(QTWriteParser.dataSyncId("100000000000000000001||USERSESSION", matches: "100000000000000000001"))
        #expect(!QTWriteParser.dataSyncId("100000000000000000001||USERSESSION", matches: nil))
        #expect(QTWriteParser.dataSyncId("USERSESSION||", matches: nil))
        #expect(!QTWriteParser.dataSyncId("USERSESSION||", matches: "100000000000000000001"))
        // Not loaded yet: neither.
        #expect(!QTWriteParser.dataSyncId("", matches: nil))
        #expect(!QTWriteParser.dataSyncId("||", matches: nil))
        #expect(!QTWriteParser.dataSyncId("garbage", matches: nil))
    }
}
