import Foundation
import Observation
import QTCore
import QTInnerTube

// Owner: data-live. The one way the app changes the library: likes, playlist adds / removals / reorders, new,
// renamed and deleted playlists, saved albums and playlists, subscriptions.
//
// Signed in with Settings › Account › "Sync likes and playlists to YouTube Music" on (the default), changes go to
// the account; otherwise (Sync off, the demo library) they stay on this Mac (`QTPlaylistEdits.local`, saved between
// launches). Either way they show at once. Account writes:
// - run one at a time, in the order they were made (a serial chain), never retried (QTInnerTube);
// - show at once as `QTPlaylistEdits.pending` and land in the catalog when YouTube confirms; a failure takes the
//   change back off the screen and says so in a toast with Try Again (no alert, nothing to dismiss);
// - quick like / unlike toggles of one song collapse into at most one write, and none when they cancel out;
// - pause after Google's bot check until Try Again (the app never opens or solves the check);
// - leave the cached pages they change stale (the client drops them), so the next visit reads the new state.

@MainActor
@Observable
public final class QTAccountWriter {
    public static var shared: QTAccountWriter { QTLiveCatalogStore.shared.writer }

    @ObservationIgnored public let edits: QTPlaylistEdits
    @ObservationIgnored weak var store: QTLiveCatalogStore?
    @ObservationIgnored weak var model: QTAppModel?

    /// Google's bot check answered a write: account writes wait until Try Again.
    public private(set) var isPaused = false
    /// Songs the account likes as far as the app knows (Liked Songs pages, rows' like status, confirmed writes).
    public private(set) var accountLikes: Set<String> = []
    /// Likes confirmed while Liked Songs may still be paging in (`noteLikedLoadStarted`), kept over its pages.
    @ObservationIgnored private var confirmedLikes: [String: (liked: Bool, at: Date)] = [:]
    @ObservationIgnored private var chain: Task<Void, Never>?
    @ObservationIgnored private var queuedLikes: Set<String> = []
    /// Changes the bot check turned away, redone by Try Again.
    @ObservationIgnored private var pausedRetries: [@MainActor () -> Void] = []
    @ObservationIgnored private(set) var writesInFlight = 0
    /// Last "which playlists hold these songs" answer (the Add to Playlist submenu).
    @ObservationIgnored private var optionsCache: (videoIDs: [String], options: [QTPlaylistOption], at: Date)?

    init(edits: QTPlaylistEdits) {
        self.edits = edits
    }

    func attach(model: QTAppModel, store: QTLiveCatalogStore) {
        self.model = model
        self.store = store
        if store.mode == .mock { accountLikes = Set(model.catalog.liked.tracks?.map(\.videoId) ?? []) }
        model.player.likeHandler = { [weak self] track, liked in self?.setLiked([track], liked) }
        publishLikes()
    }

    // MARK: Where changes go

    /// Signed in with Sync on: changes go to the YouTube Music account.
    public var syncsToAccount: Bool {
        store?.hasLibrary == true && model?.settings.settings.syncsToYouTubeMusic == true
    }

    /// What the wording promises: the account (syncing, or the DEBUG demo library playing the part with Sync on), or
    /// this Mac.
    public var savesToAccount: Bool {
        syncsToAccount || (store?.mode == .mock && model?.settings.settings.syncsToYouTubeMusic == true)
    }

    private var client: QTInnerTubeClient? { store?.client }

    // MARK: Likes

    public func isLiked(_ videoID: String) -> Bool { model?.player.likedTrackIDs.contains(videoID) ?? false }

    /// Likes or unlikes songs (only those that change).
    public func setLiked(_ tracks: [QTTrack], _ liked: Bool) {
        let changed = tracks.filter { isLiked($0.videoId) != liked }
        guard !changed.isEmpty else { return }
        edits.remember(changed)
        let sync = syncsToAccount
        for t in changed {
            if sync {
                edits.setLike(.pending, t.videoId, liked)
                sendLike(t)
            } else if accountLikes.contains(t.videoId) == liked {
                // Back to what the account says: no local change left to keep.
                edits.clearLike(.local, t.videoId)
            } else {
                edits.setLike(.local, t.videoId, liked)
            }
        }
        publishLikes()
    }

