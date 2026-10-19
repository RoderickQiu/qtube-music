import Foundation
import QTCore
import Testing
@testable import QTInnerTube

/// Records how often the client asked to sleep (retries) without sleeping.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []
    var delays: [TimeInterval] { lock.withLock { values } }
    func record(_ d: TimeInterval) { lock.withLock { values.append(d) } }
}

/// A credentials provider with fixed fake cookies.
actor FakeCredentials: QTInnerTubeCredentialsProvider {
    var value: QTInnerTubeCredentials?
    private(set) var expiredCalls = 0
    private(set) var rotated: [HTTPCookie] = []

    init(_ value: QTInnerTubeCredentials?) { self.value = value }

    func credentials() async -> QTInnerTubeCredentials? { value }
    func sessionDidExpire() async {
        expiredCalls += 1
        value = nil
    }
    func didReceive(cookies: [HTTPCookie]) async { rotated += cookies }
}

@Suite struct ClientTests {
    static let fakeCredentials = QTInnerTubeCredentials(
        cookieHeader: "SAPISID=FAKESAPISID123; SID=fake-sid", sapisid: "FAKESAPISID123", authUser: 1,
        onBehalfOfUser: "UCbrand0000000000000000")
    static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    func makeClient(_ transport: FakeTransport, credentials: (any QTInnerTubeCredentialsProvider)? = nil,
                    scrape: Bool = false, hl: String = "en", retry: QTRetryPolicy = .default,
                    sleeps: SleepRecorder = SleepRecorder()) -> QTInnerTubeClient {
        QTInnerTubeClient(configuration: QTInnerTubeConfiguration(hl: hl, gl: "VN"), transport: transport,
                          credentials: credentials, retry: retry, scrapesClientConfig: scrape,
                          sleep: { sleeps.record($0) }, now: { Self.fixedNow })
    }

    // MARK: Auth headers

