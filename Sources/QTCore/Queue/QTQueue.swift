import Foundation

/// One entry in the queue. Has its own id so the same track can appear twice.
public struct QTQueueItem: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var track: QTTrack

    public init(id: UUID = UUID(), track: QTTrack) {
        self.id = id
        self.track = track
    }
}

/// What the autoplay section continues from ("Autoplay · from “Liked Songs”").
public struct QTQueueSource: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable { case playlist, album, artist, radio, home, search }
    public var kind: Kind
    /// Playlist/album/artist id, if any.
    public var id: String?
    public var title: QTDisplayText

    public init(kind: Kind, id: String? = nil, title: QTDisplayText) {
        self.kind = kind
        self.id = id
        self.title = title
    }
}

/// The three queue sections. `nowPlaying` is a single item, not a list.
public enum QTQueueSection: String, Codable, Sendable, Hashable {
    /// Play Next / Add to Queue land here (user-added); drag to reorder.
    case upNext
    /// Radio/context continuation, visually distinct, can be turned off.
    case autoplay
}

public enum QTRepeatMode: String, Codable, Sendable, Hashable, CaseIterable {
    case off, all, one
}

/// Snapshot returned by `clearUpNext()`; pass it to `undoClearUpNext(_:)`.
public struct QTQueueUndoToken: Sendable, Hashable {
    fileprivate let items: [QTQueueItem]
}

/// The play queue: Now Playing · Up Next (user-added) · Autoplay (from a source).
/// Value type, Codable for persistence (the queue survives relaunch). Policy (when to advance, shuffle order,
/// fetching more autoplay) lives in QTPlayback's `QTQueueController`.
public struct QTQueue: Codable, Sendable, Hashable {
    public var nowPlaying: QTQueueItem?
    public var upNext: [QTQueueItem]
    public var autoplay: [QTQueueItem]
    public var autoplaySource: QTQueueSource?
    public var isAutoplayEnabled: Bool
    /// Most recent last. Capped at `historyLimit`.
    public var history: [QTQueueItem]

    public static let historyLimit = 200

    public init(nowPlaying: QTQueueItem? = nil, upNext: [QTQueueItem] = [], autoplay: [QTQueueItem] = [],
                autoplaySource: QTQueueSource? = nil, isAutoplayEnabled: Bool = true, history: [QTQueueItem] = []) {
        self.nowPlaying = nowPlaying
        self.upNext = upNext
        self.autoplay = autoplay
        self.autoplaySource = autoplaySource
        self.isAutoplayEnabled = isAutoplayEnabled
        self.history = history
    }

    public var isEmpty: Bool { nowPlaying == nil && upNext.isEmpty && autoplay.isEmpty }

    /// What plays after the current item.
    public var nextItem: QTQueueItem? {
        upNext.first ?? (isAutoplayEnabled ? autoplay.first : nil)
    }

    public func items(in section: QTQueueSection) -> [QTQueueItem] {
        section == .upNext ? upNext : autoplay
    }

    // MARK: Starting playback

    /// Plays `tracks[startIndex]` now; the rest of `tracks` after it becomes Autoplay from `source`.
    /// Up Next (user-added) is kept, as in Music.app.
    public mutating func play(_ tracks: [QTTrack], startingAt startIndex: Int = 0, source: QTQueueSource? = nil) {
        guard tracks.indices.contains(startIndex) else { return }
        pushHistory()
        nowPlaying = QTQueueItem(track: tracks[startIndex])
        autoplay = tracks[(startIndex + 1)...].filter { $0.availability.isPlayable }.map { QTQueueItem(track: $0) }
        autoplaySource = source
    }

    // MARK: Editing Up Next

    /// Inserts at the front of Up Next ("Play Next").
    public mutating func playNext(_ tracks: [QTTrack]) {
        upNext.insert(contentsOf: tracks.map { QTQueueItem(track: $0) }, at: 0)
    }

    /// Appends to Up Next ("Add to Queue").
    public mutating func addToQueue(_ tracks: [QTTrack]) {
        upNext.append(contentsOf: tracks.map { QTQueueItem(track: $0) })
    }

    public mutating func insert(_ tracks: [QTTrack], at index: Int, in section: QTQueueSection) {
        let items = tracks.map { QTQueueItem(track: $0) }
        switch section {
        case .upNext: upNext.insert(contentsOf: items, at: index.clamped(to: 0...upNext.count))
        case .autoplay: autoplay.insert(contentsOf: items, at: index.clamped(to: 0...autoplay.count))
        }
    }

    /// SwiftUI `onMove` semantics (`toOffset` is the index *before* removal).
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int, in section: QTQueueSection) {
        switch section {
        case .upNext: upNext.qtMove(fromOffsets: source, toOffset: destination)
        case .autoplay: autoplay.qtMove(fromOffsets: source, toOffset: destination)
        }
    }

    /// Moves an item between sections (dragging from Autoplay into Up Next).
    public mutating func move(itemID: UUID, to section: QTQueueSection, at index: Int) {
        guard let item = (upNext + autoplay).first(where: { $0.id == itemID }) else { return }
        remove(ids: [itemID])
        switch section {
        case .upNext: upNext.insert(item, at: index.clamped(to: 0...upNext.count))
        case .autoplay: autoplay.insert(item, at: index.clamped(to: 0...autoplay.count))
        }
    }

    public mutating func remove(ids: Set<UUID>) {
        upNext.removeAll { ids.contains($0.id) }
        autoplay.removeAll { ids.contains($0.id) }
    }

    /// Empties Up Next and returns a token for Undo (the toast's "Undo" button).
    @discardableResult
    public mutating func clearUpNext() -> QTQueueUndoToken {
        let token = QTQueueUndoToken(items: upNext)
        upNext = []
        return token
    }

    /// Restores cleared items in front of anything added since.
    public mutating func undoClearUpNext(_ token: QTQueueUndoToken) {
        let existing = Set(upNext.map(\.id))
        upNext.insert(contentsOf: token.items.filter { !existing.contains($0.id) }, at: 0)
    }

    // MARK: Advancing

    /// Moves to the next item (Up Next first, then Autoplay). Returns the new now-playing item, or nil at the end.
    @discardableResult
    public mutating func advance() -> QTQueueItem? {
        let next: QTQueueItem
        if !upNext.isEmpty {
            next = upNext.removeFirst()
        } else if isAutoplayEnabled, !autoplay.isEmpty {
            next = autoplay.removeFirst()
        } else {
            return nil
        }
        pushHistory()
        nowPlaying = next
        return next
    }

    /// Goes back to the previous item; the current one returns to the front of Up Next.
    @discardableResult
    public mutating func goBack() -> QTQueueItem? {
        guard let prev = history.popLast() else { return nil }
        if let now = nowPlaying { upNext.insert(now, at: 0) }
        nowPlaying = prev
        return prev
    }

    private mutating func pushHistory() {
        guard let now = nowPlaying else { return }
        history.append(now)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
    }
}

extension Array {
    /// Same semantics as SwiftUI's `move(fromOffsets:toOffset:)`, without importing SwiftUI.
    mutating func qtMove(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().filter { indices.contains($0) }.map { self[$0] }
        let before = source.filter { $0 < destination }.count
        for i in source.sorted(by: >) where indices.contains(i) { remove(at: i) }
        insert(contentsOf: moving, at: (destination - before).clamped(to: 0...count))
    }
}
