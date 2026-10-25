import Foundation
import Observation
import QTCore

/// What the autoplay continuation is asked for ("more like this" when Autoplay runs low).
public struct QTAutoplayRequest: Sendable, Hashable {
    public var source: QTQueueSource?
    /// The last track that will play before the new ones (radio seed).
    public var seed: QTTrack?
    /// Already queued or in the context; results matching these are dropped.
    public var excludingVideoIDs: Set<String>
}

/// A track that couldn't play. `skipped` is false when the queue gave up (too many failures in a row, or the
/// failure came while paused) — the app tells the user either way.
public struct QTPlaybackFailureEvent: Sendable, Hashable {
    public var track: QTTrack
    public var error: QTPlaybackError
    public var skipped: Bool
    /// Consecutive failures including this one.
    public var consecutive: Int

    public init(track: QTTrack, error: QTPlaybackError, skipped: Bool, consecutive: Int) {
        self.track = track
        self.error = error
        self.skipped = skipped
        self.consecutive = consecutive
    }
}

/// Fetches more Autoplay tracks (InnerTube `next` radio, M3). Injected by the app; nil = no continuation.
public typealias QTAutoplayContinuation = @MainActor (QTAutoplayRequest) async throws -> [QTTrack]

/// The rest of a context that's still loading (an artist's full song list behind the top songs that start at once).
public typealias QTContextRemainder = @MainActor () async -> [QTTrack]

/// The single owner of the play queue and of "what plays next".
///
/// Owns the `QTQueue` (Now Playing · Up Next · Autoplay), the playing context (for shuffle and Repeat All),
/// shuffle/repeat policy, Previous semantics, track-end advance, autoplay continuation, persistence, and the
/// active `QTPlaybackEngine`. Engines only play what they're told; `QTNowPlayingController` mirrors this.
///
/// Advance rules: Up Next (user-added) first, then Autoplay. Repeat One replays on natural end (Next still
/// moves on). Repeat All loops the context (re-shuffled when shuffle is on). Shuffle is a true shuffle: every
/// context track once per cycle, never the same track twice in a row across cycles; Up Next is never shuffled;
/// History records what actually played, so Previous walks back through it.
///
/// Reliability (`QTQueueController+Reliability`): the listener's intent (`wantsPlayback`) is reconciled with the
/// engine once a second while it matters — pauses nobody asked for are undone once, a queue/engine disagreement
/// reloads the queue's track, network trouble retries the same track instead of skipping it, a missed end still moves
/// on. Recovery is silent; `onNotice` speaks only when the listener has to know or act.
@MainActor
@Observable
public final class QTQueueController {
    /// Past this many seconds, Previous restarts the track instead of going back.
    public static let restartThreshold: TimeInterval = 3
    /// Ask the continuation for more when Autoplay has this many items or fewer.
    public static let autoplayLowWatermark = 3
    /// Stop skipping after this many unplayable tracks in a row (network trouble doesn't count).
    public static let maxConsecutiveFailures = 3

    public private(set) var engine: any QTPlaybackEngine
    /// Mirror of the engine's latest state.
    public private(set) var state: QTPlaybackState
    public private(set) var queue = QTQueue()
    /// Song or Video rendition of the current item.
    public private(set) var mode: QTPlaybackMode = .song
    /// The rendition the listener wants (the Song | Video switch, "Prefer videos when available"): every new track
    /// starts as its music video when it has one, otherwise as the song. `setMode` updates it.
    public var preferredMode: QTPlaybackMode = .song {
        didSet { if preferredMode != oldValue { syncPreparedNext() } }
    }
    public private(set) var isShuffleOn = false
    public var repeatMode: QTRepeatMode = .off {
        didSet { if repeatMode != oldValue { scheduleSave(); publishNowPlaying() } }
    }
    /// Playback speed (`QTPlaybackSpeed`, 1 = normal): the listener's setting, not the queue's. Every engine plays at
    /// it — set again before each load and on an engine swap, so a fresh page or a fallback engine never drops it.
    public private(set) var rate: Double = QTPlaybackSpeed.normal
    public private(set) var isFetchingAutoplay = false
    /// Bumped whenever a new *listen* of the current item begins: a new current item (play, next, autoplay, jump,
    /// previous), Repeat One wrapping to the start, Previous restarting the track. Not bumped by Song⇄Video switches,
    /// engine swaps or a restored queue. Lets scrobblers tell a replay of the same video id from the same play.
    public private(set) var playSerial = 0
    /// The last load failure (cleared by the next successful load).
    public internal(set) var lastFailure: QTPlaybackError?

