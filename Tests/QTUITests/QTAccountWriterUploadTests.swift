import Foundation
import QTCore
import QTInnerTube
import Testing
@testable import QTUI

/// Regressions from the final review of account writes and this Mac's changes: uploads that read the playlist first
/// and clear each change only once it landed, unlikes the app can't see in Liked Songs, DEBUG / scripted runs that
/// keep nothing, a launch question whose Esc decides nothing, the provisional profile before the account is known,
/// legacy profiles merged (and backed up), stale "not liked" rows, Undo of one copy of a duplicated song, and Siri's
/// answer while accounts switch. Same fake transport as `QTAccountWriterTests`: nothing reaches YouTube.
extension QTAccountWriterTests {
    static func tempLibraryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("qt-upload-\(UUID().uuidString)/LocalLibrary.json")
    }

    static func upload(_ h: Harness) async {
        h.writer.askAboutLocalChanges = { _, _ in .upload }
        h.writer.setSync(true)
        await waitUntil("sync on") { h.model.settings.settings.syncsToYouTubeMusic }
        await h.writer.idle()
    }

    // MARK: Uploads

    @Test func anUploadReadsThePlaylistFirst() async throws {
        let h = try await Self.makeHarness(sync: false)
        #expect(h.store.playlistPhase("VLPLowned") == .idle, "not opened this session")
        h.edits.remember([Self.newSong])
        // Made with Sync off: "Song Three" to the top, a song it already holds and a new one added.
        h.edits.edit(.local, "VLPLowned") { c in
            c.added = ["vidOwned002", "vidNew001"]
            c.order = ["SETID003", "SETID001", "SETID002", "vidNew001"]
            c.removed = ["vidGoneAlready"]
        }
        h.transport.enqueue("/browse/edit_playlist", .init(body: Self.fixture("handbuilt-edit-playlist-add")))
        await Self.upload(h)
        let actions = Self.actions(h)
        let adds = actions.filter { $0["action"].string == "ACTION_ADD_VIDEO" }
        #expect(adds.map { $0["addedVideoId"].string } == ["vidNew001"], "a song already there isn't added twice")
        #expect(!actions.contains { $0["action"].string == "ACTION_REMOVE_VIDEO" }, "a row already gone needs no write")
        let moves = actions.filter { $0["action"].string == "ACTION_MOVE_VIDEO_BEFORE" }
        #expect(moves.count == 1)
        #expect(moves.first?["setVideoId"].string == "SETID003")
        #expect(moves.first?["movedSetVideoIdSuccessor"].string == "SETID001")
        #expect(h.store.playlist("VLPLowned")?.tracks?.map(\.videoId)
                == ["vidOwned003", "vidOwned001", "vidOwned002", "vidNew001"], "the whole playlist, in order")
        #expect(h.edits.local["VLPLowned"] == nil, "done: nothing left on this Mac")
    }

    @Test func aFailedUploadKeepsTheChangeSavedUntilItLands() async throws {
        let url = Self.tempLibraryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let h = try await Self.makeHarness(sync: false, edits: QTPlaylistEdits(storageURL: url))
        h.writer.setLiked([Self.newSong], true)
        h.edits.edit(.local, "VLPLowned") { $0.removedEntries = ["SETID002": "vidOwned002"] }
        h.transport.enqueue("/like/like", .init(status: 500))
        h.transport.enqueue("/browse/edit_playlist", .init(body: Data(#"{"status":"STATUS_FAILED"}"#.utf8)))
        await Self.upload(h)
        #expect(h.edits.local["LM"]?.added == ["vidNew001"], "the like stays on this Mac")
        #expect(h.edits.local["VLPLowned"]?.removedEntries == ["SETID002": "vidOwned002"], "the removal too")
        #expect(h.model.player.isLiked(Self.newSong), "still on screen")
        let relaunched = QTPlaylistEdits(storageURL: url)
        relaunched.use(profile: h.edits.profile, reload: true)
        #expect(relaunched.local["LM"]?.added == ["vidNew001"], "and saved: a quit loses nothing")
        #expect(relaunched.local["VLPLowned"] != nil)
        // Uploaded again (the question at the next launch): once they land, they're gone from the file as well.
        h.writer.uploadLocalChanges()
        await h.writer.idle()
        #expect(h.transport.writes("/like/like").count == 2)
        #expect(Self.actions(h).last?["setVideoId"].string == "SETID002")
        #expect(!h.edits.hasLocalChanges)
        let after = QTPlaylistEdits(storageURL: url)
        after.use(profile: h.edits.profile, reload: true)
        #expect(!after.hasLocalChanges)
    }

    @Test func anUnlikeIsUploadedThoughLikedSongsDoesntShowTheSong() async throws {
        let h = try await Self.makeHarness(sync: false)
        // Unliked here while Liked Songs had it; this launch's Liked Songs stops short of it.
        h.edits.setLike(.local, "vidPastTheCap", false)
        #expect(!h.writer.accountLikes.contains("vidPastTheCap"))
        await Self.upload(h)
        #expect(h.transport.writes("/like/removelike").map { $0[path: "target", "videoId"].string } == ["vidPastTheCap"])
        #expect(!h.edits.hasLocalChanges)
    }

    @Test func aPlaylistMadeHereStaysUntilYouTubeMadeIt() async throws {
        let h = try await Self.makeHarness(sync: false)
        let made = try #require(h.writer.create(title: "Mine", description: "", privacy: .private, tracks: [Self.newSong],
                                                opens: false))
        h.transport.enqueue("/playlist/create", .init(status: 500))
        await Self.upload(h)
        #expect(h.edits.created.map(\.id) == [made.id], "still here after the failure")
        h.model.toast?.undo?()
        await h.writer.idle()
        #expect(h.edits.created.isEmpty)
        #expect(h.transport.writes("/playlist/create").count == 2)
        #expect(h.model.catalog.playlists.first?.id == "VLPLcreated")
    }

    // MARK: DEBUG and scripted runs; the launch question

    @Test func debugAndScriptedRunsKeepNoChanges() {
        func launch(_ args: [String: String]) -> QTLaunchOptions { QTLaunchOptions(arguments: args) }
        #expect(QTLiveCatalogStore.savesLocalChanges(launch([:]), isDebugBuild: false), "release, launched normally")
        #expect(!QTLiveCatalogStore.savesLocalChanges(launch([:]), isDebugBuild: true), "DEBUG: shares the release file")
        #expect(!QTLiveCatalogStore.savesLocalChanges(launch(["qt.section": "liked"]), isDebugBuild: false))
        #expect(!QTLiveCatalogStore.savesLocalChanges(launch(["qt.account.sync": "NO"]), isDebugBuild: false))
        #expect(!QTLiveCatalogStore.savesLocalChanges(launch(["qt.account.sync": "YES"]), isDebugBuild: true))
    }

    @Test func notNowAtLaunchDecidesNothing() async throws {
        let edits = QTPlaylistEdits()
        edits.setLike(.local, "vidKept", true)
        var asked = 0
        let h = try await Self.makeHarness(edits: edits) { _, store in
            store.writer.askAboutLocalChanges = { _, turningOn in
                if !turningOn { asked += 1 }
                return .cancel
            }
        }
        await Self.waitUntil("asked") { asked == 1 }
        #expect(h.model.settings.settings.syncsToYouTubeMusic, "Esc doesn't turn Sync off")
        #expect(h.edits.local["LM"]?.added == ["vidKept"], "nor discard anything")
        #expect(h.transport.writes("/like/like").isEmpty)
        // The next launch asks again.
        await h.writer.reconcileLocalChanges()
        #expect(asked == 2)
    }

    // MARK: Provisional profile, legacy profiles

    @Test func changesBeforeTheAccountIsKnownAreSavedAndJoinIt() throws {
        let url = Self.tempLibraryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // 0.1.1 kept this Mac's changes under "main".
        QTPlaylistEdits(storageURL: url).setLike(.local, "vidFrom011", true)
        // An offline launch: the session from 0.1.1 has no account key.
        let offline = QTPlaylistEdits(storageURL: url)
        offline.use(profile: nil, reload: true)
        offline.use(profile: QTLiveCatalogStore.localProfile(accountKey: nil, brand: nil))
        #expect(offline.likedIDs(base: []) == ["vidFrom011"], "the earlier changes show")
        offline.setLike(.local, "vidOffline", true)
        // Quit, relaunch online: the account is known.
        let online = QTPlaylistEdits(storageURL: url)
        online.use(profile: nil, reload: true)
        online.use(profile: QTLiveCatalogStore.localProfile(accountKey: "acct-a", brand: nil))
        #expect(online.likedIDs(base: []) == ["vidFrom011", "vidOffline"], "nothing made offline was lost")
        let again = QTPlaylistEdits(storageURL: url)
        again.use(profile: "main", reload: true)
        #expect(!again.hasLocalChanges, "the provisional profile joined the account")
    }

    @Test func legacyProfilesMergeAndAreBackedUp() throws {
        let url = Self.tempLibraryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = QTPlaylistEdits(storageURL: url)
        writer.setLike(.local, "vidLegacy", true)
        writer.edit(.local, "VLPLowned") { $0.title = "Old Name" }
        writer.use(profile: "acct-a", reload: true)
        writer.setLike(.local, "vidAccount", true)
        writer.edit(.local, "VLPLowned") { $0.title = "New Name" }

        let edits = QTPlaylistEdits(storageURL: url)
        edits.migrateLegacyProfiles(to: "acct-a")
        edits.use(profile: "acct-a", reload: true)
        #expect(edits.likedIDs(base: []) == ["vidLegacy", "vidAccount"], "merged, not dropped")
        #expect(edits.local["VLPLowned"]?.title == "New Name", "the account's own change wins")
        let backup = try String(contentsOf: QTPlaylistEdits.legacyBackupURL(for: url), encoding: .utf8)
        #expect(backup.contains("vidLegacy") && backup.contains("main → acct-a"))
    }

    // MARK: Stale rows

    @Test func aStaleNotLikedRowKeepsALike() async throws {
        let h = try await Self.makeHarness()
        var row = try #require(h.model.catalog.liked.tracks?.first)
        #expect(h.model.player.isLiked(row))
        // An album page from the cache, read before the song was liked elsewhere.
        row.likeStatus = .indifferent
        h.writer.noteLikeStatus([row])
        #expect(h.model.player.isLiked(row))
        #expect(h.writer.accountLikes.contains(row.videoId))
    }

    // MARK: Undo of one copy

    @Test func undoPutsBackOneCopyOfADuplicatedSong() async throws {
        let h = try await Self.makeHarness()
        await h.store.loadPlaylist("VLPLdup")
        let p = try #require(h.store.playlist("VLPLdup"))
        let first = try #require(h.writer.rows(of: p).first)
        #expect(first.setVideoId == "SETID001")
        QTTrackActions.remove([first], from: p, model: h.model, writer: h.writer)
        await h.writer.idle()
        let undo = try #require(h.model.toast?.undo)
        let added = #"{"status":"STATUS_SUCCEEDED","playlistEditResults":[{"playlistEditVideoAddedResultData":{"videoId":"vidOwned001","setVideoId":"SETNEW009"}}]}"#
        h.transport.enqueue("/browse/edit_playlist", .init(body: Data(added.utf8)))
        undo()
        let shown = h.writer.rows(of: p)
        #expect(shown.map(\.videoId) == ["vidOwned001", "vidOwned002", "vidOwned001"], "back at once, in its place")
        #expect(shown.first?.setVideoId == nil)
        await h.writer.idle()
        let actions = Self.actions(h)
        let add = try #require(actions.first { $0["action"].string == "ACTION_ADD_VIDEO" })
        #expect(add["addedVideoId"].string == "vidOwned001")
        #expect(add["dedupeOption"].string == "DEDUPE_OPTION_SKIP")
        let move = try #require(actions.last)
        #expect(move["action"].string == "ACTION_MOVE_VIDEO_BEFORE")
        #expect(move["setVideoId"].string == "SETNEW009", "the new copy moves, not the one that stayed")
        #expect(move["movedSetVideoIdSuccessor"].string == "SETID002")
        #expect(h.store.playlist("VLPLdup")?.tracks?.map(\.setVideoId) == ["SETNEW009", "SETID002", "SETID003"])
    }

    @Test func withSyncOffUndoShowsTheCopyAgainInPlace() async throws {
        let h = try await Self.makeHarness(sync: false)
        await h.store.loadPlaylist("VLPLdup")
        let p = try #require(h.store.playlist("VLPLdup"))
        let before = h.writer.rows(of: p)
        QTTrackActions.remove([before[0]], from: p, model: h.model, writer: h.writer)
        #expect(h.writer.rows(of: p).map(\.setVideoId) == ["SETID002", "SETID003"])
        h.model.toast?.undo?()
        #expect(h.writer.rows(of: p).map(\.setVideoId) == before.map(\.setVideoId))
        #expect(h.edits.local["VLPLdup"] == nil)
        await h.writer.idle()
        #expect(Self.actions(h).isEmpty)
    }

    // MARK: Siri

    @Test func likeCurrentSongSaysWhenAccountsAreSwitching() async throws {
        let switcher = FakeSwitcher()
        let h = try await Self.makeHarness(switcher: switcher)
        await h.store.loadIdentities()
        let brand = try #require(h.store.identities.first { $0.brandId == Self.brandID })
        let gate = Gate()
        switcher.gate = gate
        let switching = Task { await h.store.switchIdentity(to: brand) }
        await Self.waitUntil("switching") { h.store.switchingIdentity != nil }
        #expect(QTScripting.like(Self.newSong, player: h.model.player, store: h.store) == .switchingAccounts)
        await gate.open()
        await switching.value
        await Self.waitUntil("library reloaded") { h.store.mode == .live && h.store.likedPhase == .loaded }
        #expect(QTScripting.like(Self.newSong, player: h.model.player, store: h.store) == .liked("New Song"))
    }
}
