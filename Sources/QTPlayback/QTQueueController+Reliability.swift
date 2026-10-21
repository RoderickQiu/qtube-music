import Foundation
import QTCore

// Owner: builder "playback". Keeping the queue and the engine in agreement (docs/prelaunch-implementation.md §3).
//
// The queue owns what plays; the engine only reports. Most silent stops came from the two disagreeing with nobody
// noticing, so the queue watches (`superviseTick`, once a second while the listener wants music or something is
// pending — nothing runs while idle) and reconciles:
// - a pause nobody asked for (YouTube's "Still listening?", WebKit) is undone once after a short grace; a second one
//   soon after stops fighting and says so once. A pause (or Play) from the Picture in Picture window is the
//   listener's own: the queue's intent follows it.
// - the engine playing another item than the queue's current one (a stale gapless chain), or none, for 2 s reloads
//   the queue's track (or moves on, when the old one had ended);
// - an end or failure the queue missed (it came while a load was in flight) is acted on after 3 s;
// - network trouble retries the same track — when the network is back, or after a short backoff while online —
//   instead of skipping it, and never counts towards the skip limit; after 10 min without music it pauses and says
//   so once. A load that hangs for 90 s online counts as a network failure.
// - Autoplay's radio gets a timeout per attempt and two retries; only when the queue then runs out is the listener
//   told (with Retry).
// Recovery is silent; `onNotice` is reserved for what the listener has to know or act on — one toast per event.
// Every grace and patience here is wall-clock time (the watch runs on uptime), so it holds at any playback speed;
// the one media-time threshold (a stale next found in the current track's last seconds) is scaled by `rate`.

/// Why playback stopped when no single track failed (`QTQueueController.onNotice`). The app shows one toast.
public enum QTPlaybackNotice: Sendable, Hashable {
    /// Playback paused without the listener asking, and resuming didn't hold. Offer Resume (`play()`).
    case interrupted
    /// Autoplay couldn't load more songs after its retries, so the queue stopped at its end. Offer Retry
    /// (`retryAutoplay()`).
    case autoplayUnavailable
    /// The network has been gone (or failing every load) for `networkPatience`: playback paused instead of waiting on.
    case networkUnavailable
}

/// How one autoplay continuation went.
enum QTContinuationResult: Sendable, Equatable {
    case added
    /// The radio had nothing new: a natural end.
    case empty
    /// Every attempt failed or timed out.
    case failed
    /// The context changed meanwhile; the answer was dropped.
    case stale
}

/// What the queue's process activity asks of the system.
enum QTPlaybackActivityLevel: Equatable {
    case none
    /// Loading, between tracks, retrying: App Nap stays away, the Mac may still idle-sleep.
    case busy
    /// Playing: the Mac doesn't idle-sleep either.
    case playing
}

/// The reliability watch's memory between ticks (uptime seconds).
struct QTPlaybackWatch {
    struct Timer {
        let id: Int
        let due: TimeInterval
        let fire: @MainActor () -> Void
    }

    /// Things waiting on the clock (continuation timeouts and retries), fired by `superviseTick`.
    var timers: [Timer] = []
    var nextTimerID = 0
    var lastTick: TimeInterval?
    /// The engine sits paused while the listener wants music, since.
    var pausedSince: TimeInterval?
    /// When an unrequested pause was last undone.
    var lastAutoResume: TimeInterval?
    /// The engine's item isn't the queue's current one (or it has none), since.
    var mismatchSince: TimeInterval?
    /// Ended or failed, with the listener waiting and nothing moving on, since.
    var stuckSince: TimeInterval?
    /// Online seconds the newest load has been in flight.
    var loadOnlineSeconds: TimeInterval = 0
    /// The watch gave up on the newest load (it never answered); the engine may still show it loading.
    var abandonedLoad = false
    /// No music because of the network (failed loads, waiting offline), since; cleared once something plays.
    var networkTroubleSince: TimeInterval?
    /// The next try of the current item after an online network failure.
    var networkRetryAt: TimeInterval?
    /// Offline: the current item is tried again once the network is back.
    var waitingForNetwork = false
    var networkRetries = 0
    var networkRetryItem: UUID?
    var retryPosition: TimeInterval = 0
    /// The last position seen for a queue item (where a reload picks up).
    var lastPosition: (id: UUID, time: TimeInterval)?
    /// The load whose failure was already acted on (its `.failed` state may still arrive from the engine's stream);
    /// cleared once the engine plays again.
    var handledFailureToken: Int?

