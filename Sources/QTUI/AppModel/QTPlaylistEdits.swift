import Foundation
import Observation
import QTCore

/// Library changes that aren't in the YouTube Music account — or aren't there *yet* — laid over what the account
/// shows, so every list, heart and sidebar row reads one state:
/// - **local**: kept on this Mac (Settings › Account › Sync off, or the demo library). Saved between launches per
///   Google account and brand account (`storageURL`, `profile`), never in scripted or demo runs. Turning Sync on
///   with local changes asks to upload or discard them (`QTAccountWriter.setSync`).
/// - **pending**: on their way to the account (`QTAccountWriter`). Shown at once and dropped when the write lands
///   (the change is then in the catalog itself) or fails (which undoes it on screen).
/// Pages that stream in (Liked Songs paging, a playlist's continuation pages) replace the catalog's lists; they never
/// clobber a change here.
@MainActor
@Observable
public final class QTPlaylistEdits {
    public static let shared = QTPlaylistEdits()

    /// Changes to one list (`LM` for Liked Songs, else the playlist id).
    public struct Changes: Codable, Sendable, Hashable {
        /// Songs added (video ids). Liked Songs shows them first, newest first; playlists at the end.
        public var added: [String] = []
        /// Songs taken out (video ids): every row of the song.
        public var removed: Set<String> = []
        /// Single rows taken out, by entry id (`setVideoId` → video id): one copy of a song the list holds twice.
        public var removedEntries: [String: String] = [:]
        /// A reorder: the list's whole order, by row (`rowKey`: the entry id, else the video id).
        public var order: [String]?
        public var title: String?
        public var description: String?
        public var privacy: QTPlaylistPrivacy?
        public var isDeleted = false

        public init() {}

        /// Every field optional on disk (files written before a field existed still load).
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            added = try c.decodeIfPresent([String].self, forKey: .added) ?? []
            removed = try c.decodeIfPresent(Set<String>.self, forKey: .removed) ?? []
            removedEntries = try c.decodeIfPresent([String: String].self, forKey: .removedEntries) ?? [:]
            order = try c.decodeIfPresent([String].self, forKey: .order)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            description = try c.decodeIfPresent(String.self, forKey: .description)
            privacy = try c.decodeIfPresent(QTPlaylistPrivacy.self, forKey: .privacy)
            isDeleted = try c.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        }

        public var isEmpty: Bool { self == Changes() }

        /// How many separate changes this is (the Sync alert counts them).
        var count: Int {
            added.count + removed.count + removedEntries.count + (order == nil ? 0 : 1) + (title == nil ? 0 : 1)
                + (description == nil ? 0 : 1) + (privacy == nil ? 0 : 1) + (isDeleted ? 1 : 0)
        }

        /// Whether `track` (a row) is taken out.
        func removes(_ track: QTTrack) -> Bool {
            removed.contains(track.videoId) || track.setVideoId.map { removedEntries[$0] != nil } == true
        }

