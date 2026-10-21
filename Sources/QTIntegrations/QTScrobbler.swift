import Foundation

// Scrobbling rules (https://www.last.fm/api/scrobbling, the same for ListenBrainz): a track counts when it is longer
// than 30 seconds and has been *listened to* (paused time and skipped-over time don't count) for half its length or
// 4 minutes, whichever comes first. Listening is counted in media time, so a song played at 2× counts at twice the
// wall-clock rate. The scrobble carries the time the track started.
//
// One listen tracker feeds every connected service (`QTScrobbleService`: Last.fm, ListenBrainz). Each service has its
// own offline queue (JSON file, survives relaunch), batch size, age limit, backoff and paused state, so one service
// being down or refusing the account never holds up or drops the other's plays.

public enum QTScrobbleRules {
    public static let minimumDuration: TimeInterval = 30
    public static let maximumThreshold: TimeInterval = 240
    /// Last.fm drops plays older than 14 days.
    public static let maximumAge: TimeInterval = 14 * 86_400

    /// Tracks of 30 s or less are never scrobbled.
    public static func isEligible(duration: TimeInterval) -> Bool { duration > minimumDuration }

    /// Listening time after which the play counts.
    public static func threshold(duration: TimeInterval) -> TimeInterval { min(duration / 2, maximumThreshold) }

    public static func shouldScrobble(duration: TimeInterval, listened: TimeInterval) -> Bool {
        isEligible(duration: duration) && listened >= threshold(duration: duration)
    }
}

/// Listened time of the current track in **media** seconds: how far the song has played, at the playback rate
/// (2× speed counts double; pauses, buffering and ads count nothing; seeks don't add).
public struct QTListenTracker: Sendable, Hashable {
    public private(set) var item: QTScrobble?
    public private(set) var listened: TimeInterval = 0
    /// Media seconds per second right now: 0 paused, 1 normal speed, 2 at 2×.
    public private(set) var rate: Double = 0
    private var since: Date?
    public private(set) var didScrobble = false

    public init() {}

    public var isPlaying: Bool { rate > 0 }

    /// A new track begins (`at` = when it started; the scrobble timestamp).
    public mutating func start(_ item: QTScrobble, rate: Double, at now: Date) {
        self.item = item
        listened = 0
        didScrobble = false
        self.rate = max(0, rate)
        since = now
    }

    public mutating func start(_ item: QTScrobble, playing: Bool, at now: Date) {
        start(item, rate: playing ? 1 : 0, at: now)
    }

    /// Playback paused (0), resumed or changed speed.
    public mutating func setRate(_ rate: Double, at now: Date) {
        listened = listened(at: now)
        self.rate = max(0, rate)
        since = now
    }

    public mutating func setPlaying(_ playing: Bool, at now: Date) { setRate(playing ? 1 : 0, at: now) }

    public func listened(at now: Date) -> TimeInterval {
        guard let since, rate > 0 else { return listened }
        return listened + max(0, now.timeIntervalSince(since)) * rate
    }

    /// The play to scrobble once it has crossed the threshold (at most once per track).
    public mutating func scrobbleIfDue(at now: Date) -> QTScrobble? {
        guard let item, !didScrobble, let d = item.duration,
              QTScrobbleRules.shouldScrobble(duration: TimeInterval(d), listened: listened(at: now)) else { return nil }
        didScrobble = true
        return item
    }
}

/// Persistent offline queue of plays a service hasn't accepted yet.
public struct QTScrobbleQueue: Sendable {
    public let fileURL: URL?
    public private(set) var items: [QTScrobble]
    public static let capacity = 2_000