    var isRetryingNetwork: Bool { networkRetryAt != nil || waitingForNetwork }
    var isRecovering: Bool { pausedSince != nil || isRetryingNetwork }

    mutating func listenerResumed() {
        pausedSince = nil
        lastAutoResume = nil
        stuckSince = nil
    }

    mutating func listenerPaused() {
        pausedSince = nil
        stuckSince = nil
        networkRetryAt = nil
        waitingForNetwork = false
        networkTroubleSince = nil
    }

    mutating func loadDidStart(_ id: UUID) {
        pausedSince = nil
        mismatchSince = nil
        stuckSince = nil
        loadOnlineSeconds = 0
        abandonedLoad = false
        networkRetryAt = nil
        waitingForNetwork = false
        if networkRetryItem != id { networkRetries = 0 }
    }

    /// Forgets everything about the current item (the queue was cleared); pending waits stay (they end on their own).
    mutating func reset() {
        self = QTPlaybackWatch(timers: timers, nextTimerID: nextTimerID)
    }

    mutating func engineDidChange() {
        pausedSince = nil
        mismatchSince = nil
        stuckSince = nil
        lastTick = nil
    }

    mutating func observe(_ s: QTPlaybackState, current: UUID?, at now: TimeInterval) {
        if s.status == .playing, !s.isBuffering {
            networkTroubleSince = nil
            networkRetries = 0
            pausedSince = nil
            if let current, s.item?.queueID == current { abandonedLoad = false }
        }
        if let current, s.item?.queueID == current, s.status == .playing || s.status == .paused || s.status == .ended {
            handledFailureToken = nil
        }
        if let current, s.item?.queueID == current, s.ad == nil, s.status != .loading, s.status != .idle {
            lastPosition = (current, s.timeline.time(atUptime: now))
        }
    }
}

extension QTQueueController {
    /// Grace before an unrequested pause is undone (WebKit's own resume after a window move takes ~1 s).
    static let pauseGrace: TimeInterval = 1.5
    /// A second unrequested pause within this long of undoing one stops the fighting.
    static let autoResumeWindow: TimeInterval = 60
    /// How long the queue and the engine may disagree about the current item, or sit ended / failed unattended.
    static let mismatchGrace: TimeInterval = 2
    static let stuckGrace: TimeInterval = 3
    /// Online seconds a load may take before it counts as a network failure (the web engine's own limit is ~50 s).
    static let loadPatience: TimeInterval = 90
    /// Without music because of the network for this long, playback pauses (and says so once).
    static let networkPatience: TimeInterval = 600
    /// Waits before trying the same item again after an online network failure; then it is skipped. (Each try of the
    /// web engine already includes its own fresh-page retry, and the count starts over once the item plays, so a
    /// track that stalls now and then is retried every time while one that never starts doesn't hold the queue long.)
    static let networkRetryDelays: [TimeInterval] = [3, 10]
    /// One autoplay continuation attempt; failed attempts are retried after these waits.
    static let continuationTimeout: TimeInterval = 15
    static let continuationRetryDelays: [TimeInterval] = [2, 5]

    // MARK: Ticking

    /// Whether the watch has anything to look after (else its loop stops; idle costs nothing). A load nobody waits for
    /// (a queue restored at launch, cued) is watched only while online — offline it may wait for hours, and the engine
    /// times it out itself once the network is back.
    var needsSupervision: Bool {
        wantsPlayback || !watch.timers.isEmpty || (loadInFlight != nil && engine.isNetworkAvailable)
    }