    /// One queued write per song: it reads the wanted state when its turn comes, so toggles made meanwhile collapse
    /// into it (or into nothing when they cancel out).
    private func sendLike(_ track: QTTrack) {
        let id = track.videoId
        guard queuedLikes.insert(id).inserted else { return }
        enqueue { [self] in
            queuedLikes.remove(id)
            guard let want = edits.pendingLike(id) else { return }
            if want == accountLikes.contains(id) {
                edits.clearLike(.pending, id)
                publishLikes()
                return
            }
            do {
                try await send { try await $0.rate(videoId: id, want ? .like : .none) }
                confirmLike(track, want)
                if edits.pendingLike(id) == want { edits.clearLike(.pending, id) }
            } catch {
                if edits.pendingLike(id) == want { edits.clearLike(.pending, id) }
                fail(error, QTLoc.tr(want ? "Couldn’t like “%@”" : "Couldn’t remove “%@” from Liked Songs", table: .live,
                                     track.title)) { [weak self] in self?.setLiked([track], want) }
            }
            publishLikes()
        }
    }

    private func confirmLike(_ track: QTTrack, _ liked: Bool) {
        if liked { accountLikes.insert(track.videoId) } else { accountLikes.remove(track.videoId) }
        confirmedLikes[track.videoId] = (liked, Date())
        store?.confirmLike(track, liked)
    }

    /// Liked Songs (re)loads from its first page: likes confirmed from now on outlive its pages.
    func noteLikedLoadStarted() -> Date {
        let now = Date()
        confirmedLikes = confirmedLikes.filter { now.timeIntervalSince($0.value.at) < 600 }
        return now
    }

    /// The account's Liked Songs as paged in since `started`, with likes confirmed after that put back.
    func likedPageLoaded(_ tracks: [QTTrack], started: Date) -> [QTTrack] {
        var list = tracks
        for (id, c) in confirmedLikes where c.at >= started {
            if c.liked, !list.contains(where: { $0.videoId == id }),
               let t = model.flatMap({ edits.track(id, catalog: $0.catalog) }) {
                list.insert(t, at: 0)
            } else if !c.liked {
                list.removeAll { $0.videoId == id }
            }
        }
        // Songs past the paging limit that their rows said are liked stay liked.
        accountLikes = Set(list.map(\.videoId)).union(likedFromRows.filter { confirmedLikes[$0]?.liked != false })
        publishLikes()
        return list
    }

    @ObservationIgnored private var likedFromRows: Set<String> = []

    /// Rows that state the account likes them (`likeStatus`), e.g. songs past Liked Songs' paging limit.
    func noteLikeStatus(_ tracks: [QTTrack]) {
        let liked = tracks.filter { $0.likeStatus == .like }.map(\.videoId)
        guard !liked.isEmpty else { return }
        let fresh = liked.filter { !accountLikes.contains($0) && confirmedLikes[$0]?.liked != false }
        likedFromRows.formUnion(liked)
        guard !fresh.isEmpty else { return }
        accountLikes.formUnion(fresh)
        publishLikes()
    }

    /// Hearts everywhere: the account's likes with this Mac's and pending ones applied.
    func publishLikes() {
        guard let model else { return }
        // Guests have no likes (the library's, or this Mac's for the account, show again after signing in).
        let ids = store?.isGuest == true ? [] : edits.likedIDs(base: accountLikes)
        if model.player.likedTrackIDs != ids { model.player.likedTrackIDs = ids }
    }

    // MARK: Playlists

    /// Whether `playlist` can be edited here: one the account owns, one made on this Mac, or (demo) any user list.
    public func canEdit(_ playlist: QTPlaylist) -> Bool {
        guard playlist.kind == .user, playlist.id != QTPlaylistEdits.likedID else { return false }
        if playlist.id.hasPrefix("local:") || playlist.id.hasPrefix("pending:") { return true }
        if store?.mode == .mock { return true }
        return store?.hasLibrary == true && playlist.isEditable == true
    }

