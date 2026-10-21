import Foundation
import QTAuth
import QTCore
import QTInnerTube
import QTLyrics
import QTPlayback
import Testing
@testable import QTUI

/// `QTLiveCatalogStore` mode transitions (mock / restoring / guest / live), the auth restore → WebKit cookie
/// sync, sign-out, demo → sign-in, expiry → sign-in reload and the launch-playback-once rule — with fake cookies,
/// an in-memory Keychain, an in-memory cookie jar and a stub transport (no network, never the user's session).
@MainActor
@Suite(.serialized) struct QTLiveCatalogStoreTests {
    // MARK: Fixtures

    static func fakeLogin(psidts: String = "FAKE-TS") -> [QTCookie] {
        [
            QTCookie(name: "SAPISID", value: "FAKE-SAPISID", domain: ".youtube.com"),
            QTCookie(name: "SID", value: "FAKE-SID", domain: ".youtube.com"),
            QTCookie(name: "HSID", value: "FAKE-HSID", domain: ".youtube.com", isSecure: false, isHTTPOnly: true),
            QTCookie(name: "__Secure-1PSIDTS", value: psidts, domain: ".youtube.com", isHTTPOnly: true),
            QTCookie(name: "LOGIN_INFO", value: "FAKE-LOGIN", domain: ".youtube.com"),
        ]
    }

    /// Liked Songs answers with a recorded (anonymous, public) playlist page, the uploads songs list (two pages)
    /// with hand-built ones; everything else is offline.
    final class StubTransport: QTHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var likedRequests = 0
        private var uploadRequests = 0
        let liked: Data?
        static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("QTInnerTubeTests/Fixtures")

        init() {
            let url = Self.fixtures.appendingPathComponent("playlist-classic-rock-en.json")
            // Recorded anonymously; answer as the signed-in account would (`logged_in` = 1), or the client treats
            // it as a lost session.
            liked = (try? String(contentsOf: url, encoding: .utf8))
                .map { Data($0.replacingOccurrences(of: #""logged_in","value":"0""#, with: #""logged_in","value":"1""#).utf8) }
        }

        var likedRequestCount: Int { lock.withLock { likedRequests } }
        var uploadRequestCount: Int { lock.withLock { uploadRequests } }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            for (marker, name) in [(QTUploads.songsBrowseId, "handbuilt-uploads-songs"),
                                   ("FAKEUPLOADSCONT1", "handbuilt-uploads-songs-continuation")] where body.contains(marker) {
                lock.withLock { uploadRequests += 1 }
                let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(name + ".json"))
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
            }
            if request.url?.path.hasSuffix("/browse") == true, body.contains("\"VLLM\""), let liked {
                lock.withLock { likedRequests += 1 }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
                return (liked, response)
            }
            throw URLError(.notConnectedToInternet)
        }
    }

