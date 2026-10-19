import AppKit
import Observation
import QTCore
import QTIntegrations
import QTPlayback
@preconcurrency import UserNotifications

// Owner: builder "desktop". Feeds playback into the opt-in integrations (spec §8 notifications, §10 Last.fm and
// Discord). Each one is off by default and does nothing — no network, no socket, no Keychain read, no permission
// prompt — until the user turns it on in Settings. Ads are never scrobbled, announced or notified, and neither is
// anything that isn't the user really listening to their library: the demo library, the simulated engine, silent
// (scripted / test) playback — `reportsPlays`.

/// What the integrations see of playback at one moment (built from the app model by `sync()`; tests build their own).
struct QTIntegrationsSnapshot: Equatable {
    /// The current item — also while an ad plays before or inside it.
    var track: QTTrack?
    /// `QTQueueController.playSerial`: a new value is a new listen of the same video id (Repeat One, a replay).
    var playSerial = 0
    var isPlaying = false
    var isAd = false
    /// Position in the track (Discord timestamps).
    var elapsed: TimeInterval = 0
    /// Real, audible playback of the user's library (see `QTIntegrationsCoordinator.reportsPlays`).
    var reportsPlays = true
    var isAppActive = false
}

@MainActor
public final class QTIntegrationsCoordinator {
    public static let shared = QTIntegrationsCoordinator()

    public let store: QTIntegrationsStore
    let scrobbler: QTScrobbler
    let discord: QTDiscordPresence
    let notifier = QTTrackChangeNotifier()
    /// Last.fm client for an API account (tests inject a recording transport).
    var makeLastFMClient: (QTLastFMCredentials) -> QTLastFMClient = { QTLastFMClient(credentials: $0) }
    /// Posts "now playing" notifications (tests record instead).
    var postNotification: ((QTTrack) -> Void)?

    /// Each integration's calls run one after another, in the order playback produced them (a separate unstructured
    /// Task per call would let Swift reorder e.g. `disconnect()` before a pending `update()`). Separate queues, so a
    /// Discord client that hangs never holds up scrobbling.
    let lastFMQueue = QTSerialTaskQueue()
    let discordQueue = QTSerialTaskQueue()

    private weak var model: QTAppModel?
    private var isStarted = false
    /// Notifications: the song last seen (nil during ads). Seeded with the launch track, which isn't a "song change".
    private var notifiedTrackID: String?
    /// Last.fm: the listen the scrobbler is tracking ("<video id>#<play serial>"), and whether it is playing.
    private var scrobbleKey: String?
    private var scrobblePlaying = false
    private var lastDiscordSignature: String?
    private var scrobblerConfig: String?
    private var ticker: Task<Void, Never>?

    init(store: QTIntegrationsStore = QTIntegrationsStore(), scrobbler: QTScrobbler = QTScrobbler(),
         discord: QTDiscordPresence = QTDiscordPresence()) {
        self.store = store
        self.scrobbler = scrobbler
        self.discord = discord
    }

    public func start(model: QTAppModel) {
        guard !isStarted else { return }
        isStarted = true
        self.model = model
        notifiedTrackID = model.player.nowPlaying?.videoId
        observe()
    }

    /// Starts without an app model (tests): `apply(_:)` is then driven by hand.
    func startForTesting(launchTrack: QTTrack?) {
        isStarted = true
        notifiedTrackID = launchTrack?.videoId
    }

