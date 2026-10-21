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

/// What to do with changes kept on this Mac when Sync turns on (or is on).
public enum QTLocalChangesChoice: Sendable, Equatable {
    case upload, discard
    /// Cancel / Not Now / Esc: nothing changes (Sync stays as it was; the question comes again next time).
    case cancel
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
    /// Songs whose queued like write is an upload of this Mac's like (`uploadLike`).
    @ObservationIgnored private var forcedLikes: Set<String> = []
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

    /// Signed in with Sync on while this identity still has changes kept here (another identity's, an upload that
    /// didn't finish, a build before the question existed): the same question. Not Now (Esc) changes nothing and
    /// saves no choice: the changes stay here and the question comes again at the next launch.
    func reconcileLocalChanges() async {
        guard syncsToAccount, edits.hasLocalChanges, let choice = await ask(turningOn: false) else { return }
        switch choice {
        case .upload: uploadLocalChanges()
        case .discard: discardLocalChanges()
        case .cancel: break
        }
    }

    private func ask(turningOn: Bool) async -> QTLocalChangesChoice? {
        guard !isAskingAboutLocalChanges else { return nil }
        isAskingAboutLocalChanges = true
        defer { isAskingAboutLocalChanges = false }
        return await askAboutLocalChanges(edits.localChangeCount, turningOn)
    }

    /// This Mac's changes go to the account, each as the write it would have been with Sync on. Each stays here (on
    /// screen and saved) until its write has landed, so a failed write, a bot check or a quit loses none of them: the
    /// toast's Try Again, or the question at the next launch, sends what is left. A playlist is read again inside its
    /// queued job before its edits are worked out, so a playlist not opened this session gets the whole reorder,
    /// and songs already in it aren't added twice.
    func uploadLocalChanges() {
        guard syncsToAccount, let model else { return }
        for (id, c) in edits.local {
            // Details of a playlist made here go with the playlist (`uploadCreated`).
            if id.hasPrefix("local:") { continue }
            guard id == QTPlaylistEdits.likedID else {
                uploadPlaylist(id)
                continue
            }
            // Sent whatever the app knows of the account's likes (Liked Songs may not have loaded, or stop short
            // of the song): liking or unliking twice changes nothing.
            for (ids, liked) in [(c.added, true), (Array(c.removed), false)] {
                for v in ids {
                    uploadLike(edits.track(v, catalog: model.catalog)
                               ?? QTTrack(videoId: v, title: v, artists: [], duration: 0), liked)
                }
            }
        }
        for (key, value) in edits.localFlags {
            if key.hasPrefix("saved:") {
                let id = String(key.dropFirst("saved:".count))
                if store?.savedStates[id] == value { edits.setFlag(.local, key, nil) } else {
                    setSaved(value, playlistID: id, title: id)
                }
            } else if key.hasPrefix("subscribed:") {
                let id = String(key.dropFirst("subscribed:".count))
                if store?.subscriptions[id] == value { edits.setFlag(.local, key, nil) } else {
                    setSubscribed(value, channelID: id, name: id)
                }
            }
        }
        for p in edits.created where p.id.hasPrefix("local:") { uploadCreated(p.id) }
        publishLikes()
    }

    /// A like or unlike kept here, sent even when the account seems to agree already.
    private func uploadLike(_ track: QTTrack, _ liked: Bool) {
        forcedLikes.insert(track.videoId)
        edits.setLike(.pending, track.videoId, liked)
        sendLike(track)
    }

