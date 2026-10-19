import AppKit
import Foundation
import Observation
import QTAuth
import QTCore
import QTInnerTube

// Owner: builder "data-live". Wires YouTube Music (QTInnerTube + QTAuth) into the app: decides between the user's
// library, guest mode (signed out: YouTube Music without an account) and — DEBUG builds only — the demo (mock)
// catalog, loads pages on demand, and folds what it loads into `QTAppModel.catalog` so the existing Home / Liked /
// playlist / sidebar views show real data unchanged.
// Read-only: account writes stay off (`QTInnerTubeClient.setAllowsAccountWrites(false)`); likes and playlist edits
// remain session-only (QTPlaylistEdits) until the user approves writes.

/// Where the app's catalog comes from.
public enum QTCatalogMode: String, Sendable, Hashable {
    /// DEBUG only: the mock catalog from the prototype's 12 tracks (`-qt.catalog mock`, dev scripts, tests).
    /// Release builds never enter it (`QTBuild.allowsDemoData`).
    case mock
    /// Reading the saved session (a fraction of a second at launch).
    case restoring
    /// Signed out: YouTube Music without an account — Home, Explore, search, albums, artists and public playlists,
    /// read anonymously; the library places ask to sign in.
    case guest
    /// The user's YouTube Music library.
    case live

    /// Real YouTube Music pages (signed in or not), as opposed to the demo catalog or the launch restore.
    public var browsesYouTube: Bool { self == .live || self == .guest }
}

/// Why a page couldn't load, as the UI presents it.
public enum QTLiveFailure: Sendable, Hashable {
    case offline
    case sessionExpired
    case unavailable
    /// YouTube sent the request to Google's "unusual traffic" check (usually anonymous requests from a busy
    /// network). Signing in usually clears it; the app never opens or tries to solve the check.
    case botCheck

    /// Only connectivity errors read as offline; TLS, bad-server and other network errors are "couldn't load".
    init(_ error: any Error) {
        if let e = error as? QTInnerTubeError {
            switch e {
            case .botCheck: self = .botCheck
            case .sessionExpired, .notSignedIn: self = .sessionExpired
            default: self = e.isConnectivity ? .offline : .unavailable
            }
        } else if let u = error as? URLError, QTInnerTubeError.connectivityCodes.contains(u.code) {
            self = .offline
        } else {
            self = .unavailable
        }
    }

    /// A cancelled load (an account switch cancels in-flight pages) isn't a failure to show.
    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let e = error as? QTInnerTubeError { return e.isCancellation }
        if let u = error as? URLError { return u.code == .cancelled }
        return false
    }
}

/// Load state of one page or list.
public enum QTLivePhase: Sendable, Hashable {
    case idle, loading, loaded
    case failed(QTLiveFailure)

    /// The phase after a load threw: the failure state, or idle for a cancellation (the page loads again on demand).
    static func failure(_ error: any Error) -> QTLivePhase {
        QTLiveFailure.isCancellation(error) ? .idle : .failed(QTLiveFailure(error))
    }

    public var isSettled: Bool {
        switch self {
        case .loaded, .failed: true
        default: false
        }
    }
}

@MainActor
@Observable
public final class QTLiveCatalogStore {
    public static let shared = QTLiveCatalogStore()

    public private(set) var mode: QTCatalogMode = .mock

    public let client: QTInnerTubeClient
    public let auth: QTAuthController
    @ObservationIgnored let service: QTInnerTubeCatalog
    @ObservationIgnored private weak var model: QTAppModel?
    @ObservationIgnored private var hl: String
    @ObservationIgnored private var didApplyLaunchPlayback = false
    @ObservationIgnored private var tasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var isObservingAuth = false
    @ObservationIgnored private var isObservingLanguage = false

    // MARK: Pages

