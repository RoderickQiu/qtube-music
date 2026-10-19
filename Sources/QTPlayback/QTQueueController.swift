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

/// Fetches more Autoplay tracks (InnerTube `next` radio, M3). Injected by the app; nil = no continuation.
public typealias QTAutoplayContinuation = @MainActor (QTAutoplayRequest) async throws -> [QTTrack]

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
@MainActor
@Observable
public final class QTQueueController {
    /// Past this many seconds, Previous restarts the track instead of going back.
    public static let restartThreshold: TimeInterval = 3
    /// Ask the continuation for more when Autoplay has this many items or fewer.
    public static let autoplayLowWatermark = 3
    /// Stop skipping after this many unplayable tracks in a row.
    public static let maxConsecutiveFailures = 3

    public private(set) var engine: any QTPlaybackEngine
    /// Mirror of the engine's latest state.
    public private(set) var state: QTPlaybackState
    public private(set) var queue = QTQueue()
    /// Song or Video rendition of the current item.
    public private(set) var mode: QTPlaybackMode = .song
    public private(set) var isShuffleOn = false
    public var repeatMode: QTRepeatMode = .off {
        didSet { if repeatMode != oldValue { scheduleSave(); publishNowPlaying() } }
    }
    public private(set) var isFetchingAutoplay = false
    /// The last load failure (cleared by the next successful load).
    public private(set) var lastFailure: QTPlaybackError?

    @ObservationIgnored public var autoplayContinuation: QTAutoplayContinuation?
    /// Called when the current track changes (not on Song⇄Video switches of the same track).
    @ObservationIgnored public var onTrackChange: (@MainActor (QTTrack?) -> Void)?
    /// Like state for Now Playing and the remote like command.
    @ObservationIgnored public var isLiked: @MainActor (QTTrack) -> Bool = { _ in false }
    /// Remote "like" (Control Center / Touch Bar). The app decides what liking means (local until writes are approved).
    @ObservationIgnored public var onRemoteLike: (@MainActor (QTTrack, Bool) -> Void)?
    @ObservationIgnored public let nowPlaying: QTNowPlayingController?

    @ObservationIgnored private let store: QTQueueStore?
    @ObservationIgnored private var random: QTRandomSource
    /// The context in original order. Autoplay items share ids with these.
    @ObservationIgnored private var context: [QTQueueItem] = []
    @ObservationIgnored private var contextCursor: Int?
    /// Bumped whenever the context is replaced; stale continuation results are dropped.
    @ObservationIgnored private var contextGeneration = 0
    @ObservationIgnored private var origins: [UUID: QTQueueSection] = [:]
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var continuationTask: Task<Int, Never>?
    @ObservationIgnored private var loadToken = 0
    @ObservationIgnored private var loadsInFlight = 0
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var lastAnnouncedTrackID: String?
    @ObservationIgnored private let uptime: @MainActor () -> TimeInterval

    /// - Parameters:
    ///   - engine: the active engine (`QTPlaybackEngineSelector`).
    ///   - nowPlaying: the process's single Now Playing owner; nil for mock/screenshot runs and tests.
    ///   - store: queue persistence; nil = in-memory only.
    ///   - random: shuffle source (tests inject a seeded generator).
    ///   - uptime: clock the engine's timeline is anchored to (tests inject the simulated engine's clock).
    public init(engine: any QTPlaybackEngine, nowPlaying: QTNowPlayingController? = nil, store: QTQueueStore? = nil,
                random: any RandomNumberGenerator = SystemRandomNumberGenerator(),
                uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.engine = engine
        self.nowPlaying = nowPlaying
        self.store = store
        self.random = QTRandomSource(base: random)
        self.uptime = uptime
        state = engine.state
        observe(engine)
        nowPlaying?.commandHandler = { [weak self] command in self?.handleRemote(command) ?? false }
    }

    // MARK: Derived

    public var nowPlayingTrack: QTTrack? { queue.nowPlaying?.track }
    /// Position in the current item now (interpolated from the engine's timeline).
    public var currentTime: TimeInterval { engine.state.timeline.time(atUptime: uptime()) }
    public var capabilities: QTPlaybackCapabilities { engine.capabilities }

    // MARK: Starting playback

    /// Plays `tracks[index]`; the playable rest of `tracks` continues as Autoplay from `source` (shuffled when
    /// shuffle is on). Up Next is kept.
    public func play(_ tracks: [QTTrack], startingAt index: Int = 0, source: QTQueueSource? = nil,
                     startTime: TimeInterval = 0, autoplay: Bool = true, mode: QTPlaybackMode = .song) async {
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
        await loadCurrent(startTime: startTime, autoplay: autoplay, mode: mode)
    }