    @ObservationIgnored public var autoplayContinuation: QTAutoplayContinuation?
    /// Song⇄Video counterpart lookup (InnerTube `next`, then a conservative search) for tracks that don't carry
    /// one. Asked for the current track and the next one; results patch the queue items in place. nil = none.
    @ObservationIgnored public var counterpartResolver: (@MainActor (QTTrack) async -> QTCounterpart?)?
    @ObservationIgnored private var counterparts: [String: QTCounterpart?] = [:]
    @ObservationIgnored private var counterpartTasks: [String: Task<Void, Never>] = [:]
    /// Where a Song⇄Video switch picks up when the two renditions are different cuts (an MV with an intro): the
    /// lyrics know the shift once both timings line up (`QTLyricsRenditionCoordinator`). Gets the track, the mode
    /// switched to and the current position; nil = the same position.
    @ObservationIgnored public var modeSwitchTime: (@MainActor (QTTrack, QTPlaybackMode, TimeInterval) -> TimeInterval?)?
    /// Called when the current track changes (not on Song⇄Video switches of the same track).
    @ObservationIgnored public var onTrackChange: (@MainActor (QTTrack?) -> Void)?
    /// Like state for Now Playing and the remote like command.
    @ObservationIgnored public var isLiked: @MainActor (QTTrack) -> Bool = { _ in false }
    /// Remote "like" (Control Center / Touch Bar). The app decides what liking means (local until writes are approved).
    @ObservationIgnored public var onRemoteLike: (@MainActor (QTTrack, Bool) -> Void)?
    /// A track failed to play (and was skipped, unless `skipped` is false). The app shows a toast.
    @ObservationIgnored public var onFailure: (@MainActor (QTPlaybackFailureEvent) -> Void)?
    /// Playback stopped for a reason other than one track failing, and the listener should know (`QTPlaybackNotice`).
    /// The app shows one toast, with the notice's action.
    @ObservationIgnored public var onNotice: (@MainActor (QTPlaybackNotice) -> Void)?
    /// The speed changed (menus, shortcuts, a remote command): the app saves it.
    @ObservationIgnored public var onRateChange: (@MainActor (Double) -> Void)?
    /// The process's single Now Playing owner (nil: none). Attached later when the app switches to real data.
    @ObservationIgnored public private(set) var nowPlaying: QTNowPlayingController?

    @ObservationIgnored private var store: QTQueueStore?
    @ObservationIgnored private var random: QTRandomSource
    /// The context in original order. Autoplay items share ids with these.
    @ObservationIgnored private var context: [QTQueueItem] = []
    @ObservationIgnored private var contextCursor: Int?
    /// Bumped whenever the context is replaced; stale continuation results are dropped.
    @ObservationIgnored private var contextGeneration = 0
    @ObservationIgnored private var origins: [UUID: QTQueueSection] = [:]
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored var continuationTask: Task<QTContinuationResult, Never>?
    @ObservationIgnored private var continuationSerial = 0
    @ObservationIgnored var loadToken = 0
    /// The token of the newest load while it is in flight (superseded loads that are still unwinding don't count).
    @ObservationIgnored var loadInFlight: Int?
    /// `advance` is running (it may wait on the autoplay continuation for a while).
    @ObservationIgnored var advancesInFlight = 0
    @ObservationIgnored var consecutiveFailures = 0
    /// Bumped by every pause of the listener (or of the app on their behalf): an advance that waited for Autoplay's radio
    /// meanwhile loads its track held.
    @ObservationIgnored var pauseSerial = 0
    @ObservationIgnored private var lastAnnouncedTrackID: String?
    /// The item last handed to `engine.prepareNext` (gapless/crossfade engines may move on to it by themselves).
    @ObservationIgnored private var preparedNext: QTPlaybackItem?
    /// The user's intent: true after play/autoplaying load, false after pause. Decides whether a failure skips, and
    /// what the reliability watch reconciles the engine with. Observed: Play/Pause controls follow it
    /// (`isPlaybackRequested`).
    public internal(set) var wantsPlayback = false {
        // What the process asks of the system follows the intent at once (a load nobody waits for holds nothing).
        didSet { if wantsPlayback != oldValue { updatePlaybackActivity() } }
    }
    /// Held so App Nap never throttles track ends, ad countdowns or the simulated engine's clock when the app is in
    /// the background or occluded (real audio output already exempts the process; this covers silent engines and the
    /// gaps between tracks). Only actual playback also keeps the Mac from idle-sleeping (`activityLevel`).
    @ObservationIgnored private var playbackActivity: NSObjectProtocol?
    @ObservationIgnored private(set) var activityLevel = QTPlaybackActivityLevel.none
    @ObservationIgnored let uptime: @MainActor () -> TimeInterval
    /// What the reliability watch tracks between ticks.
    @ObservationIgnored var watch = QTPlaybackWatch()
    /// How often the watch ticks while it has something to watch (nil: only when `superviseTick()` is called — tests).
    @ObservationIgnored private let supervision: Duration?
    @ObservationIgnored private var supervisionTask: Task<Void, Never>?

    /// - Parameters:
    ///   - engine: the active engine (`QTPlaybackEngineSelector`).
    ///   - nowPlaying: the process's single Now Playing owner; nil for mock/screenshot runs and tests.
    ///   - store: queue persistence; nil = in-memory only.
    ///   - random: shuffle source (tests inject a seeded generator).
    ///   - uptime: clock the engine's timeline is anchored to (tests inject the simulated engine's clock).
    ///   - supervision: tick interval of the reliability watch; nil = ticks only through `superviseTick()` (tests on a
    ///     manual clock).
    public init(engine: any QTPlaybackEngine, nowPlaying: QTNowPlayingController? = nil, store: QTQueueStore? = nil,
                random: any RandomNumberGenerator = SystemRandomNumberGenerator(),
                uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                supervision: Duration? = .seconds(1)) {
        self.engine = engine
        self.nowPlaying = nowPlaying
        self.store = store
        self.random = QTRandomSource(base: random)
        self.uptime = uptime
        self.supervision = supervision
        state = engine.state
        observe(engine)
        nowPlaying?.commandHandler = { [weak self] command in self?.handleRemote(command) ?? false }
    }

    // MARK: Derived

    public var nowPlayingTrack: QTTrack? { queue.nowPlaying?.track }
    /// Position in the current item now (interpolated from the engine's timeline).
    public var currentTime: TimeInterval { engine.state.timeline.time(atUptime: uptime()) }
    public var capabilities: QTPlaybackCapabilities { engine.capabilities }
    /// What Play/Pause shows and toggles: the listener's intent — Pause while a track loads, retries or recovers, like
    /// Music — or, should the two ever disagree, the engine actually playing.
    public var isPlaybackRequested: Bool { wantsPlayback || state.isPlaying }

    // MARK: Starting playback