    /// One playlist's changes kept here, as one queued job: the playlist is read first (every page), then its
    /// details, removals, adds and order go out, in that order, stopping at the first that fails (Try Again redoes
    /// what is left).
    private func uploadPlaylist(_ id: String) {
        enqueue { [self] in
            guard let c = edits.local[id], !c.isEmpty else { return }
            let name = c.title ?? store?.playlist(id)?.title.resolved
                ?? model?.catalog.playlists.first { $0.id == id }?.title.resolved ?? ""
            let retry: @MainActor () -> Void = { [weak self] in self?.uploadPlaylist(id) }
            if c.isDeleted {
                showDelete(id)
                await writeDelete(id, name: name, retry: retry)
                return
            }
            if c.title != nil || c.description != nil || c.privacy != nil {
                showDetails(id, title: c.title, description: c.description, privacy: c.privacy)
                guard await writeDetails(id, title: c.title, description: c.description, privacy: c.privacy,
                                         name: name, retry: retry) else { return }
            }
            guard c.order != nil || !c.added.isEmpty || !c.removed.isEmpty || !c.removedEntries.isEmpty else { return }
            if isPaused { return fail(QTInnerTubeError.botCheck, "", retry: retry) }
            await store?.loadPlaylist(id, force: true)
            guard isCurrentJob else { return }
            guard store?.playlistPhase(id) == .loaded, let rows = store?.playlist(id)?.tracks else {
                // A bot check pauses the upload as it would a write; an expired session has its own toast.
                let error: QTInnerTubeError = switch store?.playlistPhase(id) {
                case .failed(.botCheck)?: .botCheck
                case .failed(.sessionExpired)?: .sessionExpired
                default: .parse("playlist")
                }
                return fail(error, QTLoc.tr("Couldn’t save changes to “%@”", table: .live, name), retry: retry)
            }
            // Rows the playlist no longer has and songs it already holds need no write.
            let present = Set(rows.map(\.videoId))
            let entries = Set(rows.compactMap(\.setVideoId))
            edits.clearLocal(id) { l in
                l.removed = l.removed.filter(present.contains)
                l.removedEntries = l.removedEntries.filter { entries.contains($0.key) }
                l.added.removeAll(where: present.contains)
            }
            guard let c = edits.local[id] else { return }
            let removals = rows.filter { c.removes($0) }
            if !removals.isEmpty {
                showRemove(removals, from: id)
                guard await writeRemove(removals, from: id, name: name, retry: retry) else { return }
            }
            if let model, !c.added.isEmpty {
                let adds = c.added.map {
                    edits.track($0, catalog: model.catalog) ?? QTTrack(videoId: $0, title: $0, artists: [], duration: 0)
                }
                showAdd(adds, to: id)
                guard await writeAdd(adds, to: id, name: name, retry: retry) else { return }
            }
            guard let order = edits.local[id]?.order else { return }
            let now = store?.playlist(id)?.tracks ?? []
            let wanted = QTPlaylistEdits.sorted(now, by: order)
            guard wanted.map(Self.rowKey) != now.map(Self.rowKey) else {
                edits.clearLocal(id) { $0.order = nil }
                return
            }
            showOrder(wanted, in: id)
            await writeOrder(wanted, moved: nil, in: id, name: name, retry: retry)
        }
    }