    /// One look at the queue and the engine; acts on what has been wrong for long enough. Runs once a second while
    /// needed (`superviseSoon`); tests on a manual clock call it themselves.
    func superviseTick() {
        let now = uptime()
        let elapsed = watch.lastTick.map { min(max(0, now - $0), 5) } ?? 0
        watch.lastTick = now
        fireDueTimers(at: now)
        defer { updatePlaybackActivity() }
        // A change the engine never published (or that is still on its way) is taken now.
        if engine.state != state { receive(engine.state, from: engine) }
        guard let current = queue.nowPlaying else {
            watch.mismatchSince = nil
            watch.pausedSince = nil
            watch.stuckSince = nil
            return
        }
        let s = engine.state
        watch.observe(s, current: current.id, at: now)
        if wantsPlayback, !engine.isNetworkAvailable, !(s.status == .playing && !s.isBuffering) {
            watch.networkTroubleSince = watch.networkTroubleSince ?? now
        }
        if wantsPlayback, let since = watch.networkTroubleSince, now - since >= Self.networkPatience {
            giveUpOnNetwork()
            return
        }
        if loadInFlight != nil {
            checkLoad(current, elapsed: elapsed)
            return
        }
        if checkMismatch(s, current, now) { return }
        if checkNetworkRetry(s, current, now) { return }
        checkUnrequestedPause(s, current, now)
        checkStuck(s, current, now)
    }

    /// Starts the watch's loop if it isn't running (no-op without a supervision interval: tests tick by hand).
    func superviseSoon() {
        startSupervisionLoop()
    }

    // MARK: Checks

    /// A load that never finishes online (an engine stuck on a dead page) counts as a network failure.
    private func checkLoad(_ current: QTQueueItem, elapsed: TimeInterval) {
        if engine.isNetworkAvailable { watch.loadOnlineSeconds += elapsed }
        guard watch.loadOnlineSeconds >= Self.loadPatience else { return }
        // Abandon it: its outcome, whenever it comes, is ignored; the retry's load supersedes it in the engine.
        loadToken += 1
        loadInFlight = nil
        watch.loadOnlineSeconds = 0
        watch.abandonedLoad = true
        let error = QTPlaybackError.network("load timed out")
        lastFailure = error
        guard wantsPlayback else {
            // Nobody is waiting: show it held instead of loading forever; Play starts it over.
            engine.pause()
            return
        }
        Task { await self.skipAfterFailure(current.track, error) }
    }

    /// The engine plays something other than the queue's current item, or nothing at all.
    private func checkMismatch(_ s: QTPlaybackState, _ current: QTQueueItem, _ now: TimeInterval) -> Bool {
        if agrees(s.item, with: current) {
            watch.mismatchSince = nil
            return false
        }
        let since = watch.mismatchSince ?? now
        watch.mismatchSince = since
        guard now - since >= Self.mismatchGrace else { return true }
        watch.mismatchSince = nil
        let position = resumePosition(for: current)
        // The queue's track had already finished (the engine ran on into a stale next): move on to what's queued
        // instead of replaying its last seconds. (Nothing queued: it loads at its end and ends as usual, and the queue
        // decides from there — a Repeat All wrap, Autoplay's radio, or the end.) "Its last seconds" are seconds of
        // listening: media time at the playback speed.
        if s.item != nil, wantsPlayback, advancesInFlight == 0, naturalNext() != nil, current.track.duration > 0,
           position >= current.track.duration - Self.stuckGrace * rate {
            Task { await self.advance(userInitiated: false) }
        } else {
            let autoplay = wantsPlayback
            Task { await self.loadCurrent(startTime: position, autoplay: autoplay, mode: self.mode) }
        }
        return true
    }

    /// Network trouble: try the same item again once the network is back (offline) or the backoff is over (online).
    private func checkNetworkRetry(_ s: QTPlaybackState, _ current: QTQueueItem, _ now: TimeInterval) -> Bool {
        guard watch.isRetryingNetwork else { return false }
        guard wantsPlayback, watch.networkRetryItem == current.id else {
            watch.networkRetryAt = nil
            watch.waitingForNetwork = false
            return false
        }
        guard engine.isNetworkAvailable else {
            // Offline when the backoff ran out: wait for the network instead.
            if watch.networkRetryAt != nil { watch.networkRetryAt = nil; watch.waitingForNetwork = true }
            return true
        }
        if let at = watch.networkRetryAt, now < at { return true }
        watch.networkRetryAt = nil
        watch.waitingForNetwork = false
        // The engine may be recovering by itself (the web engine reloads a stalled item when the network returns) —
        // unless what it is loading is the load the watch gave up on.
        let recovering = s.status == .playing || s.status == .paused || (s.status == .loading && !watch.abandonedLoad)
        if recovering, agrees(s.item, with: current) { return false }
        let position = watch.retryPosition
        Task { await self.loadCurrent(startTime: position, autoplay: true, mode: self.mode) }
        return true
    }