    /// The playlist as it is now (a caller's copy may predate pages that streamed in or writes that landed).
    func latest(_ playlist: QTPlaylist) -> QTPlaylist { store?.playlist(playlist.id) ?? playlist }

    /// A playlist's rows as shown: the latest copy with this Mac's and pending changes.
    public func rows(of playlist: QTPlaylist) -> [QTTrack] {
        guard let model else { return playlist.tracks ?? [] }
        return edits.tracks(for: latest(playlist), catalog: model.catalog)
    }

    /// A playlist that lives in the account (not made on this Mac, not the demo's).
    private func isAccountPlaylist(_ playlist: QTPlaylist) -> Bool {
        !playlist.id.hasPrefix("local:") && !playlist.id.hasPrefix("pending:") && store?.mode != .mock
    }

    /// Adds the songs not already in the playlist; returns them (empty when all were already there).
    @discardableResult
    public func add(_ tracks: [QTTrack], to playlist: QTPlaylist) -> [QTTrack] {
        guard let model else { return [] }
        let present = Set(rows(of: playlist).map(\.videoId))
        var seen = present
        let fresh = tracks.filter { $0.availability.isPlayable && seen.insert($0.videoId).inserted }
        guard !fresh.isEmpty else { return [] }
        edits.remember(fresh)
        let ids = fresh.map(\.videoId)
        let id = playlist.id
        guard syncsToAccount, isAccountPlaylist(playlist) else {
            if id.hasPrefix("local:"), let p = edits.createdPlaylist(id) {
                edits.setCreatedTracks(id, (p.tracks ?? []) + fresh)
                return fresh
            }
            let base = Set((latest(playlist).tracks ?? []).map(\.videoId))
            edits.edit(.local, id) { c in
                c.removed.subtract(ids)
                c.added += ids.filter { !base.contains($0) && !c.added.contains($0) }
                if c.order != nil { c.order! += ids }
            }
            return fresh
        }
        edits.edit(.pending, id) { c in
            c.removed.subtract(ids)
            c.added += ids
        }
        enqueue { [self] in
            do {
                let results = try await send { try await $0.addToPlaylist(id, videoIds: ids) }
                let setIDs = Dictionary(results.map { ($0.videoId, $0.setVideoId) }, uniquingKeysWith: { a, _ in a })
                store?.confirmAdd(fresh.map { t in var t = t; t.setVideoId = setIDs[t.videoId]; return t }, to: id)
            } catch {
                fail(error, QTLoc.tr("Couldn’t add to %@", table: .live, playlist.title.resolved)) { [weak self] in
                    self?.add(fresh, to: playlist)
                }
            }
            edits.edit(.pending, id) { c in c.added.removeAll { ids.contains($0) } }
        }
        return fresh
    }

    /// Takes songs out of a playlist the account owns (or one made here).
    public func remove(_ tracks: [QTTrack], from playlist: QTPlaylist) {
        let ids = Set(tracks.map(\.videoId))
        guard !ids.isEmpty, canEdit(playlist) else { return }
        let id = playlist.id
        guard syncsToAccount, isAccountPlaylist(playlist) else {
            if id.hasPrefix("local:"), let p = edits.createdPlaylist(id) {
                edits.setCreatedTracks(id, (p.tracks ?? []).filter { !ids.contains($0.videoId) })
            }
            edits.edit(.local, id) { c in
                let addedHere = ids.intersection(c.added)
                c.added.removeAll { ids.contains($0) }
                if !id.hasPrefix("local:") { c.removed.formUnion(ids.subtracting(addedHere)) }
            }
            return
        }
        edits.edit(.pending, id) { c in c.removed.formUnion(ids) }
        enqueue { [self] in
            // Entry ids come from the rows as they are now (a song added a moment ago has its id by then).
            let rows = (store?.playlist(id)?.tracks ?? []).filter { ids.contains($0.videoId) }
            let items = rows.compactMap { t in t.setVideoId.map { (videoId: t.videoId, setVideoId: $0) } }
            do {
                guard !items.isEmpty else { throw QTInnerTubeError.parse("setVideoId") }
                try await send { try await $0.removeFromPlaylist(id, items: items) }
                store?.confirmRemove(Set(items.map(\.setVideoId)), from: id)
            } catch {
                fail(error, QTLoc.tr("Couldn’t remove songs from %@", table: .live, playlist.title.resolved)) { [weak self] in
                    self?.remove(tracks, from: playlist)
                }
            }
            edits.edit(.pending, id) { c in c.removed.subtract(ids) }
        }
    }