    /// A playlist made on this Mac, made in the account as it is when its turn comes; it stays here until YouTube
    /// has made it (then changes made to it meanwhile follow, as for a placeholder).
    private func uploadCreated(_ id: String) {
        enqueue { [self] in
            guard let p = edits.createdPlaylist(id) else { return }
            await writeCreate(p, opens: false)
        }
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
    /// into it (or into nothing when they cancel out). An upload's like (`forcedLikes`) goes out even when the account
    /// seems to agree already: what the app knows of the account's likes may be incomplete.
    private func sendLike(_ track: QTTrack) {
        let id = track.videoId
        guard queuedLikes.insert(id).inserted else { return }
        enqueue { [self] in
            queuedLikes.remove(id)
            let uploading = forcedLikes.remove(id) != nil
            guard let want = edits.pendingLike(id) else { return }
            if want == accountLikes.contains(id), !uploading {
                edits.clearLike(.pending, id)
                publishLikes()
                return
            }
            do {
                try await send { try await $0.rate(videoId: id, want ? .like : .none) }
                confirmLike(track, want)
                if edits.pendingLike(id) == want { edits.clearLike(.pending, id) }
                // The account has it now: a like kept on this Mac for the song is done with.
                if edits.local[QTPlaylistEdits.likedID] != nil { edits.clearLike(.local, id) }
            } catch {
                guard isCurrentJob else { return }
                if edits.pendingLike(id) == want { edits.clearLike(.pending, id) }
                fail(error, QTLoc.tr(want ? "Couldn’t like “%@”" : "Couldn’t remove “%@” from Liked Songs", table: .live,
                                     track.title)) { [weak self] in
                    if uploading { self?.uploadLike(track, want) } else { self?.setLiked([track], want) }
                }
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

    /// Rows that state whether the account likes them (`likeStatus`), e.g. songs past Liked Songs' paging limit. A
    /// "not liked" row never takes a like away: the page may be a cached one from before the like (Liked Songs and
    /// confirmed writes say what the account likes). It only stops the row's earlier LIKE from counting at the next
    /// Liked Songs load.
    func noteLikeStatus(_ tracks: [QTTrack]) {
        let liked = tracks.filter { $0.likeStatus == .like }.map(\.videoId)
        let notLiked = Set(tracks.filter { $0.likeStatus == .indifferent || $0.likeStatus == .dislike }.map(\.videoId))
        likedFromRows.subtract(notLiked)
        likedFromRows.formUnion(liked)
        let fresh = liked.filter { !accountLikes.contains($0) && confirmedLikes[$0]?.liked != false }
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
    /// (Undo of a removal) puts back rows, by entry id: also rows that can't play here, and one copy of a song the
    /// playlist still holds once. A row hidden only on this Mac comes back as it was (returned with its entry id);
    /// the others come back as new rows (returned without one).
    @discardableResult
    public func add(_ tracks: [QTTrack], to playlist: QTPlaylist, restoring: Bool = false) -> [QTTrack] {
        let shown = rows(of: playlist)
        let present = Set(shown.map(\.videoId))
        let presentEntries = Set(shown.compactMap(\.setVideoId))
        var seen = Set<String>()
        let fresh = tracks.filter { t in
            guard restoring || t.availability.isPlayable else { return false }
            if restoring, let s = t.setVideoId { return !presentEntries.contains(s) && seen.insert(s).inserted }
            return !present.contains(t.videoId) && seen.insert(t.videoId).inserted
        }
        guard !fresh.isEmpty, acceptsChanges() else { return [] }
        func newRows(_ tracks: [QTTrack]) -> [QTTrack] { tracks.map { t in var t = t; t.setVideoId = nil; return t } }
        edits.remember(newRows(fresh))
        let id = playlist.id
        if Self.isPlaceholder(id) || id.hasPrefix("local:") {
            // A playlist made here, or one still being created (the songs follow it to the account).
            let songs = newRows(fresh.filter { !present.contains($0.videoId) })
            edits.updateCreated(id) { $0.tracks = ($0.tracks ?? []) + songs }
            return songs
        }
        guard syncsToAccount, isAccountPlaylist(playlist) else {
            let base = Set((latest(playlist).tracks ?? []).map(\.videoId))
            var inPlace: [QTTrack] = []
            var songs: [QTTrack] = []
            edits.edit(.local, id) { c in
                for t in fresh {
                    if let s = t.setVideoId, c.removedEntries[s] != nil {
                        c.removedEntries[s] = nil
                        inPlace.append(t)
                    } else if !present.contains(t.videoId) {
                        songs.append(t)
                    }
                }
                let ids = songs.map(\.videoId)
                c.removed.subtract(ids)
                c.added += ids.filter { !base.contains($0) && !c.added.contains($0) }
                if c.order != nil { c.order! += ids }
            }
            return inPlace + newRows(songs)
        }
        // A song the playlist doesn't hold is added; a further copy of one it holds (Undo) goes as a duplicate.
        var known = present
        var songs: [QTTrack] = []
        var copies: [QTTrack] = []
        for t in newRows(fresh) {
            if known.insert(t.videoId).inserted { songs.append(t) } else { copies.append(t) }
        }
        let ids = songs.map(\.videoId)
        edits.clearLocal(id) { c in
            c.removed.subtract(ids)
            c.added.removeAll { ids.contains($0) }
        }
        if !songs.isEmpty { sendAdd(songs, to: id, name: playlist.title.resolved) }
        if !copies.isEmpty { sendAdd(copies, to: id, name: playlist.title.resolved, copies: true) }
        return songs + copies
    }

    /// `copies`: songs the playlist already holds, added as further rows.
    private func sendAdd(_ tracks: [QTTrack], to id: String, name: String, copies: Bool = false) {
        showAdd(tracks, to: id, copies: copies)
        enqueue { [self] in await writeAdd(tracks, to: id, name: name, copies: copies) }
    }

    private func showAdd(_ tracks: [QTTrack], to id: String, copies: Bool = false) {
        let ids = tracks.map(\.videoId)
        if copies { return edits.setPendingCopies(ids, in: id, adding: true) }
        edits.edit(.pending, id) { c in
            c.removed.subtract(ids)
            c.added += ids.filter { !c.added.contains($0) }
        }
    }

    /// The add itself (in a queued job); true once YouTube has added the rows. `retry` replaces the failure toast's
    /// Try Again (an upload redoes what is left of it).
    @discardableResult
    private func writeAdd(_ tracks: [QTTrack], to id: String, name: String, copies: Bool = false,
                          retry: (@MainActor () -> Void)? = nil) async -> Bool {
        let ids = tracks.map(\.videoId)
        var landed = false
        do {
            let results = try await send { try await $0.addToPlaylist(id, videoIds: ids, allowingDuplicates: copies) }
            let setIDs = Dictionary(results.map { ($0.videoId, $0.setVideoId) }, uniquingKeysWith: { a, _ in a })
            addedEntries[id, default: [:]].merge(setIDs) { _, new in new }
            store?.confirmAdd(tracks.map { t in var t = t; t.setVideoId = setIDs[t.videoId]; return t }, to: id)
            edits.clearLocal(id) { c in c.added.removeAll { ids.contains($0) } }
            landed = true
        } catch {
            guard isCurrentJob else { return false }
            fail(error, QTLoc.tr("Couldn’t add to %@", table: .live, name), retry: retry ?? { [weak self] in
                self?.sendAdd(tracks, to: id, name: name, copies: copies)
            })
        }
        guard isCurrentJob else { return landed }
        if copies {
            edits.setPendingCopies(ids, in: id, adding: false)
        } else {
            edits.edit(.pending, id) { c in c.added.removeAll { ids.contains($0) } }
        }
        return landed
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
        showRemove(rows, from: id)
        enqueue { [self] in await writeRemove(rows, from: id, name: name) }
    }

    private func showRemove(_ rows: [QTTrack], from id: String, _ on: Bool = true) {
        edits.edit(.pending, id) { c in
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
    }

    @discardableResult
    private func writeRemove(_ rows: [QTTrack], from id: String, name: String,
                             retry: (@MainActor () -> Void)? = nil) async -> Bool {
        var landed = false
        do {
            let entries = try await entryIDs(for: rows, in: id)
            let items = zip(rows, entries).map { (videoId: $0.videoId, setVideoId: $1) }
            try await send { try await $0.removeFromPlaylist(id, items: items) }
            for item in items where addedEntries[id]?[item.videoId] == item.setVideoId {
                addedEntries[id]?[item.videoId] = nil
            }
            store?.confirmRemove(Set(entries), from: id)
            // This Mac's removal of these rows is done with (of a song, once no row of it is left).
            let left = Set(store?.playlist(id)?.tracks?.map(\.videoId) ?? [])
            edits.clearLocal(id) { c in
                for s in entries { c.removedEntries[s] = nil }
                c.removed = c.removed.filter { v in left.contains(v) || !rows.contains { $0.videoId == v } }
            }
            landed = true
        } catch {
            guard isCurrentJob else { return false }
            fail(error, QTLoc.tr("Couldn’t remove songs from %@", table: .live, name), retry: retry ?? { [weak self] in
                self?.sendRemove(rows, from: id, name: name)
            })
        }
        guard isCurrentJob else { return landed }
        showRemove(rows, from: id, false)
        return landed
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
        showOrder(order, in: id)
        enqueue { [self] in await writeOrder(order, moved: moved, in: id, name: name) }
    }

    private func showOrder(_ order: [QTTrack]?, in id: String) {
        edits.edit(.pending, id) { $0.order = order?.map(Self.rowKey) }
    }

    @discardableResult
    private func writeOrder(_ order: [QTTrack], moved: Set<String>?, in id: String, name: String,
                            retry: (@MainActor () -> Void)? = nil) async -> Bool {
        var landed = false
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
            edits.clearLocal(id) { $0.order = nil }
            landed = true
        } catch {
            guard isCurrentJob else { return false }
            fail(error, QTLoc.tr("Couldn’t reorder %@", table: .live, name), retry: retry ?? { [weak self] in
                self?.sendOrder(order, moved: moved, in: id, name: name)
            })
        }
        guard isCurrentJob else { return landed }
        showOrder(nil, in: id)
        return landed
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

    /// Entry ids for `rows` of playlist `id`: their own, the ones YouTube gave this app's adds (a row without an id is
    /// one this app added: also a further copy of a song the playlist holds), the loaded rows' (by song, each used
    /// once); when some are still missing (the page isn't loaded, or predates the rows), the playlist is read again
    /// once. Throws when a row still has none — never guesses.
    private func entryIDs(for rows: [QTTrack], in id: String) async throws -> [String] {
        func lookup() -> [String]? {
            let loaded = store?.playlist(id)?.tracks ?? []
            let added = addedEntries[id] ?? [:]
            var used = Set<String>()
            var out: [String] = []
            for r in rows {
                let s = r.setVideoId.flatMap { used.contains($0) ? nil : $0 }
                    ?? added[r.videoId].flatMap { used.contains($0) ? nil : $0 }
                    ?? loaded.first { $0.videoId == r.videoId && $0.setVideoId.map { !used.contains($0) } == true }?
                        .setVideoId
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
        showDetails(id, title: title, description: description, privacy: privacy)
        enqueue { [self] in
            await writeDetails(id, title: title, description: description, privacy: privacy, name: name)
        }
    }

    private func showDetails(_ id: String, title: String?, description: String?, privacy: QTPlaylistPrivacy?) {
        edits.edit(.pending, id) { c in
            c.title = title
            c.description = description
            c.privacy = privacy
        }
    }

    @discardableResult
    private func writeDetails(_ id: String, title: String?, description: String?, privacy: QTPlaylistPrivacy?,
                              name: String, retry: (@MainActor () -> Void)? = nil) async -> Bool {
        var landed = false
        do {
            try await send { try await $0.editPlaylistDetails(id, title: title, description: description,
                                                              privacy: privacy) }
            store?.confirmDetails(id, title: title, description: description, privacy: privacy)
            edits.clearLocal(id) { c in
                if title != nil, c.title == title { c.title = nil }
                if description != nil, c.description == description { c.description = nil }
                if privacy != nil, c.privacy == privacy { c.privacy = nil }
            }
            landed = true
        } catch {
            guard isCurrentJob else { return false }
            let again = retry ?? { [weak self] in
                self?.sendDetails(id, title: title, description: description, privacy: privacy, name: name)
            }
            fail(error, QTLoc.tr("Couldn’t save changes to “%@”", table: .live, name), retry: again)
        }
        guard isCurrentJob else { return landed }
        showDetails(id, title: nil, description: nil, privacy: nil)
        return landed
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
        showDelete(id)
        enqueue { [self] in await writeDelete(id, name: name) }
    }

    private func showDelete(_ id: String, _ on: Bool = true) {
        edits.edit(.pending, id) { $0.isDeleted = on }
    }

    private func writeDelete(_ id: String, name: String, retry: (@MainActor () -> Void)? = nil) async {
        do {
            try await send { try await $0.deletePlaylist(id) }
            store?.confirmDelete(id)
            // Nothing is left of the playlist to keep changes for.
            edits.clearLocal(id) { $0 = QTPlaylistEdits.Changes() }
        } catch {
            guard isCurrentJob else { return }
            fail(error, QTLoc.tr("Couldn’t delete “%@”", table: .live, name), retry: retry ?? { [weak self] in
                self?.sendDelete(id, name: name)
            })
        }
        guard isCurrentJob else { return }
        showDelete(id, false)
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
        enqueue { [self] in await writeCreate(placeholder, opens: opens) }
        return placeholder
    }

    /// Makes `p` in the account: a placeholder (it goes when the create fails; Try Again makes it anew) or a
    /// playlist made on this Mac being uploaded (it stays here until YouTube has made it).
    private func writeCreate(_ p: QTPlaylist, opens: Bool) async {
        let title = p.title.resolved
        do {
            let raw = try await send {
                try await $0.createPlaylist(title: title, description: p.description ?? "",
                                            privacy: p.privacy ?? .private, videoIds: (p.tracks ?? []).map(\.videoId))
            }
            madePlaylist(QTInnerTube.playlistBrowseId(raw), for: p)
        } catch {
            guard isCurrentJob else { return }
            if p.id.hasPrefix("local:") {
                return fail(error, QTLoc.tr("Couldn’t create “%@”", table: .live, title)) { [weak self] in
                    self?.uploadCreated(p.id)
                }
            }
            let latest = edits.createdPlaylist(p.id)
            QTNavigator.shared.leavePlaylist(p.id)
            edits.removeCreated(p.id)
            guard let latest else { return } // deleted meanwhile: nothing to redo
            fail(error, QTLoc.tr("Couldn’t create “%@”", table: .live, title)) { [weak self] in
                self?.create(title: latest.title.resolved, description: latest.description ?? "",
                             privacy: latest.privacy ?? .private, tracks: latest.tracks ?? [], opens: opens)
            }
        }
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
        // A switch kept on this Mac goes once the account has the new state (a failure shows it again).
        edits.setFlag(.pending, key, saved)
        enqueue { [self] in
            do {
                try await send { try await $0.rate(playlistId: raw, saved ? .like : .none) }
                store?.confirmSaved(saved, playlistID: raw)
                if edits.localFlags[key] != nil { edits.setFlag(.local, key, nil) }
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
        edits.setFlag(.pending, key, subscribed)
        enqueue { [self] in
            do {
                try await send { try await $0.setSubscribed(subscribed, channelId: channelID) }
                store?.confirmSubscribed(subscribed, channelID: channelID)
                if edits.localFlags[key] != nil { edits.setFlag(.local, key, nil) }
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
        forcedLikes = []
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