    @Test func sapisidHashMatchesKnownVector() {
        // sha1("1700000000 FAKESAPISID123 https://music.youtube.com")
        #expect(QTSAPISIDHash.header(sapisid: "FAKESAPISID123", timestamp: 1_700_000_000)
            == "SAPISIDHASH 1700000000_2e06bc8020ea8de27f1b1575014766444af9c68b")
    }

    @Test func anonymousRequestShape() async throws {
        let t = FakeTransport()
        t.enqueue("browse", data: try Fixture.data("home-en"))
        let client = makeClient(t, hl: "zh-CN")
        _ = try await client.home()
        let r = try #require(t.recorded.last)
        #expect(r.httpMethod == "POST")
        #expect(r.url?.absoluteString.hasPrefix("https://music.youtube.com/youtubei/v1/browse?") == true)
        #expect(r.url?.query?.contains("prettyPrint=false") == true)
        #expect(r.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(r.value(forHTTPHeaderField: "Cookie") == "SOCS=CAI")
        #expect(r.value(forHTTPHeaderField: "Origin") == "https://music.youtube.com")
        #expect(r.value(forHTTPHeaderField: "X-YouTube-Client-Name") == "67")
        #expect(r.value(forHTTPHeaderField: "Accept-Language") == "zh-CN")
        let body = r.jsonBody
        #expect(body["browseId"].string == "FEmusic_home")
        #expect(body[path: "context", "client", "clientName"].string == "WEB_REMIX")
        #expect(body[path: "context", "client", "clientVersion"].string == "1.20251001.01.00")
        #expect(body[path: "context", "client", "hl"].string == "zh-CN")
        #expect(body[path: "context", "client", "gl"].string == "VN")
        // No delegated identity on signed-out requests.
        #expect(body[path: "context", "user", "onBehalfOfUser"].isNull)
    }

    @Test func authenticatedRequestShape() async throws {
        let t = FakeTransport()
        var signedIn = try Fixture.json("home-en")
        if case .object(var o) = signedIn {
            o["responseContext"] = ["serviceTrackingParams": [["service": "GFEEDBACK", "params": [["key": "logged_in", "value": "1"]]]]]
            signedIn = .object(o)
        }
        t.enqueue("browse", json: signedIn)
        let client = makeClient(t, credentials: FakeCredentials(Self.fakeCredentials))
        _ = try await client.home()
        let r = try #require(t.recorded.last)
        #expect(r.value(forHTTPHeaderField: "Authorization")
            == "SAPISIDHASH 1700000000_2e06bc8020ea8de27f1b1575014766444af9c68b")
        #expect(r.value(forHTTPHeaderField: "X-Goog-AuthUser") == "1")
        #expect(r.value(forHTTPHeaderField: "X-Origin") == "https://music.youtube.com")
        #expect(r.value(forHTTPHeaderField: "Cookie") == "SAPISID=FAKESAPISID123; SID=fake-sid")
        #expect(r.httpShouldHandleCookies == false)
        #expect(r.jsonBody[path: "context", "user", "onBehalfOfUser"].string == "UCbrand0000000000000000")
    }

    // MARK: Client config scrape

    @Test func scrapesYtcfg() async throws {
        let html = """
        <script>ytcfg.set({"INNERTUBE_API_KEY":"AIzaFAKEKEY","INNERTUBE_CLIENT_NAME":"WEB_REMIX",\
        "INNERTUBE_CLIENT_VERSION":"1.20261013.15.00","VISITOR_DATA":"CgtGQUtFVklTSVRPUg%3D%3D",\
        "INNERTUBE_CONTEXT_GL":"US"});</script>
        """
        let parsed = try #require(QTInnerTubeClientConfig.scrape(html: html, fallbackVersion: "1.0"))
        #expect(parsed.apiKey == "AIzaFAKEKEY")
        #expect(parsed.clientVersion == "1.20261013.15.00")
        #expect(parsed.visitorData == "CgtGQUtFVklTSVRPUg%3D%3D")
        #expect(parsed.gl == "US")

        let t = FakeTransport()
        t.enqueue("/", data: Data(html.utf8))
        t.enqueue("search", data: try Fixture.data("search-trumua-en"))
        let client = makeClient(t, scrape: true)
        _ = try await client.search("Trú Mưa")
        let api = try #require(t.recorded.last)
        #expect(api.url?.query?.contains("key=AIzaFAKEKEY") == true)
        #expect(api.value(forHTTPHeaderField: "X-YouTube-Client-Version") == "1.20261013.15.00")
        #expect(api.value(forHTTPHeaderField: "X-Goog-Visitor-Id") == "CgtGQUtFVklTSVRPUg%3D%3D")
        #expect(api.jsonBody[path: "context", "client", "visitorData"].string == "CgtGQUtFVklTSVRPUg%3D%3D")
        // The page was fetched once, without the user's cookies.
        let page = try #require(t.recorded.first)
        #expect(page.httpMethod == "GET")
        #expect(page.value(forHTTPHeaderField: "Cookie") == "SOCS=CAI")
    }

    @Test func scrapeFailureFallsBack() async throws {
        let t = FakeTransport()
        t.enqueue("/", status: 500, data: Data())
        let client = makeClient(t, scrape: true)
        let config = await client.clientConfig()
        #expect(!config.isScraped)
        #expect(config.clientVersion == "1.20251001.01.00")
        #expect(config.apiKey == nil)
    }

    // MARK: Cache

    @Test func cachesByBodyAndLanguage() async throws {
        let t = FakeTransport()
        t.enqueue("browse", data: try Fixture.data("home-en"))
        t.enqueue("browse", data: try Fixture.data("home-zh"))
        let client = makeClient(t)
        let a = try await client.home()
        let b = try await client.home()
        #expect(a == b)
        #expect(t.recorded.count == 1)
        await client.setLanguage(hl: "zh-CN")
        let c = try await client.home()
        #expect(t.recorded.count == 2)
        #expect(c.feed.shelves.first?.title == .verbatim("猜你喜欢"))
    }

    @Test func cacheEvictsLeastRecentlyUsed() {
        var cache = QTResponseCache(capacity: 2)
        let now = Date()
        cache.store("a", for: "a", ttl: 60, now: now)
        cache.store("b", for: "b", ttl: 60, now: now)
        _ = cache.value(for: "a", now: now)
        cache.store("c", for: "c", ttl: 60, now: now)
        #expect(cache.value(for: "b", now: now) == nil)
        #expect(cache.value(for: "a", now: now) == "a")
        #expect(cache.value(for: "c", now: now.addingTimeInterval(61)) == nil)
    }

    // MARK: Retries and errors

    @Test func retriesTransientFailures() async throws {
        let t = FakeTransport()
        t.enqueue("search", .failure(URLError(.networkConnectionLost)))
        t.enqueue("search", status: 503, data: Data(), headers: ["Retry-After": "2"])
        t.enqueue("search", data: try Fixture.data("search-trumua-songs-en"))
        let sleeps = SleepRecorder()
        let client = makeClient(t, sleeps: sleeps)
        let r = try await client.search("Trú Mưa", filter: .songs)
        #expect(!r.songs.isEmpty)
        #expect(t.recorded.count == 3)
        #expect(sleeps.delays.count == 2)
        #expect(sleeps.delays.last == 2)
        // Filter params go in decoded form.
        #expect(t.recorded.last?.jsonBody["params"].string == "EgWKAQIIAWoMEA4QChADEAQQCRAF")
    }

    @Test func givesUpAfterMaxAttempts() async throws {
        let t = FakeTransport()
        for _ in 0..<3 { t.enqueue("browse", .failure(URLError(.timedOut))) }
        let client = makeClient(t)
        await #expect(throws: QTInnerTubeError.network(code: URLError.Code.timedOut.rawValue)) {
            try await client.explore()
        }
        #expect(t.recorded.count == 3)
    }

    @Test func doesNotRetryClientErrors() async throws {
        let t = FakeTransport()
        t.enqueue("browse", status: 400, json: ["error": ["code": 400, "message": "Request contains an invalid argument."]])
        let client = makeClient(t)
        await #expect(throws: QTInnerTubeError.api(status: 400, message: "Request contains an invalid argument.")) {
            try await client.album("MPREb_bad")
        }
        #expect(t.recorded.count == 1)
    }

    @Test func invalidJSONIsTyped() async throws {
        let t = FakeTransport()
        t.enqueue("browse", data: Data("<html>".utf8))
        let client = makeClient(t)
        await #expect(throws: QTInnerTubeError.invalidResponse) { try await client.explore() }
    }

    // MARK: Session handling

    @Test func libraryNeedsASession() async throws {
        let t = FakeTransport()
        let client = makeClient(t)
        await #expect(throws: QTInnerTubeError.notSignedIn) { try await client.likedSongs() }
        await #expect(throws: QTInnerTubeError.notSignedIn) { try await client.libraryPlaylists() }
        #expect(t.recorded.isEmpty)
    }

    @Test func http401WithSessionMeansExpired() async throws {
        let t = FakeTransport()
        t.enqueue("browse", status: 401, data: Data())
        // …confirmed by the signed-in web client page (SessionLossTests covers the unconfirmed cases).
        t.enqueue("/", data: SessionLossTests.page(loggedIn: false))
        let creds = FakeCredentials(Self.fakeCredentials)
        let client = makeClient(t, credentials: creds)
        await #expect(throws: QTInnerTubeError.sessionExpired) { try await client.libraryPlaylists() }
        #expect(await creds.expiredCalls == 1)
    }

    @Test func signedOutAnswerToSignedInRequestMeansExpired() async throws {
        let t = FakeTransport()
        // A recorded anonymous response says logged_in = 0.
        t.enqueue("browse", data: try Fixture.data("home-en"))
        let creds = FakeCredentials(Self.fakeCredentials)
        let client = makeClient(t, credentials: creds)
        await #expect(throws: QTInnerTubeError.sessionExpired) { try await client.home() }
        #expect(await creds.expiredCalls == 1)
        // The provider dropped the credentials, so the next request is anonymous and succeeds.
        t.enqueue("browse", data: try Fixture.data("home-en"))
        let page = try await client.home()
        #expect(!page.feed.shelves.isEmpty)
        #expect(t.recorded.last?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func rotatedCookiesReachTheProvider() async throws {
        let t = FakeTransport()
        var signedIn = try Fixture.json("explore-en")
        if case .object(var o) = signedIn { o["responseContext"] = [:]; signedIn = .object(o) }
        t.enqueue("browse", json: signedIn, headers: [
            "Set-Cookie": "__Secure-1PSIDTS=rotated-fake; Domain=.youtube.com; Path=/; Secure; HttpOnly",
        ])
        let creds = FakeCredentials(Self.fakeCredentials)
        let client = makeClient(t, credentials: creds)
        _ = try await client.explore()
        let rotated = await creds.rotated
        #expect(rotated.map(\.name) == ["__Secure-1PSIDTS"])
    }

    @Test func accountWritesAreGated() async throws {
        let t = FakeTransport()
        let client = makeClient(t, credentials: FakeCredentials(Self.fakeCredentials))
        await #expect(throws: QTInnerTubeError.writesDisabled) { try await client.rate(videoId: "x", .like) }
        await #expect(throws: QTInnerTubeError.writesDisabled) { try await client.addToPlaylist("PLx", videoIds: ["x"]) }
        #expect(t.recorded.isEmpty)
        // When enabled (only with the user's consent) the request shape is right — against a fake transport.
        await client.setAllowsAccountWrites(true)
        t.enqueue("like/like", json: [:])
        try await client.rate(videoId: "AeXLsAPORb4", .like)
        let r = try #require(t.recorded.last)
        #expect(r.url?.path.hasSuffix("/like/like") == true)
        #expect(r.jsonBody[path: "target", "videoId"].string == "AeXLsAPORb4")
        t.enqueue("browse/edit_playlist", json: [:])
        try await client.removeFromPlaylist("VLPLx", items: [(videoId: "v1", setVideoId: "s1")])
        let edit = try #require(t.recorded.last?.jsonBody)
        #expect(edit["playlistId"].string == "PLx")
        #expect(edit["actions"][0]["action"].string == "ACTION_REMOVE_VIDEO")
        #expect(edit["actions"][0]["setVideoId"].string == "s1")
    }

    // MARK: High-level calls

    @Test func continuationsUseTheBody() async throws {
        let t = FakeTransport()
        t.enqueue("browse", data: try Fixture.data("playlist-classic-rock-en"))
        t.enqueue("browse", data: try Fixture.data("playlist-classic-rock-continuation-en"))
        t.enqueue("browse", data: Data(#"{"onResponseReceivedActions":[]}"#.utf8))
        let client = makeClient(t)
        let playlist = try await client.playlistAllTracks("PL0GvsLQil0MmYC96KEs_7dTNsLm1PS6JX")
        #expect(t.recorded.first?.jsonBody["browseId"].string == "VLPL0GvsLQil0MmYC96KEs_7dTNsLm1PS6JX")
        #expect(t.recorded[1].jsonBody["continuation"].string?.isEmpty == false)
        #expect((playlist.tracks?.count ?? 0) > 6)
    }

    @Test func nextRequestShape() async throws {
        let t = FakeTransport()
        t.enqueue("next", data: try Fixture.data("next-radio-trumua-en"))
        let client = makeClient(t)
        let n = try await client.next(videoId: "AeXLsAPORb4", playlistId: "VLRDAMVMAeXLsAPORb4")
        #expect(n.tracks.count > 1)
        let body = try #require(t.recorded.last?.jsonBody)
        #expect(body["videoId"].string == "AeXLsAPORb4")
        #expect(body["playlistId"].string == "RDAMVMAeXLsAPORb4")
        #expect(body["isAudioOnly"].bool == true)
    }

    @Test func catalogServiceFoldsHomePages() async throws {
        let t = FakeTransport()
        t.enqueue("browse", data: try Fixture.data("home-en"))
        t.enqueue("browse", data: try Fixture.data("home-continuation-en"))
        t.enqueue("browse", data: try Fixture.data("home-continuation-podcasts-en"))
        let catalog = QTInnerTubeCatalog(client: makeClient(t), homePages: 3)
        let feed = try await catalog.homeFeed()
        #expect(feed.shelves.count >= 4)
        #expect(!feed.moods.isEmpty)
        await #expect(throws: QTInnerTubeError.notSignedIn) { try await catalog.likedSongs() }
    }
}
