import Foundation
import QTCore

/// Everything needed to put the queue back after a relaunch.
public struct QTQueueSnapshot: Codable, Sendable, Hashable {
    public static let currentVersion = 1

    public var version: Int
    public var queue: QTQueue
    /// The playing context (playlist/album/library/radio) in its original order, for un-shuffle and Repeat All.
    public var context: [QTQueueItem]
    /// Which section each queue item came from, so Previous puts the current item back where it was.
    public var origins: [UUID: QTQueueSection]
    /// Index in `context` of the last context item that played.
    public var contextCursor: Int?
    public var isShuffleOn: Bool
    public var repeatMode: QTRepeatMode
    public var mode: QTPlaybackMode
    /// Seconds into `queue.nowPlaying`.
    public var position: TimeInterval
    public var savedAt: Date

    public init(queue: QTQueue, context: [QTQueueItem] = [], origins: [UUID: QTQueueSection] = [:], contextCursor: Int? = nil,
                isShuffleOn: Bool = false, repeatMode: QTRepeatMode = .off, mode: QTPlaybackMode = .song,
                position: TimeInterval = 0, savedAt: Date = Date()) {
        version = Self.currentVersion
        self.queue = queue
        self.context = context
        self.origins = origins
        self.contextCursor = contextCursor
        self.isShuffleOn = isShuffleOn
        self.repeatMode = repeatMode
        self.mode = mode
        self.position = position
        self.savedAt = savedAt
    }
}

/// Persists the queue as JSON in Application Support (`~/Library/Application Support/<bundle id>/Playback/Queue.json`).
/// An actor so writes are serialized off the main thread; the controller debounces saves.
public actor QTQueueStore {
    public nonisolated let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The app's store. Dev variants (`com.roderickqiu.qtube.dev-<name>`) get their own folder.
    public static func applicationSupport(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.roderickqiu.qtube") -> QTQueueStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return QTQueueStore(fileURL: base.appending(path: bundleIdentifier).appending(path: "Playback").appending(path: "Queue.json"))
    }

    /// nil when there is no saved queue, or it can't be read (corrupt or from a newer version).
    public func load() -> QTQueueSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? Self.decoder.decode(QTQueueSnapshot.self, from: data),
              snapshot.version <= QTQueueSnapshot.currentVersion
        else { return nil }
        return snapshot
    }

    public func save(_ snapshot: QTQueueSnapshot) throws {
        let data = try Self.encoder.encode(snapshot)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
