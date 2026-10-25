import AppKit
import Observation
import QTAuth
import QTCore
import QTLyrics
import QTPlayback

/// A transient HUD message ("Added to Up Next"), optionally with Undo.
public struct QTToast: Identifiable {
    public let id = UUID()
    public var message: String
    /// The toast's one action ("Undo" unless `actionTitle` names another, e.g. "Sign In").
    public var undo: (@MainActor () -> Void)?
    public var actionTitle: String?

    public init(message: String, actionTitle: String? = nil, undo: (@MainActor () -> Void)? = nil) {
        self.message = message
        self.actionTitle = actionTitle
        self.undo = undo
    }
}

/// App-wide UI state. One per process (`QTAppModel.shared`), injected with `.environment(model)`.
/// Ownership: shared (scaffold). Builders may add state for their area; don't rename or repurpose existing members.
@MainActor
@Observable
public final class QTAppModel {
    public static let shared = QTAppModel.bootstrap()

    // MARK: Dependencies
    public let settings: QTSettingsStore
    public let player: QTPlayerModel
    @ObservationIgnored public let launch: QTLaunchOptions
    /// The catalog views read. Mock (demo) data, or the live library folded in by `QTLiveCatalogStore` (data-live).
    public internal(set) var catalog: QTMockCatalog

    // MARK: Navigation and panels
    public var surface: QTSurface = .window
    public var sidebarSelection: QTSidebarItem = .home
    public var selectedTrackIDs: Set<QTTrack.ID> = []
    /// Docked inspector (Now Playing / Queue), ⌥⌘N.
    public var isPanelShown = true
    public var panelTab: QTPanelTab = .nowPlaying
    /// Song⇄Video: true when the video rendition is shown.
    public var isVideoMode = false
    public var searchText = ""
    /// The New / Edit Playlist sheet over the main window (nil = none).
    public var playlistSheet: QTPlaylistSheetRequest?
    /// A playlist waiting for "Delete “x”?" to be answered.
    public var playlistToDelete: QTPlaylist?
    public private(set) var toast: QTToast?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// The most recent toast's message and when it showed (Help › Report a Problem… diagnostics).
    @ObservationIgnored public private(set) var lastToast: (message: String, date: Date)?
    /// Launch playback ran (it runs once per process — reopening the main window must not touch playback).
    @ObservationIgnored public private(set) var didApplyLaunchPlayback = false
    @ObservationIgnored private var isApplyingLaunchPlayback = false
    /// The live-library wiring this model is attached to (`QTLiveCatalogStore.attach`).
    @ObservationIgnored weak var liveCatalog: QTLiveCatalogStore?

    // MARK: Account
    /// Google sign-in for YouTube Music (Settings › Account reads its `state`). Set by whoever wires the live
    /// backend (data-live); nil in mock runs until the user presses Sign In, which creates one on demand.
    public var authController: QTAuthController?

    public var account: QTAccountKind = .premium {
        didSet { (player.engine as? QTSimulatedPlaybackEngine)?.account = account == .free ? .free : .premium }
    }

    public init(settings: QTSettingsStore, player: QTPlayerModel, catalog: QTMockCatalog, launch: QTLaunchOptions) {
        self.settings = settings
        self.player = player
        self.catalog = catalog
        self.launch = launch
    }