    /// Plays `tracks[index]`; the playable rest of `tracks` continues as Autoplay from `source` (shuffled when
    /// shuffle is on). Up Next is kept. `remainder` joins the context when it arrives (`extendContext`).
    /// `mode` nil = `preferredMode`.
    public func play(_ tracks: [QTTrack], startingAt index: Int = 0, source: QTQueueSource? = nil,
                     startTime: TimeInterval = 0, autoplay: Bool = true, mode: QTPlaybackMode? = nil,
                     remainder: QTContextRemainder? = nil) async {
        guard tracks.indices.contains(index), tracks[index].availability.isPlayable else { return }
        var items: [QTQueueItem] = []
        var current: QTQueueItem?
        for (i, track) in tracks.enumerated() where track.availability.isPlayable {
            let item = QTQueueItem(track: track)
            if i == index { current = item }
            items.append(item)
        }
        guard let current else { return }
        replaceContext(items, source: source)
        becomeCurrent(current, from: .autoplay)
        let rest = items.filter { $0.id != current.id }
        let after = Array(items.drop { $0.id != current.id }.dropFirst())
        queue.autoplay = isShuffleOn ? shuffled(rest, avoidingFirst: current.track.videoId) : after
        extendContext(with: remainder)
        if let mode { preferredMode = mode }
        await loadCurrent(startTime: startTime, autoplay: autoplay, mode: preferredMode)
    }

    /// "Shuffle" on a playlist/album/artist, and "Shuffle entire library": turns shuffle on and starts from a
    /// random track.
    public func shuffle(_ tracks: [QTTrack], source: QTQueueSource? = nil, remainder: QTContextRemainder? = nil) async {
        let items = tracks.filter(\.availability.isPlayable).map { QTQueueItem(track: $0) }
        guard !items.isEmpty else { return }
        isShuffleOn = true
        let order = shuffled(items, avoidingFirst: nil)
        replaceContext(items, source: source)
        becomeCurrent(order[0], from: .autoplay)
        queue.autoplay = Array(order.dropFirst())
        extendContext(with: remainder)
        await loadCurrent(startTime: 0, autoplay: true, mode: preferredMode)
    }

    // MARK: Transport

    /// Plays. When the engine has lost the queue's item (stopped, failed, crashed, or playing something else) the item
    /// loads again where it was, instead of the button doing nothing.
    public func play() {
        wantsPlayback = true
        watch.listenerResumed()
        // Play on a track that had ended (the queue stopped at its end) starts it over: a new listen.
        if let current = queue.nowPlaying, engine.state.status == .ended, agrees(engine.state.item, with: current) {
            playSerial += 1
        }
        if let reload = reloadPositionForPlay() {
            Task { await self.loadCurrent(startTime: reload, autoplay: true, mode: self.mode) }
        } else {
            engine.play()
        }
        superviseSoon()
    }

    public func pause() {
        wantsPlayback = false
        pauseSerial += 1
        watch.listenerPaused()
        engine.pause()
    }

    /// Toggles the listener's intent, not the engine's momentary state: Pause pauses a track that is still loading,
    /// retrying or recovering, instead of asking it to play again.
    public func togglePlayPause() {
        isPlaybackRequested ? pause() : play()
    }
    public func seek(to time: TimeInterval) { engine.seek(to: time) }
    public func setVolume(_ volume: Double) { engine.setVolume(volume) }
    public func setMuted(_ muted: Bool) { engine.setMuted(muted) }
    public func skipAd() { engine.skipAd() }

    /// Playback speed for everything that plays from now on (normalized to `QTPlaybackSpeed`). Song⇄Video, the next
    /// track, a reload and an engine swap all keep it.
    public func setRate(_ newRate: Double) {
        let r = QTPlaybackSpeed.normalized(newRate)
        guard r != rate else { return }
        rate = r
        engine.setRate(r)
        publishNowPlaying()
        onRateChange?(r)
    }

    /// Next (button, menu, media key). Moves on even under Repeat One.
    public func next() async {
        await advance(userInitiated: true)
    }

    /// Previous: restarts the track when more than `restartThreshold` seconds in (or with no history), else goes
    /// back to the previously played item and returns the current one to the front of its section.
    public func previous() async {
        guard queue.nowPlaying != nil else { return }
        if currentTime > Self.restartThreshold || queue.history.isEmpty {
            playSerial += 1
            if reloadPositionForPlay() != nil {
                // The engine lost the item: load it again from the start.
                await loadCurrent(startTime: 0, autoplay: true, mode: mode)
                return
            }
            engine.seek(to: 0)
            if engine.state.status != .playing { play() }
            return
        }
        let previous = queue.history.removeLast()
        // Under Repeat All the history's items are queued again too: the one coming back plays now, not later as well.
        queue.upNext.removeAll { $0.id == previous.id }
        queue.autoplay.removeAll { $0.id == previous.id }
        if let current = queue.nowPlaying, current.id != previous.id {
            switch origins[current.id] ?? .autoplay {
            case .upNext: queue.upNext.insert(current, at: 0)
            case .autoplay: queue.autoplay.insert(current, at: 0)
            }
        }
        queue.nowPlaying = previous
        playSerial += 1
        await loadCurrent(startTime: 0, autoplay: true, mode: preferredMode)
    }

    /// Song⇄Video at the same position (the counterpart loads at the current time; the queue doesn't change). On a
    /// track with both renditions this is also the listener's choice for the tracks that follow (`preferredMode`).
    public func setMode(_ newMode: QTPlaybackMode) async {
        if queue.nowPlaying?.track.hasVideo == true { preferredMode = newMode }
        guard newMode != mode, let track = queue.nowPlaying?.track, track.hasVideo || newMode == .song else { return }
        let now = currentTime
        // The listener's intent, not the engine's moment: a switch while the track loads or retries still plays.
        await loadCurrent(startTime: modeSwitchTime?(track, newMode, now) ?? now, autoplay: wantsPlayback, mode: newMode)
    }

