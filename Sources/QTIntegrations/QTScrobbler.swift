import Foundation

// Scrobbling rules (https://www.last.fm/api/scrobbling): a track counts when it is longer than 30 seconds and has
// been *listened to* (paused time and skipped-over time don't count) for half its length or 4 minutes, whichever
// comes first. The scrobble carries the time the track started. Plays that can't be sent wait in an offline queue
// (JSON file, survives relaunch) and go out in batches of 50 when Last.fm is reachable; Last.fm drops anything
// older than 14 days, so the queue does too.

public enum QTScrobbleRules {
    public static let minimumDuration: TimeInterval = 30
    public static let maximumThreshold: TimeInterval = 240
    public static let maximumAge: TimeInterval = 14 * 86_400

    /// Tracks of 30 s or less are never scrobbled.
    public static func isEligible(duration: TimeInterval) -> Bool { duration > minimumDuration }

    /// Listening time after which the play counts.
    public static func threshold(duration: TimeInterval) -> TimeInterval { min(duration / 2, maximumThreshold) }

    public static func shouldScrobble(duration: TimeInterval, listened: TimeInterval) -> Bool {
        isEligible(duration: duration) && listened >= threshold(duration: duration)
    }
}

/// Listened time of the current track: wall-clock time spent playing (seeks don't add, pauses don't count).
public struct QTListenTracker: Sendable, Hashable {
    public private(set) var item: QTScrobble?
    public private(set) var listened: TimeInterval = 0
    private var playingSince: Date?
    public private(set) var didScrobble = false

    public init() {}

    /// A new track begins (`at` = when it started; the scrobble timestamp).
    public mutating func start(_ item: QTScrobble, playing: Bool, at now: Date) {
        self.item = item
        listened = 0
        didScrobble = false
        playingSince = playing ? now : nil
    }

    public mutating func setPlaying(_ playing: Bool, at now: Date) {
        if playing {
            if playingSince == nil { playingSince = now }
        } else if let since = playingSince {
            listened += max(0, now.timeIntervalSince(since))
            playingSince = nil
        }
    }

    public func listened(at now: Date) -> TimeInterval {
        listened + (playingSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    /// The play to scrobble once it has crossed the threshold (at most once per track).
    public mutating func scrobbleIfDue(at now: Date) -> QTScrobble? {
        guard let item, !didScrobble, let d = item.duration,
              QTScrobbleRules.shouldScrobble(duration: TimeInterval(d), listened: listened(at: now)) else { return nil }
        didScrobble = true
        return item
    }
}

/// Persistent offline queue of plays not yet accepted by Last.fm.
public struct QTScrobbleQueue: Sendable {
    public let fileURL: URL?
    public private(set) var items: [QTScrobble]
    public static let capacity = 2_000

    /// `fileURL` nil = memory only (tests).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        items = fileURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([QTScrobble].self, from: $0) } ?? []
    }

    public static var defaultURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let id = Bundle.main.bundleIdentifier ?? "com.roderickqiu.qtube"
        return base.appendingPathComponent(id, isDirectory: true).appendingPathComponent("Scrobbles.json")
    }

    public mutating func append(_ s: QTScrobble) {
        guard !items.contains(s) else { return }
        items.append(s)
        if items.count > Self.capacity { items.removeFirst(items.count - Self.capacity) }
        save()
    }

    /// Drops plays Last.fm would reject as too old.
    public mutating func pruneExpired(now: Date) {
        let cutoff = Int(now.timeIntervalSince1970 - QTScrobbleRules.maximumAge)
        let before = items.count
        items.removeAll { $0.timestamp < cutoff }
        if items.count != before { save() }
    }

    public var nextBatch: [QTScrobble] { Array(items.prefix(QTLastFMRequest.maxBatch)) }

    public mutating func removeFirst(_ n: Int) {
        items.removeFirst(min(n, items.count))
        save()
    }

    private func save() {
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: fileURL, options: .atomic) }
    }
}