    /// Moves `moved` (in their current order) so they sit at `index` of the playlist as shown before the move.
    public func move(_ moved: [QTTrack], in playlist: QTPlaylist, to index: Int) {
        guard let model, canEdit(playlist), !moved.isEmpty else { return }
        let current = rows(of: playlist)
        let movedIDs = Set(moved.map(\.videoId))
        let before = current[..<min(max(index, 0), current.count)].filter { !movedIDs.contains($0.videoId) }.count
        var order = current.filter { !movedIDs.contains($0.videoId) }
        let block = current.filter { movedIDs.contains($0.videoId) }
        order.insert(contentsOf: block, at: before)
        guard order.map(\.videoId) != current.map(\.videoId) else { return }
        let id = playlist.id
        guard syncsToAccount, isAccountPlaylist(playlist) else {
            if id.hasPrefix("local:") {
                edits.setCreatedTracks(id, order)
            } else {
                edits.edit(.local, id) { $0.order = order.map(\.videoId) }
            }
            return
        }
        edits.edit(.pending, id) { $0.order = order.map(\.videoId) }
        enqueue { [self] in
            // Each moved row goes in front of its successor in the new order, last first, so every successor is
            // already in place.
            do {
                let rows = store?.playlist(id)?.tracks ?? []
                let setID = { (v: String) in rows.first { $0.videoId == v }?.setVideoId }
                for (i, t) in order.enumerated().reversed() where movedIDs.contains(t.videoId) {
                    guard let s = setID(t.videoId) else { throw QTInnerTubeError.parse("setVideoId") }
                    let successor = order.indices.contains(i + 1) ? setID(order[i + 1].videoId) : nil
                    try await send { try await $0.movePlaylistItem(id, setVideoId: s, before: successor) }
                }
                store?.confirmOrder(order.map(\.videoId), in: id)
            } catch {
                fail(error, QTLoc.tr("Couldn’t reorder %@", table: .live, playlist.title.resolved)) { [weak self] in
                    self?.move(moved, in: playlist, to: index)
                }
            }
            edits.edit(.pending, id) { $0.order = nil }
        }
    }

    /// Renames a playlist, changes its description or who can see it.
    public func editDetails(_ playlist: QTPlaylist, title: String, description: String, privacy: QTPlaylistPrivacy) {
        let id = playlist.id
        let newTitle = title == playlist.title.resolved ? nil : title
        let newDescription = description == (playlist.description ?? "") ? nil : description
        let newPrivacy = privacy == (playlist.privacy ?? .private) ? nil : privacy
        guard newTitle != nil || newDescription != nil || newPrivacy != nil else { return }
        guard syncsToAccount, isAccountPlaylist(playlist) else {
            edits.edit(.local, id) { c in
                if let newTitle { c.title = newTitle }
                if let newDescription { c.description = newDescription }
                if let newPrivacy { c.privacy = newPrivacy }
            }
            return
        }
        edits.edit(.pending, id) { c in
            c.title = newTitle
            c.description = newDescription
            c.privacy = newPrivacy
        }
        enqueue { [self] in
            do {
                try await send { try await $0.editPlaylistDetails(id, title: newTitle, description: newDescription,
                                                                  privacy: newPrivacy) }
                store?.confirmDetails(id, title: newTitle, description: newDescription, privacy: newPrivacy)
            } catch {
                fail(error, QTLoc.tr("Couldn’t save changes to “%@”", table: .live, playlist.title.resolved)) { [weak self] in
                    self?.editDetails(playlist, title: title, description: description, privacy: privacy)
                }
            }
            edits.edit(.pending, id) { c in c.title = nil; c.description = nil; c.privacy = nil }
        }
    }

