import AppKit
import Foundation
import Network
import QTCore
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
/// - **Power:** lowest video quality while no video is shown, and the page's timers are frozen a few seconds into
///   a pause (`Configuration.freezeAfterPause`), so a paused engine costs next to nothing.
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

        public init(origin: URL = URL(string: "https://music.youtube.com")!,
                    userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
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

    public var capabilities: QTPlaybackCapabilities { .free }
    public private(set) var state = QTPlaybackState(volume: 1)

    public let configuration: Configuration
    /// Shared with QTAuth: the persistent store holding the signed-in session (anonymous when empty).
    public let dataStore: WKWebsiteDataStore

    private var webView: WKWebView?
    private var hostWindow: NSWindow?
    private var messageProxy: QTWebPlaybackMessageProxy?
    private var continuations: [UUID: AsyncStream<QTPlaybackState>.Continuation] = [:]

    /// Increments per `load`; bridge messages from older generations are ignored.
    private var generation = 0
    private var isPageReady = false
    private var pendingLoads: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var lastSample: QTWebPlaybackSample?
    private var watchdog: Task<Void, Never>?
    private var lastProgress: (time: TimeInterval, uptime: TimeInterval) = (0, 0)
    private var didRetryStall = false
    /// play/pause requested before the page's player was ready; applied on `ready`.
    private var playIntentBeforeReady: Bool?
    private var freezeTask: Task<Void, Never>?
    /// WebKit's hidden-page throttling is back on (paused + frozen).
    private var isThrottlingHiddenPage = false
    /// The page's timers are frozen (paused for a while).
    public private(set) var isPageFrozen = false
    /// The video id the page is playing for the current item (may be the song for a requested video).
    public private(set) var playingVideoID: String?
    /// False while the system reports no usable network path.
    public private(set) var isNetworkAvailable = true
    /// Network went away (false) or came back (true). The app tells the user once.
    public var onNetworkChange: (@MainActor (Bool) -> Void)?
    private var pathMonitor: NWPathMonitor?
    /// Fresh-page retries left for the current load after an online timeout.
    private var loadRetriesLeft = 0

    /// - Parameters:
    ///   - dataStore: pass `QTWebPlaybackEngine.sharedDataStore` in the app (persistent, shared with QTAuth);
    ///     tests and the lab pass `.nonPersistent()` to stay anonymous.
    public init(configuration: Configuration = Configuration(), dataStore: WKWebsiteDataStore = QTWebPlaybackEngine.sharedDataStore) {
        self.configuration = configuration
        self.dataStore = dataStore
        startNetworkMonitor()
    }

    isolated deinit {
        pathMonitor?.cancel()
    }

    /// The app-wide persistent store (cookies from QTAuth's sign-in apply to playback).
    public static var sharedDataStore: WKWebsiteDataStore { .default() }

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

    private func publish() {
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
        generation += 1
        let gen = generation
        lastSample = nil
        didRetryStall = false
        playingVideoID = nil
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
                let sentToPage = self.isPageReady ? await self.command("load", videoID, item.startTime, autoplay, gen) : false
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
        if state.status == .ended {
            state.timeline = QTPlaybackTimeline(time: 0, rate: 0, duration: state.timeline.duration)
        }
        cancelFreeze()
        guard isPageReady else { playIntentBeforeReady = true; return }
        Task { await command("play") }
    }

    public func pause() {
        guard state.item != nil else { return }
        // Optimistic: freeze the timeline now so the UI doesn't drift while the page catches up.
        if state.status == .playing {
            state.timeline = QTPlaybackTimeline(time: state.timeline.currentTime, rate: 0, duration: state.timeline.duration)
            state.status = .paused
            publish()
        }
        guard isPageReady else { playIntentBeforeReady = false; return }
        Task { await command("pause") }
        scheduleFreeze()
    }

    public func seek(to time: TimeInterval) {
        guard state.item != nil, state.ad == nil else { return }
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
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView?.removeFromSuperview()
        hostWindow?.close()
        webView = nil
        hostWindow = nil
        messageProxy = nil
        isPageReady = false
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
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        QTWebKitTuning.runMediaInWebContentProcess(config.preferences)
        QTWebKitTuning.keepHiddenPageRunning(config.preferences)

        let proxy = QTWebPlaybackMessageProxy(engine: self)
        messageProxy = proxy
        let ucc = config.userContentController
        ucc.add(proxy, contentWorld: .page, name: QTWebPlaybackBridgeScript.handlerName)
        installScripts(on: ucc, bootstrap: bootstrap)

        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        view.customUserAgent = configuration.userAgent
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
        window.contentView = view
        hostWindow = window
        webView = view
        return view
    }

    private func installScripts(on ucc: WKUserContentController, bootstrap: String) {
        ucc.removeAllUserScripts()
        var sources = [bootstrap, QTWebPlaybackBridgeScript.mediaSessionShield]
        if configuration.isSilent { sources.append(QTWebPlaybackBridgeScript.silence) }
        sources.append(QTWebPlaybackBridgeScript.bridge)
        for source in sources {
            ucc.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
    }

    private func navigate(videoID: String, start: TimeInterval, autoplay: Bool, generation gen: Int) {
        isPageReady = false
        playIntentBeforeReady = nil
        let bootstrap = QTWebPlaybackBridgeScript.bootstrap(generation: gen, videoID: videoID, hold: !autoplay,
                                                            volume: state.volume, muted: state.isMuted,
                                                            silent: configuration.isSilent,
                                                            lowQuality: configuration.prefersLowVideoQuality)
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
        view.load(URLRequest(url: components.url!))
    }

    /// Calls `window.__qtBridge.<name>(…args)` in the page world. Returns the command's boolean result.
    @discardableResult
    private func command(_ name: String, _ args: Any...) async -> Bool {
        guard let webView, isPageReady else { return false }
        if name != "freeze" { stopThrottlingHiddenPage() }
        var arguments: [String: Any] = [:]
        var list: [String] = []
        for (i, a) in args.enumerated() {
            arguments["a\(i)"] = a
            list.append("a\(i)")
        }
        let js = "return window.__qtBridge ? window.__qtBridge.\(name)(\(list.joined(separator: ", "))) : false"
        let result = try? await webView.callAsyncJavaScript(js, arguments: arguments, in: nil, contentWorld: .page)
        return (result as? Bool) ?? false
    }

    // MARK: Bridge messages

    fileprivate func receive(_ body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return }
        switch type {
        case "ready":
            isPageReady = true
            if let intent = playIntentBeforeReady {
                playIntentBeforeReady = nil
                Task { await command(intent ? "play" : "pause") }
            }
        case "state":
            guard let sample = QTWebPlaybackSample(dict), sample.generation == generation else { return }
            apply(sample)
        case "ended":
            guard (dict["gen"] as? Int) == generation, state.item != nil, state.ad == nil else { return }
            let end = state.duration > 0 ? state.duration : state.timeline.currentTime
            state.timeline = QTPlaybackTimeline(time: end, rate: 0, duration: state.timeline.duration)
            state.status = .ended
            state.isBuffering = false
            stopWatchdog()
            publish()
        case "error":
            guard (dict["gen"] as? Int) == generation, state.item != nil else { return }
            let error = QTWebPlaybackErrorMapper.error(code: dict["code"] as? Int ?? 0, status: dict["status"] as? String ?? "",
                                                       reason: dict["reason"] as? String ?? "", ageGate: dict["age"] as? Bool ?? false)
            state.status = .failed(error)
            state.ad = nil
            state.isBuffering = false
            stopWatchdog()
            publish()
            pendingLoads.removeValue(forKey: generation)?.resume(throwing: error)
        default:
            break
        }
    }

    private func apply(_ s: QTWebPlaybackSample) {
        // Until the requested item shows up the page may still report the previous one (or, after an end,
        // YouTube's own autoplay pick); the bridge flags samples that belong to this load.
        guard s.matchesLoad else { return }
        // A failed item stays failed: the page keeps reporting its (unplayable) player until the next load.
        if case .failed = state.status { return }
        lastSample = s
        if s.ad == nil, !s.videoID.isEmpty { playingVideoID = s.videoID }
        let now = ProcessInfo.processInfo.systemUptime
        let duration = s.duration > 0 ? s.duration : state.duration
        let before = state

        if let ad = s.ad {
            state.ad = QTAdState(duration: ad.duration, remaining: ad.remaining, skippableIn: ad.skippableIn)
            // The ad's media hasn't reported its length yet: show it as loading rather than "Ad · 0:00".
            state.isBuffering = ad.duration <= 0
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
        if Self.isMeaningfulChange(from: before, to: state, at: now) {
            publish()
        } else {
            state.timeline = before.timeline  // keep the anchor views already interpolate from
        }

        if s.ad != nil || duration > 0 || s.playerState == 5 /* cued */ {
            pendingLoads.removeValue(forKey: generation)?.resume()
        }
        trackProgress(s, at: now)
        if !s.paused { cancelFreeze() } else if s.ad == nil, pendingLoads.isEmpty { scheduleFreeze() }
    }

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
                  self.pendingLoads.isEmpty else { return }
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

    /// Commands thaw the page themselves; this only drops a pending freeze and the flag.
    private func cancelFreeze() {
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
        guard state.status == .playing, state.ad == nil, let item = state.item else { return stopWatchdog() }
        guard isNetworkAvailable else {
            lastProgress = (state.timeline.currentTime, ProcessInfo.processInfo.systemUptime)
            return
        }
        let stalledFor = ProcessInfo.processInfo.systemUptime - lastProgress.uptime
        guard stalledFor > Double(timeout.components.seconds) else { return }
        stopWatchdog()
        if didRetryStall {
            state.status = .failed(.network("stalled"))
            state.isBuffering = false
            publish()
        } else {
            didRetryStall = true
            var resume = item
            resume.startTime = state.timeline.currentTime
            lastProgress = (resume.startTime, ProcessInfo.processInfo.systemUptime)
            Task { try? await self.load(resume, autoplay: true); self.didRetryStall = true }
        }
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
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

    /// Raw page sample (lab).
    public func debugSample() async -> [String: Any]? {
        guard let webView, isPageReady else { return nil }
        return try? await webView.callAsyncJavaScript("return window.__qtBridge ? window.__qtBridge.sample() : null",
                                                       arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    }
}

// MARK: - Support types

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
        if let ad = dict["ad"] as? [String: Any] {
            self.ad = Ad(duration: (ad["duration"] as? Double) ?? 0, remaining: (ad["remaining"] as? Double) ?? 0,
                         skippableIn: ad["skippableIn"] as? Double)
        }
    }
}

/// Breaks the WKUserContentController → handler retain cycle.
private final class QTWebPlaybackMessageProxy: NSObject, WKScriptMessageHandler {
    weak var engine: QTWebPlaybackEngine?

    init(engine: QTWebPlaybackEngine) {
        self.engine = engine
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            engine?.receive(message.body)
        }
    }
}

/// Never key, never main: the player's host window can't take focus.
private final class QTWebPlaybackHostWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
