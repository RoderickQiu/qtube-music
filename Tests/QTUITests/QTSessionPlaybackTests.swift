import Foundation
import QTAuth
import QTCore
import QTInnerTube
import QTLyrics
import QTPlayback
import Testing
@testable import QTUI

/// Every request fails as "offline" at once (no network in tests; pages land in a failure state).
private struct QTOfflineTestTransport: QTHTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

/// Counts Keychain reads (the explicit demo catalog must never read it).
private final class QTCountingSecureStore: QTSecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private let inner = QTMemorySecureStore()
    private var count = 0
    var reads: Int { lock.withLock { count } }
    func read() throws -> Data? { lock.withLock { count += 1 }; return try inner.read() }
    func write(_ data: Data) throws { try inner.write(data) }
    func delete() throws { try inner.delete() }
}

/// Catalog mode transitions (demo ⇄ library, expiry, sign-in again), launch playback once per process, and how
/// page failures read. Fake cookies, an offline fake transport and private UserDefaults suites only.
@MainActor
@Suite struct QTSessionPlaybackTests {
    static let fakeLogin = [
        QTCookie(name: "SAPISID", value: "FAKE-SAPISID", domain: ".youtube.com"),
        QTCookie(name: "SID", value: "FAKE-SID", domain: ".youtube.com"),
        QTCookie(name: "__Secure-1PSIDTS", value: "FAKE-TS", domain: ".youtube.com"),
    ]

    private static func track(_ id: String) -> QTTrack {
        QTTrack(videoId: id, title: "Title \(id)", artists: [QTArtistRef(name: "A")], duration: 200)
    }

    private struct Rig {
        let model: QTAppModel
        let store: QTLiveCatalogStore
        let sessionStore: QTSessionStore
        let keychain: QTCountingSecureStore
        let defaults: UserDefaults
        let jar: QTMemoryWebCookieStore
    }

    private static func makeRig(launch args: [String: String] = [:], demoChosen: Bool = false,
                                signedIn: Bool = false) async throws -> Rig {
        let suite = "qt.tests.session.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        if demoChosen { defaults.set(true, forKey: QTLiveCatalogStore.demoDefaultsKey) }
        let keychain = QTCountingSecureStore()
        let sessionStore = QTSessionStore(store: keychain)
        if signedIn { try await sessionStore.save(QTAuthSession(cookies: fakeLogin)) }
        let jar = QTMemoryWebCookieStore()
        let client = QTInnerTubeClient(configuration: QTInnerTubeConfiguration(hl: "en", gl: "US"),
                                       transport: QTOfflineTestTransport(), retry: QTRetryPolicy(maxAttempts: 1),
                                       scrapesClientConfig: false, sleep: { _ in })
        let auth = QTAuthController(sessionStore: sessionStore, cookieStore: jar, client: client)
        let store = QTLiveCatalogStore(client: client, auth: auth, defaults: defaults, playbackServices: QTPlaybackServices())
        let tracks = ["a", "b", "c"].map(track)
        let catalog = QTMockCatalog(tracks: tracks, liked: QTPlaylist(id: "LM", title: .localized("Liked Songs"), kind: .liked, tracks: tracks))
        let player = QTPlayerModel(engine: QTSimulatedPlaybackEngine(account: .premium, tickInterval: nil),
                                   lyricsProvider: QTMockLyricsProvider(catalog: catalog))
        let settings = QTSettingsStore(defaults: defaults)
        let model = QTAppModel(settings: settings, player: player, catalog: catalog, launch: QTLaunchOptions(arguments: args))
        return Rig(model: model, store: store, sessionStore: sessionStore, keychain: keychain, defaults: defaults, jar: jar)
    }

    private static func waitFor(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: Mode transitions

    @Test func explicitDemoCatalogNeverReadsTheKeychain() async throws {
        let rig = try await Self.makeRig(launch: ["qt.catalog": "mock"], signedIn: true)
        let reads = rig.keychain.reads
        rig.store.attach(rig.model)
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.store.mode == .mock)
        #expect(rig.keychain.reads == reads)
        #expect(rig.store.auth.state == .signedOut)
    }