    /// `fileURL` nil = memory only (tests).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        items = fileURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([QTScrobble].self, from: $0) } ?? []
    }

    /// `Application Support/<bundle id>/`, where each service's queue file lives.
    public static var defaultFolder: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.roderickqiu.qtube", isDirectory: true)
    }

    public mutating func append(_ s: QTScrobble) {
        guard !items.contains(s) else { return }
        items.append(s)
        if items.count > Self.capacity { items.removeFirst(items.count - Self.capacity) }
        save()
    }

    /// Drops plays the service would reject as too old.
    public mutating func pruneExpired(maxAge: TimeInterval, now: Date) {
        let cutoff = Int(now.timeIntervalSince1970 - maxAge)
        let before = items.count
        items.removeAll { $0.timestamp < cutoff }
        if items.count != before { save() }
    }

    public func nextBatch(max: Int) -> ArraySlice<QTScrobble> { items.prefix(max) }

    /// Removes these plays (sent, or rejected for good). By value: new plays may have arrived meanwhile.
    public mutating func remove(_ plays: some Sequence<QTScrobble>) {
        let gone = Set(plays)
        guard !gone.isEmpty else { return }
        items.removeAll { gone.contains($0) }
        save()
    }

    private func save() {
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: fileURL, options: .atomic) }
    }
}

// MARK: - Services

/// What a failed call means for the plays, decided by each service from its own error codes.
public enum QTScrobbleFailure: Sendable, Equatable {
    /// Network, server trouble or a rate limit: keep the plays, try again later (after `retryAfter` seconds when the
    /// service says how long, otherwise with a growing backoff).
    case temporary(retryAfter: TimeInterval?)
    /// The service refused the plays themselves; retrying won't help. A batch is split until the bad play is found,
    /// and only that one is dropped.
    case rejectedPlays
    /// The session or token no longer works: disconnect, the user connects again.
    case invalidCredentials
    /// The account or server itself is wrong (bad or suspended API key, an answer that isn't the API): pause sending
    /// and keep the queue until the settings change or the app relaunches.
    case accountProblem
}

/// A place plays go: Last.fm (`QTLastFMScrobbleService`) or a ListenBrainz server (`QTListenBrainzScrobbleService`).
public protocol QTScrobbleService: Sendable {
    /// Most plays one `submit` takes.
    var maxBatch: Int { get }
    /// Plays older than this are refused by the service, so the queue drops them first (nil = no limit).
    var maxAge: TimeInterval? { get }
    func nowPlaying(_ play: QTScrobble) async throws
    func submit(_ plays: [QTScrobble]) async throws
    func classify(_ error: any Error) -> QTScrobbleFailure
}

public enum QTScrobbleServiceID: String, Sendable, CaseIterable {
    case lastFM, listenBrainz

    /// The offline queue's file in `QTScrobbleQueue.defaultFolder` (`Scrobbles.json` predates ListenBrainz).
    public var queueFileName: String {
        switch self {
        case .lastFM: "Scrobbles.json"
        case .listenBrainz: "ListenBrainz.json"
        }
    }
}

// MARK: - Scrobbler

