import Foundation
import QTAuth
import QTCore
import QTInnerTube
import QTLyrics
import QTPlayback
import Testing
import WebKit
@testable import QTUI

/// `QTAccountWriter`: likes and playlist edits show at once, go to the account one at a time when syncing (collapsed,
/// rolled back with Try Again on failure, paused by the bot check, never clobbered by Liked Songs paging), stay on
/// this Mac with Sync off (and survive a relaunch), and brand-account switching only happens once the player page
/// confirms it. A fake transport with hand-built signed-in fixtures and a fake identity switcher: nothing reaches
/// YouTube or Google.
@MainActor
@Suite(.serialized) struct QTAccountWriterTests {
    static let fakeLogin = [
        QTCookie(name: "SAPISID", value: "FAKE-SAPISID", domain: ".youtube.com"),
        QTCookie(name: "SID", value: "FAKE-SID", domain: ".youtube.com"),
        QTCookie(name: "__Secure-1PSIDTS", value: "FAKE-TS", domain: ".youtube.com", isHTTPOnly: true),
    ]

    nonisolated static func fixture(_ name: String) -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("QTInnerTubeTests/Fixtures/\(name).json")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "{}"
        // Recorded anonymously: answer as the signed-in account would.
        return Data(text.replacingOccurrences(of: #""logged_in","value":"0""#, with: #""logged_in","value":"1""#).utf8)
    }

    /// Holds the like writes until released (a like still on its way while Liked Songs reloads).
    actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            for w in waiters { w.resume() }
            waiters = []
        }
    }

    /// Liked Songs, the owned playlist and the account list from fixtures; writes succeed unless a reply is queued.
    final class Transport: QTHTTPTransport, @unchecked Sendable {
        struct Reply { var status = 200; var body = Data("{}".utf8); var url: URL? }
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        private var queued: [String: [Reply]] = [:]
        var holdsLikes = false
        let gate = Gate()
        /// Set: one playlist continuation page is served once this opens (later pages fail, ending the paging).
        var continuationGate: Gate?
        private var continuationsServed = 0

        func enqueue(_ suffix: String, _ reply: Reply) { lock.withLock { queued[suffix, default: []].append(reply) } }

        var recorded: [URLRequest] { lock.withLock { requests } }

        func writes(_ suffix: String) -> [QTJSON] {
            recorded.filter { $0.url?.path.hasSuffix(suffix) == true }
                .map { (try? QTJSON(data: $0.httpBody ?? Data())) ?? .null }
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url?.path ?? ""
            let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let reply: Reply? = lock.withLock {
                requests.append(request)
                guard let key = queued.keys.sorted(by: { $0.count > $1.count }).first(where: { path.hasSuffix($0) }),
                      var list = queued[key], !list.isEmpty else { return nil }
                let r = list.removeFirst()
                queued[key] = list
                return r
            }
            if holdsLikes, path.hasSuffix("/like/like") || path.hasSuffix("/like/removelike") { await gate.wait() }
            if let continuationGate, path.hasSuffix("/browse"), body.contains("\"continuation\"") {
                await continuationGate.wait()
                let first = lock.withLock { continuationsServed += 1; return continuationsServed == 1 }
                guard first else { throw URLError(.notConnectedToInternet) }
                return (QTAccountWriterTests.fixture("playlist-classic-rock-continuation-en"),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
            }
            func answer(_ r: Reply) -> (Data, HTTPURLResponse) {
                (r.body, HTTPURLResponse(url: r.url ?? request.url!, statusCode: r.status, httpVersion: "HTTP/1.1",
                                         headerFields: [:])!)
            }
            if let reply { return answer(reply) }
            switch true {
            case path.hasSuffix("/browse") && body.contains("\"VLLM\""):
                return answer(Reply(body: QTAccountWriterTests.fixture("playlist-classic-rock-en")))
            case path.hasSuffix("/browse") && body.contains("\"VLPLowned\""):
                return answer(Reply(body: QTAccountWriterTests.fixture("handbuilt-playlist-owned")))
            case path.hasSuffix("/browse") && body.contains("\"VLPLdup\""):
                // The owned playlist with "Song One" twice (entries SETID001 and SETID003).
                let text = String(decoding: QTAccountWriterTests.fixture("handbuilt-playlist-owned"), as: UTF8.self)
                return answer(Reply(body: Data(text.replacingOccurrences(of: "vidOwned003", with: "vidOwned001").utf8)))
            case path.hasSuffix("/browse") && body.contains("\"VLPLpaged\""):
                return answer(Reply(body: QTAccountWriterTests.fixture("playlist-classic-rock-en")))
            case path.hasSuffix("/account/accounts_list"):
                return answer(Reply(body: QTAccountWriterTests.fixture("handbuilt-accounts-list")))
            case path.hasSuffix("/like/like"), path.hasSuffix("/like/removelike"):
                return answer(Reply())
            case path.hasSuffix("/browse/edit_playlist"):
                return answer(Reply(body: Data(#"{"status":"STATUS_SUCCEEDED"}"#.utf8)))
            case path.hasSuffix("/playlist/create"):
                return answer(Reply(body: Data(#"{"playlistId":"PLcreated"}"#.utf8)))
            case path.hasSuffix("/playlist/delete"), path.hasSuffix("/subscription/subscribe"),
                 path.hasSuffix("/subscription/unsubscribe"):
                return answer(Reply())
            default:
                throw URLError(.notConnectedToInternet)
            }
        }
    }

    /// Confirms (or refuses) identity switches without WebKit.
    @MainActor final class FakeSwitcher: QTSessionIdentitySwitching {
        var fails = false
        /// What a failure throws (refused by default; `.timedOut` / `.navigationFailed` = couldn't reach the page).
        var error: QTIdentitySwitchError = .notApplied
        /// Holds the switch until opened (a switch under way).
        var gate: Gate?
        var calls: [(URL, String?)] = []
        func switchIdentity(to signinURL: URL, brandId: String?, dataStore: WKWebsiteDataStore?) async throws {
            calls.append((signinURL, brandId))
            if let gate { await gate.wait() }
            if fails { throw error }
        }
    }

    struct Harness {
        let store: QTLiveCatalogStore
        let model: QTAppModel
        let transport: Transport
        let edits: QTPlaylistEdits
        @MainActor var writer: QTAccountWriter { store.writer }
    }

    static func makeHarness(sync: Bool = true, edits: QTPlaylistEdits = QTPlaylistEdits(), brand: String? = nil,
                            switcher: FakeSwitcher? = nil, prepare: (Transport, QTLiveCatalogStore) -> Void = { _, _ in })
        async throws -> Harness {
        let keychain = QTMemorySecureStore()
        try await QTSessionStore(store: keychain).save(QTAuthSession(cookies: fakeLogin, brandAccountId: brand))
        let transport = Transport()
        let client = QTInnerTubeClient(transport: transport, retry: .none, scrapesClientConfig: false, sleep: { _ in })
        let auth = QTAuthController(sessionStore: QTSessionStore(store: keychain), cookieStore: QTMemoryWebCookieStore(),
                                    client: client)
        if let switcher { auth.identitySwitcher = switcher }
        let defaults = try #require(UserDefaults(suiteName: "qt.tests.writer.\(UUID().uuidString)"))
        let store = QTLiveCatalogStore(client: client, auth: auth, defaults: defaults,
                                       playbackServices: QTPlaybackServices(), edits: edits)
        prepare(transport, store)
        let empty = QTMockCatalog(tracks: [], liked: QTPlaylist(id: "LM", title: .localized("Liked Songs"), kind: .liked, tracks: []))
        let player = QTPlayerModel(engine: QTSimulatedPlaybackEngine(account: .premium, tickInterval: nil),
                                   lyricsProvider: QTMockLyricsProvider(catalog: empty))
        let settings = QTSettingsStore(defaults: defaults)
        settings.update { $0.syncsToYouTubeMusic = sync }
        let model = QTAppModel(settings: settings, player: player, catalog: empty,
                               launch: QTLaunchOptions(arguments: ["qt.catalog": "live"]))
        store.attach(model)
        await waitUntil("live") { store.mode == .live && store.likedPhase == .loaded && !store.isLoadingMoreLiked }
        return Harness(store: store, model: model, transport: transport, edits: edits)
    }

    static func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        if !condition() { Issue.record("timed out waiting for \(what)") }
    }

    static let newSong = QTTrack(videoId: "vidNew001", title: "New Song", artists: [QTArtistRef(name: "Artist N")],
                                 duration: 200)
    static let otherSong = QTTrack(videoId: "vidNew002", title: "Other Song", artists: [QTArtistRef(name: "Artist N")],
                                   duration: 180)

    // MARK: Likes

    @Test func aLikeShowsAtOnceAndIsSentOnce() async throws {
        let h = try await Self.makeHarness()
        #expect(h.writer.syncsToAccount)
        h.model.player.toggleLike(Self.newSong)
        #expect(h.model.player.isLiked(Self.newSong), "the heart fills before YouTube answers")
        #expect(QTTrackCollection.liked(h.model.catalog, edits: h.edits).tracks.first?.videoId == "vidNew001")
        await h.writer.idle()
        let likes = h.transport.writes("/like/like")
        #expect(likes.count == 1)
        #expect(likes.first?[path: "target", "videoId"].string == "vidNew001")
        #expect(h.model.catalog.liked.tracks?.first?.videoId == "vidNew001", "confirmed: in Liked Songs itself")
        #expect(h.edits.pending.isEmpty)
        #expect(h.model.player.isLiked(Self.newSong))
    }

    @Test func quickTogglesCollapse() async throws {
        let h = try await Self.makeHarness()
        h.writer.setLiked([Self.newSong], true)
        h.writer.setLiked([Self.newSong], false)
        await h.writer.idle()
        #expect(h.transport.writes("/like/like").isEmpty && h.transport.writes("/like/removelike").isEmpty,
                "like + unlike before it was sent: nothing to send")
        #expect(!h.model.player.isLiked(Self.newSong))
        h.writer.setLiked([Self.newSong], true)
        h.writer.setLiked([Self.newSong], false)
        h.writer.setLiked([Self.newSong], true)
        await h.writer.idle()
        #expect(h.transport.writes("/like/like").count == 1)
        #expect(h.transport.writes("/like/removelike").isEmpty)
    }

    @Test func aFailedLikeRollsBackWithTryAgain() async throws {
        let h = try await Self.makeHarness()
        h.transport.enqueue("/like/like", .init(status: 500))
        h.writer.setLiked([Self.newSong], true)
        #expect(h.model.player.isLiked(Self.newSong))
        await h.writer.idle()
        #expect(!h.model.player.isLiked(Self.newSong), "taken back off the screen")
        #expect(h.model.toast?.message == QTLoc.tr("Couldn’t like “%@”", table: .live, "New Song"))
        #expect(h.model.toast?.actionTitle == QTLoc.tr("Try Again", table: .live))
        h.model.toast?.undo?()
        await h.writer.idle()
        #expect(h.model.player.isLiked(Self.newSong))
        #expect(h.transport.writes("/like/like").count == 2)
    }

    @Test func aLikeOnItsWayOutlivesLikedSongsPaging() async throws {
        let h = try await Self.makeHarness()
        h.transport.holdsLikes = true
        h.writer.setLiked([Self.newSong], true)
        await Self.waitUntil("like sent") { !h.transport.writes("/like/like").isEmpty }
        // Liked Songs reloads (without the song: YouTube hasn't answered yet).
        await h.store.loadLiked(force: true)
        #expect(h.model.player.isLiked(Self.newSong), "the page doesn't clobber the pending like")
        await h.transport.gate.open()
        await h.writer.idle()
        #expect(h.model.player.isLiked(Self.newSong))
        #expect(h.model.catalog.liked.tracks?.first?.videoId == "vidNew001")
    }

    @Test func rowsThatSayLikedCountEvenPastThePagingLimit() async throws {
        let h = try await Self.makeHarness()
        await h.store.loadPlaylist("VLPLowned")
        #expect(h.model.player.likedTrackIDs.contains("vidOwned001"), "its row says LIKE")
        #expect(!h.model.player.likedTrackIDs.contains("vidOwned002"))
    }

    @Test func theBotCheckPausesWrites() async throws {
        let h = try await Self.makeHarness()
        h.transport.enqueue("/like/like", .init(status: 429, url: URL(string: "https://www.google.com/sorry/index?q=FAKE")))
        h.writer.setLiked([Self.newSong], true)
        await h.writer.idle()
        #expect(h.writer.isPaused)
        #expect(!h.model.player.isLiked(Self.newSong))
        #expect(h.model.toast?.message == QTLoc.tr("YouTube wants to check this connection. Changes are paused.", table: .live))
        let sent = h.transport.recorded.count
        h.writer.setLiked([Self.otherSong], true)
        await h.writer.idle()
        #expect(h.transport.recorded.count == sent, "nothing goes out while paused")
        #expect(!h.model.player.isLiked(Self.otherSong))
        h.model.toast?.undo?() // Try Again: both changes go out again.
        await h.writer.idle()
        #expect(!h.writer.isPaused)
        #expect(h.model.player.isLiked(Self.newSong))
        #expect(h.model.player.isLiked(Self.otherSong))
    }

    // MARK: Sync off

    @Test func withSyncOffLikesStayOnThisMac() async throws {
        let h = try await Self.makeHarness(sync: false)
        #expect(!h.writer.syncsToAccount && !h.writer.savesToAccount)
        let before = h.transport.recorded.count
        QTTrackActions.toggleLike([Self.newSong], model: h.model, writer: h.writer)
        #expect(h.model.player.isLiked(Self.newSong))
        #expect(h.model.toast?.message == QTLoc.tr("Liked on this Mac", table: .live))
        await h.writer.idle()
        #expect(h.transport.recorded.count == before, "nothing is sent")
        #expect(h.edits.local["LM"]?.added == ["vidNew001"])
        // Turning it back on doesn't push this Mac's likes anywhere.
        h.model.settings.update { $0.syncsToYouTubeMusic = true }
        await h.writer.idle()
        #expect(h.transport.writes("/like/like").isEmpty)
        #expect(h.model.player.isLiked(Self.newSong))
    }

    @Test func localChangesSurviveARelaunch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qt-local-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = QTPlaylistEdits(storageURL: url)
        first.remember([Self.newSong])
        first.setLike(.local, "vidNew001", true)
        first.setLike(.local, "vidGone", false)
        first.addCreated(QTPlaylist(id: "local:1", title: .verbatim("Mine"), tracks: [Self.otherSong]))
        first.setFlag(.local, "saved:OLAK5uy_fake", true)
        first.setLike(.pending, "vidPending", true)

        let relaunched = QTPlaylistEdits(storageURL: url)
        #expect(relaunched.likedIDs(base: ["vidGone"]) == ["vidNew001"])
        #expect(relaunched.track("vidNew001", catalog: QTMockCatalog(tracks: [], liked: QTPlaylist(id: "LM", title: .verbatim(""))))?.title == "New Song")
        #expect(relaunched.created.map(\.id) == ["local:1"])
        #expect(relaunched.flag("saved:OLAK5uy_fake") == true)
        #expect(relaunched.pendingLike("vidPending") == nil, "pending writes are never saved")
        // Another identity has its own.
        relaunched.use(profile: "100000000000000000001")
        #expect(relaunched.likedIDs(base: []).isEmpty)
        relaunched.use(profile: "main")
        #expect(relaunched.likedIDs(base: []) == ["vidNew001"])
    }

    // MARK: Playlists

    @Test func ownedPlaylistAddRemoveAndReorder() async throws {
        let h = try await Self.makeHarness()
        await h.store.loadPlaylist("VLPLowned")
        let owned = try #require(h.store.playlist("VLPLowned"))
        #expect(h.writer.canEdit(owned))
        h.transport.enqueue("/browse/edit_playlist", .init(body: Self.fixture("handbuilt-edit-playlist-add")))
        let added = h.writer.add([Self.newSong, Self.otherSong, owned.tracks![0]], to: owned)
        #expect(added.map(\.videoId) == ["vidNew001", "vidNew002"], "a song already there isn't added again")
        #expect(h.writer.rows(of: owned).map(\.videoId).suffix(2) == ["vidNew001", "vidNew002"], "shown at once")
        await h.writer.idle()
        let rows = try #require(h.store.playlist("VLPLowned")?.tracks)
        #expect(rows.suffix(2).map(\.setVideoId) == ["SETNEW001", "SETNEW002"], "new rows keep their entry ids")

        h.writer.remove([rows[1]], from: owned)
        #expect(!h.writer.rows(of: owned).contains { $0.videoId == "vidOwned002" })
        await h.writer.idle()
        let remove = try #require(h.transport.writes("/browse/edit_playlist").last)
        #expect(remove["actions"][0]["action"].string == "ACTION_REMOVE_VIDEO")
        #expect(remove["actions"][0]["setVideoId"].string == "SETID002")
        #expect(remove["actions"][0]["removedVideoId"].string == "vidOwned002")

        // Drag "Song Three" to the top.
        let three = try #require(h.writer.rows(of: owned).first { $0.videoId == "vidOwned003" })
        h.writer.move([three], in: owned, to: 0)
        #expect(h.writer.rows(of: owned).first?.videoId == "vidOwned003")
        await h.writer.idle()
        let move = try #require(h.transport.writes("/browse/edit_playlist").last)["actions"][0]
        #expect(move["action"].string == "ACTION_MOVE_VIDEO_BEFORE")
        #expect(move["setVideoId"].string == "SETID003")
        #expect(move["movedSetVideoIdSuccessor"].string == "SETID001")
        #expect(h.store.playlist("VLPLowned")?.tracks?.first?.videoId == "vidOwned003")
        #expect(h.edits.pending.isEmpty)
    }

    @Test func aFailedRemovalPutsTheSongBack() async throws {
        let h = try await Self.makeHarness()
        await h.store.loadPlaylist("VLPLowned")
        let owned = try #require(h.store.playlist("VLPLowned"))
        h.transport.enqueue("/browse/edit_playlist", .init(body: Data(#"{"status":"STATUS_FAILED"}"#.utf8)))
        h.writer.remove([owned.tracks![0]], from: owned)
        await h.writer.idle()
        #expect(h.writer.rows(of: owned).first?.videoId == "vidOwned001")
        #expect(h.model.toast?.actionTitle == QTLoc.tr("Try Again", table: .live))
    }

    @Test func aNewPlaylistShowsAtOnceThenTakesItsRealID() async throws {
        let h = try await Self.makeHarness()
        let placeholder = try #require(h.writer.create(title: "Queue · Oct 20", description: "", privacy: .private,
                                                       tracks: [Self.newSong], opens: false))
        #expect(placeholder.id.hasPrefix("pending:"))
        #expect(h.edits.playlists(h.model.catalog.playlists).map(\.title.resolved) == ["Queue · Oct 20"])
        #expect(h.store.playlistPhase(placeholder.id) == .loaded)
        await h.writer.idle()
        let create = try #require(h.transport.writes("/playlist/create").first)
        #expect(create["videoIds"].array.map(\.string) == ["vidNew001"])
        #expect(h.model.catalog.playlists.first?.id == "VLPLcreated")
        #expect(h.model.catalog.playlists.first?.isEditable == true)
        #expect(h.edits.created.isEmpty)
        #expect(h.edits.playlists(h.model.catalog.playlists).map(\.id).first == "VLPLcreated")
    }

    @Test func renameAndDelete() async throws {
        let h = try await Self.makeHarness()
        await h.store.loadPlaylist("VLPLowned")
        let owned = try #require(h.store.playlist("VLPLowned"))
        h.writer.editDetails(owned, title: "Long Drive", description: "Songs for the drive", privacy: .unlisted)
        #expect(h.store.playlist("VLPLowned")?.title == .verbatim("Long Drive"), "renamed at once")
        await h.writer.idle()
        let rename = try #require(h.transport.writes("/browse/edit_playlist").last)["actions"].array
        #expect(rename.map { $0["action"].string } == ["ACTION_SET_PLAYLIST_NAME"], "only what changed")
        h.writer.delete(owned)
        #expect(h.store.playlist("VLPLowned") == nil, "gone at once")
        await h.writer.idle()
        #expect(h.transport.writes("/playlist/delete").first?["playlistId"].string == "PLowned")
    }

    @Test func savedAlbumsAndSubscriptions() async throws {
        let h = try await Self.makeHarness()
        h.writer.setSaved(true, playlistID: "OLAK5uy_fakeAlbum", title: "Album A")
        #expect(h.writer.isSaved("OLAK5uy_fakeAlbum") == true)
        h.writer.setSubscribed(true, channelID: "UCartistA0000000000000000", name: "Artist A")
        #expect(h.writer.isSubscribed("UCartistA0000000000000000") == true)
        await h.writer.idle()
        #expect(h.transport.writes("/like/like").first?[path: "target", "playlistId"].string == "OLAK5uy_fakeAlbum")
        #expect(h.store.savedStates["OLAK5uy_fakeAlbum"] == true)
        #expect(h.store.subscriptions["UCartistA0000000000000000"] == true)
    }

    // MARK: Brand accounts

    @Test func switchingToABrandAccountWaitsForThePlayerPage() async throws {
        let h = try await Self.makeHarness()
        let switcher = FakeSwitcher()
        h.store.auth.identitySwitcher = switcher
        await h.store.loadIdentities()
        #expect(h.store.identities.count == 3)
        let brand = try #require(h.store.identities.first { $0.brandId == "100000000000000000001" })

        switcher.fails = true
        await h.store.switchIdentity(to: brand)
        #expect(h.store.auth.brandAccountId == nil, "not confirmed: nothing changes")
        #expect(await h.store.auth.sessionStore.credentials()?.onBehalfOfUser == nil)
        #expect(h.model.toast?.message == QTLoc.tr("Couldn’t switch to %@", table: .live, "Alex Rivera Music"))

        switcher.fails = false
        await h.store.switchIdentity(to: brand)
        #expect(switcher.calls.last?.1 == "100000000000000000001")
        #expect(switcher.calls.last?.0.query?.contains("pageid=100000000000000000001") == true)
        #expect(h.store.auth.brandAccountId == "100000000000000000001")
        #expect(await h.store.auth.sessionStore.credentials()?.onBehalfOfUser == "100000000000000000001")
        await Self.waitUntil("library reloaded") { h.store.mode == .live && h.store.likedPhase == .loaded }
        // A link that isn't YouTube's own switch page is never followed.
        let spoofed = try #require(h.store.identities.first { $0.name == "Spoofed" })
        await h.store.switchIdentity(to: spoofed)
        #expect(h.store.auth.brandAccountId == "100000000000000000001")
    }

    // MARK: Settings

    @Test func syncIsOnByDefault() throws {
        #expect(QTSettings().syncsToYouTubeMusic)
        #expect(try JSONDecoder().decode(QTSettings.self, from: Data("{}".utf8)).syncsToYouTubeMusic)
        #expect(try !JSONDecoder().decode(QTSettings.self, from: Data(#"{"syncsToYouTubeMusic":false}"#.utf8)).syncsToYouTubeMusic)
    }
}
