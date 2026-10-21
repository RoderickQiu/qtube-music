import Foundation
import QTAuth
import QTCore
import QTInnerTube
import Testing
@testable import QTUI

/// Regressions from the account-writes review: identities across sign-ins and offline launches, Undo of an add,
/// Sync turning on over this Mac's changes, placeholder playlists, paging over confirmed writes, per-account local
/// changes, reset vs queued writes, duplicate rows, launch defaults for Sync, unliked songs, upload links, reorders
/// that can't find their place. Same fake transport and switcher as `QTAccountWriterTests`: nothing reaches YouTube.
extension QTAccountWriterTests {
    static let brandID = "100000000000000000001"

    static func edits(_ h: Harness, _ suffix: String = "/browse/edit_playlist") -> [QTJSON] {
        h.transport.writes(suffix)
    }

    static func actions(_ h: Harness) -> [QTJSON] {
        h.transport.writes("/browse/edit_playlist").flatMap(\.["actions"].array)
    }

    // MARK: 1–2 Identities

    @Test func aNewSessionDropsTheOldBrandAccount() async throws {
        let switcher = FakeSwitcher()
        let h = try await Self.makeHarness(switcher: switcher)
        await h.store.loadIdentities()
        let brand = try #require(h.store.identities.first { $0.brandId == Self.brandID })
        await h.store.switchIdentity(to: brand)
        #expect(h.store.auth.brandAccountId == Self.brandID)
        // Another login is imported: it starts as its own Google account, not the old brand account.
        try await h.store.auth.importSession(cookies: Self.fakeLogin)
        #expect(h.store.auth.brandAccountId == nil)
        #expect(await h.store.auth.sessionStore.credentials()?.onBehalfOfUser == nil)
    }

    @Test func anUnreachableSwitchKeepsTheSavedBrandAndTriesAgain() async throws {
        let switcher = FakeSwitcher()
        switcher.fails = true
        switcher.error = .timedOut
        let h = try await Self.makeHarness(brand: Self.brandID, switcher: switcher) { _, store in
            store.identityRetryDelays = [.milliseconds(400)]
        }
        await Self.waitUntil("session-only fallback") { h.store.auth.brandAccountId == nil }
        #expect(await h.store.auth.savedBrandAccountId() == Self.brandID, "the Keychain keeps the brand account")
        #expect(await h.store.auth.sessionStore.credentials()?.onBehalfOfUser == nil, "this session acts as the account")
        switcher.fails = false
        await Self.waitUntil("back on the brand account") { h.store.auth.brandAccountId == Self.brandID }
        #expect(await h.store.auth.sessionStore.credentials()?.onBehalfOfUser == Self.brandID)
    }

    @Test func aFailedAccountListKeepsTheSavedBrand() async throws {
        let h = try await Self.makeHarness(brand: Self.brandID, switcher: FakeSwitcher()) { transport, store in
            transport.enqueue("/account/accounts_list", .init(status: 500))
            store.identityRetryDelays = []
        }
        await Self.waitUntil("fallback") { h.store.auth.brandAccountId == nil }
        #expect(await h.store.auth.savedBrandAccountId() == Self.brandID)
    }