    /// Plays a queue item now (double-click in the queue). Items before it in its section are skipped;
    /// jumping into Autoplay keeps Up Next, which plays after it.
    public func jump(to item: QTQueueItem) async {
        if let i = queue.upNext.firstIndex(where: { $0.id == item.id }) {
            queue.upNext.removeSubrange(0...i)
            becomeCurrent(item, from: .upNext)
        } else if let i = queue.autoplay.firstIndex(where: { $0.id == item.id }) {
            queue.autoplay.removeSubrange(0...i)
            becomeCurrent(item, from: .autoplay)
        } else {
            return
        }
        await loadCurrent(startTime: 0, autoplay: true, mode: preferredMode)
    }

    // MARK: Shuffle and repeat

    /// Shuffling reorders Autoplay (Up Next keeps the user's order); turning it off resumes the context's
    /// original order after the last context track that played.
    public func setShuffle(_ on: Bool) {
        guard on != isShuffleOn else { return }
        isShuffleOn = on
        if on {
            queue.autoplay = shuffled(queue.autoplay, avoidingFirst: queue.nowPlaying?.track.videoId)
        } else {
            let start = min((contextCursor ?? -1) + 1, context.count)
            let current = queue.nowPlaying?.id
            queue.autoplay = context[start...].filter { $0.id != current }
        }
        scheduleSave()
        publishNowPlaying()
    }

    public func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    // MARK: Editing

    public func playNext(_ tracks: [QTTrack]) {
        queue.playNext(tracks.filter(\.availability.isPlayable))
        scheduleSave()
    }

    public func addToQueue(_ tracks: [QTTrack]) {
        queue.addToQueue(tracks.filter(\.availability.isPlayable))
        scheduleSave()
    }

    public func insert(_ tracks: [QTTrack], at index: Int, in section: QTQueueSection) {
        queue.insert(tracks.filter(\.availability.isPlayable), at: index, in: section)
        scheduleSave()
    }