    public private(set) var homePhase: QTLivePhase = .idle
    /// Mood chip applied to Home (`QTMoodChip.id`) and its feed.
    public private(set) var homeMood: String?
    public private(set) var moodFeeds: [String: QTHomeFeed] = [:]
    public private(set) var moodPhases: [String: QTLivePhase] = [:]
    public private(set) var likedPhase: QTLivePhase = .idle
    /// Liked Music continues loading in the background after the first page; true until every page is in.
    public private(set) var isLoadingMoreLiked = false
    public private(set) var libraryPhase: QTLivePhase = .idle
    public private(set) var songsPhase: QTLivePhase = .idle
    public private(set) var librarySongs: [QTTrack] = []
    public private(set) var albumsPhase: QTLivePhase = .idle
    public private(set) var libraryAlbums: [QTAlbum] = []
    public private(set) var artistsPhase: QTLivePhase = .idle
    public private(set) var libraryArtists: [QTArtist] = []
    /// Playlists opened from Home / search / artist pages (not in the library, so not in the sidebar).
    public private(set) var otherPlaylists: [String: QTPlaylist] = [:]
    public private(set) var playlistPhases: [String: QTLivePhase] = [:]
    /// YouTube Music's own song count per playlist id (`LM` for Liked), from the header ("1,234 songs"): the header
    /// shows max(loaded rows, this), since paging stops at `maxPlaylistPages` and unavailable rows aren't listed.
    public private(set) var reportedTrackCounts: [String: Int] = [:]
    public private(set) var albumPages: [String: QTAlbumPage] = [:]
    public private(set) var albumPhases: [String: QTLivePhase] = [:]
    public private(set) var artistPages: [String: QTArtistPage] = [:]
    public private(set) var artistPhases: [String: QTLivePhase] = [:]
    public private(set) var explore: QTExplorePage?
    public private(set) var explorePhase: QTLivePhase = .idle
    public private(set) var exploreSections: [QTLiveExploreSection: [QTShelf]] = [:]
    public private(set) var exploreSectionPhases: [QTLiveExploreSection: QTLivePhase] = [:]
    public private(set) var moodsPage: QTMoodsPage?
    public private(set) var searchResults: [String: QTSearchResults] = [:]
    public private(set) var searchPhases: [String: QTLivePhase] = [:]
    /// Album/artist keys (titles or names from the mock-era navigation API) resolved to browse ids.
    @ObservationIgnored private var resolvedKeys: [String: String] = [:]

    /// UserDefaults key earlier builds set when the user picked "Use Demo Library" on the signed-out screen. Guest
    /// mode replaced the demo library; the key is removed at launch and never read.
    static let legacyDemoDefaultsKey = "qt.data.demoLibrary"

    /// App defaults (tests pass their own suite).
    @ObservationIgnored let defaults: UserDefaults
    /// Engine / Now Playing / queue persistence switching (tests pass an unattached instance).
    @ObservationIgnored let playbackServices: QTPlaybackServices

    public convenience init() {
        let hl = QTInnerTubeConfiguration.hl(for: QTLoc.language)
        let configuration = QTInnerTubeConfiguration(hl: hl, gl: QTInnerTubeConfiguration.gl())
        #if DEBUG
        // Dev runs: `-qt.auth.store memory` keeps the session in memory (a guest run never reads, and a sign-out never
        // clears, the shared dev session); `-qt.live.fixtures YES` answers YouTube Music from recorded responses
        // (Tests/QTInnerTubeTests/Fixtures), offline, for screenshots.
        let launch = QTLaunchOptions.current
        if launch.bool("qt.live.fixtures") == true { QTImageLoader.allowsNetwork = false }
        let client = launch.bool("qt.live.fixtures") == true
            ? QTInnerTubeClient(configuration: configuration, transport: QTFixtureTransport(), retry: .none,
                                scrapesClientConfig: false)
            : QTInnerTubeClient(configuration: configuration)
        if launch.string("qt.auth.store") == "memory" {
            // WebKit's session jar is already per process and never persisted; only the Keychain item is swapped.
            self.init(client: client, auth: QTAuthController(sessionStore: QTSessionStore(store: QTMemorySecureStore()),
                                                             client: client))
            return
        }
        #else
        let client = QTInnerTubeClient(configuration: configuration)
        #endif
        self.init(client: client, auth: QTAuthController(client: client))
    }

    /// Tests: an injected client (fake transport) and auth controller (memory Keychain + memory cookie jar).
    init(client: QTInnerTubeClient, auth: QTAuthController, defaults: UserDefaults = .standard,
         playbackServices: QTPlaybackServices = .shared) {
        hl = QTInnerTubeConfiguration.hl(for: QTLoc.language)
        self.client = client
        self.auth = auth
        self.defaults = defaults
        self.playbackServices = playbackServices
        service = QTInnerTubeCatalog(client: client, homePages: 3, maxPlaylistPages: 50)
    }

    // MARK: Mode