    /// Deletes a playlist (asked first by the caller: it can't be undone).
    public func delete(_ playlist: QTPlaylist) {
        let id = playlist.id
        QTNavigator.shared.leavePlaylist(id)
        if id.hasPrefix("local:") {
            edits.removeCreated(id)
            return
        }
        guard syncsToAccount, isAccountPlaylist(playlist) else {
            edits.edit(.local, id) { $0.isDeleted = true }
            return
        }
        edits.edit(.pending, id) { $0.isDeleted = true }
        enqueue { [self] in
            do {
                try await send { try await $0.deletePlaylist(id) }
                store?.confirmDelete(id)
            } catch {
                fail(error, QTLoc.tr("Couldn’t delete “%@”", table: .live, playlist.title.resolved)) { [weak self] in
                    self?.delete(playlist)
                }
            }
            edits.edit(.pending, id) { $0.isDeleted = false }
        }
    }

    /// Makes a playlist (with `tracks`, e.g. the queue). It shows in the sidebar at once; `opens` goes to it.
    @discardableResult
    public func create(title: String, description: String, privacy: QTPlaylistPrivacy, tracks: [QTTrack],
                       opens: Bool = true) -> QTPlaylist {
        let songs = tracks.filter(\.availability.isPlayable)
        edits.remember(songs)
        let sync = syncsToAccount
        let placeholder = QTPlaylist(id: (sync ? "pending:" : "local:") + UUID().uuidString, title: .verbatim(title),
                                     kind: .user, artwork: songs.first?.artwork ?? [], tracks: songs, isEditable: true,
                                     privacy: privacy, description: description)
        edits.addCreated(placeholder)
        if opens { QTNavigator.shared.go(.section(.playlist(placeholder.id))) }
        guard sync else { return placeholder }
        enqueue { [self] in
            do {
                let id = try await send {
                    try await $0.createPlaylist(title: title, description: description, privacy: privacy,
                                                videoIds: songs.map(\.videoId))
                }
                var made = placeholder
                made.id = QTInnerTube.playlistBrowseId(id)
                made.tracks = nil
                store?.confirmCreate(made, replacing: placeholder.id)
            } catch {
                QTNavigator.shared.leavePlaylist(placeholder.id)
                fail(error, QTLoc.tr("Couldn’t create “%@”", table: .live, title)) { [weak self] in
                    self?.create(title: title, description: description, privacy: privacy, tracks: songs, opens: opens)
                }
            }
            edits.removeCreated(placeholder.id)
        }
        return placeholder
    }

    // MARK: Library and subscriptions

    /// Whether an album (its `OLAK…` playlist id) or someone else's playlist is saved in the library.
    public func isSaved(_ playlistID: String) -> Bool? {
        edits.flag("saved:" + QTInnerTube.rawPlaylistId(playlistID)) ?? store?.savedStates[QTInnerTube.rawPlaylistId(playlistID)]
    }

    public func setSaved(_ saved: Bool, playlistID: String, title: String) {
        let raw = QTInnerTube.rawPlaylistId(playlistID)
        let key = "saved:" + raw
        guard syncsToAccount else {
            edits.setFlag(.local, key, saved == store?.savedStates[raw] ? nil : saved)
            return
        }
        edits.setFlag(.pending, key, saved)
        enqueue { [self] in
            do {
                try await send { try await $0.rate(playlistId: raw, saved ? .like : .none) }
                store?.confirmSaved(saved, playlistID: raw)
            } catch {
                fail(error, QTLoc.tr(saved ? "Couldn’t add “%@” to your library" : "Couldn’t remove “%@” from your library",
                                     table: .live, title)) { [weak self] in
                    self?.setSaved(saved, playlistID: playlistID, title: title)
                }
            }
            edits.setFlag(.pending, key, nil)
        }
    }

