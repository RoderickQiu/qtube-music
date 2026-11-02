import Foundation

/// An artist the listener chose not to hear ("Don't Play This Artist"). Kept in `QTSettings.blockedArtists`, on this
/// Mac only.
public struct QTBlockedArtist: Codable, Sendable, Hashable, Identifiable {
    /// Channel / browse id (`UC…`) when the menu it was blocked from knew one.
    public var channelID: String?
    /// The name as shown when it was blocked.
    public var name: String
    public var dateAdded: Date

    public var id: String { channelID.map { "id:\($0)" } ?? "name:\(QTArtistBlocklist.nameKey(name))" }

    public init(channelID: String? = nil, name: String, dateAdded: Date = Date()) {
        self.channelID = channelID.map(QTArtistBlocklist.channelKey)
        self.name = name
        self.dateAdded = dateAdded
    }

    public init(_ ref: QTArtistRef, dateAdded: Date = Date()) {
        self.init(channelID: ref.id, name: ref.name, dateAdded: dateAdded)
    }

    public init(_ artist: QTArtist, dateAdded: Date = Date()) {
        self.init(channelID: artist.id, name: artist.name, dateAdded: dateAdded)
    }
}

/// The blocked-artist list as a matcher (Limusic's rule): an artist is blocked when its channel id is on the list, or
/// its name is, compared lower-cased and exact (trimmed, Unicode-normalised). No fuzzy matching: "Aurora" never
/// blocks "Aurora Aksnes".
///
/// Where it applies (docs/architecture.md › Keep AI music out): Autoplay, radio, mixes and shuffle skip blocked
/// artists' songs; recommendations, search results and Home / Explore shelves hide them. What the listener picks
/// themselves still plays.
public struct QTArtistBlocklist: Sendable, Hashable {
    public private(set) var entries: [QTBlockedArtist]
    private var ids: Set<String>
    private var names: Set<String>

    public init(_ entries: [QTBlockedArtist] = []) {
        self.entries = entries
        ids = Set(entries.compactMap(\.channelID))
        names = Set(entries.map { Self.nameKey($0.name) }.filter { !$0.isEmpty })
    }

    public var isEmpty: Bool { entries.isEmpty }

    // MARK: Keys

    /// How names compare: trimmed, lower-cased, NFC. Nothing else is folded.
    public static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Library artist pages are `MPLAUC…`; the artist is the channel (`UC…`).
    public static func channelKey(_ id: String) -> String {
        id.hasPrefix("MPLA") ? String(id.dropFirst(4)) : id
    }

    // MARK: Matching

    public func blocks(channelID: String?, name: String) -> Bool {
        guard !entries.isEmpty else { return false }
        if let channelID, ids.contains(Self.channelKey(channelID)) { return true }
        return names.contains(Self.nameKey(name))
    }

    public func blocks(_ ref: QTArtistRef) -> Bool { blocks(channelID: ref.id, name: ref.name) }

    public func blocks(_ artist: QTArtist) -> Bool { blocks(channelID: artist.id, name: artist.name) }

    /// A song is blocked when any of its artists is (a feature counts).
    public func blocks(_ track: QTTrack) -> Bool { !entries.isEmpty && track.artists.contains(where: blocks) }

    public func blocks(_ album: QTAlbum) -> Bool { !entries.isEmpty && album.artists.contains(where: blocks) }

    /// Playlists are never hidden: who is in them isn't known from the card.
    public func blocks(_ item: QTShelfItem) -> Bool {
        switch item {
        case .track(let t), .video(let t): blocks(t)
        case .album(let a): blocks(a)
        case .artist(let a): blocks(a)
        case .playlist: false
        }
    }

    // MARK: Editing

    /// The entry that blocks this artist (by id, else by name), if any.
    public func entry(matching ref: QTArtistRef) -> QTBlockedArtist? {
        let key = Self.nameKey(ref.name)
        if let id = ref.id.map(Self.channelKey), let e = entries.first(where: { $0.channelID == id }) { return e }
        return entries.first { Self.nameKey($0.name) == key }
    }

    /// Adds the artist (once). Returns false when it was already blocked.
    @discardableResult
    public mutating func add(_ artist: QTBlockedArtist) -> Bool {
        guard entry(matching: QTArtistRef(id: artist.channelID, name: artist.name)) == nil else { return false }
        self = QTArtistBlocklist(entries + [artist])
        return true
    }

    /// Removes every entry that blocks this artist (its id and its name), so it plays again everywhere.
    @discardableResult
    public mutating func remove(_ ref: QTArtistRef) -> [QTBlockedArtist] {
        let id = ref.id.map(Self.channelKey)
        let key = Self.nameKey(ref.name)
        let removed = entries.filter { ($0.channelID != nil && $0.channelID == id) || Self.nameKey($0.name) == key }
        guard !removed.isEmpty else { return [] }
        self = QTArtistBlocklist(entries.filter { !removed.contains($0) })
        return removed
    }

    /// Without the artists a search names (the listener typed their name: they asked for them).
    public func ignoringArtists(named query: String) -> QTArtistBlocklist {
        let key = Self.nameKey(query)
        guard !key.isEmpty, names.contains(key) else { return self }
        return QTArtistBlocklist(entries.filter { Self.nameKey($0.name) != key })
    }

    // MARK: Filtering surfaces

    /// Shelf items without blocked artists' songs, videos, albums and artist cards.
    public func filter(_ items: [QTShelfItem]) -> [QTShelfItem] {
        entries.isEmpty ? items : items.filter { !blocks($0) }
    }

    /// Shelves without blocked items; a shelf left empty goes. `keeping` exempts one artist (their own page).
    public func filter(_ shelves: [QTShelf], keeping artist: QTArtistRef? = nil) -> [QTShelf] {
        guard !entries.isEmpty else { return shelves }
        var list = self
        if let artist { list.remove(artist) }
        return shelves.compactMap { shelf in
            var s = shelf
            s.items = list.filter(shelf.items)
            return s.items.isEmpty ? nil : s
        }
    }

    public func filter(_ tracks: [QTTrack]) -> [QTTrack] {
        entries.isEmpty ? tracks : tracks.filter { !blocks($0) }
    }
}

public extension QTQueueSource {
    /// Radios, mood and genre pages, and YouTube's mixes (`RD…`, not the curated `RDCLAK…` playlists): the queue
    /// picks from these by itself, so blocked artists are skipped there even in order.
    var isAutomatic: Bool {
        switch kind {
        case .radio: return true
        case .playlist:
            guard let id else { return false }
            let raw = id.hasPrefix("VL") ? String(id.dropFirst(2)) : id
            return raw.hasPrefix("RD") && !raw.hasPrefix("RDCLAK")
        case .album, .artist, .home, .search: return false
        }
    }
}
