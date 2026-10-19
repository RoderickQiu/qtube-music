import AppKit
import Foundation
import QTCore
import QTPlayback
import WebKit

// Owner: builder "playback". How the app plays: which engine, whether it owns Now Playing and the media keys,
// whether the queue persists, and the user-facing messages for failures and network loss.
//
// Launch arguments (session-only):
//   -qt.engine auto|simulated|web      auto (default): mock catalog → simulated, real data → web
//   -qt.playback.silent YES|NO         pin the web player's media volume to 0 (default YES for mock data and
//                                      scripted runs — anything with -qt.readyFile / -qt.playback.statusFile)
//   -qt.playback.anonymous YES|NO      play in a throwaway signed-out WebKit store (default NO: real data plays with
//                                      the user's session — approved; plays land in their YouTube Music history,
//                                      Premium plays without ads)
//   -qt.playback.persist YES|NO        save/restore the queue (default: real data, unscripted runs only)
//   -qt.playback.nowPlaying YES|NO     own Now Playing + remote commands (default: any real engine)
//   -qt.playback.readyWhen playing|ad|buffering|failed|toast   hold the ready file until playback gets there
//   -qt.playback.loadDelay <s>         hold each load this long (slow-network look, for loading screenshots)
//   -qt.playback.statusFile <path>     DEBUG: JSON status for scripts (see QTPlaybackDebugHooks)
//   -qt.playback.native YES|NO         session override of Settings › Premium engine › Native engine (opt-in). The
//                                      native engine itself comes in once the account is known to be Premium and
//                                      signed in (QTNativeEngineCoordinator); real data only.

/// Where the tracks being played come from.
public enum QTPlaybackDataSource: String, Sendable, Hashable {
    /// `QTMockCatalog` (made-up track ids; MV ids are real).
    case mock
    /// InnerTube.
    case live
}

/// The resolved playback configuration for this process.
public struct QTPlaybackSetup: Sendable, Equatable {
    public var source: QTPlaybackDataSource
    public var engine: QTPlaybackEngineKind
    /// Web engine media pinned to volume 0 (tests, screenshots, mock data).
    public var isSilent: Bool
    /// Web engine uses a throwaway, signed-out data store (always for mock data). Otherwise it plays in QTAuth's
    /// session jar (non-persistent, seeded from the Keychain): signed in whenever the user is.
    public var isAnonymous: Bool
    public var publishesNowPlaying: Bool
    public var persistsQueue: Bool
    /// `-qt.playback.loadDelay <s>`: a simulated slow network (loading-state screenshots).
    public var loadDelay: Double?

    public init(source: QTPlaybackDataSource, engine: QTPlaybackEngineKind, isSilent: Bool, isAnonymous: Bool,
                publishesNowPlaying: Bool, persistsQueue: Bool) {
        self.source = source
        self.engine = engine
        self.isSilent = isSilent
        self.isAnonymous = isAnonymous
        self.publishesNowPlaying = publishesNowPlaying
        self.persistsQueue = persistsQueue
    }

    public static func resolve(launch: QTLaunchOptions, source: QTPlaybackDataSource, tier: QTPlaybackAccountTier) -> QTPlaybackSetup {
        var engine: QTPlaybackEngineKind
        switch launch.string("qt.engine") {
        case "simulated": engine = .simulated
        case "web": engine = .web
        default: engine = QTPlaybackEngineSelector.kind(tier: tier, usesMockData: source == .mock)
        }
        let scripted = launch.readyFile != nil || launch.string("qt.playback.statusFile") != nil
        var setup = QTPlaybackSetup(
            source: source, engine: engine,
            isSilent: launch.bool("qt.playback.silent") ?? (source == .mock || scripted),
            // Signed-in playback (the user's session in the player page) is approved: Premium plays without ads, and
            // plays are recorded in the user's YouTube Music history. `-qt.playback.anonymous YES` opts out.
            isAnonymous: source == .mock || (launch.bool("qt.playback.anonymous") ?? false),
            publishesNowPlaying: launch.bool("qt.playback.nowPlaying") ?? (engine != .simulated),
            persistsQueue: launch.bool("qt.playback.persist") ?? (source == .live && !scripted))
        setup.loadDelay = launch.double("qt.playback.loadDelay")
        return setup
    }