    /// "Shuffle" on a playlist/album/artist, and "Shuffle entire library": turns shuffle on and starts from a
    /// random track.
    public func shuffle(_ tracks: [QTTrack], source: QTQueueSource? = nil) async {
        let items = tracks.filter(\.availability.isPlayable).map { QTQueueItem(track: $0) }
        guard !items.isEmpty else { return }
        isShuffleOn = true
        let order = shuffled(items, avoidingFirst: nil)
        replaceContext(items, source: source)
        becomeCurrent(order[0], from: .autoplay)
        queue.autoplay = Array(order.dropFirst())
        await loadCurrent(startTime: 0, autoplay: true, mode: .song)
    }

    // MARK: Transport

    public func play() { engine.play() }
    public func pause() { engine.pause() }
    public func togglePlayPause() { engine.togglePlayPause() }
    public func seek(to time: TimeInterval) { engine.seek(to: time) }
    public func setVolume(_ volume: Double) { engine.setVolume(volume) }
    public func setMuted(_ muted: Bool) { engine.setMuted(muted) }
    public func skipAd() { engine.skipAd() }

    /// Next (button, menu, media key). Moves on even under Repeat One.
    public func next() async {
        await advance(userInitiated: true)
    }

    /// Previous: restarts the track when more than `restartThreshold` seconds in (or with no history), else goes
    /// back to the previously played item and returns the current one to the front of its section.
    public func previous() async {
        guard queue.nowPlaying != nil else { return }
        if currentTime > Self.restartThreshold || queue.history.isEmpty {
            engine.seek(to: 0)
            if engine.state.status != .playing { engine.play() }
            return
        }
        let previous = queue.history.removeLast()
        if let current = queue.nowPlaying {
            switch origins[current.id] ?? .autoplay {
            case .upNext: queue.upNext.insert(current, at: 0)
            case .autoplay: queue.autoplay.insert(current, at: 0)
            }
        }
        queue.nowPlaying = previous
        await loadCurrent(startTime: 0, autoplay: true, mode: mode)
    }

    /// Song⇄Video at the same position.
    public func setMode(_ newMode: QTPlaybackMode) async {
        guard newMode != mode, let track = queue.nowPlaying?.track, track.hasVideo || newMode == .song else { return }
        await loadCurrent(startTime: currentTime, autoplay: engine.state.isPlaying, mode: newMode)
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
        await loadCurrent(startTime: 0, autoplay: true, mode: mode)
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
        let wasPlaying = engine.state.isPlaying
        engine.stop()
        engine = newEngine
        observe(newEngine)
        state = newEngine.state
        if queue.nowPlaying != nil {
            await loadCurrent(startTime: position, autoplay: wasPlaying, mode: mode)
        }
    }

    // MARK: Persistence