    /// Paused while the listener wants music, and not by them: undo it once; a second time soon after, stop and say so.
    private func checkUnrequestedPause(_ s: QTPlaybackState, _ current: QTQueueItem, _ now: TimeInterval) {
        guard wantsPlayback, s.status == .paused, agrees(s.item, with: current) else {
            watch.pausedSince = nil
            return
        }
        if engine.isPausedByListener {
            // The Picture in Picture window's pause: the listener's own (normally adopted as it arrived).
            listenerPausedOutsideApp()
            return
        }
        let since = watch.pausedSince ?? now
        watch.pausedSince = since
        guard now - since >= Self.pauseGrace else { return }
        watch.pausedSince = nil
        if let last = watch.lastAutoResume, now - last < Self.autoResumeWindow {
            watch.lastAutoResume = nil
            pause()
            notify(.interrupted)
        } else {
            watch.lastAutoResume = now
            engine.play()
        }
    }

    /// Ended or failed while the listener waits and nothing is moving on (the event came while a load was in flight,
    /// or a handler was lost): act on it now.
    private func checkStuck(_ s: QTPlaybackState, _ current: QTQueueItem, _ now: TimeInterval) {
        let stuck: Bool
        switch s.status {
        case .ended, .failed: stuck = wantsPlayback && advancesInFlight == 0 && agrees(s.item, with: current)
        default: stuck = false
        }
        guard stuck else {
            watch.stuckSince = nil
            return
        }
        let since = watch.stuckSince ?? now
        watch.stuckSince = since
        guard now - since >= Self.stuckGrace else { return }
        watch.stuckSince = nil
        if case .failed(let error) = s.status {
            lastFailure = error
            Task { await self.skipAfterFailure(current.track, error) }
        } else {
            Task { await self.handleEnded() }
        }
    }

    // MARK: The listener outside the app

    /// Play / pause the listener made outside the app's commands (the Picture in Picture window's controls, or closing
    /// it): theirs, so the queue's intent follows at once — their pause is never resumed, their Play is wanted (the
    /// next track plays on). The media already did it; nothing is sent back to the engine, which would fight it.
    func adoptListenerControl(_ s: QTPlaybackState, previous: QTPlaybackState) {
        guard s.status != previous.status, let current = queue.nowPlaying, agrees(s.item, with: current) else { return }
        if s.status == .paused, wantsPlayback, engine.isPausedByListener {
            listenerPausedOutsideApp()
        } else if s.status == .playing, !wantsPlayback, engine.isResumedByListener {
            wantsPlayback = true
            watch.listenerResumed()
            superviseSoon()
        }
    }

    /// The listener paused outside the app: the queue's intent only (the media is paused already).
    func listenerPausedOutsideApp() {
        wantsPlayback = false
        pauseSerial += 1
        watch.listenerPaused()
        scheduleSave()
    }

    // MARK: Network trouble

    /// After a network failure of `track`: true when it is handled (a retry is scheduled, or the queue gave up and
    /// paused), false when it should be skipped (it failed online too often).
    func retryAfterNetworkFailure(_ track: QTTrack) -> Bool {
        let now = uptime()
        let since = watch.networkTroubleSince ?? now
        watch.networkTroubleSince = since
        if now - since >= Self.networkPatience {
            giveUpOnNetwork()
            return true
        }
        // Moved on meanwhile (Next, a jump): nothing to retry.
        guard let current = queue.nowPlaying, current.track.videoId == track.videoId else { return true }
        if watch.networkRetryItem != current.id {
            watch.networkRetryItem = current.id
            watch.networkRetries = 0
        }
        watch.retryPosition = resumePosition(for: current)
        defer {
            superviseSoon()
            updatePlaybackActivity()
        }
        guard engine.isNetworkAvailable else {
            watch.waitingForNetwork = true
            return true
        }
        guard watch.networkRetries < Self.networkRetryDelays.count else { return false }
        watch.networkRetryAt = now + Self.networkRetryDelays[watch.networkRetries]
        watch.networkRetries += 1
        return true
    }

