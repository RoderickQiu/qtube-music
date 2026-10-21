import Foundation
import Observation
import QTCore

/// Library changes that aren't in the YouTube Music account — or aren't there *yet* — laid over what the account
/// shows, so every list, heart and sidebar row reads one state:
/// - **local**: kept on this Mac (Settings › Account › Sync off, or the demo library). Saved between launches per
///   identity (`storageURL`, `profile`), never in scripted or demo runs.
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
        /// Songs taken out (video ids).
        public var removed: Set<String> = []
        /// A reorder: the list's whole video-id order.
        public var order: [String]?
        public var title: String?
        public var description: String?
        public var privacy: QTPlaylistPrivacy?
        public var isDeleted = false

        public init() {}

        public var isEmpty: Bool { self == Changes() }
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
    /// The identity local changes belong to ("main", or a brand account id).
    @ObservationIgnored public private(set) var profile = "main"

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
        guard let i = created.firstIndex(where: { $0.id == id }) else { return }
        created[i].tracks = tracks
        if id.hasPrefix("local:") { save() }
    }

    /// Everything pending is dropped (an account switch or sign-out; their writes are abandoned).
    public func dropPending() {
        pending = [:]
        pendingFlags = [:]
        created.removeAll { $0.id.hasPrefix("pending:") }
    }

    // MARK: Profiles and storage

    /// Switches to another identity's local changes ("main" or a brand account id); `reload` reads the file again
    /// (storage was just attached).
    public func use(profile: String, reload: Bool = false) {
        guard profile != self.profile || reload else { return }
        if !reload { save() }
        self.profile = profile
        load()
    }

    private struct Snapshot: Codable {
        var local: [String: Changes] = [:]
        var created: [QTPlaylist] = []
        var flags: [String: Bool] = [:]
        var tracks: [String: QTTrack] = [:]
    }

    private func load() {
        local = [:]
        created.removeAll { $0.id.hasPrefix("local:") }
        localFlags = [:]
        guard let storageURL, let data = try? Data(contentsOf: storageURL),
              let all = try? JSONDecoder().decode([String: Snapshot].self, from: data),
              let mine = all[profile] else { return }
        local = mine.local
        created += mine.created
        localFlags = mine.flags
        knownTracks.merge(mine.tracks) { a, _ in a }
    }

    private func save() {
        guard let storageURL else { return }
        var all = (try? Data(contentsOf: storageURL)).flatMap { try? JSONDecoder().decode([String: Snapshot].self, from: $0) }
            ?? [:]
        let mine = created.filter { $0.id.hasPrefix("local:") }
        var named = Set(local.values.flatMap(\.added))
        named.formUnion(mine.flatMap { $0.tracks ?? [] }.map(\.videoId))
        let tracks = knownTracks.filter { named.contains($0.key) }
        all[profile] = Snapshot(local: local, created: mine, flags: localFlags, tracks: tracks)
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
        var out = tracks.filter { !c.removed.contains($0.videoId) }
        var present = Set(out.map(\.videoId))
        let extra = c.added.filter { present.insert($0).inserted }.compactMap { track($0, catalog: catalog) }
        out = prepend ? extra + out : out + extra
        if let order = c.order {
            let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            out = out.enumerated().sorted {
                (rank[$0.element.videoId] ?? Int.max, $0.offset) < (rank[$1.element.videoId] ?? Int.max, $1.offset)
            }.map(\.element)
        }
        return out
    }
}