    private func observe() {
        withObservationTracking {
            sync()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func sync() {
        guard let model else { return }
        let player = model.player
        let snapshot = QTIntegrationsSnapshot(
            track: player.nowPlaying, playSerial: player.playback.playSerial, isPlaying: player.isPlaying,
            isAd: player.ad != nil, elapsed: player.timeline.currentTime, // seeks re-anchor the Discord timestamps
            reportsPlays: Self.reportsPlays(setup: QTPlaybackServices.shared.setup, engine: player.engine,
                                            catalogMode: model.liveCatalog?.mode),
            isAppActive: NSApp?.isActive ?? false)
        apply(snapshot)
    }

    /// Only real, audible playback of the user's library reaches Last.fm, Discord and notifications: never the demo
    /// library (its 12 prototype songs), the simulated engine (no audio at all) or silent scripted/test playback.
    static func reportsPlays(setup: QTPlaybackSetup?, engine: any QTPlaybackEngine, catalogMode: QTCatalogMode?) -> Bool {
        guard let setup, setup.source == .live, !setup.isSilent else { return false }
        if engine is QTSimulatedPlaybackEngine { return false }
        return catalogMode != .mock
    }

    func apply(_ s: QTIntegrationsSnapshot) {
        let settings = store.settings
        let song = s.reportsPlays ? s.track : nil
        let playing = song != nil && s.isPlaying && !s.isAd

        configureScrobbler(settings.lastFM)
        updateScrobbling(song: song, serial: s.playSerial, playing: playing, enabled: settings.lastFM.isEnabled)
        updateNotifications(shown: s.isAd ? nil : song, playing: playing, enabled: settings.notifiesTrackChanges,
                            appActive: s.isAppActive)
        updateDiscord(settings.discord, track: s.isAd ? nil : song, playing: playing, elapsed: s.elapsed)
    }

    // MARK: Last.fm

    /// One listen = one (video id, play serial): Repeat One and replays of the same song start a new listen; the
    /// launch track (cued, paused) starts one when it first plays; turning Last.fm on mid-song tracks it from then.
    private func updateScrobbling(song: QTTrack?, serial: Int, playing: Bool, enabled: Bool) {
        let key = enabled ? song.map { "\($0.videoId)#\(serial)" } : nil
        let scrobbler = scrobbler
        if key != scrobbleKey {
            if let key, let song, playing {
                scrobbleKey = key
                scrobblePlaying = true
                let item = Self.scrobble(song)
                lastFMQueue.enqueue { await scrobbler.trackChanged(to: item, playing: true) }
            } else if scrobbleKey != nil {
                scrobbleKey = nil
                scrobblePlaying = false
                // The listen ended (another song cued, stopped, or the demo library took over): what was really
                // listened to scrobbles if it qualified. Last.fm turned off: forget it without sending.
                if enabled {
                    lastFMQueue.enqueue { await scrobbler.trackChanged(to: nil, playing: false) }
                } else {
                    lastFMQueue.enqueue { await scrobbler.reset() }
                }
            }
        } else if key != nil, playing != scrobblePlaying {
            scrobblePlaying = playing
            lastFMQueue.enqueue { await scrobbler.playbackChanged(playing: playing) }
        }
        updateTicker(running: playing && key != nil)
    }

    private func configureScrobbler(_ prefs: QTLastFMPrefs) {
        let signature = "\(prefs.isEnabled)|\(prefs.isConnected)|\(prefs.apiKey)|\(prefs.hasSecret)|\(prefs.sendsNowPlaying)"
        guard signature != scrobblerConfig else { return }
        scrobblerConfig = signature
        let scrobbler = scrobbler
        guard prefs.isEnabled, prefs.isConnected else {
            lastFMQueue.enqueue { await scrobbler.configure(client: nil, sessionKey: nil) }
            return
        }
        let store = store, makeClient = makeLastFMClient
        lastFMQueue.enqueue {
            // The Keychain read happens off the main thread (`loadLastFMSession`).
            guard let session = await store.loadLastFMSession() else {
                await scrobbler.configure(client: nil, sessionKey: nil)
                return
            }
            await scrobbler.configure(client: makeClient(session.credentials), sessionKey: session.sessionKey,
                                      sendsNowPlaying: prefs.sendsNowPlaying,
                                      onInvalidSession: { Task { @MainActor in QTIntegrationsCoordinator.shared.lastFMSessionWasRevoked() } },
                                      onPaused: { Task { @MainActor in QTIntegrationsCoordinator.shared.lastFMSendingPaused() } })
            await scrobbler.flush()
        }
    }

    private func lastFMSessionWasRevoked() {
        store.disconnectLastFM()
        model?.showToast(QTLoc.tr("Last.fm disconnected. Connect again in Settings.", table: .desktop))
    }

    private func lastFMSendingPaused() {
        model?.showToast(QTLoc.tr("Last.fm isn’t accepting scrobbles. Check the API key in Settings.", table: .desktop))
    }

    /// Long tracks scrobble at the threshold, not only when they end.
    private func updateTicker(running: Bool) {
        if running, ticker == nil {
            ticker = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    guard let self, !Task.isCancelled else { return }
                    let scrobbler = self.scrobbler
                    self.lastFMQueue.enqueue { await scrobbler.tick() }
                }
            }
        } else if !running {
            ticker?.cancel()
            ticker = nil
        }
    }

    static func scrobble(_ t: QTTrack) -> QTScrobble {
        QTScrobble(artist: t.artists.first?.name ?? t.artistLine, track: t.title, album: t.album?.title,
                   duration: t.duration > 0 ? Int(t.duration.rounded()) : nil, timestamp: Int(Date().timeIntervalSince1970))
    }