    public func isSubscribed(_ channelID: String) -> Bool? {
        edits.flag("subscribed:" + channelID) ?? store?.subscriptions[channelID]
    }

    public func setSubscribed(_ subscribed: Bool, channelID: String, name: String) {
        let key = "subscribed:" + channelID
        guard syncsToAccount else {
            edits.setFlag(.local, key, subscribed == store?.subscriptions[channelID] ? nil : subscribed)
            return
        }
        edits.setFlag(.pending, key, subscribed)
        enqueue { [self] in
            do {
                try await send { try await $0.setSubscribed(subscribed, channelId: channelID) }
                store?.confirmSubscribed(subscribed, channelID: channelID)
            } catch {
                fail(error, QTLoc.tr(subscribed ? "Couldn’t subscribe to %@" : "Couldn’t unsubscribe from %@",
                                     table: .live, name)) { [weak self] in
                    self?.setSubscribed(subscribed, channelID: channelID, name: name)
                }
            }
            edits.setFlag(.pending, key, nil)
        }
    }

    // MARK: Add to Playlist

    /// The account's playlists that can take songs, with whether each already holds all of `tracks` (YouTube's
    /// own answer; nil when not syncing or it couldn't be read). A short cache keeps a reopened menu free.
    public func playlistOptions(for tracks: [QTTrack]) async -> [QTPlaylistOption]? {
        guard syncsToAccount, !isPaused, let client else { return nil }
        let ids = tracks.map(\.videoId)
        if let c = optionsCache, c.videoIDs == ids, Date().timeIntervalSince(c.at) < 30, writesInFlight == 0 {
            return c.options
        }
        guard let options = try? await client.addToPlaylistOptions(videoIds: ids) else { return nil }
        optionsCache = (ids, options, Date())
        store?.noteEditable(options)
        return options
    }

    // MARK: Plumbing

    /// Waits until every queued write has finished (account switch, tests).
    public func idle() async {
        while let current = chain {
            await current.value
            if chain == current { break }
        }
    }

    private func enqueue(_ job: @escaping @MainActor () async -> Void) {
        let previous = chain
        writesInFlight += 1
        chain = Task { @MainActor [weak self] in
            await previous?.value
            await job()
            self?.writesInFlight -= 1
            self?.optionsCache = nil
        }
    }

    /// One write through the client, refused at once while paused by the bot check.
    private func send<T: Sendable>(_ write: @Sendable (QTInnerTubeClient) async throws -> T) async throws -> T {
        guard let client else { throw QTInnerTubeError.notSignedIn }
        if isPaused { throw QTInnerTubeError.botCheck }
        await client.setAllowsAccountWrites(syncsToAccount)
        return try await write(client)
    }

    /// The change is off the screen again; say so once, quietly, with the way forward.
    private func fail(_ error: any Error, _ message: String, retry: @escaping @MainActor () -> Void) {
        guard let model else { return }
        switch error as? QTInnerTubeError {
        case .sessionExpired?, .notSignedIn?:
            // The session's own toast ("Signed out of YouTube Music" + Sign In) says it.
            return
        case .botCheck?:
            // Every change refused while paused waits for the one Try Again.
            isPaused = true
            pausedRetries.append(retry)
            model.showToast(QTLoc.tr("YouTube wants to check this connection. Changes are paused.", table: .live),
                            actionTitle: QTLoc.tr("Try Again", table: .live)) { [weak self] in
                guard let self else { return }
                let retries = self.pausedRetries
                self.pausedRetries = []
                self.isPaused = false
                for r in retries { r() }
            }
        default:
            model.showToast(message, actionTitle: QTLoc.tr("Try Again", table: .live), undo: retry)
        }
    }

    /// A new session or identity: queued writes belong to the old one.
    func reset() {
        chain?.cancel()
        chain = nil
        queuedLikes = []
        writesInFlight = 0
        isPaused = false
        pausedRetries = []
        accountLikes = []
        confirmedLikes = [:]
        likedFromRows = []
        optionsCache = nil
        edits.dropPending()
        publishLikes()
    }
}