    /// Builds the app model from launch arguments: settings, mock catalog, simulated engine.
    public static func bootstrap(launch: QTLaunchOptions = .current) -> QTAppModel {
        // DEBUG: a dev/scripted launch whose display (`-qt.screen`, default U270CA) is missing never shows a window.
        QTScreenGuard.refuseLaunchIfScreenMissing(launch)
        let settings = QTSettingsStore()
        settings.override { s in
            if let v = launch.language { s.interfaceLanguage = v }
            if let v = launch.theme { s.theme = v }
            if let v = launch.string("qt.accent").flatMap(QTAccentSource.init(rawValue:)) { s.accentSource = v }
            if let v = launch.stageLayout { s.stageLayout = v }
            if let v = launch.stageBackground { s.stageBackground = v }
            if let v = launch.translation { s.lyricsTranslation = v }
            if let v = launch.bool("qt.playback.native") { s.playbackEffects.nativeEngine = v }
            if let v = launch.double("qt.playback.rate") { s.playbackEffects.playbackRate = QTPlaybackSpeed.normalized(v) }
            // Off in DEBUG and scripted runs unless `-qt.account.sync YES`: never a write to the owner's account.
            if let v = QTAccountWriter.launchSyncOverride(launch) { s.syncsToYouTubeMusic = v }
            if let v = QTLyricsSession.unofficialSources(argument: launch.string("qt.lyrics.unofficial")) {
                s.unofficialLyricsSources = v
            }
        }
        // The demo catalog only for a DEBUG `-qt.catalog mock` launch; YouTube Music (signed in or guest) starts empty,
        // so no demo track, lyric or palette can surface (release builds never find the catalog at all).
        let catalog: QTMockCatalog
        if !QTLiveCatalogStore.wantsLive(launch) {
            if let url = QTMockCatalog.locate(explicitPath: launch.catalogPath), var loaded = try? QTMockCatalog.load(from: url) {
                // `-qt.playlists.empty YES`: the demo library without playlists (the sidebar's empty Playlists).
                if launch.bool("qt.playlists.empty") == true { loaded.playlists = [] }
                catalog = loaded
            } else {
                FileHandle.standardError.write(Data("QTube Music: mock catalog not found; run Scripts/make-mock-catalog.py\n".utf8))
                catalog = QTLiveCatalogStore.emptyCatalog
            }
        } else {
            catalog = QTLiveCatalogStore.emptyCatalog
        }
        // `-qt.lyrics.engine mock` serves the catalog's bundled lyrics, which came from unofficial providers; say so
        // in the session's settings (never persisted) so the lyrics options don't name NetEase over an "Unofficial
        // sources" switch that is off. Live lookups keep the user's setting (unofficial sources are opt-in).
        let mockSources = Set(catalog.lyrics.values.filter(\.source.isUnofficial).map(\.source.id))
        if launch.string("qt.lyrics.engine") == QTLyricsSession.Engine.mock.rawValue,
           !mockSources.isEmpty, !settings.settings.unofficialLyricsSources.anyEnabled {
            settings.override { s in
                s.unofficialLyricsSources = QTUnofficialLyricsSources(netease: mockSources.contains(QTLyricsSource.netease.id),
                                                                      kugou: mockSources.contains(QTLyricsSource.kugou.id),
                                                                      qq: mockSources.contains(QTLyricsSource.qq.id))
            }
        }
        // Engine, Now Playing ownership and queue persistence: QTPlaybackSetup. The user's library (data-live,
        // `QTLiveCatalogStore.wantsLive`) plays through the web engine; the demo catalog through the simulated one
        // unless `-qt.engine web` (its tracks' real music videos, silently).
        let tier: QTPlaybackAccountTier = launch.account == .free ? .free : .premium
        let source: QTPlaybackDataSource = QTLiveCatalogStore.wantsLive(launch) ? .live : .mock
        let playbackSetup = QTPlaybackSetup.resolve(launch: launch, source: source, tier: tier)
        let sessionStore = QTLiveCatalogStore.shared.auth.webDataStore
        let player = QTPlayerModel(engine: playbackSetup.makeEngine(tier: tier, sessionDataStore: sessionStore),
                                   lyricsProvider: QTMockLyricsProvider(catalog: catalog),
                                   likedTrackIDs: Set(catalog.liked.tracks?.map(\.videoId) ?? []),
                                   nowPlaying: playbackSetup.makeNowPlaying(), queueStore: playbackSetup.makeQueueStore())
        player.lyricsSession = QTLyricsSession.makeDefault(settings: settings, catalog: catalog, launch: launch)
        let model = QTAppModel(settings: settings, player: player, catalog: catalog, launch: launch)
        QTPlaybackServices.shared.install(model: model, setup: playbackSetup)
        model.account = launch.account ?? .premium
        model.surface = launch.surface ?? .window
        model.sidebarSelection = launch.section ?? .home
        model.panelTab = launch.panelTab ?? .nowPlaying
        // `-qt.search <text>`: open with search results (screenshots).
        if let query = launch.string("qt.search") { model.searchText = query }
        #if DEBUG
        // `-qt.lyrics.importFile <path>`: imports that file for the first song that plays, once its lyrics have
        // loaded (the Open panel needs a person).
        if let path = launch.string("qt.lyrics.importFile") {
            Task { @MainActor in
                for _ in 0..<600 {
                    if let session = model.lyricsSession, let track = model.player.nowPlaying, session.track?.videoId == track.videoId,
                       model.player.isPlaying, !session.isLoading {
                        QTLyricsImport.importFile(URL(fileURLWithPath: (path as NSString).expandingTildeInPath), model: model)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        #endif
        model.isPanelShown = !(launch.panelHidden ?? false)
        model.isVideoMode = launch.videoMode ?? (launch.stageBackground == .video || settings.settings.preferVideos)
        if launch.extraWindows.contains(.desktopLyrics) { settings.override { $0.desktopLyrics.isShown = true } }
        QTReadiness.shared.configure(readyFile: launch.readyFile)
        // Live YouTube Music data unless `-qt.catalog mock` (or the demo was chosen); see QTLiveCatalogStore.
        QTLiveCatalogStore.shared.attach(model)
        // Song⇄Video intent, counterparts, Picture in Picture (NowPlaying/QTVideoModeService.swift).
        QTVideoModeService.shared.install(model: model)
        // Lyrics follow the rendition that plays (an MV of another length gets its own timing or unsynced lyrics).
        QTLyricsRenditionCoordinator.shared.install(player: player)
        // The app-wide accent from the playing song's artwork (Theme/QTArtworkAccentService.swift).
        QTArtworkAccentService.shared.install(model: model)
        model.applyAppearance()
        return model
    }

    /// Launch playback, **once per process**: the saved queue (real data), else the launch track (`qt.track`,
    /// default: first Liked song) at `qt.time`, paused unless `-qt.paused NO`; `-qt.ad YES` forces the ad state.
    /// Without `-qt.time` the track is cued at 0 — scripted runs (`-qt.readyFile`) default to 31.5 s, just before the
    /// hero track's first lyric. Callable any number of times (the main window's first appearance, the live store
    /// once the session is restored and once Liked arrives): it does nothing while the session is being restored,
    /// waits for Liked when there is nothing to cue yet, and never runs again after it cued something — so
    /// reopening the main window doesn't disturb what is playing.
    public func applyLaunchPlayback() async {
        guard !didApplyLaunchPlayback, !isApplyingLaunchPlayback else { return }
        // The live library is restoring the session: the player page must start signed in; the store calls again.
        guard liveCatalog?.isRestoringSession != true else { return }
        // Something is already playing (the user got there first).
        guard player.nowPlaying == nil else { didApplyLaunchPlayback = true; return }
        isApplyingLaunchPlayback = true
        defer { isApplyingLaunchPlayback = false }
        if launch.trackID == nil, await QTPlaybackServices.shared.restoreSavedQueue(into: player) {
            didApplyLaunchPlayback = true
            return
        }
        let liked = catalog.liked.tracks ?? catalog.tracks
        // The live library hasn't loaded Liked yet: QTLiveCatalogStore calls again when it arrives.
        guard !liked.isEmpty else { return }
        didApplyLaunchPlayback = true
        let index = launch.trackID.flatMap { id in liked.firstIndex { $0.videoId == id } } ?? 0
        let paused = launch.paused ?? true
        await player.play(liked, startingAt: index, source: QTQueueSource(kind: .playlist, id: catalog.liked.id, title: catalog.liked.title),
                          startTime: Self.launchStartTime(launch), autoplay: !paused, mode: isVideoMode ? .video : .song)
        QTPlayerLaunch.apply(launch, catalog: catalog, to: player)
        if launch.forceAd, let sim = player.engine as? QTSimulatedPlaybackEngine {
            sim.playAd()
            if paused { sim.pause() }
        }
    }

    /// Where the launch track is cued: `-qt.time`, else 31.5 s for scripted (screenshot) runs, else the start.
    static func launchStartTime(_ launch: QTLaunchOptions) -> TimeInterval {
        launch.time ?? (launch.readyFile != nil ? 31.5 : 0)
    }

    /// The catalog source changed mid-session (demo library ⇄ the user's library): launch playback may run again
    /// for the new source.
    func resetLaunchPlayback() {
        didApplyLaunchPlayback = false
    }

    // MARK: Settings shortcuts (persisted)

    public var stageLayout: QTStageLayout {
        get { settings.settings.stageLayout }
        set { settings.update { $0.stageLayout = newValue } }
    }

    public var stageBackground: QTStageBackground {
        get { settings.settings.stageBackground }
        set { settings.update { $0.stageBackground = newValue } }
    }

    public var theme: QTThemePreference {
        get { settings.settings.theme }
        set { settings.update { $0.theme = newValue }; applyAppearance() }
    }

    public var lyricsTranslation: QTLyricsTranslationTarget {
        get { settings.settings.lyricsTranslation }
        set { settings.update { $0.lyricsTranslation = newValue } }
    }

    public var isDesktopLyricsShown: Bool {
        get { settings.settings.desktopLyrics.isShown }
        set { settings.update { $0.desktopLyrics.isShown = newValue } }
    }

    /// The translation language currently in effect (nil = off).
    public var resolvedTranslationLanguage: String? {
        lyricsTranslation.resolvedLanguage(interface: QTLoc.language)
    }

    /// The lyrics service every surface reads (`QTLyricsSession`); same object as `player.lyricsSession`.
    public var lyricsSession: QTLyricsSession? { player.lyricsSession }

    /// Artwork palette driving the app-wide accent (`QTArtworkAccentService`, sticky between songs); nil when
    /// Settings › Accent colour is System, or the art has no usable colour — the system accent then.
    public var palette: QTArtworkPalette? {
        settings.settings.accentSource == .system ? nil : QTArtworkAccentService.shared.palette
    }

    /// Settings › Accent colour.
    public var accentSource: QTAccentSource {
        get { settings.settings.accentSource }
        set { settings.update { $0.accentSource = newValue } }
    }

    // MARK: Toasts

    /// Shows a HUD message; with an action (`undo`, titled "Undo" unless `actionTitle` says otherwise) it stays 5 s,
    /// otherwise 2.2 s (prototype timings).
    public func showToast(_ message: String, actionTitle: String? = nil, undo: (@MainActor () -> Void)? = nil) {
        toastTask?.cancel()
        toast = QTToast(message: message, actionTitle: actionTitle, undo: undo)
        lastToast = (message, Date())
        let duration: Duration = undo == nil ? .milliseconds(2200) : .seconds(5)
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    public func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }

    // MARK: Appearance

    /// Applies the theme to every window (incl. panels) via NSApp.appearance; `.automatic` follows the system.
    public func applyAppearance() {
        switch settings.settings.theme {
        case .automatic: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
