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
    public var undo: (@MainActor () -> Void)?

    public init(message: String, undo: (@MainActor () -> Void)? = nil) {
        self.message = message
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
    public private(set) var catalog: QTMockCatalog

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
    public private(set) var toast: QTToast?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

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
        let settings = QTSettingsStore()
        settings.override { s in
            if let v = launch.language { s.interfaceLanguage = v }
            if let v = launch.theme { s.theme = v }
            if let v = launch.stageLayout { s.stageLayout = v }
            if let v = launch.stageBackground { s.stageBackground = v }
            if let v = launch.translation { s.lyricsTranslation = v }
        }
        let catalog: QTMockCatalog
        if let url = QTMockCatalog.locate(explicitPath: launch.catalogPath), let loaded = try? QTMockCatalog.load(from: url) {
            catalog = loaded
        } else {
            FileHandle.standardError.write(Data("QTube Music: mock catalog not found; run Scripts/make-mock-catalog.py\n".utf8))
            catalog = QTMockCatalog(tracks: [], liked: QTPlaylist(id: "LM", title: .localized("Liked Songs"), kind: .liked, tracks: []))
        }
        // Mock runs serve lyrics that came from unofficial providers; say so in the session's settings (never
        // persisted) so the lyrics options don't name NetEase over an "Unofficial sources" switch that is off.
        let mockSources = Set(catalog.lyrics.values.filter(\.source.isUnofficial).map(\.source.id))
        if !mockSources.isEmpty, !settings.settings.unofficialLyricsSources.anyEnabled {
            settings.override { s in
                s.unofficialLyricsSources = QTUnofficialLyricsSources(netease: mockSources.contains(QTLyricsSource.netease.id),
                                                                      kugou: mockSources.contains(QTLyricsSource.kugou.id),
                                                                      qq: mockSources.contains(QTLyricsSource.qq.id))
            }
        }
        let engine = QTSimulatedPlaybackEngine(account: launch.account == .free ? .free : .premium)
        let player = QTPlayerModel(engine: engine, lyricsProvider: QTMockLyricsProvider(catalog: catalog),
                                   likedTrackIDs: Set(catalog.liked.tracks?.map(\.videoId) ?? []))
        let model = QTAppModel(settings: settings, player: player, catalog: catalog, launch: launch)
        model.account = launch.account ?? .premium
        model.surface = launch.surface ?? .window
        model.sidebarSelection = launch.section ?? .home
        model.panelTab = launch.panelTab ?? .nowPlaying
        model.isPanelShown = !(launch.panelHidden ?? false)
        model.isVideoMode = launch.videoMode ?? (launch.stageBackground == .video)
        if launch.extraWindows.contains(.desktopLyrics) { settings.override { $0.desktopLyrics.isShown = true } }
        QTReadiness.shared.configure(readyFile: launch.readyFile)
        model.applyAppearance()
        return model
    }

    /// Loads the launch track (`qt.track`, default: first Liked song) at `qt.time` (default 31.5 s, just before the
    /// hero track's first lyric), paused unless `-qt.paused NO`; `-qt.ad YES` forces the ad state.
    public func applyLaunchPlayback() async {
        let liked = catalog.liked.tracks ?? catalog.tracks
        guard !liked.isEmpty else { return }
        let index = launch.trackID.flatMap { id in liked.firstIndex { $0.videoId == id } } ?? 0
        let paused = launch.paused ?? true
        await player.play(liked, startingAt: index, source: QTQueueSource(kind: .playlist, id: catalog.liked.id, title: catalog.liked.title),
                          startTime: launch.time ?? 31.5, autoplay: !paused, mode: isVideoMode ? .video : .song)
        QTPlayerLaunch.apply(launch, catalog: catalog, to: player)
        if launch.forceAd, let sim = player.engine as? QTSimulatedPlaybackEngine {
            sim.playAd()
            if paused { sim.pause() }
        }
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

    /// Artwork palette driving the accent tint.
    public var palette: QTArtworkPalette? { player.nowPlaying?.palette }

    // MARK: Toasts

    /// Shows a HUD message; with `undo` it stays 5 s, otherwise 2.2 s (prototype timings).
    public func showToast(_ message: String, undo: (@MainActor () -> Void)? = nil) {
        toastTask?.cancel()
        toast = QTToast(message: message, undo: undo)
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