    /// Called once from `QTAppModel.bootstrap`. DEBUG `-qt.catalog mock` (or a mock catalog path) keeps the demo
    /// catalog and never touches the Keychain. Otherwise — always in release builds — the saved session restores:
    /// the user's library when there is one, guest mode when there isn't.
    public func attach(_ model: QTAppModel) {
        guard self.model == nil else { return }
        self.model = model
        // Settings › Account (desktop) reads the app's one auth controller from the model.
        model.authController = auth
        // Earlier builds left the session in WebKit's plain-text persistent cookie jar; the app keeps none.
        QTLegacyWebStorage.purge()
        // The demo library is gone (guest mode replaced it); forget an old choice.
        defaults.removeObject(forKey: Self.legacyDemoDefaultsKey)
        model.liveCatalog = self
        guard Self.wantsLive(model.launch) else {
            mode = .mock
            return
        }
        mode = .restoring
        model.catalog = Self.emptyCatalog
        // Screenshot states (session-only): guest mode without touching the Keychain.
        if model.launch.bool("qt.live.signedOut") == true {
            Task { await client.setAllowsAccountWrites(false) }
            observeLanguage()
            enterGuest()
            if model.launch.bool("qt.live.signIn") == true { openSignInAfterLaunch() }
            return
        }
        Task { await client.setAllowsAccountWrites(false) }
        observeLanguage()
        let hold = QTReadiness.shared.hold("live.restore")
        Task { @MainActor in
            await self.restore()
            QTReadiness.shared.release(hold)
        }
    }

    /// YouTube Music pages, signed in or as a guest (not the demo catalog, not while the session restores).
    public var isLive: Bool { mode.browsesYouTube }

    /// The user's own library is there (signed in): Liked Songs, library playlists, songs, albums and artists.
    public var hasLibrary: Bool { mode == .live }

    /// Guest mode: YouTube Music without an account.
    public var isGuest: Bool { mode == .guest }

    /// Reading the saved session; launch playback waits for it (the player page must start signed in).
    public var isRestoringSession: Bool { mode == .restoring }

    /// DEBUG `-qt.catalog mock` or a mock catalog folder: the demo catalog only, the Keychain is never read. Never in
    /// release builds.
    public static func isDemoOnly(_ launch: QTLaunchOptions, allowsDemoData: Bool = QTBuild.allowsDemoData) -> Bool {
        guard allowsDemoData else { return false }
        switch launch.string("qt.catalog") {
        case "mock"?: return true
        case let path? where !path.isEmpty && path != "live": return true
        default: return false
        }
    }

    /// Whether this launch uses YouTube Music (the user's library, or guest mode) rather than the demo catalog: always
    /// in release builds; in DEBUG unless `-qt.catalog mock` (or a mock catalog folder). Bootstrap also uses it to
    /// pick the playback engine.
    public static func wantsLive(_ launch: QTLaunchOptions, allowsDemoData: Bool = QTBuild.allowsDemoData) -> Bool {
        !isDemoOnly(launch, allowsDemoData: allowsDemoData)
    }

    /// Whether live pages replace the mock-era pages for this destination. History is the app's own play history
    /// (local, not the account's) in every mode.
    public func handles(_ destination: QTDestination) -> Bool {
        switch mode {
        case .mock: return false
        case .restoring: return true
        case .live, .guest:
            if case .section(.history) = destination { return false }
            return true
        }
    }

    /// Places that are the account's library: guest mode shows the sign-in state there.
    public static func isLibrary(_ destination: QTDestination) -> Bool {
        switch destination {
        case .section(.liked), .section(.songs), .section(.albums), .section(.artists): return true
        // Playlists in the sidebar are the library's; one opened from Home, search or an artist page is public.
        case .section(.playlist(let id)): return id == "LM"
        default: return false
        }
    }

    private func restore() async {
        await auth.restore()
        observeAuth()
        if auth.isSignedIn {
            await enterLive()
        } else {
            enterGuest()
            await model?.applyLaunchPlayback()
        }
    }

    /// Guest mode: YouTube Music read anonymously; the library places ask to sign in. Home loads when shown.
    private func enterGuest() {
        mode = .guest
        // Signed out, YouTube's player plays as a free listener (with ads).
        if let model, model.launch.account == nil { model.account = .free }
        installAutoplay()
        applyLaunchDestination()
    }

    private func enterLive() async {
        mode = .live
        let hold = QTReadiness.shared.hold("live.initial")
        defer { QTReadiness.shared.release(hold) }
        // The session is in the player's jar now: the saved queue (if any) cues signed in.
        await model?.applyLaunchPlayback()
        // Premium + account region first: `gl` shapes Home.
        await auth.refreshAccount()
        applyAccount()
        installAutoplay()
        async let home: Void = loadHome()
        async let library: Void = loadLibraryPlaylists()
        async let liked: Void = loadLiked()
        _ = await (home, library, liked)
        applyLaunchDestination()
    }

    /// Autoplay after the queue runs out: YouTube Music's radio for the last track (`next` with `RDAMVM<id>`,
    /// read-only), minus what is already queued. Signed in or as a guest (anonymous `next`).
    private func installAutoplay() {
        guard let model else { return }
        let client = client
        model.player.playback.autoplayContinuation = { [weak self] request in
            guard let self, self.mode.browsesYouTube, let seed = request.seed, seed.videoId.count == 11 else { return [] }
            let page = try await client.next(videoId: seed.videoId, playlistId: "RDAMVM" + seed.videoId)
            return page.tracks.filter { $0.videoId != seed.videoId && !request.excludingVideoIDs.contains($0.videoId) }
        }
    }