    @Test func aRefusedSwitchFallsBackForGood() async throws {
        let switcher = FakeSwitcher()
        switcher.fails = true
        let h = try await Self.makeHarness(brand: Self.brandID, switcher: switcher)
        await Self.waitUntil("fallback") { h.store.auth.brandAccountId == nil }
        await h.writer.idle()
        for _ in 0..<100 where await h.store.auth.savedBrandAccountId() != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await h.store.auth.savedBrandAccountId() == nil)
    }

    // MARK: 3 Undo of an add

    @Test func undoingAnAddWorksForAPlaylistThatIsntLoaded() async throws {
        let h = try await Self.makeHarness()
        let owned = QTPlaylist(id: "VLPLowned", title: .verbatim("Road Trip"), kind: .user, isEditable: true)
        h.transport.enqueue("/browse/edit_playlist", .init(body: Self.fixture("handbuilt-edit-playlist-add")))
        QTTrackActions.add([Self.newSong], to: owned, model: h.model, writer: h.writer)
        await h.writer.idle()
        let undo = try #require(h.model.toast?.undo)
        undo()
        await h.writer.idle()
        let remove = try #require(Self.actions(h).last)
        #expect(remove["action"].string == "ACTION_REMOVE_VIDEO")
        #expect(remove["setVideoId"].string == "SETNEW001", "the entry id YouTube gave the add")
        #expect(remove["removedVideoId"].string == "vidNew001")
    }

    // MARK: 4 Sync turning on

    @Test func turningSyncOnUploadsThisMacsChanges() async throws {
        let h = try await Self.makeHarness(sync: false)
        h.writer.setLiked([Self.newSong], true)
        h.writer.setSaved(true, playlistID: "OLAK5uy_fakeAlbum", title: "Album A")
        #expect(h.edits.localChangeCount == 2)
        var asked: (Int, Bool)?
        h.writer.askAboutLocalChanges = { count, turningOn in asked = (count, turningOn); return .upload }
        h.writer.setSync(true)
        await Self.waitUntil("sync on") { h.model.settings.settings.syncsToYouTubeMusic }
        await h.writer.idle()
        #expect(asked?.0 == 2 && asked?.1 == true)
        #expect(h.transport.writes("/like/like").map { $0[path: "target", "videoId"].string }.contains("vidNew001"))
        #expect(h.transport.writes("/like/like").contains { $0[path: "target", "playlistId"].string == "OLAK5uy_fakeAlbum" })
        #expect(!h.edits.hasLocalChanges)
        #expect(h.model.player.isLiked(Self.newSong))
    }

    @Test func turningSyncOnCanDiscardOrCancel() async throws {
        let h = try await Self.makeHarness(sync: false)
        h.writer.setLiked([Self.newSong], true)
        h.writer.askAboutLocalChanges = { _, _ in .cancel }
        h.writer.setSync(true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!h.model.settings.settings.syncsToYouTubeMusic, "Cancel leaves Sync off")
        #expect(h.edits.hasLocalChanges)
        h.writer.askAboutLocalChanges = { _, _ in .discard }
        h.writer.setSync(true)
        await Self.waitUntil("sync on") { h.model.settings.settings.syncsToYouTubeMusic }
        await h.writer.idle()
        #expect(!h.edits.hasLocalChanges)
        #expect(!h.model.player.isLiked(Self.newSong))
        #expect(h.transport.writes("/like/like").isEmpty)
    }

    @Test func aWriteSupersedesThisMacsChangeForTheSameSong() async throws {
        let h = try await Self.makeHarness(sync: false)
        h.writer.setLiked([Self.newSong], true)
        // Sync on without the question (a launch override): the next change of that song is the account's.
        h.model.settings.update { $0.syncsToYouTubeMusic = true }
        h.writer.setLiked([Self.newSong], false)
        await h.writer.idle()
        #expect(h.edits.local["LM"] == nil)
        #expect(!h.model.player.isLiked(Self.newSong))
    }

    // MARK: 5 Placeholders

    @Test func editsToANewPlaylistFollowItToTheAccount() async throws {
        let h = try await Self.makeHarness()
        let placeholder = try #require(h.writer.create(title: "Mix", description: "", privacy: .private,
                                                       tracks: [Self.newSong], opens: false))
        // Before YouTube has answered.
        h.writer.add([Self.otherSong], to: placeholder)
        h.writer.editDetails(placeholder, title: "Weekend Mix")
        #expect(h.store.playlist(placeholder.id)?.title.resolved == "Weekend Mix")
        #expect(h.writer.rows(of: placeholder).map(\.videoId) == ["vidNew001", "vidNew002"])
        #expect(h.edits.local.isEmpty, "nothing filed under the placeholder")
        await h.writer.idle()
        #expect(h.transport.writes("/playlist/create").first?["videoIds"].array.map(\.string) == ["vidNew001"])
        let edits = Self.edits(h)
        #expect(edits.allSatisfy { $0["playlistId"].string == "PLcreated" })
        let actions = Self.actions(h)
        #expect(actions.contains { $0["action"].string == "ACTION_ADD_VIDEO" && $0["addedVideoId"].string == "vidNew002" })
        #expect(actions.contains { $0["action"].string == "ACTION_SET_PLAYLIST_NAME" && $0["playlistName"].string == "Weekend Mix" })
        #expect(h.store.playlist("VLPLcreated")?.title.resolved == "Weekend Mix")
        #expect(h.edits.created.isEmpty)
    }

    @Test func deletingANewPlaylistBeforeItsMadeDeletesItInTheAccount() async throws {
        let h = try await Self.makeHarness()
        let placeholder = try #require(h.writer.create(title: "Oops", description: "", privacy: .private,
                                                       tracks: [Self.newSong], opens: false))
        h.writer.delete(placeholder)
        await h.writer.idle()
        #expect(h.transport.writes("/playlist/delete").first?["playlistId"].string == "PLcreated")
        #expect(!h.model.catalog.playlists.contains { $0.id == "VLPLcreated" })
    }

    @Test func earlierBuildsPlaceholderEditsAreDroppedOnLoad() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qt-local-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let json = #"{"main":{"local":{"pending:ABC":{"added":["vidNew001"]},"VLPLowned":{"title":"Kept"}},"created":[],"flags":{},"tracks":{}}}"#
        try Data(json.utf8).write(to: url)
        let edits = QTPlaylistEdits(storageURL: url)
        #expect(edits.local.keys.sorted() == ["VLPLowned"])
    }

    // MARK: 6 Paging

    @Test func laterPagesKeepWritesConfirmedMeanwhile() async throws {
        let h = try await Self.makeHarness()
        let gate = Gate()
        h.transport.continuationGate = gate
        let loading = Task { await h.store.loadPlaylist("VLPLpaged") }
        await Self.waitUntil("first page") { h.store.playlistPhase("VLPLpaged") == .loaded }
        let firstPage = h.store.playlist("VLPLpaged")?.tracks?.count ?? 0
        h.store.confirmDetails("VLPLpaged", title: "Renamed", description: nil, privacy: nil)
        var added = Self.newSong
        added.setVideoId = "SETNEW001"
        h.store.confirmAdd([added], to: "VLPLpaged")
        await gate.open()
        await loading.value
        let p = try #require(h.store.playlist("VLPLpaged"))
        #expect(p.title.resolved == "Renamed")
        #expect((p.tracks?.count ?? 0) > firstPage + 1, "the next page arrived")
        #expect(p.tracks?.last?.videoId == "vidNew001", "the added row stays, at the end")
    }

    // MARK: 7 Per-account local changes

    @Test func accountKeysAreStableAndHashed() {
        let main = QTAccountContext.accountKey(dataSyncId: "111222333||")
        let brand = QTAccountContext.accountKey(dataSyncId: "999888777||111222333")
        #expect(main != nil && main == brand, "one key for the account and its brand accounts")
        #expect(main?.hasPrefix("acct-") == true)
        #expect(main?.contains("111222333") == false)
        #expect(QTAccountContext.accountKey(dataSyncId: "444555666||") != main)
        #expect(QTAccountContext.accountKey(dataSyncId: "") == nil)
        #expect(QTLiveCatalogStore.localProfile(accountKey: "acct-a", brand: nil) == "acct-a")
        #expect(QTLiveCatalogStore.localProfile(accountKey: "acct-a", brand: "123") == "acct-a/123")
        #expect(QTLiveCatalogStore.localProfile(accountKey: nil, brand: "123") == nil)
    }

    @Test func localChangesBelongToOneGoogleAccount() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qt-local-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        // Written before profiles were per account.
        let old = QTPlaylistEdits(storageURL: url)
        old.setLike(.local, "vidMain", true)
        old.use(profile: Self.brandID)
        old.setLike(.local, "vidBrand", true)

        let edits = QTPlaylistEdits(storageURL: url)
        edits.use(profile: nil, reload: true)
        edits.setLike(.local, "vidEarly", true) // before the account was known
        edits.migrateLegacyProfiles(to: "acct-a")
        edits.use(profile: "acct-a")
        #expect(edits.likedIDs(base: []) == ["vidMain", "vidEarly"], "the old profile, plus what was made meanwhile")
        edits.use(profile: "acct-a/\(Self.brandID)")
        #expect(edits.likedIDs(base: []) == ["vidBrand"])
        edits.use(profile: "acct-b")
        #expect(edits.likedIDs(base: []).isEmpty, "another Google account sees none of it")
        let relaunched = QTPlaylistEdits(storageURL: url)
        relaunched.use(profile: "main", reload: true)
        #expect(relaunched.likedIDs(base: []).isEmpty, "the old profile moved")
    }

    // MARK: 8 Reset

    @Test func aResetStopsQueuedWrites() async throws {
        let h = try await Self.makeHarness()
        h.transport.holdsLikes = true
        h.writer.setLiked([Self.newSong], true)
        await Self.waitUntil("first like sent") { !h.transport.writes("/like/like").isEmpty }
        h.writer.setLiked([Self.otherSong], true)
        h.writer.reset()
        await h.transport.gate.open()
        try await Task.sleep(for: .milliseconds(100))
        await h.writer.idle()
        #expect(h.transport.writes("/like/like").count == 1, "the queued like never goes out")
        #expect(h.writer.writesInFlight == 0)
        #expect(!(h.model.catalog.liked.tracks ?? []).contains { $0.videoId == "vidNew001" },
                "an answer for the old session doesn't land in the new one")
    }

    @Test func noChangeStartsWhileSwitchingIdentity() async throws {
        let switcher = FakeSwitcher()
        let h = try await Self.makeHarness(switcher: switcher)
        await h.store.loadIdentities()
        let brand = try #require(h.store.identities.first { $0.brandId == Self.brandID })
        let gate = Gate()
        switcher.gate = gate
        let switching = Task { await h.store.switchIdentity(to: brand) }
        await Self.waitUntil("switching") { h.store.switchingIdentity != nil }
        h.writer.setLiked([Self.newSong], true)
        #expect(!h.model.player.isLiked(Self.newSong))
        #expect(h.model.toast?.message == QTLoc.tr("Switching accounts. Try again in a moment.", table: .live))
        await gate.open()
        await switching.value
        #expect(h.transport.writes("/like/like").isEmpty)
    }

    // MARK: 9 Duplicates

    @Test func oneCopyOfADuplicatedSongIsRemovedAndMovedAlone() async throws {
        let h = try await Self.makeHarness()
        await h.store.loadPlaylist("VLPLdup")
        let p = try #require(h.store.playlist("VLPLdup"))
        let rows = h.writer.rows(of: p)
        #expect(rows.map(\.videoId) == ["vidOwned001", "vidOwned002", "vidOwned001"])
        // Move the second copy to the top: by its own entry id.
        h.writer.move([rows[2]], in: p, to: 0)
        await h.writer.idle()
        let move = try #require(Self.actions(h).last)
        #expect(move["setVideoId"].string == "SETID003")
        #expect(move["movedSetVideoIdSuccessor"].string == "SETID001")
        // Remove that copy only.
        let copy = try #require(h.writer.rows(of: p).first)
        QTTrackActions.remove([copy], from: p, model: h.model, writer: h.writer)
        #expect(h.writer.rows(of: p).filter { $0.videoId == "vidOwned001" }.count == 1, "the other copy stays")
        await h.writer.idle()
        let remove = try #require(Self.actions(h).last)
        #expect(remove["action"].string == "ACTION_REMOVE_VIDEO")
        #expect(remove["setVideoId"].string == "SETID003")
        #expect(h.store.playlist("VLPLdup")?.tracks?.map(\.setVideoId) == ["SETID001", "SETID002"])
    }

    @Test func withSyncOffOneCopyIsHiddenAlone() async throws {
        let h = try await Self.makeHarness(sync: false)
        await h.store.loadPlaylist("VLPLdup")
        let p = try #require(h.store.playlist("VLPLdup"))
        h.writer.remove([h.writer.rows(of: p)[2]], from: p)
        #expect(h.writer.rows(of: p).map(\.videoId) == ["vidOwned001", "vidOwned002"])
        #expect(h.edits.local["VLPLdup"]?.removedEntries == ["SETID003": "vidOwned001"])
    }

    // MARK: 10 Sync off in DEBUG and scripted runs

    @Test func syncIsOffForDebugAndScriptedRuns() {
        func launch(_ args: [String: String]) -> QTLaunchOptions { QTLaunchOptions(arguments: args) }
        #expect(QTAccountWriter.launchSyncOverride(launch([:]), isDebugBuild: false) == nil, "release: the user's setting")
        #expect(QTAccountWriter.launchSyncOverride(launch([:]), isDebugBuild: true) == false)
        #expect(QTAccountWriter.launchSyncOverride(launch(["qt.readyFile": "/tmp/x.json"]), isDebugBuild: false) == false)
        #expect(QTAccountWriter.launchSyncOverride(launch(["qt.catalog": "mock"]), isDebugBuild: false) == false)
        #expect(QTAccountWriter.launchSyncOverride(launch(["qt.section": "liked"]), isDebugBuild: false) == false)
        #expect(QTAccountWriter.launchSyncOverride(launch(["qt.account.sync": "YES"]), isDebugBuild: true) == true)
        #expect(QTAccountWriter.launchSyncOverride(launch(["qt.account.sync": "NO"]), isDebugBuild: false) == false)
        // The bootstrap applies it for the session only (DEBUG test build: off).
        let model = QTAppModel.bootstrap(launch: launch(["qt.catalog": "mock", "qt.screen": "none"]))
        #expect(!model.settings.settings.syncsToYouTubeMusic)
    }

    // MARK: 11 Unliked songs

    @Test func anUnlikedSongStaysUnlikedAfterLaterReloads() async throws {
        let h = try await Self.makeHarness()
        await h.store.loadPlaylist("VLPLowned")
        #expect(h.model.player.likedTrackIDs.contains("vidOwned001"), "its row said LIKE")
        let row = try #require(h.store.playlist("VLPLowned")?.tracks?.first)
        h.writer.setLiked([row], false)
        await h.writer.idle()
        #expect(h.transport.writes("/like/removelike").count == 1)
        // Long after the confirmation, Liked Songs reloads.
        h.writer.now = { Date().addingTimeInterval(3600) }
        await h.store.loadLiked(force: true)
        #expect(!h.model.player.likedTrackIDs.contains("vidOwned001"))
    }

    // MARK: 12 Upload links

    @Test func uploadsHaveNoLinkToShare() {
        var upload = Self.newSong
        upload.isPrivatelyOwned = true
        #expect(QTTrackActions.shareableLink(for: upload) == nil)
        #expect(QTTrackActions.shareableLink(for: Self.newSong) == QTTrackActions.link(for: Self.newSong))
        #expect(!QTTrackActions.canCopyLinks([upload]))
        #expect(QTTrackActions.canCopyLinks([upload, Self.newSong]))
        let drag = QTTrackActions.dragString(for: upload)
        #expect(!drag.contains("youtube.com"))
        #expect(QTTrackActions.videoID(fromLink: drag) == "vidNew001", "this app's playlists still take the drop")
    }

    // MARK: 13, 15, 16, 17 Library, details, reorders, Undo

    @Test func removeFromLibraryAlwaysRemoves() async throws {
        let h = try await Self.makeHarness()
        // Nothing known about it yet: a toggle would have saved it.
        QTPlaylistActions.setSaved(false, id: "VLPLsaved", title: "Someone's", model: h.model, writer: h.writer)
        await h.writer.idle()
        #expect(h.transport.writes("/like/removelike").first?[path: "target", "playlistId"].string == "PLsaved")
        #expect(h.transport.writes("/like/like").isEmpty)
    }

    @Test func anUnknownPrivacyIsNeverSent() async throws {
        let h = try await Self.makeHarness()
        let p = QTPlaylist(id: "VLPLowned", title: .verbatim("Road Trip"), kind: .user, isEditable: true)
        h.writer.editDetails(p, title: "Road Trip", description: "", privacy: nil)
        await h.writer.idle()
        #expect(Self.edits(h).isEmpty, "nothing changed")
        h.writer.editDetails(p, title: "Road Trip 2")
        await h.writer.idle()
        #expect(Self.actions(h).map { $0["action"].string } == ["ACTION_SET_PLAYLIST_NAME"])
    }

    @Test func aReorderThatCantFindItsPlaceIsRefused() async throws {
        let h = try await Self.makeHarness()
        await h.store.loadPlaylist("VLPLowned")
        let owned = try #require(h.store.playlist("VLPLowned"))
        // An add YouTube confirmed without saying the new row's entry id.
        h.writer.add([Self.newSong], to: owned)
        await h.writer.idle()
        let rows = h.writer.rows(of: owned)
        #expect(rows.map(\.videoId) == ["vidOwned001", "vidOwned002", "vidOwned003", "vidNew001"])
        // "Song Two" goes in front of the new row, whose entry id nobody knows.
        h.writer.move([rows[1]], in: owned, to: 3)
        await h.writer.idle()
        #expect(!Self.actions(h).contains { $0["action"].string == "ACTION_MOVE_VIDEO_BEFORE" },
                "never moved to the end instead")
        #expect(h.model.toast?.message == QTLoc.tr("Couldn’t reorder %@", table: .live, owned.title.resolved))
    }

    @Test func undoPutsBackRowsThatCantPlay() async throws {
        let h = try await Self.makeHarness(sync: false)
        await h.store.loadPlaylist("VLPLowned")
        let owned = try #require(h.store.playlist("VLPLowned"))
        var gone = Self.otherSong
        gone.availability = .regionLocked
        #expect(h.writer.add([gone], to: owned).isEmpty, "not added from a menu")
        #expect(h.writer.add([gone], to: owned, restoring: true).map(\.videoId) == ["vidNew002"], "but Undo puts it back")
    }

    // MARK: 18 Import

    @Test func cancelStopsASessionImport() async throws {
        final class Hanging: QTHTTPTransport, @unchecked Sendable {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                try await Task.sleep(for: .seconds(30))
                throw URLError(.timedOut)
            }
        }
        let client = QTInnerTubeClient(transport: Hanging(), retry: .none, scrapesClientConfig: false, sleep: { _ in })
        let auth = QTAuthController(sessionStore: QTSessionStore(store: QTMemorySecureStore()),
                                    cookieStore: QTMemoryWebCookieStore(), client: client)
        let importing = Task { try await auth.importSession(cookies: Self.fakeLogin) }
        await Self.waitUntil("checking") { auth.state == .signingIn }
        auth.cancelSignIn()
        let result = await importing.result
        guard case .failure(let error) = result else { Issue.record("the import finished"); return }
        #expect(error is CancellationError)
        #expect(auth.state == .signedOut)
        #expect(await auth.sessionStore.current == nil, "nothing kept")
    }
}
