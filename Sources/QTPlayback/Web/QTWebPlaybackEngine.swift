import AppKit
import Foundation
import Network
import QTCore
import QTInnerTube
import WebKit

/// Free-account engine: YouTube Music's own web player, ads included, in a headless `WKWebView`.
///
/// - **Headless:** the web view lives in a borderless window that is never ordered on screen (WebKit only runs
///   media for views inside a window). It is excluded from the Windows menu, Mission Control and screen capture,
///   and never becomes key, so it can't take focus.
/// - **One Now Playing entry:** media runs in the WebContent process (`UseGPUProcessForMediaEnabled` off). The
///   GPU process is what publishes WebKit's own Now Playing card on the app's behalf (Kaset bug #457); the
///   sandboxed WebContent process can't, so `QTNowPlayingController` is the only publisher. The page's
///   `navigator.mediaSession` is shielded too.
/// - **Tiny bridge:** `QTWebPlaybackBridgeScript` reports state and forwards load/play/pause/seek/volume/skip.
/// - **Track end:** the bridge posts `ended` once per load generation and holds YouTube's own autoplay; the
///   engine reports `.ended` and `QTQueueController` decides what's next.
/// - **Errors:** player errors and non-OK playability (age gate, region lock, removed) fail the item with a
///   specific `QTPlaybackError`; the queue skips it and the app shows a toast.
/// - **Network:** offline time never counts towards load timeouts or the stall watchdog; when the network comes
///   back a stalled item reloads at its position. A load that times out online is retried once on a fresh page.
/// - **Crashes:** a WebContent process that dies (`webContentProcessDidTerminate`), a page that no longer takes
///   commands, or a page left over from a long sleep is replaced by a fresh one at the same position, playing or
///   paused as before.
/// - **Power:** lowest video quality while no video is shown, and the page's timers are frozen a few seconds into
///   a pause the app asked for (`Configuration.freezeAfterPause`), so a paused engine costs next to nothing. A pause
///   the page made itself is never frozen: its "Still listening?" prompt has to stay answerable
///   (`QTWebPlaybackBridgeScript.keepAlive`).
/// - **Video (M5):** `video` (`QTWebVideoOutput`) moves the web view into an app view while the app shows the
///   music video (the page becomes a bare `<video>` surface, quality sized to the slot) and back into the hidden
///   host when it doesn't; native Picture in Picture goes through WebKit. Song⇄Video switches of the same track
///   are measured (`lastModeSwitch`: requested vs landed position, latency).
/// - **Visualizer data (web-audio):** `audio` (`QTWebAudioTap`) decodes the audio the page appends to its
///   MediaSource and returns spectra, pulled only while a visualizer shows. Nothing is routed: media element,
///   volume, ads and Now Playing are untouched. EQ/crossfade can't be done in the page (`docs/web-audio.md`).
@MainActor
public final class QTWebPlaybackEngine: QTPlaybackEngine {
    public struct Configuration: Sendable {
        /// Page that hosts the player. Watch pages on music.youtube.com play songs and videos, with ads for free accounts.
        public var origin: URL
        /// Desktop Safari UA so YouTube Music serves its full player.
        public var userAgent: String
        /// Pins every media element's volume to 0 at the source (tests, lab). Engine volume still reports normally.
        public var isSilent: Bool
        /// How long `load` waits for the player to report the new item before failing.
        public var loadTimeout: Duration
        /// No time progress for this long while playing (not buffering an ad) counts as a stall and reloads once.
        public var stallTimeout: Duration
        /// Ask YouTube for its lowest video rendition (144p): the app never shows the page's video, so decoding
        /// more is wasted power. Audio quality is unaffected (separate stream).
        public var prefersLowVideoQuality: Bool
        /// Freeze the page's timers this long into a pause (nil = never).
        public var freezeAfterPause: Duration?
        /// Maps an item to the video id to play (default `QTWebPlaybackEngine.videoID(for:)`). The app uses it to
        /// play mock-catalog tracks through their real music-video ids.
        public var videoIDResolver: (@Sendable (QTPlaybackItem) -> String)?
        /// Testing: holds every load after the first this long before it reaches the page (a slow network, for
        /// screenshots of the loading state between tracks).
        public var debugLoadDelay: Duration?
        /// Song⇄Video while playing prepares the other rendition in a second silent page and crossfades it in
        /// (no gap). Off: the page reloads in place (a short gap).
        public var seamlessModeSwitch = true

        public init(origin: URL = URL(string: "https://music.youtube.com")!,
                    userAgent: String = QTInnerTubeConfiguration.defaultUserAgent,
                    isSilent: Bool = false, loadTimeout: Duration = .seconds(25), stallTimeout: Duration = .seconds(20),
                    prefersLowVideoQuality: Bool = true, freezeAfterPause: Duration? = .seconds(6),
                    videoIDResolver: (@Sendable (QTPlaybackItem) -> String)? = nil) {
            self.origin = origin
            self.userAgent = userAgent
            self.isSilent = isSilent
            self.loadTimeout = loadTimeout
            self.stallTimeout = stallTimeout
            self.prefersLowVideoQuality = prefersLowVideoQuality
            self.freezeAfterPause = freezeAfterPause
            self.videoIDResolver = videoIDResolver
        }
    }

    /// Video, AirPlay and visualizer data (the page's spectrum tap, `audio`); gapless/crossfade/EQ stay native-only.
    public var capabilities: QTPlaybackCapabilities { .web }
    public internal(set) var state = QTPlaybackState(volume: 1)

    public let configuration: Configuration
    /// Where the page's cookies live. Always non-persistent: the app passes QTAuth's session jar
    /// (`QTWebKitCookieStore.session`, seeded from the Keychain) for signed-in playback, or a throwaway store.
    public let dataStore: WKWebsiteDataStore

    /// The player page (internal: `QTWebVideoOutput` moves it between the hidden host and the app's video slots).
    var webView: WKWebView?
    var hostWindow: NSWindow?
    /// The page's video in the app's own views, and Picture in Picture.
    public let video: QTWebVideoOutput
    /// Spectrum data for the visualizer, decoded from the stream the page plays (web-audio).
    public let audio = QTWebAudioTap()
    /// The last Song⇄Video switch of one track: where it was asked to start and where the new rendition started.
    public internal(set) var lastModeSwitch: QTModeSwitchReport?
    /// Called once per Song⇄Video switch when the new rendition starts playing (logs, acceptance scripts).
    public var onModeSwitch: (@MainActor (QTModeSwitchReport) -> Void)?
    private var pendingSwitch: (requested: TimeInterval, from: QTPlaybackMode, to: QTPlaybackMode, uptime: TimeInterval, generation: Int)?
    /// The id requested from the page for the current item.
    var requestedVideoID: String?
    /// WebKit pauses a page's video when its view moves from a visible window into the hidden host; the move
    /// arms this (only while playing), and a pause reported before the deadline is undone. A real pause clears it.
    private var resumeAfterMoveDeadline: TimeInterval?
    var messageProxy: QTWebPlaybackMessageProxy?
    private var continuations: [UUID: AsyncStream<QTPlaybackState>.Continuation] = [:]

