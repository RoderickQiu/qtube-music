import Foundation
import Observation
import QTCore
import QTInnerTube

// Owner: data-live. The one way the app changes the library: likes, playlist adds / removals / reorders, new,
// renamed and deleted playlists, saved albums and playlists, subscriptions.
//
// Signed in with Settings › Account › "Sync likes and playlists to YouTube Music" on (the default in release builds;
// off in DEBUG and scripted runs, `launchSyncOverride`), changes go to the account; otherwise (Sync off, the demo
// library) they stay on this Mac (`QTPlaylistEdits.local`, saved between launches). Either way they show at once.
// Turning Sync on with changes kept here asks to upload or discard them (`setSync`). Account writes:
// - run one at a time, in the order they were made (a serial chain), never retried (QTInnerTube);
// - show at once as `QTPlaylistEdits.pending` and land in the catalog when YouTube confirms; a failure takes the
//   change back off the screen and says so in a toast with Try Again (no alert, nothing to dismiss);
// - quick like / unlike toggles of one song collapse into at most one write, and none when they cancel out;
// - pause after Google's bot check until Try Again (the app never opens or solves the check);
// - leave the cached pages they change stale (the client drops them), so the next visit reads the new state;
// - name playlist rows by their entry id (`setVideoId`), so one copy of a song a playlist holds twice is removed or
//   moved alone; ids the app doesn't have yet come from YouTube's answer to an add, else the playlist is read again;
// - belong to one session and identity: `reset()` (sign-out, identity switch) stops every queued one, and no new
//   change starts while an identity switch is under way.
// Edits to a playlist still being created (`pending:` placeholder) are kept on the placeholder and follow as edits
// of the real playlist once YouTube has made it.

/// What to do with changes kept on this Mac when Sync turns on.
public enum QTLocalChangesChoice: Sendable, Equatable {
    case upload, discard, cancel
}