        /// These changes with `newer` on top (changes made before the account was known joining its profile).
        func merged(with newer: Changes) -> Changes {
            var c = self
            c.added += newer.added.filter { !c.added.contains($0) }
            c.removed.subtract(newer.added)
            c.removed.formUnion(newer.removed)
            c.added.removeAll { newer.removed.contains($0) }
            c.removedEntries.merge(newer.removedEntries) { _, new in new }
            c.order = newer.order ?? c.order
            c.title = newer.title ?? c.title
            c.description = newer.description ?? c.description
            c.privacy = newer.privacy ?? c.privacy
            c.isDeleted = c.isDeleted || newer.isDeleted
            return c
        }
    }

    /// A row's identity in a list: its entry id when it has one (two copies of a song differ), else the song.
    public static func rowKey(_ track: QTTrack) -> String { track.setVideoId ?? track.videoId }

    /// `tracks` in `order` (row keys; rows it doesn't name keep their place after the named ones).
    static func sorted(_ tracks: [QTTrack], by order: [String]) -> [QTTrack] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        func r(_ t: QTTrack) -> Int { rank[rowKey(t)] ?? rank[t.videoId] ?? Int.max }
        return tracks.enumerated().sorted { (r($0.element), $0.offset) < (r($1.element), $1.offset) }.map(\.element)
    }

    public enum Layer: Sendable { case local, pending }

    public static let likedID = "LM"

    public private(set) var local: [String: Changes] = [:]
    public private(set) var pending: [String: Changes] = [:]
    /// Playlists made on this Mac (`local:` ids) and new playlists still being created in the account (`pending:`).
    public private(set) var created: [QTPlaylist] = []
    /// Saved-to-library (`saved:<playlist id>`) and subscription (`subscribed:<channel id>`) switches set here.
    public private(set) var localFlags: [String: Bool] = [:]
    public private(set) var pendingFlags: [String: Bool] = [:]
    /// Songs the changes name (a liked or added song the catalog may not hold after a relaunch).
    @ObservationIgnored private var knownTracks: [String: QTTrack] = [:]

    /// Where local changes are saved (nil = memory only: tests, scripted runs, the demo library).
    @ObservationIgnored public var storageURL: URL?
    /// The identity local changes belong to: `QTLiveCatalogStore.localProfile` (a hashed Google-account key, plus
    /// "/<brand id>" for a brand account). nil while the account isn't known yet: changes then stay in memory and
    /// move to the account's profile once it is.
    @ObservationIgnored public private(set) var profile: String? = "main"

    public init(storageURL: URL? = nil) {
        self.storageURL = storageURL
        load()
    }

    // MARK: Reading

    /// Songs added locally per list (compat: earlier session-only edits).
    public var added: [String: [String]] { local.mapValues(\.added) }

    /// A list's songs as shown: the account's (or demo's) rows with local, then pending changes applied.
    public func tracks(for playlist: QTPlaylist, catalog: QTMockCatalog) -> [QTTrack] {
        let prepend = playlist.kind == .liked || playlist.id == Self.likedID
        let base = playlist.tracks ?? created.first { $0.id == playlist.id }?.tracks ?? []
        return apply(pending[playlist.id], to: apply(local[playlist.id], to: base, prepend: prepend, catalog: catalog),
                     prepend: prepend, catalog: catalog)
    }

    /// The sidebar's playlists: the account's (renamed, deleted ones hidden) and those made here.
    public func playlists(_ library: [QTPlaylist]) -> [QTPlaylist] {
        (library + created).compactMap(resolved)
    }

    /// One playlist with its title / description / privacy changes applied; nil once deleted.
    public func resolved(_ p: QTPlaylist) -> QTPlaylist? {
        var p = p
        for c in [local[p.id], pending[p.id]].compactMap({ $0 }) {
            if c.isDeleted { return nil }
            if let t = c.title { p.title = .verbatim(t) }
            if let d = c.description { p.description = d }
            if let v = c.privacy { p.privacy = v }
        }
        return p
    }

    public func createdPlaylist(_ id: String) -> QTPlaylist? { created.first { $0.id == id }.flatMap(resolved) }

    /// Liked songs: the account's (`base`) with local and pending likes applied.
    public func likedIDs(base: Set<String>) -> Set<String> {
        var ids = base
        for c in [local[Self.likedID], pending[Self.likedID]].compactMap({ $0 }) {
            ids.subtract(c.removed)
            ids.formUnion(c.added)
        }
        return ids
    }

    /// The like a pending write wants for a song (nil = none pending).
    public func pendingLike(_ videoID: String) -> Bool? {
        guard let c = pending[Self.likedID] else { return nil }
        if c.added.contains(videoID) { return true }
        if c.removed.contains(videoID) { return false }
        return nil
    }

    public func flag(_ key: String) -> Bool? { pendingFlags[key] ?? localFlags[key] }

    /// Whether anything is kept on this Mac for the current identity (likes, playlist edits, playlists made here,
    /// saved albums, subscriptions).
    public var hasLocalChanges: Bool { localChangeCount > 0 }

    public var localChangeCount: Int {
        local.values.map(\.count).reduce(0, +) + localFlags.count + created.filter { $0.id.hasPrefix("local:") }.count
    }

    public func track(_ id: String, catalog: QTMockCatalog) -> QTTrack? { knownTracks[id] ?? catalog.track(id: id) }

    // MARK: Changing

    public func remember(_ tracks: [QTTrack]) {
        for t in tracks { knownTracks[t.videoId] = t }
    }

    public func edit(_ layer: Layer, _ id: String, _ change: (inout Changes) -> Void) {
        switch layer {
        case .local:
            var c = local[id] ?? Changes()
            change(&c)
            local[id] = c.isEmpty ? nil : c
            save()
        case .pending:
            var c = pending[id] ?? Changes()
            change(&c)
            pending[id] = c.isEmpty ? nil : c
        }
    }

    /// Changes a list's local entry only when it has one (a write that supersedes part of it), so the file isn't
    /// rewritten for nothing.
    public func clearLocal(_ id: String, _ change: (inout Changes) -> Void) {
        guard local[id] != nil else { return }
        edit(.local, id, change)
    }

    public func setLike(_ layer: Layer, _ videoID: String, _ liked: Bool) {
        edit(layer, Self.likedID) { c in
            if liked {
                c.removed.remove(videoID)
                c.added.removeAll { $0 == videoID }
                c.added.insert(videoID, at: 0)
            } else {
                c.added.removeAll { $0 == videoID }
                c.removed.insert(videoID)
            }
        }
    }

    public func clearLike(_ layer: Layer, _ videoID: String) {
        edit(layer, Self.likedID) { c in
            c.added.removeAll { $0 == videoID }
            c.removed.remove(videoID)
        }
    }

    public func setFlag(_ layer: Layer, _ key: String, _ value: Bool?) {
        switch layer {
        case .local:
            localFlags[key] = value
            save()
        case .pending:
            pendingFlags[key] = value
        }
    }

    /// Appends tracks not already in the playlist, on this Mac; returns the ids actually added (for Undo).
    @discardableResult
    public func add(_ trackIDs: [String], to playlist: QTPlaylist) -> [String] {
        let existing = Set((playlist.tracks ?? []).map(\.videoId) + (local[playlist.id]?.added ?? []))
        var seen = existing
        let fresh = trackIDs.filter { seen.insert($0).inserted }
        guard !fresh.isEmpty else { return [] }
        edit(.local, playlist.id) { c in
            c.removed.subtract(fresh)
            c.added += fresh
        }
        return fresh
    }

    public func undoAdd(_ trackIDs: [String], to playlistID: String) {
        let drop = Set(trackIDs)
        if local[playlistID] == nil { local[playlistID] = Changes() }
        local[playlistID]?.added.removeAll { drop.contains($0) }
        save()
    }

    /// A playlist made on this Mac, or a placeholder for one being created in the account.
    public func addCreated(_ p: QTPlaylist) {
        created.removeAll { $0.id == p.id }
        created.append(p)
        if p.id.hasPrefix("local:") { save() }
    }

    public func removeCreated(_ id: String) {
        created.removeAll { $0.id == id }
        local[id] = nil
        pending[id] = nil
        if id.hasPrefix("local:") { save() }
    }

    /// Replaces a local playlist's own rows (a reorder or removal of a playlist made on this Mac).
    public func setCreatedTracks(_ id: String, _ tracks: [QTTrack]) {
        updateCreated(id) { $0.tracks = tracks }
    }

    /// Changes a playlist made here, or a placeholder still being created (its edits go to the account once YouTube
    /// has made it).
    public func updateCreated(_ id: String, _ change: (inout QTPlaylist) -> Void) {
        guard let i = created.firstIndex(where: { $0.id == id }) else { return }
        change(&created[i])
        if id.hasPrefix("local:") { save() }
    }

    /// Everything pending is dropped (an account switch or sign-out; their writes are abandoned).
    public func dropPending() {
        pending = [:]
        pendingFlags = [:]
        created.removeAll { $0.id.hasPrefix("pending:") }
    }

    /// What this Mac keeps for the current identity, handed over for upload (Sync turned on), and gone from here.
    func takeLocal() -> (changes: [String: Changes], flags: [String: Bool], created: [QTPlaylist]) {
        let taken = (local, localFlags, created.filter { $0.id.hasPrefix("local:") })
        discardLocal()
        return taken
    }

    /// Forgets this Mac's changes for the current identity (Sync turned on, Discard Changes).
    public func discardLocal() {
        local = [:]
        localFlags = [:]
        created.removeAll { $0.id.hasPrefix("local:") }
        save()
    }

    // MARK: Profiles and storage

    /// Switches to another identity's local changes; `reload` reads the file again (storage was just attached).
    /// Changes made while the account wasn't known yet (`profile` nil) move into the profile it turns out to be.
    public func use(profile: String?, reload: Bool = false) {
        guard profile != self.profile || reload else { return }
        let carried = self.profile == nil && profile != nil && !reload
            ? (local, localFlags, created.filter { $0.id.hasPrefix("local:") }) : nil
        if !reload { save() }
        self.profile = profile
        load()
        if let (changes, flags, made) = carried, !changes.isEmpty || !flags.isEmpty || !made.isEmpty {
            local.merge(changes) { saved, early in saved.merged(with: early) }
            localFlags.merge(flags) { _, new in new }
            created += made.filter { m in !created.contains { $0.id == m.id } }
            save()
        }
    }

    /// Files written before profiles were keyed by Google account ("main", "<brand id>") become the profiles of
    /// `account` (the first account signed in after the update), unless it already has its own.
    public func migrateLegacyProfiles(to account: String) {
        guard let storageURL, let data = try? Data(contentsOf: storageURL),
              var all = try? JSONDecoder().decode([String: Snapshot].self, from: data) else { return }
        let legacy = all.keys.filter { !$0.hasPrefix(Self.accountPrefix) }
        guard !legacy.isEmpty else { return }
        for key in legacy {
            let target = key == "main" ? account : "\(account)/\(key)"
            if all[target] == nil { all[target] = all[key] }
            all[key] = nil
        }
        write(all)
    }

    /// Prefix of account-keyed profiles (`QTAccountContext.accountKey`).
    static let accountPrefix = "acct-"

    private struct Snapshot: Codable {
        var local: [String: Changes] = [:]
        var created: [QTPlaylist] = []
        var flags: [String: Bool] = [:]
        var tracks: [String: QTTrack] = [:]

        var isEmpty: Bool { local.isEmpty && created.isEmpty && flags.isEmpty }
    }

    private func load() {
        local = [:]
        created.removeAll { $0.id.hasPrefix("local:") }
        localFlags = [:]
        guard let storageURL, let data = try? Data(contentsOf: storageURL),
              let all = try? JSONDecoder().decode([String: Snapshot].self, from: data),
              let profile, let mine = all[profile] else { return }
        // Edits an earlier build filed under a playlist still being created ("pending:…") never reach the account.
        local = mine.local.filter { !$0.key.hasPrefix("pending:") }
        created += mine.created
        localFlags = mine.flags
        knownTracks.merge(mine.tracks) { a, _ in a }
    }

    private func save() {
        guard let storageURL, let profile else { return }
        var all = (try? Data(contentsOf: storageURL)).flatMap { try? JSONDecoder().decode([String: Snapshot].self, from: $0) }
            ?? [:]
        let mine = created.filter { $0.id.hasPrefix("local:") }
        var named = Set(local.values.flatMap(\.added))
        named.formUnion(mine.flatMap { $0.tracks ?? [] }.map(\.videoId))
        let tracks = knownTracks.filter { named.contains($0.key) }
        let snapshot = Snapshot(local: local, created: mine, flags: localFlags, tracks: tracks)
        all[profile] = snapshot.isEmpty ? nil : snapshot
        write(all)
    }

    private func write(_ all: [String: Snapshot]) {
        guard let storageURL else { return }
        try? FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: storageURL, options: .atomic) }
    }

    /// `Application Support/<bundle id>/LocalLibrary.json`.
    public static func defaultStorageURL(bundleID: String = Bundle.main.bundleIdentifier ?? "com.roderickqiu.qtube") -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(bundleID, isDirectory: true).appendingPathComponent("LocalLibrary.json")
    }

    // MARK: Applying

    private func apply(_ c: Changes?, to tracks: [QTTrack], prepend: Bool, catalog: QTMockCatalog) -> [QTTrack] {
        guard let c, !c.isEmpty else { return tracks }
        var out = tracks.filter { !c.removes($0) }
        var present = Set(out.map(\.videoId))
        let extra = c.added.filter { present.insert($0).inserted }.compactMap { track($0, catalog: catalog) }
        out = prepend ? extra + out : out + extra
        if let order = c.order { out = Self.sorted(out, by: order) }
        return out
    }
}