    /// Counts Keychain reads (a mock launch must not do any).
    final class CountingSecureStore: QTSecureStore, @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        private var readCount = 0
        init(data: Data? = nil) { self.data = data }
        var reads: Int { lock.withLock { readCount } }
        var stored: Data? { lock.withLock { data } }
        func read() throws -> Data? { lock.withLock { readCount += 1; return data } }
        func write(_ data: Data) throws { lock.withLock { self.data = data } }
        func delete() throws { lock.withLock { data = nil } }
    }

    struct Harness {
        let store: QTLiveCatalogStore
        let model: QTAppModel
        let jar: QTMemoryWebCookieStore
        let keychain: CountingSecureStore
        let transport: StubTransport
    }

    /// `savedSession`: cookies already in the "Keychain". `webCookies`: what WebKit's jar holds at launch.
    static func makeHarness(catalog arg: String = "live", savedSession: [QTCookie]? = nil,
                            webCookies: [QTCookie] = []) async throws -> Harness {
        let keychain = CountingSecureStore()
        if let savedSession {
            try await QTSessionStore(store: keychain).save(QTAuthSession(cookies: savedSession))
        }
        let readsBefore = keychain.reads
        #expect(readsBefore == 0)
        let transport = StubTransport()
        let client = QTInnerTubeClient(transport: transport, retry: .none, scrapesClientConfig: false, sleep: { _ in })
        let jar = QTMemoryWebCookieStore(cookies: webCookies)
        let auth = QTAuthController(sessionStore: QTSessionStore(store: keychain), cookieStore: jar, client: client)
        let store = QTLiveCatalogStore(client: client, auth: auth)
        let defaults = UserDefaults(suiteName: "qt.tests.live.\(UUID().uuidString)")!
        let empty = QTMockCatalog(tracks: [], liked: QTPlaylist(id: "LM", title: .localized("Liked Songs"), kind: .liked, tracks: []))
        let engine = QTSimulatedPlaybackEngine(account: .premium, tickInterval: nil)
        let player = QTPlayerModel(engine: engine, lyricsProvider: QTMockLyricsProvider(catalog: empty))
        let model = QTAppModel(settings: QTSettingsStore(defaults: defaults), player: player, catalog: empty,
                               launch: QTLaunchOptions(arguments: ["qt.catalog": arg]))
        store.attach(model)
        return Harness(store: store, model: model, jar: jar, keychain: keychain, transport: transport)
    }

    /// Polls `condition` on the main actor (observation callbacks hop through tasks).
    static func waitUntil(_ what: String, timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline {
                Issue.record("timed out waiting for \(what)")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    static func cleanUp() {
        UserDefaults.standard.removeObject(forKey: QTLiveCatalogStore.legacyDemoDefaultsKey)
    }

    // MARK: Tests

    @Test func mockLaunchNeverTouchesKeychainOrWebKit() async throws {
        let h = try await Self.makeHarness(catalog: "mock")
        #expect(h.store.mode == .mock)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.keychain.reads == 0)
        #expect(h.jar.cookies.isEmpty)
        #expect(h.transport.likedRequestCount == 0)
        #expect(!h.store.handles(.section(.home)))
    }

    @Test func noSavedSessionIsSignedOutAndTheJarStaysEmpty() async throws {
        let h = try await Self.makeHarness()
        #expect(h.store.mode == .restoring)
        await Self.waitUntil("guest") { h.store.mode == .guest }
        #expect(h.keychain.reads == 1)
        #expect(h.jar.cookies.isEmpty, "nothing may land in the persistent WebKit jar without a session")
        #expect(h.store.handles(.section(.liked)))
        #expect(h.transport.likedRequestCount == 0)
    }

    @Test func restoreSyncsKeychainCookiesIntoWebKitAndLoadsTheLibrary() async throws {
        defer { Self.cleanUp() }
        let h = try await Self.makeHarness(savedSession: Self.fakeLogin())
        await Self.waitUntil("live") { h.store.mode == .live }
        #expect(Set(h.jar.cookies.map(\.name)).isSuperset(of: ["SAPISID", "SID", "__Secure-1PSIDTS"]))
        await Self.waitUntil("liked loaded") { h.store.likedPhase == .loaded }
        let liked = h.model.catalog.liked.tracks ?? []
        #expect(!liked.isEmpty)
        #expect(h.model.player.likedTrackIDs == Set(liked.map(\.videoId)))
        // Pages that can't reach the (stub) network fail as offline instead of spinning forever.
        await Self.waitUntil("home settled") { h.store.homePhase.isSettled }
        #expect(h.store.homePhase == .failed(.offline))
    }

    /// Library › Uploads: signed in, every page streams in (privately owned); a guest gets the sign-in prompt and
    /// never sends a request for it.
    @Test func uploadsLoadSignedInOnly() async throws {
        defer { Self.cleanUp() }
        let guest = try await Self.makeHarness()
        await Self.waitUntil("guest") { guest.store.mode == .guest }
        #expect(QTLiveCatalogStore.isLibrary(.section(.uploads)) && guest.store.handles(.section(.uploads)))
        await guest.store.loadUploads(.songs)
        #expect(guest.store.uploadsPhase(.songs) == .idle && guest.transport.uploadRequestCount == 0)

        let h = try await Self.makeHarness(savedSession: Self.fakeLogin())
        await Self.waitUntil("live") { h.store.mode == .live }
        await h.store.loadUploads(.songs)
        #expect(h.store.uploadsPhase(.songs) == .loaded)
        #expect(h.store.uploads.songs.map(\.videoId) == ["upl0adVid01", "upl0adVid02", "upl0adVid03", "upl0adVid04"])
        #expect(h.store.uploads.songs.allSatisfy { $0.isPrivatelyOwned && !$0.hasVideo })
        #expect(h.transport.uploadRequestCount == 2)
        // Upload ids are ids, never names to search for.
        let album = QTUploads.albumPrefix + "b_po_fakeLanterns"
        let artist = QTUploads.artistPrefix + "a_po_fakeMara"
        #expect(h.store.albumID(for: album) == album && h.store.artistID(for: artist) == artist)
    }

    @Test func restoreFoldsFresherWebKitCookiesBackIntoTheKeychain() async throws {
        let h = try await Self.makeHarness(savedSession: Self.fakeLogin(psidts: "OLD-TS"),
                                           webCookies: Self.fakeLogin(psidts: "ROTATED-TS"))
        await Self.waitUntil("live") { h.store.mode == .live }
        let session = try #require(await h.store.auth.sessionStore.current)
        #expect(session.cookies.first { $0.name == "__Secure-1PSIDTS" }?.value == "ROTATED-TS")
        #expect(h.jar.cookies.filter { $0.name == "__Secure-1PSIDTS" }.map(\.value) == ["ROTATED-TS"])
        Self.cleanUp()
    }

    @Test func launchPlaybackRunsOnceAndNeverReplacesWhatIsPlaying() async throws {
        defer { Self.cleanUp() }
        let h = try await Self.makeHarness(savedSession: Self.fakeLogin())
        await Self.waitUntil("liked loaded") { h.store.likedPhase == .loaded }
        await Self.waitUntil("launch track") { h.model.player.nowPlaying != nil }
        let liked = h.model.catalog.liked.tracks ?? []
        #expect(h.model.player.nowPlaying?.videoId == liked.first?.videoId)
        #expect(h.model.player.isPlaying == false, "launch playback starts paused")
        // The user picks something else; reloading Liked must not put the launch track back.
        let other = try #require(liked.last)
        await h.model.player.play([other], startingAt: 0, autoplay: false)
        await h.store.loadLiked(force: true)
        await Self.waitUntil("liked reloaded") { h.store.likedPhase == .loaded }
        #expect(h.model.player.nowPlaying?.videoId == other.videoId)
    }

    @Test func signOutResetsToSignedOutAndClearsKeychainAndWebKit() async throws {
        defer { Self.cleanUp() }
        let h = try await Self.makeHarness(savedSession: Self.fakeLogin())
        await Self.waitUntil("liked loaded") { h.store.likedPhase == .loaded }
        await h.store.signOut()
        #expect(h.store.mode == .guest)
        #expect(h.store.likedPhase == .idle)
        #expect(h.model.catalog.liked.tracks == nil)
        #expect(h.model.player.likedTrackIDs.isEmpty)
        #expect(h.keychain.stored == nil)
        let googleLeft = h.jar.cookies.filter(\.isGoogleOrYouTube)
        #expect(googleLeft.isEmpty)
    }

    #if DEBUG
    @Test func guestThenSignInEntersLive() async throws {
        defer { Self.cleanUp() }
        let h = try await Self.makeHarness()
        await Self.waitUntil("guest") { h.store.mode == .guest }
        #expect(h.transport.likedRequestCount == 0, "guest mode never asks for the account's library")
        // A sign-in (the DEBUG import stands in for the Google window) takes the app to the live library.
        try await h.store.auth.importSession(cookies: Self.fakeLogin())
        await Self.waitUntil("live after sign-in") { h.store.mode == .live }
        await Self.waitUntil("liked loaded") { h.store.likedPhase == .loaded }
        #expect(!(h.model.catalog.liked.tracks ?? []).isEmpty)
    }

    @Test func signingInAgainAfterExpiryReloadsEveryPage() async throws {
        defer { Self.cleanUp() }
        let h = try await Self.makeHarness(savedSession: Self.fakeLogin())
        await Self.waitUntil("liked loaded") { h.store.likedPhase == .loaded }
        let before = h.transport.likedRequestCount
        // YouTube answers a signed-in request as signed out.
        await h.store.auth.sessionStore.sessionDidExpire()
        await Self.waitUntil("expired") { h.store.auth.state == .sessionExpired }
        // Expiry shows the signed-out screen ("Signed out of YouTube Music" + Sign In), not failing pages.
        await Self.waitUntil("guest mode after expiry") { h.store.mode == .guest }
        try await h.store.auth.importSession(cookies: Self.fakeLogin(psidts: "NEW-TS"))
        await Self.waitUntil("liked reloaded from the network") { h.transport.likedRequestCount > before }
        await Self.waitUntil("liked loaded") { h.store.likedPhase == .loaded }
        #expect(h.store.mode == .live)
    }
    #endif
}
