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

    /// The oldest plays that belong to `account` (plays of other accounts wait for theirs).
    public func nextBatch(max: Int, account: String? = nil) -> ArraySlice<QTScrobble> {
        items.filter { $0.account == account }.prefix(max)
    }

    public func count(account: String?) -> Int { items.count(where: { $0.account == account }) }

    /// Plays queued before they were keyed belong to the account that connects first.
    public mutating func adopt(by account: String) {
        guard items.contains(where: { $0.account == nil }) else { return }
        for i in items.indices where items[i].account == nil { items[i].account = account }
        save()
    }

    /// Drops one account's plays (an explicit Disconnect). Returns how many.
    @discardableResult
    public mutating func removeAll(account: String) -> Int {
        let before = items.count
        items.removeAll { $0.account == account }
        if items.count != before { save() }
        return before - items.count
    }

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

/// A playback event for the listen tracker. The caller stamps when it happened (`QTScrobbler.post(_:at:)`), so a
/// slow server answering an earlier event never makes it count late.
public enum QTListenEvent: Sendable {
    /// A new track (nil = playback stopped) playing at `rate` (0 = cued, paused).
    case track(QTScrobble?, rate: Double)
    /// Paused (0), resumed, or the speed changed.
    case rate(Double)
    /// Periodic check while playing.
    case tick
}

/// Drives the scrobble services from playback events: now-playing updates, scrobbles at the threshold, queued sends.
/// A service sends nothing until `configure` gives it one; every play that qualifies lands in the queue of each
/// configured service, keyed to its account (and server), and is only ever sent there.
///
/// Events are bookkeeping only (`post(_:at:)` / `setUp`); what they send runs afterwards on one chain in event order
/// (`send`), so a server that takes its time never delays the next event.
public actor QTScrobbler {
    private struct Sink {
        var queue: QTScrobbleQueue
        var service: (any QTScrobbleService)?
        /// Whose plays this service sends ("user" or "user@server"); nil in tests.
        var account: String?
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
    /// The network work queued so far (now playing, sends), one after another.
    private var sends: Task<Void, Never>?

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

    /// Sets (or with nil, stops) one service and waits for what that sends. Clears a pause and any backoff. A
    /// service connected mid-listen hears about the song now rather than at the next one.
    /// - Parameter account: whose plays it sends; plays queued for another account wait for that one.
    public func configure(_ id: QTScrobbleServiceID, service: (any QTScrobbleService)?, account: String? = nil,
                          sendsNowPlaying: Bool = true, onInvalidCredentials: (@Sendable () -> Void)? = nil,
                          onPaused: (@Sendable () -> Void)? = nil) async {
        await setUp(id, service: service, account: account, sendsNowPlaying: sendsNowPlaying,
                    onInvalidCredentials: onInvalidCredentials, onPaused: onPaused).value
    }

    /// `configure` without waiting for the network (the app's serial event queue).
    @discardableResult
    public func setUp(_ id: QTScrobbleServiceID, service: (any QTScrobbleService)?, account: String? = nil,
                      sendsNowPlaying: Bool = true, onInvalidCredentials: (@Sendable () -> Void)? = nil,
                      onPaused: (@Sendable () -> Void)? = nil) -> Task<Void, Never> {
        guard var sink = sinks[id] else { return send {} }
        sink.service = service
        sink.account = account
        sink.sendsNowPlaying = sendsNowPlaying
        sink.onInvalidCredentials = onInvalidCredentials
        sink.onPaused = onPaused
        sink.isPaused = false
        sink.retryAt = nil
        sink.backoff = 0
        sink.generation += 1
        if service != nil, let account { sink.queue.adopt(by: account) }
        sinks[id] = sink
        if service != nil, let item = tracker.item, tracker.isPlaying, !tracker.didScrobble {
            return send { await self.announce(item, to: id) }
        }
        return send {}
    }

    /// Sends one service's queued plays, after the work already queued (no waiting).
    @discardableResult
    public func sendQueued(_ id: QTScrobbleServiceID) -> Task<Void, Never> {
        send { await self.flush(id) }
    }

    /// An explicit Disconnect: that account's unsent plays are dropped. Returns how many.
    @discardableResult
    public func discardQueue(_ id: QTScrobbleServiceID, account: String) -> Int {
        sinks[id]?.queue.removeAll(account: account) ?? 0
    }

    /// Plays waiting for `account`.
    public func queuedCount(_ id: QTScrobbleServiceID, account: String?) -> Int {
        sinks[id]?.queue.count(account: account) ?? 0
    }

    /// Waits until the network work queued so far has run (tests, the coordinator's `drain`).
    public func settle() async {
        await sends?.value
    }

    /// Runs `work` after everything queued before it.
    private func send(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = sends
        let task = Task {
            await previous?.value
            await work()
        }
        sends = task
        return task
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

    /// Handles one playback event at `time` (when the app saw it; the listen clock's differences are what count)
    /// and queues what it sends. Scrobbles the previous track on a track change if it qualified.
    @discardableResult
    public func post(_ event: QTListenEvent, at time: Date) -> Task<Void, Never> {
        switch event {
        case .track(let item, let rate):
            if let due = tracker.scrobbleIfDue(at: time) { record(due) }
            guard let item else {
                tracker = QTListenTracker()
                return send { await self.flush() }
            }
            tracker.start(item, rate: rate, at: time)
            return send {
                if rate > 0 { await self.announce(item) }
                await self.flush()
            }
        case .rate(let rate):
            let wasPlaying = tracker.isPlaying
            tracker.setRate(rate, at: time)
            if let due = tracker.scrobbleIfDue(at: time) {
                record(due)
                return send { await self.flush() }
            }
            if rate > 0, !wasPlaying, let item = tracker.item, !tracker.didScrobble, tracker.listened(at: time) < 1 {
                return send { await self.announce(item) }
            }
            return send {}
        case .tick:
            if let due = tracker.scrobbleIfDue(at: time) { record(due) }
            return send { await self.flush() }
        }
    }

    /// A new track (or nil when playback stops) playing at `rate` (0 = cued, paused), now; waits for what it sends.
    public func trackChanged(to item: QTScrobble?, rate: Double) async {
        await post(.track(item, rate: rate), at: now()).value
    }

    public func trackChanged(to item: QTScrobble?, playing: Bool) async {
        await trackChanged(to: item, rate: playing ? 1 : 0)
    }

    /// Paused (0), resumed, or the speed changed.
    public func playbackChanged(rate: Double) async {
        await post(.rate(rate), at: now()).value
    }

    public func playbackChanged(playing: Bool) async {
        await playbackChanged(rate: playing ? 1 : 0)
    }

    /// Periodic check while playing (the app calls it every ~15 s), so long tracks scrobble at the threshold
    /// rather than only when they end, and queued plays go out once a backoff has passed.
    public func tick() async {
        await post(.tick, at: now()).value
    }

    /// The play goes into the queue of every configured service (a paused one too: it keeps its queue), as that
    /// service's account's.
    private func record(_ play: QTScrobble) {
        for id in QTScrobbleServiceID.allCases where sinks[id]?.service != nil {
            var keyed = play
            keyed.account = sinks[id]?.account
            sinks[id]?.queue.append(keyed)
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
        while let batch = sinks[id]?.queue.nextBatch(max: service.maxBatch, account: sink.account), !batch.isEmpty {
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