/// Drives the scrobble services from playback events: now-playing updates, scrobbles at the threshold, queued sends.
/// A service sends nothing until `configure` gives it one; every play that qualifies lands in the queue of each
/// configured service.
public actor QTScrobbler {
    private struct Sink {
        var queue: QTScrobbleQueue
        var service: (any QTScrobbleService)?
        var sendsNowPlaying = true
        /// Stopped for an account problem (`QTScrobbleFailure.accountProblem`) until `configure` or a relaunch.
        var isPaused = false
        var isFlushing = false
        /// No calls before this (a rate limit or the backoff after a temporary failure).
        var retryAt: Date?
        var backoff: TimeInterval = 0
        /// Bumped by `configure`, so an answer to an old configuration can't disconnect or pause the new one.
        var generation = 0
        var onInvalidCredentials: (@Sendable () -> Void)?
        var onPaused: (@Sendable () -> Void)?
    }

    /// Backoff after a temporary failure without a server-given wait: 15 s, doubling up to 10 min.
    static let minimumBackoff: TimeInterval = 15
    static let maximumBackoff: TimeInterval = 600

    private var sinks: [QTScrobbleServiceID: Sink]
    private var tracker = QTListenTracker()
    private let now: @Sendable () -> Date

    /// `queueFolder` nil = memory-only queues (tests).
    public init(queueFolder: URL? = QTScrobbleQueue.defaultFolder, now: @escaping @Sendable () -> Date = { Date() }) {
        sinks = Dictionary(uniqueKeysWithValues: QTScrobbleServiceID.allCases.map { id in
            (id, Sink(queue: QTScrobbleQueue(fileURL: queueFolder?.appendingPathComponent(id.queueFileName))))
        })
        self.now = now
    }

    public func queue(_ id: QTScrobbleServiceID) -> QTScrobbleQueue { sinks[id]!.queue }
    public func isPaused(_ id: QTScrobbleServiceID) -> Bool { sinks[id]!.isPaused }
    public func isActive(_ id: QTScrobbleServiceID) -> Bool { sinks[id]!.service != nil }
    /// Any service configured.
    public var isActive: Bool { sinks.values.contains { $0.service != nil } }

    /// Sets (or with nil, stops) one service. Clears a pause and any backoff. A service connected mid-listen hears
    /// about the song now rather than at the next one.
    public func configure(_ id: QTScrobbleServiceID, service: (any QTScrobbleService)?, sendsNowPlaying: Bool = true,
                          onInvalidCredentials: (@Sendable () -> Void)? = nil, onPaused: (@Sendable () -> Void)? = nil) async {
        guard var sink = sinks[id] else { return }
        sink.service = service
        sink.sendsNowPlaying = sendsNowPlaying
        sink.onInvalidCredentials = onInvalidCredentials
        sink.onPaused = onPaused
        sink.isPaused = false
        sink.retryAt = nil
        sink.backoff = 0
        sink.generation += 1
        sinks[id] = sink
        if service != nil, let item = tracker.item, tracker.isPlaying, !tracker.didScrobble {
            await announce(item, to: id)
        }
    }

    /// Last.fm shorthand: a client and session key (either nil stops Last.fm).
    public func configure(client: QTLastFMClient?, sessionKey: String?, sendsNowPlaying: Bool = true,
                          onInvalidSession: (@Sendable () -> Void)? = nil, onPaused: (@Sendable () -> Void)? = nil) async {
        let service = client.flatMap { c in sessionKey.map { QTLastFMScrobbleService(client: c, sessionKey: $0) } }
        await configure(.lastFM, service: service, sendsNowPlaying: sendsNowPlaying,
                        onInvalidCredentials: onInvalidSession, onPaused: onPaused)
    }

    /// Forgets the current listen without scrobbling it (every service turned off, demo playback).
    public func reset() {
        tracker = QTListenTracker()
    }

    /// The listen being tracked (tests, diagnostics).
    public var currentItem: QTScrobble? { tracker.item }

    /// A new track (or nil when playback stops) playing at `rate` (0 = cued, paused). Scrobbles the previous one if
    /// it qualified.
    public func trackChanged(to item: QTScrobble?, rate: Double) async {
        let t = now()
        if let due = tracker.scrobbleIfDue(at: t) { record(due) }
        if let item {
            tracker.start(item, rate: rate, at: t)
            if rate > 0 { await announce(item) }
        } else {
            tracker = QTListenTracker()
        }
        await flush()
    }

    public func trackChanged(to item: QTScrobble?, playing: Bool) async {
        await trackChanged(to: item, rate: playing ? 1 : 0)
    }

    /// Paused (0), resumed, or the speed changed.
    public func playbackChanged(rate: Double) async {
        let t = now()
        let wasPlaying = tracker.isPlaying
        tracker.setRate(rate, at: t)
        if let due = tracker.scrobbleIfDue(at: t) {
            record(due)
            await flush()
        } else if rate > 0, !wasPlaying, let item = tracker.item, !tracker.didScrobble, tracker.listened(at: t) < 1 {
            await announce(item)
        }
    }

    public func playbackChanged(playing: Bool) async {
        await playbackChanged(rate: playing ? 1 : 0)
    }

    /// Periodic check while playing (the app calls it every ~15 s), so long tracks scrobble at the threshold
    /// rather than only when they end, and queued plays go out once a backoff has passed.
    public func tick() async {
        if let due = tracker.scrobbleIfDue(at: now()) { record(due) }
        await flush()
    }

    /// The play goes into the queue of every configured service (a paused one too: it keeps its queue).
    private func record(_ play: QTScrobble) {
        for id in QTScrobbleServiceID.allCases where sinks[id]?.service != nil {
            sinks[id]?.queue.append(play)
        }
    }

    private func isWaiting(_ sink: Sink) -> Bool {
        sink.retryAt.map { now() < $0 } ?? false
    }

    /// Now playing goes to each service at once (a slow server never delays the other); best effort.
    private func announce(_ item: QTScrobble) async {
        await withTaskGroup(of: Void.self) { group in
            for id in QTScrobbleServiceID.allCases { group.addTask { await self.announce(item, to: id) } }
        }
    }

    private func announce(_ item: QTScrobble, to id: QTScrobbleServiceID) async {
        guard let sink = sinks[id], let service = sink.service, sink.sendsNowPlaying, !sink.isPaused, !isWaiting(sink)
        else { return }
        do {
            try await service.nowPlaying(item)
        } catch {
            guard sinks[id]?.generation == sink.generation else { return }
            switch service.classify(error) {
            case .invalidCredentials: invalidate(id)
            case .temporary(let after?): backOff(id, after: after) // a rate limit holds every call
            default: break // Now playing is best effort.
            }
        }
    }

    /// Sends every service's queued plays, each in its own batches and at the same time.
    public func flush() async {
        await withTaskGroup(of: Void.self) { group in
            for id in QTScrobbleServiceID.allCases { group.addTask { await self.flush(id) } }
        }
    }

    /// Sends one service's queued plays. Temporary failures keep them for later (with backoff); only plays the
    /// service rejects as plays are dropped; an account problem pauses sending and keeps the queue.
    public func flush(_ id: QTScrobbleServiceID) async {
        guard let sink = sinks[id], let service = sink.service, !sink.isFlushing, !sink.isPaused, !isWaiting(sink)
        else { return }
        sinks[id]?.isFlushing = true
        defer { sinks[id]?.isFlushing = false }
        if let maxAge = service.maxAge { sinks[id]?.queue.pruneExpired(maxAge: maxAge, now: now()) }
        while let batch = sinks[id]?.queue.nextBatch(max: service.maxBatch), !batch.isEmpty {
            guard await deliver(batch, via: service, to: id, generation: sink.generation) else { return }
        }
    }

    /// Submits `batch`; false = stop sending for now. A batch refused as plays is halved until the bad play is alone,
    /// and only that one is dropped.
    private func deliver(_ batch: ArraySlice<QTScrobble>, via service: any QTScrobbleService, to id: QTScrobbleServiceID,
                         generation: Int) async -> Bool {
        do {
            try await service.submit(Array(batch))
            guard sinks[id]?.generation == generation else { return false }
            sinks[id]?.queue.remove(batch)
            sinks[id]?.backoff = 0
            return true
        } catch {
            guard sinks[id]?.generation == generation else { return false }
            switch service.classify(error) {
            case .rejectedPlays:
                if batch.count == 1 {
                    sinks[id]?.queue.remove(batch)
                    return true
                }
                let middle = batch.startIndex + batch.count / 2
                guard await deliver(batch[..<middle], via: service, to: id, generation: generation) else { return false }
                return await deliver(batch[middle...], via: service, to: id, generation: generation)
            case .temporary(let after):
                backOff(id, after: after)
                return false
            case .invalidCredentials:
                invalidate(id)
                return false
            case .accountProblem:
                sinks[id]?.isPaused = true
                sinks[id]?.onPaused?()
                return false
            }
        }
    }

    private func backOff(_ id: QTScrobbleServiceID, after: TimeInterval?) {
        guard let sink = sinks[id] else { return }
        let next = min(max(sink.backoff * 2, Self.minimumBackoff), Self.maximumBackoff)
        sinks[id]?.backoff = next
        sinks[id]?.retryAt = now().addingTimeInterval(after.map { max($0, 1) } ?? next)
    }

    private func invalidate(_ id: QTScrobbleServiceID) {
        let callback = sinks[id]?.onInvalidCredentials
        sinks[id]?.service = nil
        callback?()
    }
}
