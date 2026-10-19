import AppKit
import Observation
import QTCore
import QTIntegrations
@preconcurrency import UserNotifications

// Owner: builder "desktop". Feeds playback into the opt-in integrations (spec §8 notifications, §10 Last.fm and
// Discord). Each one is off by default and does nothing — no network, no socket, no Keychain read, no permission
// prompt — until the user turns it on in Settings. Ads are never scrobbled, announced or notified.

@MainActor
public final class QTIntegrationsCoordinator {
    public static let shared = QTIntegrationsCoordinator()

    public let store = QTIntegrationsStore()
    let scrobbler = QTScrobbler()
    let discord = QTDiscordPresence()
    let notifier = QTTrackChangeNotifier()

    private weak var model: QTAppModel?
    private var lastTrackID: String?
    private var lastPlaying = false
    private var lastDiscordSignature: String?
    private var scrobblerConfig: String?
    private var ticker: Task<Void, Never>?

    public func start(model: QTAppModel) {
        guard self.model == nil else { return }
        self.model = model
        // The launch track (restored queue / first Liked song, paused) isn't a "song change".
        lastTrackID = model.player.nowPlaying?.videoId
        observe()
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
        let settings = store.settings
        let isAd = player.ad != nil
        let track = isAd ? nil : player.nowPlaying
        let playing = player.isPlaying && !isAd
        _ = player.timeline // seeks re-anchor the Discord timestamps

        configureScrobbler(settings.lastFM)
        let changed = track?.videoId != lastTrackID
        if changed {
            let previous = lastTrackID
            lastTrackID = track?.videoId
            lastPlaying = playing
            if settings.lastFM.isEnabled {
                let item = track.map(Self.scrobble)
                Task { await scrobbler.trackChanged(to: item, playing: playing) }
            }
            if let track, previous != nil || playing, settings.notifiesTrackChanges, !NSApp.isActive {
                notifier.post(track)
            }
        } else if playing != lastPlaying {
            lastPlaying = playing
            if settings.lastFM.isEnabled { Task { await scrobbler.playbackChanged(playing: playing) } }
        }
        updateTicker(running: playing && settings.lastFM.isEnabled)
        updateDiscord(settings.discord, track: track, playing: playing, model: model)
    }

    // MARK: Last.fm

    private func configureScrobbler(_ prefs: QTLastFMPrefs) {
        let signature = "\(prefs.isEnabled)|\(prefs.isConnected)|\(prefs.apiKey)|\(prefs.hasSecret)|\(prefs.sendsNowPlaying)"
        guard signature != scrobblerConfig else { return }
        scrobblerConfig = signature
        guard prefs.isEnabled, prefs.isConnected, let creds = store.lastFMCredentials(), let key = store.lastFMSessionKey else {
            Task { await scrobbler.configure(client: nil, sessionKey: nil) }
            return
        }
        let client = QTLastFMClient(credentials: creds)
        Task {
            await scrobbler.configure(client: client, sessionKey: key, sendsNowPlaying: prefs.sendsNowPlaying) {
                Task { @MainActor in QTIntegrationsCoordinator.shared.lastFMSessionWasRevoked() }
            }
            await scrobbler.flush()
        }
    }

    private func lastFMSessionWasRevoked() {
        store.disconnectLastFM()
        model?.showToast(QTLoc.tr("Last.fm disconnected. Connect again in Settings.", table: .desktop))
    }

    /// Long tracks scrobble at the threshold, not only when they end.
    private func updateTicker(running: Bool) {
        if running, ticker == nil {
            ticker = Task { [scrobbler] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    await scrobbler.tick()
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

    // MARK: Discord

    private func updateDiscord(_ prefs: QTDiscordPrefs, track: QTTrack?, playing: Bool, model: QTAppModel) {
        let active = prefs.isEnabled && prefs.hasValidClientID
        // Paused or stopped clears the presence (like other players), so a stale song never lingers.
        let shown = active && playing ? track : nil
        let elapsed = model.player.timeline.currentTime
        let start = Int(Date().timeIntervalSince1970 - elapsed)
        let signature = active ? "\(prefs.clientID)|\(shown?.videoId ?? "-")|\(start / 2)|\(prefs.showsArtwork)" : nil
        guard signature != lastDiscordSignature else { return }
        let wasActive = lastDiscordSignature != nil
        lastDiscordSignature = signature
        guard active else {
            if wasActive { Task { await discord.disconnect() } }
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
        Task { await discord.update(clientID: clientID, track: payload, showsArtwork: artwork, buttonTitle: button) }
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