    /// - Parameter sessionDataStore: QTAuth's non-persistent session jar (`QTAuthController.webDataStore`), used
    ///   unless the setup is anonymous. A persistent store is never used (WebKit saves its cookies in plain text).
    @MainActor
    public func makeEngine(tier: QTPlaybackAccountTier, sessionDataStore: WKWebsiteDataStore? = nil) -> any QTPlaybackEngine {
        switch engine {
        case .simulated:
            return QTSimulatedPlaybackEngine(account: tier == .premium ? .premium : .free)
        case .web, .native:
            var configuration = QTWebPlaybackEngine.Configuration(
                isSilent: isSilent,
                videoIDResolver: source == .mock ? Self.mockVideoID : Self.liveVideoID)
            configuration.debugLoadDelay = loadDelay.map { .milliseconds(Int($0 * 1000)) }
            let store = isAnonymous ? nil : sessionDataStore.flatMap { $0.isPersistent ? nil : $0 }
            return QTWebPlaybackEngine(configuration: configuration, dataStore: store ?? .nonPersistent())
        }
    }

    @MainActor
    public func makeNowPlaying() -> QTNowPlayingController? {
        publishesNowPlaying ? QTNowPlayingController() : nil
    }

    public func makeQueueStore() -> QTQueueStore? {
        persistsQueue ? .applicationSupport() : nil
    }

    /// Real data, plus demo-catalog tracks if the user switches to the demo library mid-session (their made-up
    /// ids aren't 11-character YouTube ids).
    @Sendable
    static func liveVideoID(for item: QTPlaybackItem) -> String {
        item.track.videoId.count == 11 ? QTWebPlaybackEngine.videoID(for: item) : mockVideoID(for: item)
    }

    /// Mock tracks carry made-up ids but real music-video counterparts: play those (Song and Video alike).
    /// Tracks without one keep their made-up id, which YouTube rejects — the unplayable path, for real.
    @Sendable
    static func mockVideoID(for item: QTPlaybackItem) -> String {
        if let c = item.track.counterpart, c.musicVideoType.isVideo { return c.videoId }
        return QTWebPlaybackEngine.videoID(for: item)
    }
}

/// Glue between playback and the rest of the app: failure toasts, offline notice, readiness for screenshots,
/// queue flush on quit, DEBUG hooks. One per process.
@MainActor
public final class QTPlaybackServices {
    public static let shared = QTPlaybackServices()

    public private(set) var setup: QTPlaybackSetup?
    private weak var model: QTAppModel?
    private var terminationObserver: NSObjectProtocol?
    private var readyHold: UUID?
    private var readyWatch: Task<Void, Never>?
    private var wasOfflineNoticeShown = false