/// The job a write runs in (its session generation), so a write queued before `reset()` never goes out after it.
private enum QTWriteJob {
    @TaskLocal static var generation: Int?
}

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
    /// Bumped by `reset()`: queued writes of an earlier generation never go out.
    @ObservationIgnored private var generation = 0
    /// Entry ids YouTube gave the songs this app added, per playlist (Undo of an add to a playlist whose page isn't
    /// loaded, a move right after an add).
    @ObservationIgnored private var addedEntries: [String: [String: String]] = [:]
    /// Last "which playlists hold these songs" answer (the Add to Playlist submenu).
    @ObservationIgnored private var optionsCache: (videoIDs: [String], options: [QTPlaylistOption], at: Date)?
    /// Asks what to do with this Mac's changes (count, whether Sync is being turned on): `QTLocalChangesAlert` in the
    /// app, a stub in tests.
    @ObservationIgnored var askAboutLocalChanges: @MainActor (Int, Bool) async -> QTLocalChangesChoice = { count, turningOn in
        await QTLocalChangesAlert.ask(count: count, turningOn: turningOn)
    }
    @ObservationIgnored private var isAskingAboutLocalChanges = false
    /// The clock confirmations are dated by (tests move it on).
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }

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

    /// The session's Sync setting from the launch: `-qt.account.sync YES|NO` when given; otherwise off in DEBUG builds
    /// and in every run scripts or tests drive (any `-qt.*` argument: a ready file, the demo catalog, a section…), so
    /// agents and UI tests never write to the owner's account. nil = the user's setting (release builds launched
    /// normally; on by default).
    public static func launchSyncOverride(_ launch: QTLaunchOptions,
                                          isDebugBuild: Bool = QTBuild.allowsDemoData) -> Bool? {
        if let explicit = launch.bool("qt.account.sync") { return explicit }
        if isDebugBuild || !launch.raw.isEmpty { return false }
        return nil
    }

    /// No change starts while the session moves to another identity (it would land in either library); says so.
    public func acceptsChanges() -> Bool {
        guard store?.switchingIdentity != nil else { return true }
        model?.showToast(QTLoc.tr("Switching accounts. Try again in a moment.", table: .live))
        return false
    }

    // MARK: Sync switch

    /// Settings › Account › Sync and the Account menu. Turning it on while this Mac keeps changes asks first: Upload
    /// Changes (they go to the account, as if made with Sync on), Discard Changes, or Cancel (Sync stays off) — so a
    /// change made here never silently overrides the account afterwards.
    public func setSync(_ on: Bool) {
        guard let model, on != model.settings.settings.syncsToYouTubeMusic else { return }
        guard on, store?.hasLibrary == true, edits.hasLocalChanges else {
            model.settings.update { $0.syncsToYouTubeMusic = on }
            return
        }
        Task { @MainActor in
            guard let choice = await ask(turningOn: true) else { return }
            switch choice {
            case .upload:
                model.settings.update { $0.syncsToYouTubeMusic = true }
                uploadLocalChanges()
            case .discard:
                model.settings.update { $0.syncsToYouTubeMusic = true }
                discardLocalChanges()
            case .cancel:
                break
            }
        }
    }

    /// Signed in with Sync on while this identity still has changes kept here (another identity's, `-qt.account.sync`,
    /// a build before the question existed): the same question; Turn Off Sync keeps them on this Mac.
    func reconcileLocalChanges() async {
        guard syncsToAccount, edits.hasLocalChanges, let choice = await ask(turningOn: false) else { return }
        switch choice {
        case .upload: uploadLocalChanges()
        case .discard: discardLocalChanges()
        case .cancel: model?.settings.update { $0.syncsToYouTubeMusic = false }
        }
    }

    private func ask(turningOn: Bool) async -> QTLocalChangesChoice? {
        guard !isAskingAboutLocalChanges else { return nil }
        isAskingAboutLocalChanges = true
        defer { isAskingAboutLocalChanges = false }
        return await askAboutLocalChanges(edits.localChangeCount, turningOn)
    }

    /// This Mac's changes go to the account, each as the write it would have been with Sync on; they stay on screen
    /// throughout (local → pending → the account).
    func uploadLocalChanges() {
        guard syncsToAccount, let model else { return }
        let (changes, flags, made) = edits.takeLocal()
        func track(_ id: String) -> QTTrack {
            edits.track(id, catalog: model.catalog) ?? QTTrack(videoId: id, title: id, artists: [], duration: 0)
        }
        for (id, c) in changes {
            if id == QTPlaylistEdits.likedID {
                for (ids, liked) in [(c.added, true), (Array(c.removed), false)] {
                    for v in ids where accountLikes.contains(v) != liked {
                        edits.setLike(.pending, v, liked)
                        sendLike(track(v))
                    }
                }
                continue
            }
            let playlist = store?.playlist(id)
            let name = c.title ?? playlist?.title.resolved ?? ""
            if c.isDeleted {
                sendDelete(id, name: name)
                continue
            }
            if c.title != nil || c.description != nil || c.privacy != nil {
                sendDetails(id, title: c.title, description: c.description, privacy: c.privacy, name: name)
            }
            let rows = playlist?.tracks ?? []
            var removals = rows.filter { c.removes($0) }
            removals += c.removed.filter { v in !rows.contains { $0.videoId == v } }.map(track)
            removals += c.removedEntries.filter { s, _ in !rows.contains { $0.setVideoId == s } }.map { s, v in
                var t = track(v)
                t.setVideoId = s
                return t
            }
            if !removals.isEmpty { sendRemove(removals, from: id, name: name) }
            let present = Set(rows.map(\.videoId))
            let adds = c.added.filter { !present.contains($0) }.map(track)
            if !adds.isEmpty { sendAdd(adds, to: id, name: name) }
            if let order = c.order {
                sendOrder(QTPlaylistEdits.sorted(rows.filter { !c.removes($0) } + adds, by: order), moved: nil, in: id,
                          name: name)
            }
        }
        for (key, value) in flags {
            if key.hasPrefix("saved:") {
                let id = String(key.dropFirst("saved:".count))
                if store?.savedStates[id] != value { setSaved(value, playlistID: id, title: id) }
            } else if key.hasPrefix("subscribed:") {
                let id = String(key.dropFirst("subscribed:".count))
                if store?.subscriptions[id] != value { setSubscribed(value, channelID: id, name: id) }
            }
        }
        for p in made {
            guard let placeholder = create(title: p.title.resolved, description: p.description ?? "",
                                           privacy: p.privacy ?? .private, tracks: p.tracks ?? [], opens: false)
            else { continue }
            QTNavigator.shared.replacePlaylist(p.id, with: placeholder.id)
        }
        publishLikes()
    }

    func discardLocalChanges() {
        for p in edits.created where p.id.hasPrefix("local:") { QTNavigator.shared.leavePlaylist(p.id) }
        edits.discardLocal()
        publishLikes()
    }

    // MARK: Likes

    public func isLiked(_ videoID: String) -> Bool { model?.player.likedTrackIDs.contains(videoID) ?? false }

    /// Likes or unlikes songs (only those that change).
    public func setLiked(_ tracks: [QTTrack], _ liked: Bool) {
        let changed = tracks.filter { isLiked($0.videoId) != liked }
        guard !changed.isEmpty, acceptsChanges() else { return }
        edits.remember(changed)
        let sync = syncsToAccount
        for t in changed {
            if sync {
                // The account decides from now on: a like kept on this Mac for the song is superseded.
                edits.clearLocal(QTPlaylistEdits.likedID) { c in
                    c.added.removeAll { $0 == t.videoId }
                    c.removed.remove(t.videoId)
                }
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
                guard isCurrentJob else { return }
                if edits.pendingLike(id) == want { edits.clearLike(.pending, id) }
                fail(error, QTLoc.tr(want ? "Couldn’t like “%@”" : "Couldn’t remove “%@” from Liked Songs", table: .live,
                                     track.title)) { [weak self] in self?.setLiked([track], want) }
            }
            publishLikes()
        }
    }

    private func confirmLike(_ track: QTTrack, _ liked: Bool) {
        if liked {
            accountLikes.insert(track.videoId)
            likedFromRows.insert(track.videoId)
        } else {
            accountLikes.remove(track.videoId)
            // A row seen before the unlike said LIKE; that's out of date now (Liked Songs reloads must not bring it
            // back once the confirmation ages out).
            likedFromRows.remove(track.videoId)
        }
        confirmedLikes[track.videoId] = (liked, now())
        store?.confirmLike(track, liked)
    }

    /// Liked Songs (re)loads from its first page: likes confirmed from now on outlive its pages.
    func noteLikedLoadStarted() -> Date {
        let now = now()
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

    /// Rows that state whether the account likes them (`likeStatus`), e.g. songs past Liked Songs' paging limit.
    func noteLikeStatus(_ tracks: [QTTrack]) {
        let liked = tracks.filter { $0.likeStatus == .like }.map(\.videoId)
        let notLiked = Set(tracks.filter { $0.likeStatus == .indifferent || $0.likeStatus == .dislike }.map(\.videoId))
        likedFromRows.subtract(notLiked)
        likedFromRows.formUnion(liked)
        let fresh = liked.filter { !accountLikes.contains($0) && confirmedLikes[$0]?.liked != false }
        let gone = notLiked.filter { accountLikes.contains($0) && confirmedLikes[$0]?.liked != true }
        guard !fresh.isEmpty || !gone.isEmpty else { return }
        accountLikes.formUnion(fresh)
        accountLikes.subtract(gone)
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
        if Self.isPlaceholder(playlist.id) || playlist.id.hasPrefix("local:") { return true }
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

    /// A row's identity in a playlist: its entry id when it has one (two copies of a song differ), else the song.
    static func rowKey(_ track: QTTrack) -> String { QTPlaylistEdits.rowKey(track) }

    /// A playlist being created in the account (YouTube hasn't answered yet).
    static func isPlaceholder(_ id: String) -> Bool { id.hasPrefix("pending:") }

    /// A playlist that lives in the account (not made on this Mac, not the demo's).
    private func isAccountPlaylist(_ playlist: QTPlaylist) -> Bool {
        !playlist.id.hasPrefix("local:") && !Self.isPlaceholder(playlist.id) && store?.mode != .mock
    }

    /// Adds the songs not already in the playlist; returns them (empty when all were already there). `restoring`
    /// (Undo of a removal) puts back rows that can't play here too.
    @discardableResult
    public func add(_ tracks: [QTTrack], to playlist: QTPlaylist, restoring: Bool = false) -> [QTTrack] {
        let present = Set(rows(of: playlist).map(\.videoId))
        var seen = present
        let fresh = tracks.filter { (restoring || $0.availability.isPlayable) && seen.insert($0.videoId).inserted }
            .map { t in var t = t; t.setVideoId = nil; return t }
        guard !fresh.isEmpty, acceptsChanges() else { return [] }
        edits.remember(fresh)
        let ids = fresh.map(\.videoId)
        let id = playlist.id
        if Self.isPlaceholder(id) || id.hasPrefix("local:") {
            // A playlist made here, or one still being created (the songs follow it to the account).
            edits.updateCreated(id) { $0.tracks = ($0.tracks ?? []) + fresh }
            return fresh
        }
        guard syncsToAccount, isAccountPlaylist(playlist) else {
            let base = Set((latest(playlist).tracks ?? []).map(\.videoId))
            edits.edit(.local, id) { c in
                c.removed.subtract(ids)
                c.added += ids.filter { !base.contains($0) && !c.added.contains($0) }
                if c.order != nil { c.order! += ids }
            }
            return fresh
        }
        edits.clearLocal(id) { c in
            c.removed.subtract(ids)
            c.added.removeAll { ids.contains($0) }
        }
        sendAdd(fresh, to: id, name: playlist.title.resolved)
        return fresh
    }

    private func sendAdd(_ tracks: [QTTrack], to id: String, name: String) {
        let ids = tracks.map(\.videoId)
        edits.edit(.pending, id) { c in
            c.removed.subtract(ids)
            c.added += ids.filter { !c.added.contains($0) }
        }
        enqueue { [self] in
            do {
                let results = try await send { try await $0.addToPlaylist(id, videoIds: ids) }
                let setIDs = Dictionary(results.map { ($0.videoId, $0.setVideoId) }, uniquingKeysWith: { a, _ in a })
                addedEntries[id, default: [:]].merge(setIDs) { _, new in new }
                store?.confirmAdd(tracks.map { t in var t = t; t.setVideoId = setIDs[t.videoId]; return t }, to: id)
            } catch {
                guard isCurrentJob else { return }
                fail(error, QTLoc.tr("Couldn’t add to %@", table: .live, name)) { [weak self] in
                    self?.sendAdd(tracks, to: id, name: name)
                }
            }
            guard isCurrentJob else { return }
            edits.edit(.pending, id) { c in c.added.removeAll { ids.contains($0) } }
        }
    }

    /// Takes rows out of a playlist the account owns (or one made here): exactly these rows, so one copy of a song
    /// the playlist holds twice goes alone.
    public func remove(_ tracks: [QTTrack], from playlist: QTPlaylist) {
        guard !tracks.isEmpty, canEdit(playlist), acceptsChanges() else { return }
        let id = playlist.id
        if Self.isPlaceholder(id) || id.hasPrefix("local:") {
            let ids = Set(tracks.map(\.videoId))
            edits.updateCreated(id) { $0.tracks = ($0.tracks ?? []).filter { !ids.contains($0.videoId) } }
            return
        }
        guard syncsToAccount, isAccountPlaylist(playlist) else {
            edits.edit(.local, id) { c in
                for t in tracks {
                    if t.setVideoId == nil, c.added.contains(t.videoId) {
                        c.added.removeAll { $0 == t.videoId }
                    } else if let s = t.setVideoId {
                        c.removedEntries[s] = t.videoId
                    } else {
                        c.removed.insert(t.videoId)
                    }
                }
            }
            return
        }
        let ids = Set(tracks.map(\.videoId))
        edits.clearLocal(id) { c in c.added.removeAll { ids.contains($0) } }
        sendRemove(tracks, from: id, name: playlist.title.resolved)
    }

    private func sendRemove(_ rows: [QTTrack], from id: String, name: String) {
        func overlay(_ c: inout QTPlaylistEdits.Changes, _ on: Bool) {
            for t in rows {
                if let s = t.setVideoId {
                    c.removedEntries[s] = on ? t.videoId : nil
                } else if on {
                    c.removed.insert(t.videoId)
                } else {
                    c.removed.remove(t.videoId)
                }
            }
        }
        edits.edit(.pending, id) { overlay(&$0, true) }
        enqueue { [self] in
            do {
                let entries = try await entryIDs(for: rows, in: id)
                let items = zip(rows, entries).map { (videoId: $0.videoId, setVideoId: $1) }
                try await send { try await $0.removeFromPlaylist(id, items: items) }
                for item in items where addedEntries[id]?[item.videoId] == item.setVideoId {
                    addedEntries[id]?[item.videoId] = nil
                }
                store?.confirmRemove(Set(entries), from: id)
            } catch {
                guard isCurrentJob else { return }
                fail(error, QTLoc.tr("Couldn’t remove songs from %@", table: .live, name)) { [weak self] in
                    self?.sendRemove(rows, from: id, name: name)
                }
            }
            guard isCurrentJob else { return }
            edits.edit(.pending, id) { overlay(&$0, false) }
        }
    }

    /// Moves `moved` (in their current order) so they sit at `index` of the playlist as shown before the move.
    public func move(_ moved: [QTTrack], in playlist: QTPlaylist, to index: Int) {
        guard canEdit(playlist), !moved.isEmpty, acceptsChanges() else { return }
        let current = rows(of: playlist)
        let movedKeys = Set(moved.map(Self.rowKey))
        let before = current[..<min(max(index, 0), current.count)].filter { !movedKeys.contains(Self.rowKey($0)) }.count
        var order = current.filter { !movedKeys.contains(Self.rowKey($0)) }
        let block = current.filter { movedKeys.contains(Self.rowKey($0)) }
        guard !block.isEmpty else { return }
        order.insert(contentsOf: block, at: before)
        guard order.map(Self.rowKey) != current.map(Self.rowKey) else { return }
        let id = playlist.id
        if Self.isPlaceholder(id) || id.hasPrefix("local:") {
            edits.setCreatedTracks(id, order)
            return
        }
        guard syncsToAccount, isAccountPlaylist(playlist) else {
            edits.edit(.local, id) { $0.order = order.map(Self.rowKey) }
            return
        }
        edits.clearLocal(id) { $0.order = nil }
        sendOrder(order, moved: movedKeys, in: id, name: playlist.title.resolved)
    }

    /// Brings the playlist into `order`. `moved` (row keys) are the rows to move; nil works out the fewest moves
    /// (an upload of a reorder made with Sync off, a placeholder's reorder).
    private func sendOrder(_ order: [QTTrack], moved: Set<String>?, in id: String, name: String) {
        edits.edit(.pending, id) { $0.order = order.map(Self.rowKey) }
        enqueue { [self] in
            do {
                let movedIndexes: [Int]
                let entries: [String?]
                if let moved {
                    movedIndexes = order.indices.filter { moved.contains(Self.rowKey(order[$0])) }
                    // The moved rows and the rows they go in front of; nothing else needs an id.
                    let needed = Set(movedIndexes.flatMap { [$0, $0 + 1] }.filter { order.indices.contains($0) })
                    let ids = try await entryIDs(for: needed.sorted().map { order[$0] }, in: id)
                    let byIndex = Dictionary(uniqueKeysWithValues: zip(needed.sorted(), ids))
                    entries = order.indices.map { byIndex[$0] }
                } else {
                    let ids = try await entryIDs(for: order, in: id)
                    let current = (store?.playlist(id)?.tracks ?? []).compactMap(\.setVideoId)
                    movedIndexes = Self.fewestMoves(to: ids, from: current)
                    entries = ids
                }
                // Each moved row goes in front of its successor in the new order, last first, so every successor
                // is already in place. A successor without an id would send the row to the end instead: never.
                for i in movedIndexes.reversed() {
                    guard let s = entries[i] else { throw QTInnerTubeError.parse("setVideoId") }
                    let successor: String?
                    if order.indices.contains(i + 1) {
                        guard let next = entries[i + 1] else { throw QTInnerTubeError.parse("setVideoId") }
                        successor = next
                    } else {
                        successor = nil
                    }
                    try await send { try await $0.movePlaylistItem(id, setVideoId: s, before: successor) }
                }
                store?.confirmOrder(order.map(Self.rowKey), in: id)
            } catch {
                guard isCurrentJob else { return }
                fail(error, QTLoc.tr("Couldn’t reorder %@", table: .live, name)) { [weak self] in
                    self?.sendOrder(order, moved: moved, in: id, name: name)
                }
            }
            guard isCurrentJob else { return }
            edits.edit(.pending, id) { $0.order = nil }
        }
    }

    /// Indexes of `target` to move so `current` reads as `target`: everything outside one longest run that is
    /// already in order (and rows `current` doesn't hold).
    static func fewestMoves(to target: [String], from current: [String]) -> [Int] {
        let position = Dictionary(current.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let known = target.indices.filter { position[target[$0]] != nil }
        // Longest increasing subsequence of current positions (patience sorting with back links).
        var tails: [Int] = []
        var back = [Int?](repeating: nil, count: known.count)
        for (k, i) in known.enumerated() {
            let p = position[target[i]]!
            var lo = 0, hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if position[target[known[tails[mid]]]]! < p { lo = mid + 1 } else { hi = mid }
            }
            back[k] = lo > 0 ? tails[lo - 1] : nil
            if lo == tails.count { tails.append(k) } else { tails[lo] = k }
        }
        var keep = Set<Int>()
        var k = tails.last
        while let j = k {
            keep.insert(known[j])
            k = back[j]
        }
        return target.indices.filter { !keep.contains($0) }
    }

    /// Entry ids for `rows` of playlist `id`: their own, the loaded rows' (by song, each used once), the ones
    /// YouTube gave this app's adds; when some are still missing (the page isn't loaded, or predates the rows), the
    /// playlist is read again once. Throws when a row still has none — never guesses.
    private func entryIDs(for rows: [QTTrack], in id: String) async throws -> [String] {
        func lookup() -> [String]? {
            let loaded = store?.playlist(id)?.tracks ?? []
            let added = addedEntries[id] ?? [:]
            var used = Set<String>()
            var out: [String] = []
            for r in rows {
                let s = r.setVideoId.flatMap { used.contains($0) ? nil : $0 }
                    ?? loaded.first { $0.videoId == r.videoId && $0.setVideoId.map { !used.contains($0) } == true }?
                        .setVideoId
                    ?? added[r.videoId].flatMap { used.contains($0) ? nil : $0 }
                guard let s else { return nil }
                used.insert(s)
                out.append(s)
            }
            return out
        }
        if let ids = lookup() { return ids }
        await store?.loadPlaylist(id, force: true)
        try checkCurrentJob()
        if let ids = lookup() { return ids }
        throw QTInnerTubeError.parse("setVideoId")
    }

    /// Renames a playlist, changes its description or who can see it. nil (or the value it has) = unchanged; a
    /// privacy the app hasn't read yet is never sent unless chosen.
    public func editDetails(_ playlist: QTPlaylist, title: String?, description: String? = nil,
                            privacy: QTPlaylistPrivacy? = nil) {
        let id = playlist.id
        let newTitle = title.flatMap { $0 == playlist.title.resolved ? nil : $0 }
        let newDescription = description.flatMap { $0 == (playlist.description ?? "") ? nil : $0 }
        let newPrivacy = privacy.flatMap { $0 == playlist.privacy ? nil : $0 }
        guard newTitle != nil || newDescription != nil || newPrivacy != nil, acceptsChanges() else { return }
        if Self.isPlaceholder(id) {
            edits.updateCreated(id) { p in
                if let newTitle { p.title = .verbatim(newTitle) }
                if let newDescription { p.description = newDescription }
                if let newPrivacy { p.privacy = newPrivacy }
            }
            return
        }
        guard syncsToAccount, isAccountPlaylist(playlist) else {
            edits.edit(.local, id) { c in
                if let newTitle { c.title = newTitle }
                if let newDescription { c.description = newDescription }
                if let newPrivacy { c.privacy = newPrivacy }
            }
            return
        }
        edits.clearLocal(id) { c in
            if newTitle != nil { c.title = nil }
            if newDescription != nil { c.description = nil }
            if newPrivacy != nil { c.privacy = nil }
        }
        sendDetails(id, title: newTitle, description: newDescription, privacy: newPrivacy, name: playlist.title.resolved)
    }

    private func sendDetails(_ id: String, title: String?, description: String?, privacy: QTPlaylistPrivacy?,
                             name: String) {
        edits.edit(.pending, id) { c in
            c.title = title
            c.description = description
            c.privacy = privacy
        }
        enqueue { [self] in
            do {
                try await send { try await $0.editPlaylistDetails(id, title: title, description: description,
                                                                  privacy: privacy) }
                store?.confirmDetails(id, title: title, description: description, privacy: privacy)
            } catch {
                guard isCurrentJob else { return }
                fail(error, QTLoc.tr("Couldn’t save changes to “%@”", table: .live, name)) { [weak self] in
                    self?.sendDetails(id, title: title, description: description, privacy: privacy, name: name)
                }
            }
            guard isCurrentJob else { return }
            edits.edit(.pending, id) { c in c.title = nil; c.description = nil; c.privacy = nil }
        }
    }

    /// Deletes a playlist (asked first by the caller: it can't be undone).
    public func delete(_ playlist: QTPlaylist) {
        guard acceptsChanges() else { return }
        let id = playlist.id
        QTNavigator.shared.leavePlaylist(id)
        if id.hasPrefix("local:") || Self.isPlaceholder(id) {
            // A placeholder's playlist is deleted in the account as soon as YouTube has made it (`create`).
            edits.removeCreated(id)
            return
        }
        guard syncsToAccount, isAccountPlaylist(playlist) else {
            edits.edit(.local, id) { $0.isDeleted = true }
            return
        }
        edits.clearLocal(id) { $0 = QTPlaylistEdits.Changes() }
        sendDelete(id, name: playlist.title.resolved)
    }

    private func sendDelete(_ id: String, name: String) {
        edits.edit(.pending, id) { $0.isDeleted = true }
        enqueue { [self] in
            do {
                try await send { try await $0.deletePlaylist(id) }
                store?.confirmDelete(id)
            } catch {
                guard isCurrentJob else { return }
                fail(error, QTLoc.tr("Couldn’t delete “%@”", table: .live, name)) { [weak self] in
                    self?.sendDelete(id, name: name)
                }
            }
            guard isCurrentJob else { return }
            edits.edit(.pending, id) { $0.isDeleted = false }
        }
    }

    /// Makes a playlist (with `tracks`, e.g. the queue). It shows in the sidebar at once; `opens` goes to it. Syncing,
    /// it is a placeholder until YouTube has made it: changes to it meanwhile (songs, order, name, delete) follow as
    /// changes to the real playlist. nil while an identity switch is under way.
    @discardableResult
    public func create(title: String, description: String, privacy: QTPlaylistPrivacy, tracks: [QTTrack],
                       opens: Bool = true) -> QTPlaylist? {
        guard acceptsChanges() else { return nil }
        let songs = tracks.filter(\.availability.isPlayable).map { t in var t = t; t.setVideoId = nil; return t }
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
                let raw = try await send {
                    try await $0.createPlaylist(title: title, description: description, privacy: privacy,
                                                videoIds: songs.map(\.videoId))
                }
                madePlaylist(QTInnerTube.playlistBrowseId(raw), for: placeholder)
            } catch {
                guard isCurrentJob else { return }
                let latest = edits.createdPlaylist(placeholder.id)
                QTNavigator.shared.leavePlaylist(placeholder.id)
                edits.removeCreated(placeholder.id)
                guard let latest else { return } // deleted meanwhile: nothing to redo
                fail(error, QTLoc.tr("Couldn’t create “%@”", table: .live, title)) { [weak self] in
                    self?.create(title: latest.title.resolved, description: latest.description ?? "",
                                 privacy: latest.privacy ?? privacy, tracks: latest.tracks ?? [], opens: opens)
                }
            }
        }
        return placeholder
    }

    /// YouTube made the playlist `id` for `placeholder`: it takes the placeholder's place, and whatever changed on
    /// the placeholder since (songs, order, details, a delete) follows as edits of it.
    private func madePlaylist(_ id: String, for placeholder: QTPlaylist) {
        let sent = placeholder.tracks ?? []
        let name = placeholder.title.resolved
        guard let now = edits.createdPlaylist(placeholder.id) else {
            // Deleted before YouTube answered.
            edits.removeCreated(placeholder.id)
            sendDelete(id, name: name)
            return
        }
        var made = placeholder
        made.id = id
        made.tracks = sent
        store?.confirmCreate(made, replacing: placeholder.id)
        edits.removeCreated(placeholder.id)
        let newTitle = now.title.resolved == name ? nil : now.title.resolved
        let newDescription = (now.description ?? "") == (placeholder.description ?? "") ? nil : now.description
        let newPrivacy = now.privacy == placeholder.privacy ? nil : now.privacy
        if newTitle != nil || newDescription != nil || newPrivacy != nil {
            sendDetails(id, title: newTitle, description: newDescription, privacy: newPrivacy, name: name)
        }
        let wanted = now.tracks ?? []
        let sentIDs = Set(sent.map(\.videoId))
        let wantedIDs = Set(wanted.map(\.videoId))
        let removed = sent.filter { !wantedIDs.contains($0.videoId) }
        let added = wanted.filter { !sentIDs.contains($0.videoId) }
        if !removed.isEmpty { sendRemove(removed, from: id, name: now.title.resolved) }
        if !added.isEmpty { sendAdd(added, to: id, name: now.title.resolved) }
        let expected = sent.filter { wantedIDs.contains($0.videoId) }.map(\.videoId) + added.map(\.videoId)
        if wanted.map(\.videoId) != expected { sendOrder(wanted, moved: nil, in: id, name: now.title.resolved) }
    }

    // MARK: Library and subscriptions

    /// Whether an album (its `OLAK…` playlist id) or someone else's playlist is saved in the library.
    public func isSaved(_ playlistID: String) -> Bool? {
        edits.flag("saved:" + QTInnerTube.rawPlaylistId(playlistID)) ?? store?.savedStates[QTInnerTube.rawPlaylistId(playlistID)]
    }

    public func setSaved(_ saved: Bool, playlistID: String, title: String) {
        guard acceptsChanges() else { return }
        let raw = QTInnerTube.rawPlaylistId(playlistID)
        let key = "saved:" + raw
        guard syncsToAccount else {
            edits.setFlag(.local, key, saved == store?.savedStates[raw] ? nil : saved)
            return
        }
        if edits.localFlags[key] != nil { edits.setFlag(.local, key, nil) }
        edits.setFlag(.pending, key, saved)
        enqueue { [self] in
            do {
                try await send { try await $0.rate(playlistId: raw, saved ? .like : .none) }
                store?.confirmSaved(saved, playlistID: raw)
            } catch {
                guard isCurrentJob else { return }
                fail(error, QTLoc.tr(saved ? "Couldn’t add “%@” to your library" : "Couldn’t remove “%@” from your library",
                                     table: .live, title)) { [weak self] in
                    self?.setSaved(saved, playlistID: playlistID, title: title)
                }
            }
            guard isCurrentJob else { return }
            edits.setFlag(.pending, key, nil)
        }
    }

    public func isSubscribed(_ channelID: String) -> Bool? {
        edits.flag("subscribed:" + channelID) ?? store?.subscriptions[channelID]
    }

    public func setSubscribed(_ subscribed: Bool, channelID: String, name: String) {
        guard acceptsChanges() else { return }
        let key = "subscribed:" + channelID
        guard syncsToAccount else {
            edits.setFlag(.local, key, subscribed == store?.subscriptions[channelID] ? nil : subscribed)
            return
        }
        if edits.localFlags[key] != nil { edits.setFlag(.local, key, nil) }
        edits.setFlag(.pending, key, subscribed)
        enqueue { [self] in
            do {
                try await send { try await $0.setSubscribed(subscribed, channelId: channelID) }
                store?.confirmSubscribed(subscribed, channelID: channelID)
            } catch {
                guard isCurrentJob else { return }
                fail(error, QTLoc.tr(subscribed ? "Couldn’t subscribe to %@" : "Couldn’t unsubscribe from %@",
                                     table: .live, name)) { [weak self] in
                    self?.setSubscribed(subscribed, channelID: channelID, name: name)
                }
            }
            guard isCurrentJob else { return }
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
        let generation = generation
        writesInFlight += 1
        chain = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, generation == self.generation else { return }
            await QTWriteJob.$generation.withValue(generation) { await job() }
            // A reset meanwhile already zeroed the count (and the cache).
            guard generation == self.generation else { return }
            self.writesInFlight -= 1
            self.optionsCache = nil
        }
    }

    /// Whether the running job still belongs to this session and identity (no `reset()` since it was queued).
    private var isCurrentJob: Bool { QTWriteJob.generation.map { $0 == generation } ?? true }

    private func checkCurrentJob() throws {
        guard isCurrentJob else { throw CancellationError() }
    }

    /// One write through the client, refused at once while paused by the bot check — and never sent, nor counted
    /// as landed, once a reset has made the job stale.
    private func send<T: Sendable>(_ write: @Sendable (QTInnerTubeClient) async throws -> T) async throws -> T {
        try checkCurrentJob()
        guard let client else { throw QTInnerTubeError.notSignedIn }
        if isPaused { throw QTInnerTubeError.botCheck }
        await client.setAllowsAccountWrites(syncsToAccount)
        try checkCurrentJob()
        let result = try await write(client)
        try checkCurrentJob()
        return result
    }

    /// The change is off the screen again; say so once, quietly, with the way forward.
    private func fail(_ error: any Error, _ message: String, retry: @escaping @MainActor () -> Void) {
        guard let model, !(error is CancellationError), isCurrentJob else { return }
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

    /// A new session or identity: queued writes belong to the old one and never go out.
    func reset() {
        generation += 1
        chain?.cancel()
        chain = nil
        queuedLikes = []
        writesInFlight = 0
        isPaused = false
        pausedRetries = []
        accountLikes = []
        confirmedLikes = [:]
        likedFromRows = []
        addedEntries = [:]
        optionsCache = nil
        edits.dropPending()
        publishLikes()
    }
}