    /// Increments per `load`; bridge messages from older generations are ignored.
    var generation = 0
    var isPageReady = false
    var pendingLoads: [Int: CheckedContinuation<Void, any Error>] = [:]
    var lastSample: QTWebPlaybackSample?
    private var watchdog: Task<Void, Never>?
    private var lastProgress: (time: TimeInterval, uptime: TimeInterval) = (0, 0)
    /// Last change of the ad countdown (nil while no ad shows).
    private var adProgress: (remaining: TimeInterval, uptime: TimeInterval)?
    /// Position of the last content (not ad) sample this load; a stuck ad reloads the item from here.
    private var lastContentTime: TimeInterval?
    /// An ad whose countdown hasn't moved for this long (while playing) is stuck: the item reloads once.
    static let adStallTimeout: TimeInterval = 10
    private var didRetryStall = false
    /// play/pause requested before the page's player was ready; applied on `ready`.
    private var playIntentBeforeReady: Bool?
    /// What the app last asked for: play (autoplaying load, play) or not (cued load, pause, stop). A page that pauses
    /// while this is true paused on its own, and is never frozen.
    private(set) var intendsPlayback = false
    /// Notices a WebContent process that died (the page goes blank and stops answering).
    private lazy var navigationWatcher = QTWebPlaybackNavigationWatcher(engine: self)
    /// Recent WebContent crashes (uptime); a page that keeps crashing fails the item instead of looping.
    private var recentCrashes: [TimeInterval] = []
    /// After a sleep this long the page's player state (tokens, stream URLs) is stale: the next play gets a fresh page.
    static let longSleep: TimeInterval = 30 * 60
    private var freezeTask: Task<Void, Never>?
    /// WebKit's hidden-page throttling is back on (paused + frozen).
    var isThrottlingHiddenPage = false
    /// The page's timers are frozen (paused for a while).
    public private(set) var isPageFrozen = false
    /// The video id the page is playing for the current item (may be the song for a requested video).
    public internal(set) var playingVideoID: String?
    /// False while the system reports no usable network path.
    public private(set) var isNetworkAvailable = true
    /// Network went away (false) or came back (true). The app tells the user once.
    public var onNetworkChange: (@MainActor (Bool) -> Void)?
    private var pathMonitor: NWPathMonitor?
    /// Fresh-page retries left for the current load after an online timeout.
    private var loadRetriesLeft = 0
    /// The store's login changed: the next load navigates a fresh page instead of reusing the loaded player.
    var needsFreshPage = false
    /// A Song⇄Video switch preparing its rendition in a second, silent page (`QTWebPlaybackEngine+ModeSwitch`).
    var standby: QTWebStandbySwitch?
    /// Request → standby page playing, learnt per switch (sizes how far ahead the standby starts).
    var modeSwitchReadyEstimate: TimeInterval = 2.5
    /// play → audible on a held standby page, learnt per switch.
    var modeSwitchPlayLatency: TimeInterval = 0.04
    /// Why the last seamless Song⇄Video switch fell back to an in-page reload (diagnostics; nil = it didn't).
    public internal(set) var lastSeamlessFallback: String?
    /// The standby gives up (in-page reload instead) after this long without a playable, buffered rendition.
    var modeSwitchStandbyTimeout: TimeInterval = 12
    /// Who the player page plays as (its own `ytcfg`), read when it becomes ready; nil = not known yet.
    /// Seamless switches never run for a signed-in free account (see `canSwitchSeamlessly`).
    var pageAccount: QTWebPageAccount?
    /// How the engine talks to its pages (WebKit; tests drive fake pages through it).
    var pageIO = QTWebPageIO.webKit

    /// - Parameters:
    ///   - dataStore: the app passes QTAuth's non-persistent session jar for signed-in playback; tests and the lab
    ///     pass `.nonPersistent()` to stay anonymous. Never a persistent store (WebKit saves its cookies in plain text).
    public init(configuration: Configuration = Configuration(), dataStore: WKWebsiteDataStore = QTWebPlaybackEngine.sharedDataStore) {
        precondition(!dataStore.isPersistent, "QTWebPlaybackEngine: persistent WebKit stores save cookies in plain text")
        self.configuration = configuration
        self.dataStore = dataStore
        video = QTWebVideoOutput()
        video.engine = self
        audio.fetchFrames = { [weak self] bands, ahead, step in await self?.audioFrames(bands: bands, ahead: ahead, step: step) }
        audio.releasePage = { [weak self] in await self?.audioRelease() }
        startNetworkMonitor()
    }

    isolated deinit {
        pathMonitor?.cancel()
    }

    /// A process-wide anonymous, non-persistent store (the default when no store is given).
    public static let sharedDataStore: WKWebsiteDataStore = .nonPersistent()

    // MARK: Stream