    /// Called once from `QTAppModel.bootstrap`.
    public func install(model: QTAppModel, setup: QTPlaybackSetup) {
        self.model = model
        self.setup = setup
        let playback = model.player.playback
        playback.onFailure = { [weak self] event in self?.report(event) }
        hookEngine(playback.engine)
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            QTMainActorHop.onMainThread {
                playback.flushNow()
                playback.engine.webEngine?.shutdown()
                playback.nowPlaying?.clear()
            }
        }
        holdReadinessIfAsked(model.launch)
        // Premium + opted in + signed in → the native engine (and back when any of that stops being true).
        QTNativeEngineCoordinator.shared.install(model: model)
        #if DEBUG
        QTPlaybackDebugHooks.shared.install(model: model, setup: setup)
        #endif
    }

    private func hookEngine(_ engine: any QTPlaybackEngine) {
        if let web = engine.webEngine {
            web.onNetworkChange = { [weak self] available in self?.networkChanged(available: available) }
        }
    }

    /// The user signed in or out: a signed-in player page has to be reloaded to pick the new identity up.
    public func sessionDidChange() {
        model?.player.playback.engine.webEngine?.sessionDidChange()
    }

    /// The catalog source changed mid-session (demo library ⇄ the user's library): the matching engine (simulated for
    /// the demo, the signed-in web engine for real data), Now Playing and queue persistence, as a launch with that
    /// source would have. The other source's queue is cleared; the saved real queue is never overwritten by the demo.
    public func switchSource(to source: QTPlaybackDataSource) async {
        guard let model, let current = setup, current.source != source else { return }
        let tier: QTPlaybackAccountTier = model.launch.account == .free ? .free : .premium
        let next = QTPlaybackSetup.resolve(launch: model.launch, source: source, tier: tier)
        setup = next
        let playback = model.player.playback
        playback.setStore(nil)
        playback.clearAll()
        let old = playback.engine
        let engine = next.makeEngine(tier: tier, sessionDataStore: QTLiveCatalogStore.shared.auth.webDataStore)
        hookEngine(engine)
        await playback.replaceEngine(engine)
        (old as? QTNativePlaybackEngine)?.shutdownNative()
        old.webEngine?.shutdown()
        if let sim = engine as? QTSimulatedPlaybackEngine { sim.account = model.account == .free ? .free : .premium }
        if next.publishesNowPlaying, playback.nowPlaying == nil { playback.attachNowPlaying(QTNowPlayingController()) }
        playback.setStore(next.makeQueueStore())
    }

    /// Restores the saved queue (real sessions). Returns false when there's nothing to restore.
    public func restoreSavedQueue(into player: QTPlayerModel) async -> Bool {
        guard setup?.persistsQueue == true else { return false }
        return await player.playback.restore(autoplay: false)
    }

    // MARK: Messages

    /// The toast for a failed track. Exposed for tests.
    public static func message(for event: QTPlaybackFailureEvent) -> String {
        let title = event.track.title
        if event.error == .botCheck { return QTLoc.tr("YouTube wants to check this connection", table: .live) }
        guard event.skipped else {
            return event.consecutive >= QTQueueController.maxConsecutiveFailures
                ? QTLoc.tr("Playback stopped — the next songs couldn’t play", table: .playback)
                : QTLoc.tr("Couldn’t play “%@”", table: .playback, title)
        }
        switch event.error {
        case .ageRestricted: return QTLoc.tr("“%@” is age-restricted — skipped", table: .playback, title)
        case .unavailable(.regionLocked): return QTLoc.tr("“%@” isn’t available in your region — skipped", table: .playback, title)
        case .unavailable: return QTLoc.tr("“%@” isn’t available — skipped", table: .playback, title)
        case .network: return QTLoc.tr("“%@” didn’t load — skipped", table: .playback, title)
        case .engine, .botCheck: return QTLoc.tr("Couldn’t play “%@” — skipped", table: .playback, title)
        }
    }

    private func report(_ event: QTPlaybackFailureEvent) {
        let message = Self.message(for: event)
        lastFailureMessage = message
        // A bot check: one calm toast with Sign In (signing in usually clears it); signed in already, just the line.
        if event.error == .botCheck, QTLiveCatalogStore.shared.auth.isSignedIn == false {
            model?.showToast(message, actionTitle: QTLoc.tr("Sign In", table: .live)) { QTLiveCatalogStore.shared.signIn() }
        } else {
            model?.showToast(message)
        }
    }

    /// The most recent failure toast (DEBUG status file, tests).
    public private(set) var lastFailureMessage: String?

    private func networkChanged(available: Bool) {
        guard let model else { return }
        if !available, model.player.isPlaying || model.player.state.status == .loading, !wasOfflineNoticeShown {
            wasOfflineNoticeShown = true
            model.showToast(QTLoc.tr("You’re offline — playback continues when you reconnect", table: .playback))
        } else if available {
            wasOfflineNoticeShown = false
        }
    }

    // MARK: Readiness (screenshots of live states)

    private func holdReadinessIfAsked(_ launch: QTLaunchOptions) {
        guard let goal = launch.string("qt.playback.readyWhen"), let model else { return }
        let hold = QTReadiness.shared.hold("playback \(goal)")
        readyHold = hold
        let timeout = launch.double("qt.playback.readyTimeout") ?? 120
        readyWatch = Task { @MainActor [weak model] in
            let start = ProcessInfo.processInfo.systemUptime
            var since: TimeInterval?
            while ProcessInfo.processInfo.systemUptime - start < timeout, let model {
                let player = model.player
                let reached: Bool
                switch goal {
                case "ad": reached = player.ad != nil && player.ad.map { $0.duration > 0 } == true
                case "buffering": reached = player.isBuffering && !player.queue.history.isEmpty  // between tracks
                case "failed": reached = QTPlaybackServices.shared.lastFailureMessage != nil
                case "toast": reached = model.toast != nil
                default: reached = player.isPlaying && player.ad == nil && !player.state.isBuffering
                }
                // States must hold briefly so the frame shows them (ad countdown text, toast fade-in).
                if reached {
                    since = since ?? ProcessInfo.processInfo.systemUptime
                    if ProcessInfo.processInfo.systemUptime - (since ?? 0) >= (goal == "buffering" ? 0.6 : 1.2) { break }
                } else {
                    since = nil
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            QTReadiness.shared.release(hold)
        }
    }
}