    /// Restores the saved queue and cues the current item at its saved position (paused unless `autoplay`).
    @discardableResult
    public func restore(autoplay: Bool = false) async -> Bool {
        guard let store, let snapshot = await store.load() else { return false }
        apply(snapshot)
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

    /// Writes now (app termination). Normal edits are saved debounced.
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

    private func scheduleSave() {
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

    private func advance(userInitiated: Bool) async {
        guard queue.nowPlaying != nil || !queue.upNext.isEmpty || !queue.autoplay.isEmpty else { return }
        if let next = popNext() {
            becomeCurrent(next.item, from: next.section)
        } else if repeatMode == .all, !context.isEmpty {
            let current = queue.nowPlaying?.track.videoId
            queue.autoplay = isShuffleOn ? shuffled(context, avoidingFirst: current) : context
            contextCursor = nil
            guard let next = popNext() else { return }
            becomeCurrent(next.item, from: next.section)
        } else if queue.isAutoplayEnabled, autoplayContinuation != nil, await awaitContinuation() > 0, let next = popNext() {
            becomeCurrent(next.item, from: next.section)
        } else {
            // End of the queue: the last item stays loaded (ended), like Music.app.
            return
        }
        await loadCurrent(startTime: 0, autoplay: true, mode: mode)
    }

    private func handleEnded() async {
        if repeatMode == .one {
            engine.seek(to: 0)
            engine.play()
            return
        }
        await advance(userInitiated: false)
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
        origins[item.id] = section
        if section == .autoplay, let i = context.firstIndex(where: { $0.id == item.id }) { contextCursor = i }
    }

    private func replaceContext(_ items: [QTQueueItem], source: QTQueueSource?) {
        context = items
        contextCursor = nil
        contextGeneration += 1
        continuationTask?.cancel()
        continuationTask = nil
        queue.autoplaySource = source
    }

    private func loadCurrent(startTime: TimeInterval, autoplay: Bool, mode newMode: QTPlaybackMode) async {
        guard let item = queue.nowPlaying else { return }
        loadToken += 1
        let token = loadToken
        loadsInFlight += 1
        defer { loadsInFlight -= 1 }
        let track = item.track
        mode = (newMode == .video && track.hasVideo) ? .video : .song
        announceTrackChange()
        scheduleSave()
        do {
            try await engine.load(QTPlaybackItem(track: track, mode: mode, startTime: startTime), autoplay: autoplay)
            guard token == loadToken else { return }
            consecutiveFailures = 0
            lastFailure = nil
            prefetchContinuationIfNeeded()
        } catch is CancellationError {
            return
        } catch {
            guard token == loadToken else { return }
            lastFailure = (error as? QTPlaybackError) ?? .engine(String(describing: error))
            await skipAfterFailure(wasPlaying: autoplay)
        }
    }

    private func skipAfterFailure(wasPlaying: Bool) async {
        consecutiveFailures += 1
        guard wasPlaying, consecutiveFailures < Self.maxConsecutiveFailures else { return }
        await advance(userInitiated: false)
    }

    private func announceTrackChange() {
        let id = queue.nowPlaying?.track.videoId
        guard id != lastAnnouncedTrackID else { return }
        lastAnnouncedTrackID = id
        onTrackChange?(queue.nowPlaying?.track)
    }

    // MARK: Autoplay continuation

    private func prefetchContinuationIfNeeded() {
        guard queue.isAutoplayEnabled, autoplayContinuation != nil, continuationTask == nil, repeatMode != .all,
              queue.autoplay.count <= Self.autoplayLowWatermark else { return }
        continuationTask = Task { @MainActor [weak self] in
            guard let self else { return 0 }
            let added = await self.fetchContinuation()
            self.continuationTask = nil
            return added
        }
    }

    private func awaitContinuation() async -> Int {
        if let running = continuationTask { return await running.value }
        return await fetchContinuation()
    }

    private func fetchContinuation() async -> Int {
        guard let fetch = autoplayContinuation else { return 0 }
        let generation = contextGeneration
        var exclude = Set(context.map(\.track.videoId))
        exclude.formUnion(queue.upNext.map(\.track.videoId))
        exclude.formUnion(queue.autoplay.map(\.track.videoId))
        if let id = queue.nowPlaying?.track.videoId { exclude.insert(id) }
        let request = QTAutoplayRequest(source: queue.autoplaySource,
                                        seed: (queue.autoplay.last ?? queue.nowPlaying)?.track,
                                        excludingVideoIDs: exclude)
        isFetchingAutoplay = true
        defer { isFetchingAutoplay = false }
        guard let tracks = try? await fetch(request), generation == contextGeneration else { return 0 }
        var seen = exclude
        let items = tracks.filter { $0.availability.isPlayable && seen.insert($0.videoId).inserted }.map { QTQueueItem(track: $0) }
        guard !items.isEmpty else { return 0 }
        context.append(contentsOf: items)
        queue.autoplay.append(contentsOf: isShuffleOn ? shuffled(items, avoidingFirst: nil) : items)
        scheduleSave()
        return items.count
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

    private func receive(_ s: QTPlaybackState, from source: any QTPlaybackEngine) {
        guard source === engine else { return }
        let previous = state
        state = s
        publishNowPlaying()
        guard loadsInFlight == 0, s.item?.track.videoId == queue.nowPlaying?.track.videoId else { return }
        if s.status == .ended, previous.status != .ended {
            Task { await self.handleEnded() }
        } else if case .failed(let error) = s.status, previous.status != s.status, previous.item != nil {
            lastFailure = error
            Task { await self.skipAfterFailure(wasPlaying: previous.status == .playing) }
        } else if s.status != previous.status, s.status == .paused {
            scheduleSave()
        }
    }

    // MARK: Now Playing and remote commands

    /// Re-publishes Now Playing (call after a like change).
    public func publishNowPlaying() {
        guard let nowPlaying else { return }
        let track = queue.nowPlaying?.track
        nowPlaying.update(track: track, state: state, isLiked: track.map(isLiked) ?? false)
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