    /// `-qt.live.open album:<id|title>` / `artist:<id|name>` / `playlist:<id>` opens that page at launch;
    /// `-qt.live.state skeleton|offline|unavailable|expired` pins a page state (screenshots).
    private func applyLaunchDestination() {
        guard let model, let open = model.launch.string("qt.live.open") else { return }
        let parts = open.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        switch parts[0] {
        case "album": QTNavigator.shared.go(.album(parts[1]))
        case "artist": QTNavigator.shared.go(.artist(parts[1]))
        case "playlist": QTNavigator.shared.go(.section(.playlist(parts[1])))
        default: break
        }
    }

    /// A pinned page state from `-qt.live.state` (nil = real state).
    public var pinnedPhase: QTLivePhase? {
        switch model?.launch.string("qt.live.state") {
        case "skeleton"?: .loading
        case "offline"?: .failed(.offline)
        case "unavailable"?: .failed(.unavailable)
        case "expired"?: .failed(.sessionExpired)
        case "botCheck"?: .failed(.botCheck)
        default: nil
        }
    }

    /// DEBUG `-qt.live.loadDelay <s>`: Home and mood feeds arrive this much later (a slow network, for loading and
    /// transition screenshots).
    private func debugLoadDelay() async {
        #if DEBUG
        if let s = model?.launch.double("qt.live.loadDelay"), s > 0 { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }
        #endif
    }