    // MARK: Notifications

    private func updateNotifications(shown: QTTrack?, playing: Bool, enabled: Bool, appActive: Bool) {
        let id = shown?.videoId
        guard id != notifiedTrackID else { return }
        let previous = notifiedTrackID
        notifiedTrackID = id
        // Not for the launch track (cued, paused), never while QTube Music is frontmost.
        guard let shown, previous != nil || playing, enabled, !appActive else { return }
        if let postNotification { postNotification(shown) } else { notifier.post(shown) }
    }

    // MARK: Discord

    private func updateDiscord(_ prefs: QTDiscordPrefs, track: QTTrack?, playing: Bool, elapsed: TimeInterval) {
        let active = prefs.isEnabled && prefs.hasValidClientID
        // Paused or stopped clears the presence (like other players), so a stale song never lingers.
        let shown = active && playing ? track : nil
        let start = Int(Date().timeIntervalSince1970 - elapsed)
        let signature = active ? "\(prefs.clientID)|\(shown?.videoId ?? "-")|\(start / 2)|\(prefs.showsArtwork)" : nil
        guard signature != lastDiscordSignature else { return }
        let wasActive = lastDiscordSignature != nil
        lastDiscordSignature = signature
        let discord = discord
        guard active else {
            if wasActive { discordQueue.enqueue { await discord.disconnect() } }
            return
        }
        let payload = shown.map { t in
            QTDiscordTrack(title: t.title, artist: t.artistLine, album: t.album?.title,
                           artworkURL: t.artwork.max { ($0.width ?? 0) < ($1.width ?? 0) }?.url,
                           link: URL(string: QTTrackActions.link(for: t)), duration: t.duration,
                           elapsed: elapsed, isPlaying: true)
        }
        let clientID = prefs.clientID, artwork = prefs.showsArtwork
        let button = QTLoc.tr("Open in YouTube Music", table: .desktop)
        discordQueue.enqueue {
            await discord.update(clientID: clientID, track: payload, showsArtwork: artwork, buttonTitle: button)
        }
    }

    /// Waits until every integration call queued so far has run (tests).
    func drain() async {
        await lastFMQueue.drain()
        await discordQueue.drain()
    }
}

/// Runs async operations one at a time, in the order they were enqueued, on the main actor (each one may await an
/// integration actor). Replaces "a new `Task {}` per call", whose start order Swift doesn't promise.
@MainActor
final class QTSerialTaskQueue {
    typealias Operation = @MainActor () async -> Void
    private let continuation: AsyncStream<Operation>.Continuation
    private var worker: Task<Void, Never>?

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Operation.self)
        self.continuation = continuation
        worker = Task { @MainActor in
            for await operation in stream { await operation() }
        }
    }

    func enqueue(_ operation: @escaping Operation) {
        continuation.yield(operation)
    }

    /// Returns once everything enqueued before it has run.
    func drain() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            enqueue { done.resume() }
        }
    }
}

// MARK: - Notifications

/// "Notify when the song changes" (off by default). Permission is requested only when the user turns it on.
@MainActor
final class QTTrackChangeNotifier {
    /// UNUserNotificationCenter needs a real app bundle (not `swift run`, not tests).
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    /// The switch was turned on: ask macOS. Calls back with whether notifications may be shown.
    static func requestPermission(_ done: @escaping @MainActor (Bool) -> Void) {
        guard isAvailable else { done(false); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            Task { @MainActor in done(granted) }
        }
    }

    func post(_ track: QTTrack) {
        guard Self.isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = track.title
        content.subtitle = track.artistLine
        if let album = track.album?.title, !album.isEmpty { content.body = album }
        content.threadIdentifier = "qt.nowPlaying"
        let id = "qt.nowPlaying.\(track.videoId)"
        let artwork = track.artwork.max { ($0.width ?? 0) < ($1.width ?? 0) }?.url
        Task {
            if let artwork, let attachment = await Self.attachment(for: artwork, id: track.videoId) {
                content.attachments = [attachment]
            }
            let center = UNUserNotificationCenter.current()
            // One notification at a time: the new song replaces the last one in Notification Center.
            center.removeDeliveredNotifications(withIdentifiers: [id])
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    /// The artwork (already cached for the player bar) as a small PNG in the temporary folder.
    private static func attachment(for url: URL, id: String) async -> UNNotificationAttachment? {
        guard let image = await QTImageLoader.shared.image(at: url, maxPixel: 256) else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("qt-notification-\(id).png")
        guard (try? png.write(to: file, options: .atomic)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "artwork", url: file)
    }
}