    /// SwiftUI `onMove` semantics within a section.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int, in section: QTQueueSection) {
        queue.move(fromOffsets: source, toOffset: destination, in: section)
        scheduleSave()
    }

    /// Moves an item between sections (drag from Autoplay into Up Next).
    public func move(itemID: UUID, to section: QTQueueSection, at index: Int) {
        queue.move(itemID: itemID, to: section, at: index)
        scheduleSave()
    }

    public func remove(_ ids: Set<UUID>) {
        queue.remove(ids: ids)
        context.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    @discardableResult
    public func clearUpNext() -> QTQueueUndoToken {
        defer { scheduleSave() }
        return queue.clearUpNext()
    }

    public func undoClearUpNext(_ token: QTQueueUndoToken) {
        queue.undoClearUpNext(token)
        scheduleSave()
    }

    public func setAutoplayEnabled(_ enabled: Bool) {
        queue.isAutoplayEnabled = enabled
        scheduleSave()
        if enabled { prefetchContinuationIfNeeded() }
    }

    /// Empties the whole queue and stops playback.
    public func clearAll() {
        wantsPlayback = false
        watch.reset()
        engine.stop()
        queue = QTQueue()
        replaceContext([], source: nil)
        origins = [:]
        announceTrackChange()
        nowPlaying?.clear()
        scheduleSave()
    }

    // MARK: Engines

    /// Switches engines (account tier change, sign-in) keeping the current item and position.
    public func replaceEngine(_ newEngine: any QTPlaybackEngine) async {
        guard newEngine !== engine else { return }
        let position = currentTime
        // The listener's intent: a track that was loading or retrying when the engines changed still plays.
        let wasPlaying = wantsPlayback
        engine.stop()
        engine.prepareNext(nil)
        engine = newEngine
        newEngine.setRate(rate)
        preparedNext = nil
        watch.engineDidChange()
        observe(newEngine)
        state = newEngine.state
        if queue.nowPlaying != nil {
            await loadCurrent(startTime: position, autoplay: wasPlaying, mode: mode)
        }
    }

    /// Takes over Now Playing + remote commands (the app switched from demo to real data mid-session).
    public func attachNowPlaying(_ controller: QTNowPlayingController) {
        guard nowPlaying !== controller else { return }
        nowPlaying?.clear()
        nowPlaying = controller
        controller.commandHandler = { [weak self] command in self?.handleRemote(command) ?? false }
        publishNowPlaying()
    }

    /// Starts or stops persisting the queue (nil = in-memory only). Pending saves to the old store are dropped, so
    /// a demo-library queue never overwrites the saved real one.
    public func setStore(_ newStore: QTQueueStore?) {
        saveTask?.cancel()
        saveTask = nil
        store = newStore
    }

    // MARK: Persistence

    /// Restores the saved queue and cues the current item at its saved position (paused unless `autoplay`).
    @discardableResult
    public func restore(autoplay: Bool = false) async -> Bool {
        guard let store, let snapshot = await store.load() else { return false }
        apply(snapshot)
        preferredMode = snapshot.mode
        guard queue.nowPlaying != nil else { return true }
        await loadCurrent(startTime: snapshot.position, autoplay: autoplay, mode: snapshot.mode)
        return true
    }

    /// The current queue as a persistable value.
    public func snapshot() -> QTQueueSnapshot {
        QTQueueSnapshot(queue: queue, context: context, origins: liveOrigins(), contextCursor: contextCursor,
                        isShuffleOn: isShuffleOn, repeatMode: repeatMode, mode: mode,
                        position: queue.nowPlaying == nil ? 0 : currentTime)
    }

    /// Writes synchronously on the calling thread (app termination, where awaiting isn't possible).
    public func flushNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let store else { return }
        try? QTQueueStore.write(snapshot(), to: store.fileURL)
    }

    /// Writes now. Normal edits are saved debounced.
    public func flush() async {
        saveTask?.cancel()
        saveTask = nil
        guard let store else { return }
        try? await store.save(snapshot())
    }

    func apply(_ snapshot: QTQueueSnapshot) {
        queue = snapshot.queue
        context = snapshot.context
        origins = snapshot.origins
        contextCursor = snapshot.contextCursor
        isShuffleOn = snapshot.isShuffleOn
        repeatMode = snapshot.repeatMode
        mode = snapshot.mode
        contextGeneration += 1
    }

    /// After every queue edit (all of them save): the engine hears what comes next.
    func scheduleSave() {
        syncPreparedNext()
        guard store != nil else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            self.saveTask = nil
            try? await self.store?.save(self.snapshot())
        }
    }

    private func liveOrigins() -> [UUID: QTQueueSection] {
        var live = Set(queue.upNext.map(\.id))
        live.formUnion(queue.autoplay.map(\.id))
        live.formUnion(queue.history.map(\.id))
        if let id = queue.nowPlaying?.id { live.insert(id) }
        return origins.filter { live.contains($0.key) }
    }

    // MARK: Advancing

    func advance(userInitiated: Bool) async {
        guard queue.nowPlaying != nil || !queue.upNext.isEmpty || !queue.autoplay.isEmpty else { return }
        advancesInFlight += 1
        defer { advancesInFlight -= 1 }
        var autoplay = true
        if let next = popNext() {
            becomeCurrent(next.item, from: next.section)
        } else if repeatMode == .all, queue.isAutoplayEnabled, !context.isEmpty {
            // (With Autoplay off the context doesn't play, so there is nothing to wrap round to.)
            let current = queue.nowPlaying?.track.videoId
            queue.autoplay = isShuffleOn ? shuffled(context, avoidingFirst: current) : context
            contextCursor = nil
            guard let next = popNext() else { return }
            becomeCurrent(next.item, from: next.section)
        } else if queue.isAutoplayEnabled, autoplayContinuation != nil {
            let current = queue.nowPlaying?.id
            let pauses = pauseSerial
            let result = await awaitContinuation()
            // Something else moved the queue on while the continuation loaded (Next, a jump): that wins.
            guard queue.nowPlaying?.id == current else { return }
            guard result == .added, let next = popNext() else {
                reachedEnd(userInitiated: userInitiated, autoplayFailed: result == .failed)
                return
            }
            becomeCurrent(next.item, from: next.section)
            // Paused while the radio answered (and not played again): the new track waits, cued, for Play.
            autoplay = pauseSerial == pauses || wantsPlayback
        } else {
            reachedEnd(userInitiated: userInitiated, autoplayFailed: false)
            return
        }
        await loadCurrent(startTime: 0, autoplay: autoplay, mode: preferredMode)
    }

    /// End of the queue: the last item stays loaded (ended), like Music.app, and the listener is no longer waiting for
    /// anything. When Autoplay couldn't load more (radio failed after its retries) they hear about it once, with Retry.
    private func reachedEnd(userInitiated: Bool, autoplayFailed: Bool) {
        if !userInitiated, !engine.state.isPlaying { wantsPlayback = false }
        if autoplayFailed { notify(.autoplayUnavailable) }
    }

    func handleEnded() async {
        if repeatMode == .one {
            playSerial += 1
            engine.seek(to: 0)
            play()
            return
        }
        await advance(userInitiated: false)
    }

    /// Something can follow the current item: queued, a Repeat All wrap, or more from Autoplay's continuation.
    var hasNextItem: Bool {
        !queue.upNext.isEmpty || (queue.isAutoplayEnabled && (!queue.autoplay.isEmpty || autoplayContinuation != nil))
            || (repeatMode == .all && queue.isAutoplayEnabled && !context.isEmpty)
    }

    /// What `advance` would play next without asking anyone (no Repeat All wrap, no continuation fetch), or nil.
    /// Repeat One replays on its own, so nothing is prepared then.
    func naturalNext() -> QTQueueItem? {
        guard repeatMode != .one, queue.nowPlaying != nil else { return nil }
        if let first = queue.upNext.first { return first }
        return queue.isAutoplayEnabled ? queue.autoplay.first : nil
    }

    /// Tells the engine what plays next in order (it prefetches it, and may join it gaplessly or crossfade into it).
    private func syncPreparedNext() {
        let item = naturalNext().map { next in
            QTPlaybackItem(track: next.track, mode: preferredMode == .video && next.track.hasVideo ? .video : .song,
                           queueID: next.id)
        }
        guard item != preparedNext else { return }
        preparedNext = item
        engine.prepareNext(item)
    }

    /// The engine moved on to the prepared next item by itself (a gapless join or a crossfade): the queue follows
    /// without loading anything.
    private func advanceToPrepared(_ s: QTPlaybackState) {
        guard let id = s.item?.queueID, let next = naturalNext(), next.id == id, let section = popNext()?.section else { return }
        becomeCurrent(next, from: section)
        if let m = s.item?.mode { mode = m }
        consecutiveFailures = 0
        lastFailure = nil
        // A join that lands as the listener pauses stays paused; one that plays is wanted.
        wantsPlayback = wantsPlayback || s.status == .playing
        watch.loadDidStart(next.id)
        superviseSoon()
        announceTrackChange()
        resolveCounterparts()
        prefetchContinuationIfNeeded()
        scheduleSave()
        publishNowPlaying()
    }

    private func popNext() -> (item: QTQueueItem, section: QTQueueSection)? {
        if !queue.upNext.isEmpty { return (queue.upNext.removeFirst(), .upNext) }
        if queue.isAutoplayEnabled, !queue.autoplay.isEmpty { return (queue.autoplay.removeFirst(), .autoplay) }
        return nil
    }

    private func becomeCurrent(_ item: QTQueueItem, from section: QTQueueSection) {
        if let current = queue.nowPlaying {
            queue.history.append(current)
            if queue.history.count > QTQueue.historyLimit { queue.history.removeFirst(queue.history.count - QTQueue.historyLimit) }
        }
        queue.nowPlaying = item
        playSerial += 1
        origins[item.id] = section
        if section == .autoplay, let i = context.firstIndex(where: { $0.id == item.id }) { contextCursor = i }
    }

    /// Adds the rest of a loading context once it arrives: new tracks join the context's own part of Autoplay, ahead
    /// of any radio continuation (in order, or scattered among the tracks still to come when shuffle is on). Dropped
    /// when another context replaced this one meanwhile.
    private func extendContext(with remainder: QTContextRemainder?) {
        guard let remainder else { return }
        let generation = contextGeneration
        let own = context.count
        Task { @MainActor [weak self] in
            let tracks = await remainder()
            guard let self, generation == contextGeneration else { return }
            let base = min(own, context.count)
            var seen = Set(context.map(\.track.videoId))
            let items = tracks.filter { $0.availability.isPlayable && seen.insert($0.videoId).inserted }
                .map { QTQueueItem(track: $0) }
            guard !items.isEmpty else { return }
            let radio = Set(context[base...].map(\.id))
            let end = queue.autoplay.firstIndex { radio.contains($0.id) } ?? queue.autoplay.count
            if isShuffleOn {
                var spots = queue.autoplay[..<end]
                for item in items { spots.insert(item, at: Int.random(in: 0...spots.count, using: &random)) }
                queue.autoplay.replaceSubrange(..<end, with: spots)
            } else {
                queue.autoplay.insert(contentsOf: items, at: end)
            }
            context.insert(contentsOf: items, at: base)
            scheduleSave()
        }
    }

    private func replaceContext(_ items: [QTQueueItem], source: QTQueueSource?) {
        context = items
        contextCursor = nil
        contextGeneration += 1
        continuationTask?.cancel()
        continuationTask = nil
        isFetchingAutoplay = false
        queue.autoplaySource = source
    }

    func loadCurrent(startTime: TimeInterval, autoplay: Bool, mode newMode: QTPlaybackMode) async {
        applyKnownCounterpart()
        guard let item = queue.nowPlaying else { return }
        loadToken += 1
        let token = loadToken
        loadInFlight = token
        defer { if loadInFlight == token { loadInFlight = nil } }
        let track = item.track
        resolveCounterparts()
        mode = (newMode == .video && track.hasVideo) ? .video : .song
        wantsPlayback = autoplay
        watch.loadDidStart(item.id)
        superviseSoon()
        announceTrackChange()
        scheduleSave()
        // Every load at the listener's speed (an engine that was swapped, crashed or fell back included).
        engine.setRate(rate)
        do {
            try await engine.load(QTPlaybackItem(track: track, mode: mode, startTime: startTime, queueID: item.id), autoplay: autoplay)
            guard token == loadToken else { return }
            consecutiveFailures = 0
            lastFailure = nil
            prefetchContinuationIfNeeded()
            syncPreparedNext()
            handleEndOrFailureDuringLoad()
        } catch is CancellationError {
            // Not replaced by a newer load: the engine dropped this one itself (the track ended or failed while a
            // Song⇄Video switch was preparing, or a stop). Whatever the engine reported meanwhile was ignored.
            guard token == loadToken else { return }
            handleEndOrFailureDuringLoad()
        } catch {
            guard token == loadToken else { return }
            let failure = (error as? QTPlaybackError) ?? .engine(String(describing: error))
            lastFailure = failure
            await skipAfterFailure(track, failure)
        }
    }

    /// `receive` ignores engine states while a load is in flight, and a load can be long (a seamless Song⇄Video
    /// switch waits for a second page). If the current track ended or failed meanwhile, act on it now — otherwise the
    /// queue would sit at the end of the track. The engine may also have put the old rendition back (an abandoned
    /// switch): the queue's mode follows it.
    private func handleEndOrFailureDuringLoad() {
        let s = engine.state
        guard let item = s.item, let track = queue.nowPlaying?.track, item.track.videoId == track.videoId else { return }
        if item.mode != mode { mode = item.mode }
        state = s
        switch s.status {
        case .ended:
            Task { await self.handleEnded() }
        case .failed(let error):
            lastFailure = error
            Task { await self.skipAfterFailure(track, error) }
        default:
            break
        }
    }

    /// Skips an unplayable item when the user meant to be listening; stops after `maxConsecutiveFailures`.
    /// Network trouble isn't the item's fault: it is tried again first (`retryAfterNetworkFailure`), and a network
    /// failure that does end in a skip never counts towards the limit.
    func skipAfterFailure(_ track: QTTrack, _ error: QTPlaybackError) async {
        // Acted on once: the engine's stream may still deliver this load's `.failed` afterwards.
        watch.handledFailureToken = loadToken
        if error.isNetwork {
            // Paused: nothing to retry now; Play loads it again.
            guard wantsPlayback else { return }
            if retryAfterNetworkFailure(track) { return }
        } else {
            consecutiveFailures += 1
        }
        // A bot check stops the queue: the next item would land on it too.
        let skip = wantsPlayback && consecutiveFailures < Self.maxConsecutiveFailures && hasNextItem && error != .botCheck
        onFailure?(QTPlaybackFailureEvent(track: track, error: error, skipped: skip, consecutive: consecutiveFailures))
        guard skip else {
            // The queue gave up: the listener isn't waiting for anything any more — and the engine hears it, so it
            // never brings the failed track back by itself (the web engine reloads network failures once online).
            wantsPlayback = false
            engine.pause()
            return
        }
        await advance(userInitiated: false)
    }

    private func announceTrackChange() {
        let id = queue.nowPlaying?.track.videoId
        guard id != lastAnnouncedTrackID else { return }
        lastAnnouncedTrackID = id
        onTrackChange?(queue.nowPlaying?.track)
    }

    // MARK: Song⇄Video counterparts

    /// A counterpart found earlier (prefetched while the previous track played) goes onto the item before it loads,
    /// so "Prefer videos" starts it as the video straight away.
    private func applyKnownCounterpart() {
        guard let track = queue.nowPlaying?.track, track.counterpart == nil,
              let known = counterparts[track.videoId], let counterpart = known else { return }
        queue.nowPlaying?.track.counterpart = counterpart
    }

    /// Looks up counterparts for the current track and the next one (once per video id).
    private func resolveCounterparts() {
        guard let resolver = counterpartResolver else { return }
        let next = queue.upNext.first ?? queue.autoplay.first
        for track in [queue.nowPlaying?.track, next?.track].compactMap({ $0 }) where track.counterpart == nil {
            let id = track.videoId
            guard counterparts[id] == nil, counterpartTasks[id] == nil else { continue }
            counterpartTasks[id] = Task { @MainActor [weak self] in
                let found = await resolver(track)
                guard let self else { return }
                self.counterpartTasks[id] = nil
                self.counterparts[id] = .some(found)
                if self.counterparts.count > 256 { self.counterparts.removeAll() }
                guard let found else { return }
                self.patchCounterpart(found, forVideoID: id)
            }
        }
    }

    /// Writes a resolved counterpart into every queue item of that track (the queue's order never changes).
    private func patchCounterpart(_ counterpart: QTCounterpart, forVideoID id: String) {
        if queue.nowPlaying?.track.videoId == id, queue.nowPlaying?.track.counterpart == nil {
            queue.nowPlaying?.track.counterpart = counterpart
        }
        for i in queue.upNext.indices where queue.upNext[i].track.videoId == id { queue.upNext[i].track.counterpart = counterpart }
        for i in queue.autoplay.indices where queue.autoplay[i].track.videoId == id { queue.autoplay[i].track.counterpart = counterpart }
        for i in context.indices where context[i].track.videoId == id { context[i].track.counterpart = counterpart }
        syncPreparedNext()
    }

    // MARK: Autoplay continuation

    func prefetchContinuationIfNeeded() {
        guard queue.isAutoplayEnabled, autoplayContinuation != nil, continuationTask == nil, repeatMode != .all,
              queue.autoplay.count <= Self.autoplayLowWatermark else { return }
        startContinuation()
    }

    @discardableResult
    private func startContinuation() -> Task<QTContinuationResult, Never> {
        continuationSerial += 1
        let serial = continuationSerial
        let task = Task { @MainActor [weak self] () -> QTContinuationResult in
            guard let self else { return .failed }
            let result = await self.fetchContinuation()
            if self.continuationSerial == serial { self.continuationTask = nil }
            return result
        }
        continuationTask = task
        return task
    }

    private func awaitContinuation() async -> QTContinuationResult {
        await (continuationTask ?? startContinuation()).value
    }

    /// More Autoplay tracks: each attempt has `continuationTimeout`, a failed or hung one is retried after a short
    /// pause (`continuationRetryDelays`). `.failed` only when every attempt failed; `.empty` when the radio had
    /// nothing new (a natural end).
    private func fetchContinuation() async -> QTContinuationResult {
        guard autoplayContinuation != nil else { return .empty }
        let generation = contextGeneration
        isFetchingAutoplay = true
        defer { if generation == contextGeneration { isFetchingAutoplay = false } }
        superviseSoon()
        for attempt in 0...Self.continuationRetryDelays.count {
            if attempt > 0 { await watchWait(Self.continuationRetryDelays[attempt - 1]) }
            guard generation == contextGeneration, let fetch = autoplayContinuation else { return .stale }
            var exclude = Set(context.map(\.track.videoId))
            exclude.formUnion(queue.upNext.map(\.track.videoId))
            exclude.formUnion(queue.autoplay.map(\.track.videoId))
            if let id = queue.nowPlaying?.track.videoId { exclude.insert(id) }
            let request = QTAutoplayRequest(source: queue.autoplaySource,
                                            seed: (queue.autoplay.last ?? queue.nowPlaying)?.track,
                                            excludingVideoIDs: exclude)
            let answer = await fetchWithTimeout(fetch, request, timeout: Self.continuationTimeout)
            guard generation == contextGeneration else { return .stale }
            guard let tracks = answer else { continue }
            var seen = request.excludingVideoIDs
            let items = tracks.filter { $0.availability.isPlayable && seen.insert($0.videoId).inserted }.map { QTQueueItem(track: $0) }
            guard !items.isEmpty else { return .empty }
            context.append(contentsOf: items)
            queue.autoplay.append(contentsOf: isShuffleOn ? shuffled(items, avoidingFirst: nil) : items)
            scheduleSave()
            return .added
        }
        return .failed
    }

    /// The Retry of `.autoplayUnavailable`: asks for more Autoplay again and, when the queue had stopped at its end,
    /// plays on.
    public func retryAutoplay() async {
        guard queue.nowPlaying != nil, autoplayContinuation != nil else { return }
        if naturalNext() == nil, !engine.state.isPlaying {
            wantsPlayback = true
            superviseSoon()
            await advance(userInitiated: false)
        } else if await awaitContinuation() == .failed {
            notify(.autoplayUnavailable)
        }
    }

    // MARK: Sleep and wake

    /// The Mac is going to sleep: pause, as the listener would (nothing resumes by itself on wake, like Music).
    public func systemWillSleep() {
        guard wantsPlayback || engine.state.isPlaying else { return }
        pause()
    }

    /// The Mac woke after `sleep` seconds. The engine checks itself (a long sleep gets a fresh player page, the native
    /// graph is verified); the watch starts its timings afresh.
    public func systemDidWake(after sleep: TimeInterval) {
        watch.engineDidChange()
        engine.systemDidWake(after: sleep)
    }

    // MARK: Reliability watch loop

    /// Ticks the watch once a second while it has something to watch, then stops (no timer while idle).
    func startSupervisionLoop() {
        guard let interval = supervision, supervisionTask == nil else { return }
        supervisionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                self.superviseTick()
                guard self.needsSupervision else {
                    self.supervisionTask = nil
                    return
                }
            }
        }
    }

    // MARK: Engine state

    private func observe(_ engine: any QTPlaybackEngine) {
        stateTask?.cancel()
        let stream = engine.stateUpdates()
        stateTask = Task { @MainActor [weak self] in
            for await s in stream {
                guard let self, !Task.isCancelled else { return }
                self.receive(s, from: engine)
            }
        }
    }

    func receive(_ s: QTPlaybackState, from source: any QTPlaybackEngine) {
        guard source === engine else { return }
        let previous = state
        state = s
        watch.observe(s, current: queue.nowPlaying?.id, at: uptime())
        updatePlaybackActivity()
        if loadInFlight == nil, let id = s.item?.queueID, id != queue.nowPlaying?.id, id == preparedNext?.queueID {
            advanceToPrepared(s)
            return
        }
        adoptListenerControl(s, previous: previous)
        publishNowPlaying()
        guard loadInFlight == nil, s.item?.track.videoId == queue.nowPlaying?.track.videoId else { return }
        if s.status == .ended, previous.status != .ended {
            Task { await self.handleEnded() }
        } else if case .failed(let error) = s.status, previous.status != s.status, previous.item != nil,
                  // Still failed now: a failure that arrives after the next load already plays is stale (it would
                  // count twice and stop the queue).
                  engine.state.status == s.status,
                  watch.handledFailureToken != loadToken, let track = queue.nowPlaying?.track {
            lastFailure = error
            Task { await self.skipAfterFailure(track, error) }
        } else if s.status != previous.status, s.status == .paused {
            scheduleSave()
            // Not asked for while the listener wants music ("Still listening?", WebKit): the watch looks at it.
            if wantsPlayback { superviseSoon() }
        }
    }

    /// Only actual playback keeps the Mac awake; a load the listener waits for (which may wait for the network for
    /// minutes), the gap between tracks or a retry only keeps App Nap away, so their timers run on time. A load nobody
    /// waits for (a queue restored at launch, cued) holds nothing.
    func updatePlaybackActivity() {
        let level: QTPlaybackActivityLevel
        switch state.status {
        case .playing: level = .playing
        case .loading: level = wantsPlayback ? .busy : .none
        default: level = wantsPlayback && (advancesInFlight > 0 || watch.isRecovering) ? .busy : .none
        }
        guard level != activityLevel else { return }
        activityLevel = level
        if let activity = playbackActivity {
            ProcessInfo.processInfo.endActivity(activity)
            playbackActivity = nil
        }
        switch level {
        case .none: break
        case .busy:
            playbackActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Loading music")
        case .playing:
            playbackActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Playing music")
        }
    }

    // MARK: Now Playing and remote commands

    /// Re-publishes Now Playing (call after a like change).
    public func publishNowPlaying() {
        guard let nowPlaying else { return }
        let track = queue.nowPlaying?.track
        nowPlaying.update(track: track, state: state, isLiked: track.map(isLiked) ?? false, wantsPlayback: wantsPlayback)
    }

    @discardableResult
    func handleRemote(_ command: QTRemoteCommand) -> Bool {
        guard queue.nowPlaying != nil else { return false }
        switch command {
        case .play: play()
        case .pause: pause()
        case .togglePlayPause: togglePlayPause()
        case .next: Task { await next() }
        case .previous: Task { await previous() }
        case .seek(let t):
            guard state.ad == nil else { return false }
            seek(to: t)
        case .like(let liked):
            guard let track = queue.nowPlaying?.track, let onRemoteLike else { return false }
            onRemoteLike(track, liked)
            publishNowPlaying()
        case .setShuffle(let on): setShuffle(on)
        case .setRepeat(let m): repeatMode = m
        case .setRate(let r): setRate(r)
        }
        return true
    }

    // MARK: Shuffle helper

    /// A uniform permutation; if `avoidingFirst` would come first, it swaps with another item so the same track
    /// never plays twice in a row across shuffle cycles.
    private func shuffled(_ items: [QTQueueItem], avoidingFirst videoID: String?) -> [QTQueueItem] {
        var result = items.shuffled(using: &random)
        if let videoID, result.count > 1, result[0].track.videoId == videoID,
           let swap = result.indices.dropFirst().first(where: { result[$0].track.videoId != videoID }) {
            result.swapAt(0, swap)
        }
        return result
    }
}

/// Type-erased generator so tests can inject a seeded one.
struct QTRandomSource: RandomNumberGenerator {
    var base: any RandomNumberGenerator
    mutating func next() -> UInt64 { base.next() }
}