    @Test func demoChoiceStillRestoresTheAccountAndASessionSwitchesToTheLibrary() async throws {
        let rig = try await Self.makeRig(demoChosen: true, signedIn: true)
        rig.store.attach(rig.model)
        #expect(rig.store.mode == .mock)
        await Self.waitFor { rig.store.mode == .live }
        #expect(rig.store.mode == .live)
        #expect(rig.store.auth.isSignedIn)
        // The choice is cleared: the next launch opens the library.
        #expect(!rig.defaults.bool(forKey: QTLiveCatalogStore.demoDefaultsKey))
        #expect(QTLiveCatalogStore.wantsLive(QTLaunchOptions(arguments: [:]), defaults: rig.defaults))
    }

    #if DEBUG
    @Test func signingInFromTheDemoLibrarySwitchesToTheLibrary() async throws {
        let rig = try await Self.makeRig(demoChosen: true)
        rig.store.attach(rig.model)
        await Self.waitFor { rig.store.lastAuthState != nil || rig.store.auth.state == .signedOut }
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.store.mode == .mock)
        #expect(rig.store.auth.state == .signedOut)
        // A sign-in (Settings › Account) — the debug import takes the same path into `.signedIn`.
        try await rig.store.auth.importSession(cookies: Self.fakeLogin)
        await Self.waitFor { rig.store.mode == .live }
        #expect(rig.store.mode == .live)
        #expect(!rig.defaults.bool(forKey: QTLiveCatalogStore.demoDefaultsKey))
    }

    @Test func expiryShowsSignedOutAndSigningInAgainReloadsThePages() async throws {
        let rig = try await Self.makeRig(launch: ["qt.catalog": "live"], signedIn: true)
        rig.store.attach(rig.model)
        await Self.waitFor { rig.store.mode == .live && rig.store.likedPhase.isSettled }
        #expect(rig.store.mode == .live)

        await rig.sessionStore.sessionDidExpire()
        await Self.waitFor { rig.store.mode == .signedOut }
        #expect(rig.store.mode == .signedOut)
        #expect(rig.store.auth.state == .sessionExpired)

        try await rig.store.auth.importSession(cookies: Self.fakeLogin)
        await Self.waitFor { rig.store.mode == .live && rig.store.likedPhase.isSettled }
        #expect(rig.store.mode == .live)
        // Pages loaded again with the new session (offline in this test), never left on "signed out".
        #expect(rig.store.likedPhase != .failed(.sessionExpired))
        #expect(rig.store.homePhase != .failed(.sessionExpired))
    }
    #endif

    @Test func useDemoLibraryOnAnExpiredSessionDropsIt() async throws {
        let rig = try await Self.makeRig(launch: ["qt.catalog": "live"], signedIn: true)
        rig.store.attach(rig.model)
        await Self.waitFor { rig.store.mode == .live }
        await rig.sessionStore.sessionDidExpire()
        await Self.waitFor { rig.store.mode == .signedOut }
        rig.store.useDemoLibrary()
        #expect(rig.store.mode == .mock)
        #expect(rig.defaults.bool(forKey: QTLiveCatalogStore.demoDefaultsKey))
        await Self.waitFor { rig.store.auth.state == .signedOut }
        #expect(rig.store.auth.state == .signedOut)
        #expect(try rig.keychain.read() == nil)
        #expect(rig.jar.cookies.filter(\.isGoogleOrYouTube).isEmpty)
    }

    @Test func pageFailuresReadRight() {
        #expect(QTLivePhase.failure(URLError(.cancelled)) == .idle)
        #expect(QTLivePhase.failure(CancellationError()) == .idle)
        #expect(QTLivePhase.failure(QTInnerTubeError.network(code: URLError.Code.cancelled.rawValue)) == .idle)
        #expect(QTLivePhase.failure(QTInnerTubeError.network(code: URLError.Code.notConnectedToInternet.rawValue)) == .failed(.offline))
        #expect(QTLivePhase.failure(QTInnerTubeError.network(code: URLError.Code.secureConnectionFailed.rawValue)) == .failed(.unavailable))
        #expect(QTLivePhase.failure(QTInnerTubeError.network(code: URLError.Code.badServerResponse.rawValue)) == .failed(.unavailable))
        #expect(QTLivePhase.failure(QTInnerTubeError.http(status: 403)) == .failed(.unavailable))
        #expect(QTLivePhase.failure(QTInnerTubeError.sessionExpired) == .failed(.sessionExpired))
    }

    // MARK: Launch playback

    @Test func launchPlaybackRunsOncePerProcess() async throws {
        let rig = try await Self.makeRig()
        let model = rig.model
        await model.applyLaunchPlayback()
        #expect(model.player.nowPlaying?.videoId == "a")
        #expect(model.player.queue.nowPlaying != nil)
        #expect(model.didApplyLaunchPlayback)
        // The user moves on; reopening the main window (its `.task` calls this again) must not touch playback.
        await model.player.play([Self.track("c")], startingAt: 0, source: nil, startTime: 42, autoplay: false)
        await model.applyLaunchPlayback()
        await model.applyLaunchPlayback()
        #expect(model.player.nowPlaying?.videoId == "c")
    }

    @Test func launchTrackStartsAtZeroUnlessScripted() {
        #expect(QTAppModel.launchStartTime(QTLaunchOptions(arguments: [:])) == 0)
        #expect(QTAppModel.launchStartTime(QTLaunchOptions(arguments: ["qt.readyFile": "/tmp/x"])) == 31.5)
        #expect(QTAppModel.launchStartTime(QTLaunchOptions(arguments: ["qt.time": "12"])) == 12)
    }

    @Test func launchPlaybackWaitsForLikedWhenThereIsNothingToCue() async throws {
        let rig = try await Self.makeRig()
        let model = rig.model
        let full = model.catalog
        model.catalog = QTLiveCatalogStore.emptyCatalog
        await model.applyLaunchPlayback()
        #expect(model.player.nowPlaying == nil)
        #expect(!model.didApplyLaunchPlayback)
        model.catalog = full  // Liked arrived
        await model.applyLaunchPlayback()
        #expect(model.player.nowPlaying?.videoId == "a")
    }

    // MARK: Signed-in playback

    @Test func realDataPlaysInTheSessionJarNeverAPersistentStore() {
        let live = QTPlaybackSetup.resolve(launch: QTLaunchOptions(arguments: [:]), source: .live, tier: .premium)
        #expect(!live.isAnonymous)
        let jar = QTWebKitCookieStore.session.dataStore
        let engine = live.makeEngine(tier: .premium, sessionDataStore: jar) as? QTWebPlaybackEngine
        #expect(engine?.dataStore === jar)
        #expect(engine?.dataStore.isPersistent == false)
        // Opting out, or the demo catalog, plays in a throwaway store.
        let anonymous = QTPlaybackSetup.resolve(launch: QTLaunchOptions(arguments: ["qt.playback.anonymous": "YES"]), source: .live, tier: .premium)
        let anonEngine = anonymous.makeEngine(tier: .premium, sessionDataStore: jar) as? QTWebPlaybackEngine
        #expect(anonEngine.map { $0.dataStore !== jar && !$0.dataStore.isPersistent } == true)
        #expect(!QTWebPlaybackEngine.sharedDataStore.isPersistent)
    }

    @Test func longCollectionsReadInHoursAndMinutes() {
        let en = Locale(identifier: "en_US")
        #expect(QTFormat.totalDuration(minutes: 312, locale: en) == "5 hr, 12 min")
        #expect(QTFormat.totalDuration(minutes: 312, locale: Locale(identifier: "zh-Hans")) == "5小时12分钟")
        #expect(QTFormat.totalDuration(minutes: 60, locale: en) == "1 hr")
        #expect(QTFormat.songCountAndMinutes(count: 80, seconds: 312 * 60, locale: en).contains("5 hr, 12 min"))
        #expect(QTFormat.songCountAndMinutes(count: 12, seconds: 50 * 60, locale: en).contains("50"))
    }
}