/// Drives Last.fm from playback events: now-playing updates, scrobbles at the threshold, queued sends.
/// Inactive (sends nothing) until `configure` gets a client and a session key.
public actor QTScrobbler {
    public private(set) var queue: QTScrobbleQueue
    private var tracker = QTListenTracker()
    private var client: QTLastFMClient?
    private var sessionKey: String?
    private var sendsNowPlaying = true
    private var isFlushing = false
    /// Sending stopped because Last.fm refused the API account itself (bad or suspended key, bad signature, an
    /// answer it couldn't read): the queue is kept; sending resumes after `configure` (new credentials) or a relaunch.
    public private(set) var isPaused = false
    private let now: @Sendable () -> Date
    /// Called when Last.fm rejects the session key (the user must connect again).
    private var onInvalidSession: (@Sendable () -> Void)?
    /// Called once when sending pauses for an API-account problem (`isPaused`).
    private var onPaused: (@Sendable () -> Void)?

    public init(queueURL: URL? = QTScrobbleQueue.defaultURL, now: @escaping @Sendable () -> Date = { Date() }) {
        queue = QTScrobbleQueue(fileURL: queueURL)
        self.now = now
    }

    public var isActive: Bool { client != nil && sessionKey != nil }

    public func configure(client: QTLastFMClient?, sessionKey: String?, sendsNowPlaying: Bool = true,
                          onInvalidSession: (@Sendable () -> Void)? = nil, onPaused: (@Sendable () -> Void)? = nil) {
        self.client = client
        self.sessionKey = sessionKey
        self.sendsNowPlaying = sendsNowPlaying
        self.onInvalidSession = onInvalidSession
        self.onPaused = onPaused
        isPaused = false
    }

    /// Forgets the current listen without scrobbling it (Last.fm turned off, demo playback).
    public func reset() {
        tracker = QTListenTracker()
    }

    /// The listen being tracked (tests, diagnostics).
    public var currentItem: QTScrobble? { tracker.item }

    /// A new track (or nil when playback stops). Scrobbles the previous one if it qualified.
    public func trackChanged(to item: QTScrobble?, playing: Bool) async {
        let t = now()
        if let due = tracker.scrobbleIfDue(at: t) { queue.append(due) }
        if let item {
            tracker.start(item, playing: playing, at: t)
            if playing { await announce(item) }
        } else {
            tracker = QTListenTracker()
        }
        await flush()
    }

    public func playbackChanged(playing: Bool) async {
        let t = now()
        tracker.setPlaying(playing, at: t)
        if let due = tracker.scrobbleIfDue(at: t) {
            queue.append(due)
            await flush()
        } else if playing, let item = tracker.item, !tracker.didScrobble, tracker.listened(at: t) < 1 {
            await announce(item)
        }
    }

    /// Periodic check while playing (the app calls it every ~15 s), so long tracks scrobble at the threshold
    /// rather than only when they end.
    public func tick() async {
        if let due = tracker.scrobbleIfDue(at: now()) {
            queue.append(due)
            await flush()
        }
    }

    private func announce(_ item: QTScrobble) async {
        guard sendsNowPlaying, !isPaused, let client, let sessionKey else { return }
        do {
            try await client.updateNowPlaying(item, sessionKey: sessionKey)
        } catch let error as QTLastFMError where error.isInvalidSession {
            invalidate()
        } catch {
            // Now playing is best effort.
        }
    }

    /// Sends queued plays, 50 at a time. Network / temporary errors keep them for later; only plays Last.fm rejects
    /// as plays (error 6 / 7) are dropped. Anything that says the API account itself is wrong (10 invalid key,
    /// 26 suspended key, 13 invalid signature, unreadable answers…) pauses sending and keeps the queue.
    public func flush() async {
        guard !isFlushing, !isPaused, let client, let sessionKey else { return }
        isFlushing = true
        defer { isFlushing = false }
        queue.pruneExpired(now: now())
        while !queue.items.isEmpty {
            let batch = queue.nextBatch
            do {
                try await client.scrobble(batch, sessionKey: sessionKey)
                queue.removeFirst(batch.count)
            } catch let error as QTLastFMError {
                if error.isInvalidSession { invalidate() }
                if error.isTemporary || error.isInvalidSession { return }
                if error.isRejectedPlay {
                    // The plays themselves are bad: drop the batch rather than retrying forever.
                    queue.removeFirst(batch.count)
                    continue
                }
                isPaused = true
                onPaused?()
                return
            } catch {
                return
            }
        }
    }

    private func invalidate() {
        sessionKey = nil
        onInvalidSession?()
    }
}