    private func giveUpOnNetwork() {
        watch.networkTroubleSince = nil
        // The listener isn't waiting any more; a load still in flight finishes paused.
        pause()
        notify(.networkUnavailable)
    }

    // MARK: Helpers

    /// The engine's item is the queue's current entry (by queue id; by video id for an item without one).
    func agrees(_ item: QTPlaybackItem?, with current: QTQueueItem) -> Bool {
        guard let item else { return false }
        if let id = item.queueID { return id == current.id }
        return item.track.videoId == current.track.videoId
    }

    /// Where the current item picks up again: the engine's clock while it still has the item, else the last position
    /// seen for it, else the start.
    func resumePosition(for current: QTQueueItem) -> TimeInterval {
        let s = engine.state
        if agrees(s.item, with: current), s.ad == nil {
            switch s.status {
            case .ended: return 0
            case .loading: return s.item?.startTime ?? 0
            default: return max(0, s.timeline.time(atUptime: uptime()))
            }
        }
        if let last = watch.lastPosition, last.id == current.id { return last.time }
        return 0
    }

    /// Play when the engine has lost the queue's item (stopped, failed, crashed, another item): the position to load
    /// it at; nil when a plain play will do.
    func reloadPositionForPlay() -> TimeInterval? {
        guard let current = queue.nowPlaying, loadInFlight == nil else { return nil }
        let s = engine.state
        // The engine still holds the load the watch gave up on (it never answered): start it over.
        if watch.abandonedLoad, s.status != .playing { return resumePosition(for: current) }
        switch s.status {
        case .idle, .failed: return resumePosition(for: current)
        default: return agrees(s.item, with: current) ? nil : resumePosition(for: current)
        }
    }

    func notify(_ notice: QTPlaybackNotice) {
        onNotice?(notice)
    }

    // MARK: Waiting on the watch's clock

    /// Suspends for `seconds` of the watch's clock (fired by `superviseTick`, so tests on a manual clock control it).
    func watchWait(_ seconds: TimeInterval) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            addTimer(after: seconds) { c.resume() }
        }
    }

    /// The continuation's answer, or nil when it threw or took longer than `timeout` (a late answer is dropped).
    func fetchWithTimeout(_ fetch: @escaping QTAutoplayContinuation, _ request: QTAutoplayRequest,
                          timeout: TimeInterval) async -> [QTTrack]? {
        await withCheckedContinuation { (c: CheckedContinuation<[QTTrack]?, Never>) in
            let once = QTResumeOnce(c)
            let timer = addTimer(after: timeout) { once.resume(nil) }
            Task { @MainActor [weak self] in
                let tracks = try? await fetch(request)
                self?.cancelTimer(timer)
                once.resume(tracks)
            }
        }
    }

    @discardableResult
    private func addTimer(after seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> Int {
        watch.nextTimerID += 1
        let id = watch.nextTimerID
        watch.timers.append(.init(id: id, due: uptime() + seconds, fire: fire))
        superviseSoon()
        return id
    }

    private func cancelTimer(_ id: Int) {
        watch.timers.removeAll { $0.id == id }
    }

    /// Fires every pending wait now (tests tearing a controller down: nothing is left suspended).
    func fireAllWatchTimers() {
        let all = watch.timers
        watch.timers = []
        for timer in all { timer.fire() }
    }

    private func fireDueTimers(at now: TimeInterval) {
        let due = watch.timers.filter { $0.due <= now }
        guard !due.isEmpty else { return }
        watch.timers.removeAll { $0.due <= now }
        for timer in due { timer.fire() }
    }
}

/// Resumes a checked continuation once, whichever side gets there first (an answer or its timeout).
@MainActor
private final class QTResumeOnce<T: Sendable> {
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }

    func resume(_ value: T) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