    /// `-qt.live.signIn YES`: the Google sign-in window at launch, in a private throwaway WebKit store (so it shows
    /// Google's page even when signed in, and a login there is never kept).
    private func openSignInAfterLaunch() {
        let hold = QTReadiness.shared.hold("live.signIn")
        Task { @MainActor in
            for _ in 0..<50 where !NSApp.windows.contains(where: { $0.identifier == QTWindowID.main.identifier && $0.isVisible }) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(500))
            let shown = Task { @MainActor in
                for await _ in NotificationCenter.default.notifications(named: QTAuthController.ephemeralSignInDidShow) {
                    break
                }
            }
            signIn(ephemeral: true)
            let timeout = Task { @MainActor in try? await Task.sleep(for: .seconds(20)); shown.cancel() }
            await shown.value
            timeout.cancel()
            QTReadiness.shared.release(hold)
        }
    }

    private func applyAccount() {
        guard let model, model.launch.account == nil, case .signedIn(_, let premium) = auth.state,
              auth.account?.isPremium != nil else { return }
        model.account = premium ? .premium : .free
    }

    /// Opens Google's sign-in window over the main window.
    public func signIn(ephemeral: Bool = false) {
        let parent = NSApp.windows.first { $0.identifier == QTWindowID.main.identifier }
        auth.beginSignIn(hl: hl, over: parent, isEphemeral: ephemeral)
    }

    /// Signs out and continues as a guest at once (no relaunch): the library goes, YouTube Music stays.
    public func signOut() async {
        await auth.signOut()
        leaveLibraryForGuest()
    }

    /// The library's pages and likes go; Home and the other pages reload anonymously when shown.
    private func leaveLibraryForGuest() {
        resetPages()
        model?.catalog = Self.emptyCatalog
        model?.player.likedTrackIDs = []
        enterGuest()
    }

    private func observeAuth() {
        guard !isObservingAuth else { return }
        isObservingAuth = true
        trackAuth()
    }

    private func trackAuth() {
        withObservationTracking { _ = auth.state } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.authStateChanged()
                self.trackAuth()
            }
        }
    }

    /// The one place auth transitions change the catalog mode. Exposed for tests.
    func authStateChanged() {
        lastAuthState = auth.state
        switch auth.state {
        case .signedIn:
            switch mode {
            case .live:
                applyAccount()
            case .restoring:
                break
            case .guest:
                // Signed in from guest mode (sidebar, a library page, Settings), or again after the session expired.
                resetPages()
                playbackServices.sessionDidChange()
                Task { await enterLive() }
            case .mock:
                // DEBUG demo catalog: it never reads or follows the account.
                break
            }
        case .signedOut:
            playbackServices.sessionDidChange()
            guard mode == .live || mode == .restoring else { return }
            leaveLibraryForGuest()
        case .sessionExpired:
            // YouTube no longer sees the login: guest mode (a toast says so; the library places and Settings ›
            // Account offer Sign In) instead of every page failing on its own. A new sign-in reloads everything.
            guard mode == .live else { return }
            leaveLibraryForGuest()
            model?.showToast(QTLoc.tr("Signed out of YouTube Music", table: .live), actionTitle: QTLoc.tr("Sign In", table: .live)) {
                QTLiveCatalogStore.shared.signIn()
            }
        case .signingIn:
            break
        }
    }

    /// The auth state the last transition handled (tests).
    @ObservationIgnored private(set) var lastAuthState: QTAuthState?

    private func observeLanguage() {
        guard !isObservingLanguage else { return }
        isObservingLanguage = true
        trackLanguage()
    }

    private func trackLanguage() {
        withObservationTracking { _ = QTLocalizer.shared.language } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.languageChanged()
                self.trackLanguage()
            }
        }
    }

    /// `hl` follows the interface language; titles are localized server-side, so loaded pages reload.
    private func languageChanged() {
        let new = QTInnerTubeConfiguration.hl(for: QTLoc.language)
        guard new != hl else { return }
        hl = new
        Task {
            await client.setLanguage(hl: new)
            guard mode.browsesYouTube else { return }
            homePhase = .idle
            moodFeeds = [:]
            moodPhases = [:]
            explorePhase = .idle
            exploreSections = [:]
            exploreSectionPhases = [:]
            albumPhases = [:]
            artistPhases = [:]
            searchPhases = [:]
            searchResults = [:]
            await loadHome()
        }
    }

    private func resetPages() {
        for t in tasks.values { t.task.cancel() }
        tasks = [:]
        homePhase = .idle; homeMood = nil; moodFeeds = [:]; moodPhases = [:]
        likedPhase = .idle; isLoadingMoreLiked = false; libraryPhase = .idle
        songsPhase = .idle; librarySongs = []; albumsPhase = .idle; libraryAlbums = []
        artistsPhase = .idle; libraryArtists = []
        otherPlaylists = [:]; playlistPhases = [:]; reportedTrackCounts = [:]; albumPages = [:]; albumPhases = [:]
        artistPages = [:]; artistPhases = [:]; explore = nil; explorePhase = .idle
        exploreSections = [:]; exploreSectionPhases = [:]; moodsPage = nil
        searchResults = [:]; searchPhases = [:]; resolvedKeys = [:]
        didApplyLaunchPlayback = false
    }

    static var emptyCatalog: QTMockCatalog {
        QTMockCatalog(tracks: [], liked: QTPlaylist(id: "LM", title: .localized("Liked Songs"), kind: .liked, tracks: nil))
    }

    // MARK: Loading helpers

    /// Runs `work` once per key at a time; readiness waits for it during launch.
    private func run(_ key: String, _ work: @escaping @MainActor () async -> Void) async {
        if let running = tasks[key] { await running.task.value; return }
        let hold = QTReadiness.shared.hold("live.\(key)")
        let id = UUID()
        let task = Task { @MainActor in await work() }
        tasks[key] = (id, task)
        await task.value
        // A reset may have started a new task under the same key meanwhile; keep that one.
        if tasks[key]?.id == id { tasks[key] = nil }
        QTReadiness.shared.release(hold)
    }

    private func updateCatalog(_ change: (inout QTMockCatalog) -> Void) {
        guard let model, mode.browsesYouTube else { return }
        var c = model.catalog
        change(&c)
        model.catalog = c
    }

    /// Every track the app has seen goes into `catalog.tracks` (drag and drop, album/artist lookups by title).
    private func remember(_ tracks: [QTTrack]) {
        guard !tracks.isEmpty else { return }
        updateCatalog { c in
            var known = Set(c.tracks.map(\.videoId))
            c.tracks += tracks.filter { known.insert($0.videoId).inserted }
        }
    }

    // MARK: Home

    public func loadHome(force: Bool = false) async {
        guard mode.browsesYouTube, force || !homePhase.isLoadedOrLoading else { return }
        await run("home") { [self] in
            homePhase = .loading
            do {
                await debugLoadDelay()
                let feed = try await service.homeFeed()
                updateCatalog { $0.home = feed }
                remember(feed.shelves.flatMap { $0.items.compactMap(\.track) })
                homePhase = .loaded
            } catch {
                homePhase = .failure(error)
            }
        }
    }

    /// Home filtered by a mood chip (nil = all).
    public func selectMood(_ id: String?) {
        homeMood = id
        guard let id, moodFeeds[id] == nil else { return }
        Task { await loadMood(id) }
    }

    public func loadMood(_ id: String) async {
        await run("mood:\(id)") { [self] in
            moodPhases[id] = .loading
            do {
                await debugLoadDelay()
                let page = try await client.home(QTBrowseTarget(moodChipID: id))
                moodFeeds[id] = page.feed
                remember(page.feed.shelves.flatMap { $0.items.compactMap(\.track) })
                moodPhases[id] = .loaded
            } catch {
                moodPhases[id] = .failure(error)
            }
        }
    }

    // MARK: Liked / library

    public func loadLiked(force: Bool = false) async {
        guard mode == .live, force || !likedPhase.isLoadedOrLoading else { return }
        await run("liked") { [self] in
            likedPhase = .loading
            do {
                let first = try await client.likedSongs()
                reportedTrackCounts["LM"] = first.totalTrackCount
                var tracks = first.playlist.tracks ?? []
                setLiked(tracks)
                likedPhase = .loaded
                await applyLaunchPlaybackOnce()
                // The rest arrives in the background, page by page.
                var token = first.continuation
                isLoadingMoreLiked = token != nil
                var pages = 1
                while let t = token, pages < service.maxPlaylistPages, mode == .live {
                    guard let more = try? await client.playlistContinuation(t) else { break }
                    tracks += more.tracks
                    setLiked(tracks)
                    token = more.continuation
                    pages += 1
                }
                isLoadingMoreLiked = false
            } catch {
                likedPhase = .failure(error)
            }
        }
    }

    private func setLiked(_ tracks: [QTTrack]) {
        updateCatalog { $0.liked = QTPlaylist(id: "LM", title: .localized("Liked Songs"), kind: .liked, tracks: tracks) }
        model?.player.likedTrackIDs = Set(tracks.map(\.videoId))
        remember(tracks)
    }

    /// The launch track (`qt.track`, default: first Liked song) once Liked has arrived — paused unless asked.
    private func applyLaunchPlaybackOnce() async {
        guard let model, !didApplyLaunchPlayback, model.player.nowPlaying == nil else { return }
        didApplyLaunchPlayback = true
        await model.applyLaunchPlayback()
    }

    public func loadLibraryPlaylists(force: Bool = false) async {
        guard mode == .live, force || !libraryPhase.isLoadedOrLoading else { return }
        await run("library") { [self] in
            libraryPhase = .loading
            do {
                let lists = try await service.libraryPlaylists()
                updateCatalog { c in
                    // Keep tracks of playlists already opened.
                    let opened = Dictionary(c.playlists.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    c.playlists = lists.map { p in
                        var p = p
                        if p.tracks == nil { p.tracks = opened[p.id]?.tracks }
                        return p
                    }
                }
                libraryPhase = .loaded
            } catch {
                libraryPhase = .failure(error)
            }
        }
    }

    public func loadLibrarySongs(force: Bool = false) async {
        guard mode == .live, force || !songsPhase.isLoadedOrLoading else { return }
        await run("songs") { [self] in
            songsPhase = .loading
            do {
                var page = try await client.librarySongs()
                var tracks = page.items
                librarySongs = tracks
                songsPhase = .loaded
                var pages = 1
                while let t = page.continuation, pages < 40, mode == .live {
                    guard let more = try? await client.libraryContinuation(t) else { break }
                    tracks += more.items.compactMap(\.track)
                    librarySongs = tracks
                    page = QTLibraryPage(items: [], continuation: more.continuation)
                    pages += 1
                }
                remember(tracks)
            } catch {
                songsPhase = .failure(error)
            }
        }
    }

    public func loadLibraryAlbums(force: Bool = false) async {
        guard mode == .live, force || !albumsPhase.isLoadedOrLoading else { return }
        await run("albums") { [self] in
            albumsPhase = .loading
            do {
                var page = try await client.libraryAlbums()
                var albums = page.items
                var pages = 1
                while let t = page.continuation, pages < 20 {
                    guard let more = try? await client.libraryContinuation(t) else { break }
                    albums += more.items.compactMap { if case .album(let a) = $0 { a } else { nil } }
                    page = QTLibraryPage(items: [], continuation: more.continuation)
                    pages += 1
                }
                libraryAlbums = albums
                albumsPhase = .loaded
            } catch {
                albumsPhase = .failure(error)
            }
        }
    }

    public func loadLibraryArtists(force: Bool = false) async {
        guard mode == .live, force || !artistsPhase.isLoadedOrLoading else { return }
        await run("artists") { [self] in
            artistsPhase = .loading
            do {
                var page = try await client.libraryArtists()
                var artists = page.items
                libraryArtists = artists
                artistsPhase = .loaded
                var pages = 1
                while let t = page.continuation, pages < 20 {
                    guard let more = try? await client.libraryContinuation(t) else { break }
                    artists += more.items.compactMap {
                        if case .artist(var a) = $0 { a.id = QTInnerTubeClient.channelId(a.id); return a } else { return nil }
                    }
                    libraryArtists = artists
                    page = QTLibraryPage(items: [], continuation: more.continuation)
                    pages += 1
                }
            } catch {
                artistsPhase = .failure(error)
            }
        }
    }

    // MARK: Playlists

    /// The playlist for an id: a library playlist (sidebar) or one opened from elsewhere.
    public func playlist(_ id: String) -> QTPlaylist? {
        if id == "LM" || id == "VLLM" { return model?.catalog.liked }
        return model?.catalog.playlists.first { $0.id == id } ?? otherPlaylists[id]
    }

    public func playlistPhase(_ id: String) -> QTLivePhase {
        if id == "LM" || id == "VLLM" { return likedPhase }
        return playlistPhases[id] ?? .idle
    }

    /// Loads a playlist's tracks: the first page shows at once, the rest streams in behind it.
    public func loadPlaylist(_ id: String, force: Bool = false) async {
        guard mode.browsesYouTube else { return }
        if id == "LM" || id == "VLLM" { await loadLiked(force: force); return }
        guard force || !(playlistPhases[id] ?? .idle).isLoadedOrLoading else { return }
        await run("playlist:\(id)") { [self] in
            playlistPhases[id] = .loading
            let known = playlist(id)
            do {
                let first: QTPlaylistPage
                do {
                    first = try await client.playlist(id)
                } catch {
                    // Radios and mixes ("RD…") have no browse page: their tracks come from `next`.
                    guard known?.kind == .mix || id.hasPrefix("VLRD") || id.hasPrefix("RD") else { throw error }
                    let next = try await client.next(videoId: nil, playlistId: id)
                    var p = known ?? QTPlaylist(id: id, title: .verbatim(""), kind: .mix)
                    p.tracks = next.tracks
                    store(p)
                    remember(next.tracks)
                    playlistPhases[id] = .loaded
                    return
                }
                reportedTrackCounts[id] = first.totalTrackCount
                var p = first.playlist
                p.id = id
                if let known {
                    if p.artwork.isEmpty { p.artwork = known.artwork }
                    if case .verbatim(let t) = p.title, t.isEmpty { p.title = known.title }
                    p.kind = known.kind
                }
                var tracks = p.tracks ?? []
                store(p)
                remember(tracks)
                playlistPhases[id] = .loaded
                var token = first.continuation
                var pages = 1
                while let t = token, pages < service.maxPlaylistPages, mode.browsesYouTube {
                    guard let more = try? await client.playlistContinuation(t) else { break }
                    tracks += more.tracks
                    p.tracks = tracks
                    store(p)
                    token = more.continuation
                    pages += 1
                }
                remember(tracks)
            } catch {
                playlistPhases[id] = .failure(error)
            }
        }
    }

    private func store(_ p: QTPlaylist) {
        if let model, model.catalog.playlists.contains(where: { $0.id == p.id }) {
            updateCatalog { c in
                if let i = c.playlists.firstIndex(where: { $0.id == p.id }) {
                    var merged = p
                    if merged.artwork.isEmpty { merged.artwork = c.playlists[i].artwork }
                    c.playlists[i] = merged
                }
            }
        } else {
            otherPlaylists[p.id] = p
        }
    }

    // MARK: Album / artist

    /// Browse id for an album/artist key: ids pass through; titles/names (mock-era navigation) are looked up in
    /// the tracks seen so far.
    public func albumID(for key: String) -> String? {
        if key.hasPrefix("MPREb_") { return key }
        if let id = resolvedKeys["album:\(key)"] { return id }
        return model?.catalog.tracks.lazy.compactMap { $0.album?.title == key ? $0.album?.id : nil }.first
    }

    public func artistID(for key: String) -> String? {
        if key.hasPrefix("UC") || key.hasPrefix("MPLA") { return QTInnerTubeClient.channelId(key) }
        if let id = resolvedKeys["artist:\(key)"] { return id }
        return model?.catalog.tracks.lazy.flatMap(\.artists).first { $0.name == key && $0.id != nil }?.id
            .map(QTInnerTubeClient.channelId)
    }

    public func loadAlbum(_ key: String, force: Bool = false) async {
        guard mode.browsesYouTube, force || !(albumPhases[key] ?? .idle).isLoadedOrLoading else { return }
        await run("album:\(key)") { [self] in
            albumPhases[key] = .loading
            do {
                var id = albumID(for: key)
                if id == nil {
                    let found = try await client.search(key, filter: .albums).albums
                    id = (found.first { $0.title == key } ?? found.first)?.id
                    if let id { resolvedKeys["album:\(key)"] = id }
                }
                guard let id else { throw QTInnerTubeError.parse("album") }
                let page = try await client.album(id)
                albumPages[key] = page
                remember(page.album.tracks ?? [])
                albumPhases[key] = .loaded
            } catch {
                albumPhases[key] = .failure(error)
            }
        }
    }

    public func loadArtist(_ key: String, force: Bool = false) async {
        guard mode.browsesYouTube, force || !(artistPhases[key] ?? .idle).isLoadedOrLoading else { return }
        await run("artist:\(key)") { [self] in
            artistPhases[key] = .loading
            do {
                var id = artistID(for: key)
                if id == nil {
                    let found = try await client.search(key, filter: .artists).artists
                    id = (found.first { $0.name == key } ?? found.first)?.id
                    if let id { resolvedKeys["artist:\(key)"] = id }
                }
                guard let id else { throw QTInnerTubeError.parse("artist") }
                let page = try await client.artist(id)
                artistPages[key] = page
                remember(page.songs + page.videos)
                artistPhases[key] = .loaded
            } catch {
                artistPhases[key] = .failure(error)
            }
        }
    }

    /// Hover prefetch: warms the client cache for a card's page (cheap: one request, cached for minutes).
    public func prefetch(_ item: QTShelfItem) {
        guard mode.browsesYouTube else { return }
        switch item {
        case .album(let a) where albumPhases[a.id] == nil: Task(priority: .utility) { _ = try? await client.album(a.id) }
        case .artist(let a) where artistPhases[a.id] == nil: Task(priority: .utility) { _ = try? await client.artist(a.id) }
        case .playlist(let p) where playlistPhases[p.id] == nil && p.kind != .mix:
            Task(priority: .utility) { _ = try? await client.playlist(p.id) }
        default: break
        }
    }

    // MARK: Explore

    public func loadExplore(force: Bool = false) async {
        guard mode.browsesYouTube, force || !explorePhase.isLoadedOrLoading else { return }
        await run("explore") { [self] in
            explorePhase = .loading
            do {
                let page = try await client.explore()
                explore = page
                remember(page.shelves.flatMap { $0.items.compactMap(\.track) })
                explorePhase = .loaded
            } catch {
                explorePhase = .failure(error)
            }
        }
    }

    public func loadExploreSection(_ section: QTLiveExploreSection, force: Bool = false) async {
        guard mode.browsesYouTube, section != .overview,
              force || !(exploreSectionPhases[section] ?? .idle).isLoadedOrLoading else { return }
        await run("explore:\(section.rawValue)") { [self] in
            exploreSectionPhases[section] = .loading
            do {
                switch section {
                case .newReleases: exploreSections[section] = try await client.newReleases()
                case .charts: exploreSections[section] = try await client.charts()
                case .moods:
                    moodsPage = try await client.moodsAndGenres()
                    exploreSections[section] = []
                case .overview: break
                }
                remember((exploreSections[section] ?? []).flatMap { $0.items.compactMap(\.track) })
                exploreSectionPhases[section] = .loaded
            } catch {
                exploreSectionPhases[section] = .failure(error)
            }
        }
    }

    /// Shelves of a mood / genre page (Explore › Moods & genres).
    public func loadMoodPage(_ chip: QTMoodChip) async {
        let key = "moodpage:\(chip.id)"
        guard mode.browsesYouTube, !(moodPhases[key] ?? .idle).isLoadedOrLoading else { return }
        await run(key) { [self] in
            moodPhases[key] = .loading
            do {
                moodFeeds[key] = QTHomeFeed(shelves: try await client.moodPage(chip))
                moodPhases[key] = .loaded
            } catch {
                moodPhases[key] = .failure(error)
            }
        }
    }

    // MARK: Search

    /// Grouped, music-only search (podcasts, episodes and profiles are dropped by the parser).
    public func search(_ query: String, force: Bool = false) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode.browsesYouTube, !q.isEmpty, force || !(searchPhases[q] ?? .idle).isLoadedOrLoading else { return }
        await run("search:\(q)") { [self] in
            searchPhases[q] = .loading
            do {
                // The videos filter alongside (window-data): unfiltered rows have no durations and few videos, so
                // "Music videos" could only show compilations; the filter's rows let it rank official MVs first.
                async let videos = try? client.search(q, filter: .videos)
                var results = try await client.search(q)
                if let videos = await videos { results = results.mergingVideos(from: videos) }
                searchResults[q] = results
                remember(results.songs + results.videos + (results.topResult?.track.map { [$0] } ?? []))
                searchPhases[q] = .loaded
            } catch {
                searchPhases[q] = .failure(error)
            }
        }
    }
}

/// Explore's sub-pages (a segmented control at the top of Explore).
public enum QTLiveExploreSection: String, Sendable, Hashable, CaseIterable {
    case overview, newReleases, charts, moods
}

extension QTLivePhase {
    var isLoadedOrLoading: Bool {
        switch self {
        case .loading, .loaded: true
        default: false
        }
    }
}