    public func stateUpdates() -> AsyncStream<QTPlaybackState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<QTPlaybackState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(state)
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations[id] = nil }
        }
        return stream
    }

    func publish() {
        for c in continuations.values { c.yield(state) }
    }

    // MARK: Transport

    public func load(_ item: QTPlaybackItem, autoplay: Bool = true) async throws {
        guard item.track.availability.isPlayable else {
            state.status = .failed(.unavailable(item.track.availability))
            publish()
            throw QTPlaybackError.unavailable(item.track.availability)
        }
        let videoID = resolvedVideoID(for: item)
        guard Self.isWellFormedVideoID(videoID) else {
            // YouTube would show an error page without a player; fail now instead of after the load timeout.
            stop()
            state = QTPlaybackState(item: item, status: .failed(.unavailable(.removed)), volume: state.volume, isMuted: state.isMuted)
            publish()
            throw QTPlaybackError.unavailable(.removed)
        }
        // A switch still preparing in the standby page is superseded by any new load (including switching back).
        cancelStandby(.superseded)
        intendsPlayback = autoplay
        var item = item
        var autoplay = autoplay
        let previousMode = state.item.flatMap { $0.track.videoId == item.track.videoId ? $0.mode : nil }
        let isModeSwitch = previousMode != nil && previousMode != item.mode
        // Song⇄Video where both renditions are the same upload (a video without a separate song, demo tracks):
        // nothing to load — only the presentation changes, instantly and without a gap.
        if isModeSwitch, videoID == requestedVideoID, pendingLoads.isEmpty, state.status == .playing || state.status == .paused {
            state.item = item
            video.itemDidChange(isVideo: item.mode == .video)
            publish()
            return
        }
        // While playing, the other rendition is prepared in a second silent page and crossfaded in at the same
        // moment: the music never stops (see QTWebPlaybackEngine+ModeSwitch).
        if isModeSwitch, let from = previousMode, canSwitchSeamlessly(autoplay: autoplay) {
            // The renditions can be different cuts (an MV with an intro): the queue then asks for another position
            // than the clock's, and the standby lines up with the old page shifted by that much.
            let shift = Self.modeSwitchShift(requested: item.startTime, clock: state.timeline.currentTime)
            switch await seamlessModeSwitch(to: item, videoID: videoID, from: from, shift: shift) {
            case .done:
                return
            case .superseded:
                throw CancellationError()
            case .fallBack:
                // Load it in the page instead, from where playback is now and as the listener wants it now.
                item.startTime = max(0, state.timeline.currentTime + shift)
                autoplay = state.status == .playing
            }
        }
        if isModeSwitch, let from = previousMode {
            pendingSwitch = (item.startTime, from, item.mode, ProcessInfo.processInfo.systemUptime, generation + 1)
        } else {
            pendingSwitch = nil
        }
        generation += 1
        let gen = generation
        lastSample = nil
        didRetryStall = false
        adProgress = nil
        lastContentTime = nil
        playingVideoID = nil
        requestedVideoID = videoID
        video.itemDidChange(isVideo: item.mode == .video)
        audio.itemDidChange()
        loadRetriesLeft = 1
        cancelFreeze()
        failPendingLoads(except: gen)

        let duration = item.track.duration
        state = QTPlaybackState(item: item, status: .loading,
                                timeline: QTPlaybackTimeline(time: item.startTime, rate: 0, duration: duration > 0 ? duration : .infinity),
                                duration: duration, isBuffering: true, ad: nil, volume: state.volume, isMuted: state.isMuted)
        publish()

        // Register first: the page can answer (or fail) before `command` returns.
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            pendingLoads[gen] = c
            startLoadTimeout(generation: gen, item: item, videoID: videoID, autoplay: autoplay)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let delay = self.configuration.debugLoadDelay, gen > 1 { try? await Task.sleep(for: delay) }
                let sentToPage = self.isPageReady && !self.needsFreshPage
                    ? await self.command("load", videoID, item.startTime, autoplay, gen) : false
                guard gen == self.generation, self.pendingLoads[gen] != nil else { return }
                if !sentToPage { self.navigate(videoID: videoID, start: item.startTime, autoplay: autoplay, generation: gen) }
            }
        }
    }

    /// The load timeout counts only online seconds; an online timeout retries once on a fresh page, then fails.
    private func startLoadTimeout(generation gen: Int, item: QTPlaybackItem, videoID: String, autoplay: Bool) {
        let limit = Double(configuration.loadTimeout.components.seconds)
        Task { @MainActor [weak self] in
            var online = 0.0
            while true {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.pendingLoads[gen] != nil, gen == self.generation else { return }
                // Google's bot check instead of the player: fail now (no retry — a fresh page lands there too).
                if QTWebPlaybackErrorMapper.isBotCheckPage(self.webView?.url),
                   let c = self.pendingLoads.removeValue(forKey: gen) {
                    self.state.status = .failed(.botCheck)
                    self.state.isBuffering = false
                    self.publish()
                    c.resume(throwing: QTPlaybackError.botCheck)
                    return
                }
                if self.isNetworkAvailable { online += 0.5 }
                guard online >= limit else { continue }
                if self.loadRetriesLeft > 0 {
                    self.loadRetriesLeft -= 1
                    online = 0
                    self.navigate(videoID: videoID, start: item.startTime, autoplay: autoplay, generation: gen)
                    continue
                }
                guard let c = self.pendingLoads.removeValue(forKey: gen) else { return }
                self.state.status = .failed(.network("timeout"))
                self.state.isBuffering = false
                self.publish()
                c.resume(throwing: QTPlaybackError.network("timeout"))
                return
            }
        }
    }

    private func resolvedVideoID(for item: QTPlaybackItem) -> String {
        configuration.videoIDResolver?(item) ?? Self.videoID(for: item)
    }

    public func play() {
        guard state.item != nil else { return }
        intendsPlayback = true
        // A page left over from a long sleep (or a crash) plays nothing useful: a fresh one at the same position.
        if needsFreshPage, pendingLoads.isEmpty, webView != nil {
            reloadCurrent(autoplay: true)
            return
        }
        if state.status == .ended {
            state.timeline = QTPlaybackTimeline(time: 0, rate: 0, duration: state.timeline.duration)
        }
        if !pendingLoads.isEmpty, state.status == .paused {
            // Paused while it loaded, wanted again: still on its way.
            state.status = .loading
            state.isBuffering = true
            publish()
        }
        cancelFreeze()
        guard isPageReady else { playIntentBeforeReady = true; return }
        let gen = generation
        Task { @MainActor [weak self] in
            guard let self, await !self.command("play") else { return }
            // The page didn't take it (its process died, the player is gone): reload where it was, playing.
            guard gen == self.generation, self.intendsPlayback, self.pendingLoads.isEmpty else { return }
            QTWebVideoOutput.log.info("the page didn't take play; reloading the item")
            self.reloadCurrent(autoplay: true)
        }
    }

    public func pause() {
        resumeAfterMoveDeadline = nil
        intendsPlayback = false
        cancelStandby(.fallBack)
        guard state.item != nil else { return }
        // Optimistic: freeze the timeline now so the UI doesn't drift while the page catches up. Paused while
        // loading (offline, a slow page) shows paused at once; the load finishes held.
        if state.status == .playing || (state.status == .loading && state.ad == nil) {
            state.timeline = QTPlaybackTimeline(time: state.timeline.currentTime, rate: 0, duration: state.timeline.duration)
            state.status = .paused
            state.isBuffering = false
            publish()
        }
        guard isPageReady else { playIntentBeforeReady = false; return }
        Task { await command("pause") }
        scheduleFreeze()
    }

    public func seek(to time: TimeInterval) {
        guard state.item != nil, state.ad == nil else { return }
        cancelStandby(.fallBack)
        let upper = state.duration > 0 ? max(0, state.duration - 0.5) : time
        let t = min(max(0, time), upper)
        if state.status == .ended { state.status = .paused }
        state.timeline = QTPlaybackTimeline(time: t, rate: state.status == .playing ? 1 : 0, duration: state.timeline.duration)
        publish()
        cancelFreeze()  // the seek command thaws the page
        Task { await command("seek", t) }
        if state.status != .playing { scheduleFreeze() }
    }

    public func setVolume(_ volume: Double) {
        state.volume = min(1, max(0, volume))
        publish()
        Task { await command("volume", state.volume, state.isMuted) }
    }

    public func setMuted(_ muted: Bool) {
        state.isMuted = muted
        publish()
        Task { await command("volume", state.volume, state.isMuted) }
    }

    public func skipAd() {
        guard state.ad?.canSkip == true, let webView, isPageReady else { return }
        Task {
            guard let target = try? await webView.callAsyncJavaScript(
                "return window.__qtBridge ? window.__qtBridge.skipTarget() : null", arguments: [:], in: nil, contentWorld: .page
            ) as? [String: Any], let x = target["x"] as? Double, let y = target["y"] as? Double else { return }
            Self.click(webView, atViewportX: x, y: y)
        }
    }

    /// Delivers a real (trusted) click to our own offscreen web view — never to the user's screen.
    private static func click(_ webView: WKWebView, atViewportX x: Double, y: Double) {
        guard let window = webView.window else { return }
        let inView = NSPoint(x: x, y: webView.isFlipped ? y : webView.bounds.height - y)
        let inWindow = webView.convert(inView, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            if type == .leftMouseDown { webView.mouseDown(with: event) } else { webView.mouseUp(with: event) }
        }
    }

    public func stop() {
        cancelStandby(.superseded)
        intendsPlayback = false
        generation += 1
        cancelFreeze()
        playingVideoID = nil
        failPendingLoads(except: generation)
        Task { await command("pause") }
        state = QTPlaybackState(volume: state.volume, isMuted: state.isMuted)
        watchdog?.cancel()
        watchdog = nil
        publish()
    }

    /// Tears the web view down (sign-out, engine switch). The next `load` recreates it.
    public func shutdown() {
        stop()
        video.engineWillTearDown()
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView?.removeFromSuperview()
        hostWindow?.close()
        webView = nil
        hostWindow = nil
        messageProxy = nil
        isPageReady = false
    }

    /// The data store's login changed (sign-in, sign-out, account switch). The loaded player page keeps the identity
    /// it was loaded with, so the next load navigates a fresh page; a current item reloads now at its position,
    /// keeping play/pause (a Premium sign-in drops a running ad at once).
    public func sessionDidChange() {
        guard webView != nil else { return }
        cancelStandby(.superseded)
        needsFreshPage = true
        pageAccount = nil
        guard let item = state.item, pendingLoads.isEmpty else { return }
        switch state.status {
        case .playing, .paused, .loading: break
        default: return
        }
        var resume = item
        resume.startTime = state.ad == nil ? state.timeline.currentTime : item.startTime
        let autoplay = state.status == .playing || playIntentBeforeReady == true
        Task { try? await self.load(resume, autoplay: autoplay) }
    }

    // MARK: Recovery

    /// Loads the current item again at its position on a fresh page (a crashed WebContent process, a page that stopped
    /// answering commands, a long sleep), playing or held as `autoplay` says.
    func reloadCurrent(autoplay: Bool) {
        guard var item = state.item, pendingLoads.isEmpty else { return }
        needsFreshPage = true
        switch state.status {
        case .ended: item.startTime = 0
        case .loading: break
        default: item.startTime = state.ad == nil ? state.timeline.currentTime : (lastContentTime ?? item.startTime)
        }
        Task { try? await self.load(item, autoplay: autoplay) }
    }

    /// The page's WebContent process died (memory pressure, a WebKit crash): the page is blank and every command
    /// fails. The item reloads on a fresh page where it was — playing or held as the app last asked. A page that keeps
    /// crashing fails the item instead (the queue moves on).
    func webContentProcessDidTerminate() {
        QTWebVideoOutput.log.error("player page's WebContent process terminated")
        isPageReady = false
        isPageFrozen = false
        isThrottlingHiddenPage = false
        needsFreshPage = true
        stopWatchdog()
        cancelFreeze()
        let now = ProcessInfo.processInfo.systemUptime
        recentCrashes = recentCrashes.filter { now - $0 < 120 } + [now]
        guard let item = state.item else { return }
        if recentCrashes.count >= 3 {
            recentCrashes = []
            let error = QTPlaybackError.engine("the player page keeps crashing")
            state.status = .failed(error)
            state.ad = nil
            state.isBuffering = false
            publish()
            pendingLoads.removeValue(forKey: generation)?.resume(throwing: error)
            return
        }
        if pendingLoads[generation] != nil, let videoID = requestedVideoID {
            // The load in flight goes on, on a new page.
            navigate(videoID: videoID, start: item.startTime, autoplay: intendsPlayback, generation: generation)
        } else if intendsPlayback, state.status == .playing {
            reloadCurrent(autoplay: true)
        }
        // Paused, ended or failed: nothing plays, so no page is needed yet — the next play or load makes a fresh one
        // (`needsFreshPage`), at the position the state still shows.
    }

    /// From the Picture in Picture window's own controls: the listener's pause, not the page's.
    public var isPausedByListener: Bool {
        state.status == .paused && video.isPictureInPictureActive
    }

    /// After a long sleep the page's player state is stale (tokens, stream URLs): the next play reloads it fresh.
    public func systemDidWake(after sleep: TimeInterval) {
        lastProgress = (state.timeline.currentTime, ProcessInfo.processInfo.systemUptime)
        guard sleep >= Self.longSleep, webView != nil else { return }
        needsFreshPage = true
        pageAccount = nil
    }

    // MARK: Song/Video ids

    /// YouTube video ids are 11 characters of `[A-Za-z0-9_-]`.
    public nonisolated static func isWellFormedVideoID(_ id: String) -> Bool {
        id.utf8.count == 11 && id.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2D || c == 0x5F
        }
    }

    /// The video id to play for an item: Song mode prefers the audio track (ATV), Video mode the music video.
    public nonisolated static func videoID(for item: QTPlaybackItem) -> String {
        let track = item.track
        switch item.mode {
        case .song:
            if track.musicVideoType.isVideo, let c = track.counterpart, !c.musicVideoType.isVideo { return c.videoId }
        case .video:
            if !track.musicVideoType.isVideo, let c = track.counterpart, c.musicVideoType.isVideo { return c.videoId }
        }
        return track.videoId
    }

    // MARK: Web view

    private func makeWebView(bootstrap: String) -> WKWebView {
        let proxy = QTWebPlaybackMessageProxy(engine: self)
        messageProxy = proxy
        let (view, window) = makePage(bootstrap: bootstrap, proxy: proxy)
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "qt.video.debugVisibleHost"),
           let screen = NSScreen.screens.first(where: { $0.localizedName.contains("U270CA") }) {
            window.alphaValue = 1
            window.sharingType = .readOnly
            window.setFrame(NSRect(x: screen.frame.minX + 40, y: screen.frame.minY + 40, width: 1280, height: 800), display: true)
            window.title = "QTDebugHost"
            window.orderFront(nil)
        }
        #endif
        hostWindow = window
        webView = view
        video.webViewDidLoad()
        return view
    }

    /// A player page in its own offscreen host window (the main page, or a Song⇄Video standby page).
    func makePage(bootstrap: String, proxy: QTWebPlaybackMessageProxy) -> (WKWebView, NSWindow) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        QTWebKitTuning.runMediaInWebContentProcess(config.preferences)
        QTWebKitTuning.keepHiddenPageRunning(config.preferences)
        QTWebKitTuning.allowPictureInPicture(config.preferences)

        let ucc = config.userContentController
        ucc.add(proxy, contentWorld: .page, name: QTWebPlaybackBridgeScript.handlerName)
        installScripts(on: ucc, bootstrap: bootstrap)

        let view = QTWebPlaybackView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        view.customUserAgent = configuration.userAgent
        view.navigationDelegate = navigationWatcher
        // Transparent page: in a video slot the slot's own backdrop shows around (and before) the first frame.
        if view.responds(to: NSSelectorFromString("setDrawsBackground:")) { view.setValue(false, forKey: "drawsBackground") }
        view.underPageBackgroundColor = .clear
        #if DEBUG
        view.isInspectable = true
        #endif

        // Offscreen host: never ordered in, never key, invisible to capture and Mission Control.
        let window = QTWebPlaybackHostWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1280, height: 800),
                                             styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.sharingType = .none
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.alphaValue = 0
        // The page sits in a plain root view, so moving it to a video slot and back is one reparent (it is never
        // without a window on the way, which would interrupt its media).
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        view.autoresizingMask = [.width, .height]
        root.addSubview(view)
        window.contentView = root
        return (view, window)
    }

    func installScripts(on ucc: WKUserContentController, bootstrap: String) {
        ucc.removeAllUserScripts()
        var sources = [bootstrap, QTWebPlaybackBridgeScript.mediaSessionShield]
        if configuration.isSilent { sources.append(QTWebPlaybackBridgeScript.silence) }
        sources.append(QTWebPlaybackBridgeScript.videoSurface)
        sources.append(QTWebPlaybackBridgeScript.keepAlive)
        sources.append(QTWebAudioScript.parsers)
        sources.append(QTWebAudioScript.tap)
        sources.append(QTWebPlaybackBridgeScript.bridge)
        for source in sources {
            ucc.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
    }

    private func navigate(videoID: String, start: TimeInterval, autoplay: Bool, generation gen: Int) {
        isPageReady = false
        needsFreshPage = false
        playIntentBeforeReady = nil
        audio.itemDidChange()
        let bootstrap = QTWebPlaybackBridgeScript.bootstrap(generation: gen, videoID: videoID, hold: !autoplay,
                                                            volume: state.volume, muted: state.isMuted,
                                                            silent: configuration.isSilent,
                                                            lowQuality: configuration.prefersLowVideoQuality,
                                                            present: video.isPresenting, quality: video.quality)
        let view: WKWebView
        if let existing = webView {
            installScripts(on: existing.configuration.userContentController, bootstrap: bootstrap)
            view = existing
        } else {
            view = makeWebView(bootstrap: bootstrap)
        }
        var components = URLComponents(url: configuration.origin.appending(path: "watch"), resolvingAgainstBaseURL: false)!
        var query = [URLQueryItem(name: "v", value: videoID)]
        if start >= 1 { query.append(URLQueryItem(name: "t", value: "\(Int(start))s")) }
        components.queryItems = query
        pageIO.load(view, URLRequest(url: components.url!))
    }

    /// Calls `window.__qtBridge.<name>(…args)` in the page world. Returns the command's boolean result.
    @discardableResult
    func command(_ name: String, _ args: Any...) async -> Bool {
        guard let webView, isPageReady else { return false }
        if name != "freeze" { stopThrottlingHiddenPage() }
        return (await pageIO.call(webView, name, args) as? Bool) ?? false
    }

    // MARK: Spectrum (web-audio)

    /// Spectrum for the visualizer, decoded from the stream the page plays; nil when the stream can't be read
    /// (the visualizer then animates on its own). Each call pulls the page's next frame; nothing runs between calls.
    public func spectrum(bandCount: Int) -> [Float]? {
        Self.isSpectrumTapEnabled ? audio.spectrum(bandCount: bandCount) : nil
    }

    /// `-qt.webaudio.tap NO` turns the tap off (the visualizer then animates on its own): A/B measurements.
    nonisolated static let isSpectrumTapEnabled = UserDefaults.standard.object(forKey: "qt.webaudio.tap") == nil
        || UserDefaults.standard.bool(forKey: "qt.webaudio.tap")

    /// `window.__qtAudio.frames(…)`. Never thaws a frozen page (the visualizer only asks while playing).
    private func audioFrames(bands: Int, ahead: Int, step: TimeInterval) async -> Any? {
        guard let webView, isPageReady else { return nil }
        return try? await webView.callAsyncJavaScript(
            "return window.__qtAudio ? window.__qtAudio.frames(bands, ahead, step) : 'nodata'",
            arguments: ["bands": bands, "ahead": ahead, "step": step], in: nil, contentWorld: .page)
    }

    private func audioRelease() async {
        guard let webView, isPageReady else { return }
        _ = try? await webView.callAsyncJavaScript("return window.__qtAudio ? window.__qtAudio.release() : false",
                                                    arguments: [:], in: nil, contentWorld: .page)
    }

    /// The page tap's own view (state, segments kept, decode stats) — lab and debug hooks.
    public func debugAudioInfo() async -> [String: Any]? {
        guard let webView, isPageReady else { return nil }
        return try? await webView.callAsyncJavaScript("return window.__qtAudio ? window.__qtAudio.info() : null",
                                                       arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    }

    // MARK: Bridge messages

    func receive(_ body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return }
        switch type {
        case "ready":
            isPageReady = true
            video.pageDidBecomeReady()
            readPageAccount()
            if let intent = playIntentBeforeReady {
                playIntentBeforeReady = nil
                Task { await command(intent ? "play" : "pause") }
            }
        case "state":
            guard let sample = QTWebPlaybackSample(dict), sample.generation == generation else { return }
            apply(sample)
        case "ended":
            guard (dict["gen"] as? Int) == generation, state.item != nil, state.ad == nil else { return }
            finishItem()
        case "error":
            guard (dict["gen"] as? Int) == generation, state.item != nil else { return }
            let error = QTWebPlaybackErrorMapper.error(code: dict["code"] as? Int ?? 0, status: dict["status"] as? String ?? "",
                                                       reason: dict["reason"] as? String ?? "", ageGate: dict["age"] as? Bool ?? false)
            state.status = .failed(error)
            state.ad = nil
            state.isBuffering = false
            stopWatchdog()
            // The page that failed is the one playing: a switch in flight can't hand over from it.
            abandonStandbyForOldPage()
            publish()
            pendingLoads.removeValue(forKey: generation)?.resume(throwing: error)
        default:
            break
        }
    }

    /// The item is over: `.ended` at its end; the queue decides what's next.
    private func finishItem() {
        let end = state.duration > 0 ? state.duration : state.timeline.currentTime
        state.timeline = QTPlaybackTimeline(time: end, rate: 0, duration: state.timeline.duration)
        state.status = .ended
        state.isBuffering = false
        stopWatchdog()
        // A Song⇄Video switch still preparing is dropped: the track is over, the queue moves on.
        abandonStandbyForOldPage()
        publish()
    }

    private func apply(_ s: QTWebPlaybackSample) {
        video.update(isPictureInPicture: s.isPictureInPicture)
        if let deadline = resumeAfterMoveDeadline, s.paused, s.ad == nil, s.matchesLoad {
            resumeAfterMoveDeadline = nil
            if ProcessInfo.processInfo.systemUptime < deadline {
                QTWebVideoOutput.log.info("resuming after the page moved between windows")
                Task { await command("play") }
            }
        }
        // Until the requested item shows up the page may still report the previous one (or, after an end,
        // YouTube's own autoplay pick); the bridge flags samples that belong to this load.
        guard s.matchesLoad else { return }
        // A failed item stays failed: the page keeps reporting its (unplayable) player until the next load.
        if case .failed = state.status { return }
        lastSample = s
        if s.ad == nil, !s.videoID.isEmpty { playingVideoID = s.videoID }
        if s.ad == nil { lastContentTime = s.time }
        let now = ProcessInfo.processInfo.systemUptime
        let duration = s.duration > 0 ? s.duration : state.duration
        let before = state

        if let ad = s.ad {
            state.ad = QTAdState(duration: ad.duration, remaining: ad.remaining, skippableIn: ad.skippableIn)
            // The ad's media hasn't reported its length yet: show it as loading rather than "Ad · 0:00".
            // Its media over but the page not handed back yet (between ads of a pod, content loading): no
            // "Ad · 0:00" over a full bar, the ad state shows it's loading.
            state.isBuffering = ad.duration <= 0 || ad.remaining <= 0.05
            state.status = s.paused ? .paused : .playing
            state.timeline = QTPlaybackTimeline(time: s.time, rate: 0, anchorUptime: now, duration: duration > 0 ? duration : .infinity)
        } else {
            state.ad = nil
            if state.status != .ended || s.time < duration - 1 {
                state.status = s.paused ? .paused : .playing
            }
            state.isBuffering = s.isBuffering
            let rate: Double = (state.status == .playing && !s.isBuffering) ? 1 : 0
            // A cued video reports 0 until it plays; show the position it will start from (restored queue).
            let time = s.playerState == 5 ? (state.item?.startTime ?? s.time) : s.time
            state.timeline = QTPlaybackTimeline(time: time, rate: rate, anchorUptime: now, duration: duration > 0 ? duration : .infinity)
        }
        state.duration = duration
        // A content frame of the requested rendition (not an ad, not YouTube swapping a video for its song).
        video.update(hasFrame: standby == nil && s.ad == nil && s.videoWidth > 0 && s.readyState >= 2 && s.videoID == requestedVideoID,
                     size: CGSize(width: s.videoWidth, height: s.videoHeight), pictureBars: s.pictureBars)
        if let pending = pendingSwitch, pending.generation == generation, s.ad == nil, !s.paused, s.playerState == 1 {
            pendingSwitch = nil
            let report = QTModeSwitchReport(videoID: s.videoID, from: pending.from, to: pending.to, requested: pending.requested,
                                            landed: s.time, latency: now - pending.uptime)
            lastModeSwitch = report
            QTWebVideoOutput.log.info("Song⇄Video \(report.from.rawValue, privacy: .public)→\(report.to.rawValue, privacy: .public) \(report.videoID, privacy: .public): requested \(report.requested, format: .fixed(precision: 2)) s, landed \(report.landed, format: .fixed(precision: 2)) s, offset \(report.offset, format: .fixed(precision: 2)) s, latency \(report.latency, format: .fixed(precision: 2)) s")
            onModeSwitch?(report)
        }
        if Self.isMeaningfulChange(from: before, to: state, at: now) {
            publish()
        } else {
            state.timeline = before.timeline  // keep the anchor views already interpolate from
        }

        if s.ad != nil || duration > 0 || s.playerState == 5 /* cued */ {
            pendingLoads.removeValue(forKey: generation)?.resume()
        }
        trackProgress(s, at: now)
        if !s.paused { cancelFreeze() } else if s.ad == nil, pendingLoads.isEmpty, mayFreeze { scheduleFreeze() }
    }

    /// Only a pause the app asked for (or the end of the item) freezes the page; one the page made by itself keeps its
    /// timers, so the queue can resume it and the bridge can answer YouTube's prompt.
    private var mayFreeze: Bool { !intendsPlayback || state.status == .ended }

    /// Samples arrive every ~1.2 s while playing; most only confirm the interpolated timeline. Publishing those
    /// would re-render every view that reads the state, so only real changes (and drift ≥ 0.25 s) go out.
    static func isMeaningfulChange(from a: QTPlaybackState, to b: QTPlaybackState, at uptime: TimeInterval) -> Bool {
        if a.status != b.status || a.isBuffering != b.isBuffering || a.ad != b.ad || a.duration != b.duration
            || a.item != b.item || a.timeline.rate != b.timeline.rate { return true }
        return abs(a.timeline.time(atUptime: uptime) - b.timeline.time(atUptime: uptime)) >= 0.25
    }

    // MARK: Freezing a paused page

    private func scheduleFreeze() {
        guard let delay = configuration.freezeAfterPause, freezeTask == nil, !isPageFrozen else { return }
        let gen = generation
        freezeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.freezeTask = nil
            guard self.state.status == .paused || self.state.status == .ended, self.state.ad == nil,
                  self.pendingLoads.isEmpty, self.mayFreeze else { return }
            self.isPageFrozen = await self.command("freeze")
            if self.isPageFrozen, let prefs = self.webView?.configuration.preferences {
                QTWebKitTuning.setHiddenPageThrottling(true, on: prefs)
                self.isThrottlingHiddenPage = true
            }
        }
    }

    /// Re-arms normal scheduling before the page has work to do again.
    private func stopThrottlingHiddenPage() {
        guard isThrottlingHiddenPage, let prefs = webView?.configuration.preferences else { return }
        isThrottlingHiddenPage = false
        QTWebKitTuning.setHiddenPageThrottling(false, on: prefs)
    }

    /// Another engine took over (the native engine plays the song): stop, and freeze the page now rather than after
    /// the paused delay, so the idle page costs nothing until the next load (which thaws it).
    public func standDown() {
        stop()
        guard webView != nil, isPageReady, !isPageFrozen else { return }
        let gen = generation
        Task { @MainActor [weak self] in
            guard let self, gen == self.generation, self.state.item == nil, self.pendingLoads.isEmpty else { return }
            self.isPageFrozen = await self.command("freeze")
            if self.isPageFrozen, let prefs = self.webView?.configuration.preferences {
                QTWebKitTuning.setHiddenPageThrottling(true, on: prefs)
                self.isThrottlingHiddenPage = true
            }
        }
    }

    /// Commands thaw the page themselves; this only drops a pending freeze and the flag.
    func cancelFreeze() {
        freezeTask?.cancel()
        freezeTask = nil
        isPageFrozen = false
        stopThrottlingHiddenPage()
    }

    // MARK: Network

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = Self.pathHandler { [weak self] available in self?.networkChanged(available: available) }
        monitor.start(queue: DispatchQueue(label: "com.roderickqiu.qtube.playback.network", qos: .utility))
        pathMonitor = monitor
    }

    /// Runs on the monitor's queue, so it's built outside the main actor and hops back explicitly.
    nonisolated private static func pathHandler(_ onChange: @escaping @MainActor @Sendable (Bool) -> Void) -> @Sendable (NWPath) -> Void {
        { path in
            let available = path.status == .satisfied
            Task { @MainActor in onChange(available) }
        }
    }

    /// Back online: an item that stalled or timed out while offline reloads at its position; the watchdog
    /// restarts its clock either way.
    public func networkChanged(available: Bool) {
        guard available != isNetworkAvailable else { return }
        isNetworkAvailable = available
        onNetworkChange?(available)
        lastProgress = (state.timeline.currentTime, ProcessInfo.processInfo.systemUptime)
        guard available, let item = state.item, pendingLoads.isEmpty, state.ad == nil else { return }
        let networkFailure: Bool
        if case .failed(.network) = state.status { networkFailure = true } else { networkFailure = false }
        guard networkFailure || (state.status == .playing && state.isBuffering) else { return }
        var resume = item
        resume.startTime = state.timeline.currentTime
        Task { try? await self.load(resume, autoplay: true) }
    }

    private func failPendingLoads(except gen: Int) {
        for (g, c) in pendingLoads where g != gen {
            pendingLoads[g] = nil
            c.resume(throwing: CancellationError())
        }
    }

    // MARK: Stall watchdog

    private func trackProgress(_ s: QTWebPlaybackSample, at now: TimeInterval) {
        if s.ad != nil || s.paused || abs(s.time - lastProgress.time) > 0.05 {
            lastProgress = (s.time, now)
        }
        // An ad progresses when its countdown moves; one that sits still (its media over, the page never handing
        // back, or the page's samples no longer matching this load) is a stall like any other.
        if let ad = s.ad {
            if s.paused || adProgress.map({ abs($0.remaining - ad.remaining) > 0.05 }) ?? true {
                adProgress = (ad.remaining, now)
            }
        } else {
            adProgress = nil
        }
        if state.status == .playing, watchdog == nil {
            let timeout = configuration.stallTimeout
            watchdog = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard let self, !Task.isCancelled else { return }
                    self.checkStall(timeout: timeout)
                }
            }
        } else if state.status != .playing {
            stopWatchdog()
        }
    }

    private func checkStall(timeout: Duration) {
        guard state.status == .playing, let item = state.item else { return stopWatchdog() }
        let now = ProcessInfo.processInfo.systemUptime
        guard isNetworkAvailable else {
            lastProgress = (state.timeline.currentTime, now)
            if let ad = state.ad { adProgress = (ad.remaining, now) }
            return
        }
        let stalledFor: TimeInterval
        let limit: TimeInterval
        if state.ad != nil {
            stalledFor = now - (adProgress?.uptime ?? lastProgress.uptime)
            limit = min(Double(timeout.components.seconds), Self.adStallTimeout)
        } else {
            stalledFor = now - lastProgress.uptime
            limit = Double(timeout.components.seconds)
        }
        guard stalledFor > limit else { return }
        stopWatchdog()
        if state.ad != nil {
            QTWebVideoOutput.log.info("ad stalled for \(stalledFor, format: .fixed(precision: 1)) s; reloading the item")
        }
        // During an ad the page's clock may be the ad's: resume the content where it was (or where it starts).
        let position = state.ad != nil ? (lastContentTime ?? item.startTime) : lastProgress.time
        switch Self.stallAction(position: position, duration: state.duration, didRetry: didRetryStall) {
        case .finish:
            // Stuck in the last seconds: a reload there would never be armed to end (and YouTube would pick its own
            // next). The track is as good as over.
            state.ad = nil
            finishItem()
        case .fail:
            state.status = .failed(.network("stalled"))
            state.ad = nil
            state.isBuffering = false
            state.timeline = QTPlaybackTimeline(time: position, rate: 0, duration: state.timeline.duration)
            publish()
        case .reload:
            didRetryStall = true
            var resume = item
            resume.startTime = position
            lastProgress = (resume.startTime, ProcessInfo.processInfo.systemUptime)
            Task { try? await self.load(resume, autoplay: true); self.didRetryStall = true }
        }
    }

    enum StallAction: Equatable { case reload, finish, fail }

    /// What a stall at `position` does: the last seconds of an item finish it; otherwise one reload there, then fail.
    static func stallAction(position: TimeInterval, duration: TimeInterval, didRetry: Bool) -> StallAction {
        if duration > 0, position >= duration - 3 { return .finish }
        return didRetry ? .fail : .reload
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    /// Called by `QTWebVideoOutput` right before it moves the page between windows.
    func pageWillMoveBetweenWindows() {
        let playing = state.status == .playing || state.status == .loading || playIntentBeforeReady == true
        guard playing else { resumeAfterMoveDeadline = nil; return }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        resumeAfterMoveDeadline = deadline
        // The pause can come without a prompt event from a hidden page: look right away instead of waiting for one.
        Task { @MainActor [weak self] in
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, self.resumeAfterMoveDeadline == deadline else { return }
                guard let sample = await self.debugSample(), (sample["paused"] as? Bool) == true, sample["ad"] is NSNull || sample["ad"] == nil
                else { continue }
                self.resumeAfterMoveDeadline = nil
                QTWebVideoOutput.log.info("resuming after the page moved between windows")
                await self.command("play")
                return
            }
        }
    }

    // MARK: Diagnostics (lab, tests)

    /// WebKit's own view of whether *it* registered a Now Playing session for this page (SPI, debug aid).
    /// With media in the WebContent process this may report `true` while nothing reaches the system;
    /// the lab checks the system's active player path instead.
    public func webKitNowPlayingSessionInfo() async -> (active: Bool, registered: Bool)? {
        guard let webView else { return nil }
        return await QTWebKitTuning.activeNowPlayingSessionInfo(of: webView)
    }

    /// pid of the WebContent process playing the media (lab CPU measurements).
    public var webContentProcessIdentifier: pid_t? {
        guard let webView, webView.responds(to: NSSelectorFromString("_webProcessIdentifier")) else { return nil }
        return (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value
    }

    /// Evaluates a function body in the page world (lab diagnostics only).
    public func debugEvaluate(_ body: String) async -> Any? {
        guard let webView else { return nil }
        return try? await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
    }

    /// The page's media element (volume, muted, decoded size, quality) — proves silence and low decode in tests.
    public func debugMediaInfo() async -> [String: Any]? {
        guard let webView, isPageReady else { return nil }
        return try? await webView.callAsyncJavaScript("return window.__qtBridge ? window.__qtBridge.media() : null",
                                                       arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    }

    /// Whether the player page is signed in, and Premium, as its own `ytcfg` says (acceptance runs). Never cookies.
    public func debugPageAccount() async -> [String: Any]? {
        guard let webView, isPageReady else { return nil }
        return await pageIO.evaluate(webView, Self.pageAccountScript) as? [String: Any]
    }

    static let pageAccountScript = """
        const c = window.ytcfg && window.ytcfg.get ? window.ytcfg : null;
        if (!c) return null;
        return {loggedIn: c.get('LOGGED_IN') ?? null, premium: c.get('IS_SUBSCRIBER') ?? null};
        """

    /// Reads who the page plays as once it is ready (a page swap keeps the same store, so the same account).
    private func readPageAccount() {
        guard let view = webView else { return }
        Task { @MainActor [weak self] in
            guard let self, let info = await self.pageIO.evaluate(view, Self.pageAccountScript) as? [String: Any],
                  self.webView === view else { return }
            self.pageAccount = QTWebPageAccount(ytcfg: info)
        }
    }

    /// Raw page sample (lab).
    public func debugSample() async -> [String: Any]? {
        guard let webView, isPageReady else { return nil }
        return try? await webView.callAsyncJavaScript("return window.__qtBridge ? window.__qtBridge.sample() : null",
                                                       arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    }
}

// MARK: - Support types

/// How the engine talks to a player page. The app uses WebKit; tests put a fake page behind the same calls, so the
/// engine's own logic (loads, Song⇄Video switches, cancellation) runs unchanged.
struct QTWebPageIO {
    /// Navigates a page.
    var load: @MainActor (WKWebView, URLRequest) -> Void
    /// `window.__qtBridge.<name>(…args)` in the page world; nil when the page has no bridge (or the call failed).
    var call: @MainActor (WKWebView, String, [Any]) async -> Any?
    /// A raw function body in the page world (diagnostics, the page's account).
    var evaluate: @MainActor (WKWebView, String) async -> Any?

    static var webKit: QTWebPageIO {
        QTWebPageIO(
            load: { view, request in view.load(request) },
            call: { view, name, args in
                var arguments: [String: Any] = [:]
                var list: [String] = []
                for (i, a) in args.enumerated() {
                    arguments["a\(i)"] = a
                    list.append("a\(i)")
                }
                let js = "return window.__qtBridge ? window.__qtBridge.\(name)(\(list.joined(separator: ", "))) : null"
                return try? await view.callAsyncJavaScript(js, arguments: arguments, in: nil, contentWorld: .page)
            },
            evaluate: { view, body in
                try? await view.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
            })
    }
}

/// Who a player page plays as, from its own `ytcfg` (`LOGGED_IN`, `IS_SUBSCRIBER`).
enum QTWebPageAccount: Equatable {
    case signedOut, free, premium

    init?(ytcfg info: [String: Any]) {
        func flag(_ key: String) -> Bool? {
            if let b = info[key] as? Bool { return b }
            if let n = info[key] as? NSNumber { return n.boolValue }
            if let s = info[key] as? String { return s == "true" || s == "1" }
            return nil
        }
        guard let loggedIn = flag("loggedIn") else { return nil }
        if !loggedIn { self = .signedOut; return }
        self = flag("premium") == true ? .premium : .free
    }
}

/// One `state` message from the bridge.
struct QTWebPlaybackSample: Equatable {
    struct Ad: Equatable {
        var duration: TimeInterval
        var remaining: TimeInterval
        var skippableIn: TimeInterval?
    }

    var generation: Int
    /// The id the page is playing (may differ from the requested one: YouTube Music can swap a video for its song).
    var videoID: String
    /// The sample belongs to the current load.
    var matchesLoad: Bool
    var time: TimeInterval
    var duration: TimeInterval
    var paused: Bool
    var playerState: Int
    var isBuffering: Bool
    var ad: Ad?
    /// Decoded size and readiness of the page's video element (0 until a frame exists).
    var videoWidth: Double
    var videoHeight: Double
    var readyState: Int
    var isPictureInPicture: Bool
    /// Bars still visible around the cropped picture while presented (fractions of the slot).
    var pictureBars: QTVideoPictureBars

    init?(_ dict: [String: Any]) {
        guard let gen = dict["gen"] as? Int else { return nil }
        generation = gen
        videoID = dict["vid"] as? String ?? ""
        matchesLoad = dict["match"] as? Bool ?? false
        time = (dict["t"] as? Double) ?? 0
        duration = (dict["d"] as? Double) ?? 0
        paused = dict["paused"] as? Bool ?? true
        playerState = dict["ps"] as? Int ?? -1
        isBuffering = dict["buffering"] as? Bool ?? false
        videoWidth = (dict["vw"] as? Double) ?? 0
        videoHeight = (dict["vh"] as? Double) ?? 0
        readyState = (dict["rs"] as? Int) ?? 0
        isPictureInPicture = dict["pip"] as? Bool ?? false
        let pic = (dict["pic"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
        pictureBars = pic.count == 4 ? QTVideoPictureBars(left: pic[0], top: pic[1], right: pic[2], bottom: pic[3]) : .zero
        if let ad = dict["ad"] as? [String: Any] {
            self.ad = Ad(duration: (ad["duration"] as? Double) ?? 0, remaining: (ad["remaining"] as? Double) ?? 0,
                         skippableIn: ad["skippableIn"] as? Double)
        }
    }
}

/// Breaks the WKUserContentController → handler retain cycle. A standby page's messages go to its switch
/// (`onStandbyMessage`) until it becomes the engine's page; a retired page's are dropped.
final class QTWebPlaybackMessageProxy: NSObject, WKScriptMessageHandler {
    enum Role { case main, standby, retired }

    weak var engine: QTWebPlaybackEngine?
    var role: Role
    var onStandbyMessage: (@MainActor (Any) -> Void)?

    init(engine: QTWebPlaybackEngine, role: Role = .main) {
        self.engine = engine
        self.role = role
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        QTMainActorHop.onMainThread {
            switch role {
            case .main: engine?.receive(message.body)
            case .standby: onStandbyMessage?(message.body)
            case .retired: break
            }
        }
    }
}

/// The pages' navigation delegate, for one event: a WebContent process that died. The main page reloads; a
/// Song⇄Video standby page is dropped (its switch falls back to the in-page reload).
@MainActor
final class QTWebPlaybackNavigationWatcher: NSObject, WKNavigationDelegate {
    weak var engine: QTWebPlaybackEngine?

    init(engine: QTWebPlaybackEngine) { self.engine = engine }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let engine else { return }
        if webView === engine.webView {
            engine.webContentProcessDidTerminate()
        } else if let standby = engine.standby, standby.webView === webView {
            standby.failed = true
        }
    }
}

/// Never key, never main: the player's host window can't take focus.
private final class QTWebPlaybackHostWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
