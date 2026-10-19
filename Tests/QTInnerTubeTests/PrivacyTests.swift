import Foundation
import QTCore
import Testing
@testable import QTInnerTube

/// Which automatic requests carry the session (docs/architecture.md › Signed-in requests). Searches never do:
/// YouTube Music keeps signed-in searches in the account's search history.
@Suite struct QTRequestIdentityTests {
    func makeClient(_ transport: FakeTransport) -> QTInnerTubeClient {
        QTInnerTubeClient(configuration: QTInnerTubeConfiguration(hl: "en", gl: "US"), transport: transport,
                          credentials: FakeCredentials(ClientTests.fakeCredentials), scrapesClientConfig: false,
                          sleep: { _ in }, now: { ClientTests.fixedNow })
    }

    func isSignedIn(_ r: URLRequest) -> Bool {
        r.value(forHTTPHeaderField: "Authorization") != nil || r.value(forHTTPHeaderField: "Cookie") != "SOCS=CAI"
            || r.value(forHTTPHeaderField: "X-Goog-AuthUser") != nil || !r.jsonBody[path: "context", "user", "onBehalfOfUser"].isNull
    }

    @Test func counterpartSearchFallbackIsAnonymousWhileNextKeepsTheSession() async throws {
        let t = FakeTransport()
        t.enqueue("next", json: [:])    // no counterpart in the answer → falls back to search
        t.enqueue("search", json: [:])
        let client = makeClient(t)
        let track = QTTrack(videoId: "abcdefghijk", title: "Perfect", artists: [QTArtistRef(name: "Ed Sheeran")],
                            duration: 263, musicVideoType: .atv)
        _ = try await client.counterpart(for: track)
        let requests = t.recorded
        let next = try #require(requests.first { $0.url?.path.hasSuffix("next") == true })
        let search = try #require(requests.first { $0.url?.path.hasSuffix("search") == true })
        #expect(isSignedIn(next))
        #expect(!isSignedIn(search))
        #expect(search.jsonBody["query"].string == "Perfect Ed Sheeran")
    }

    @Test func searchesAreAnonymousUnlessTheCallerAsksForTheSession() async throws {
        let t = FakeTransport()
        t.enqueue("search", json: [:])
        t.enqueue("search", json: [:])
        let client = makeClient(t)
        _ = try await client.search("hello")
        _ = try await client.search("hello again", identity: .session)
        let requests = t.recorded
        #expect(requests.count == 2)
        #expect(!isSignedIn(requests[0]))
        #expect(isSignedIn(requests[1]))
    }

    @Test func anonymousRequestsNeverSendTheSignedInVisitorID() async throws {
        let t = FakeTransport()
        t.enqueue("browse", json: ["responseContext": ["visitorData": "SIGNED-IN-VISITOR"]])
        t.enqueue("search", json: [:])
        let client = makeClient(t)
        _ = try? await client.home()
        _ = try await client.search("x")
        let search = try #require(t.recorded.last)
        #expect(search.value(forHTTPHeaderField: "X-Goog-Visitor-Id") == nil)
        #expect(search.jsonBody[path: "context", "client", "visitorData"].isNull)
    }

    /// With the real `ytcfg` scrape: the signed-out page's visitor id goes only on anonymous requests, the one
    /// signed-in answers give only on signed-in ones — the two are never mixed, so Google can't tie an "anonymous"
    /// search to the account through a shared X-Goog-Visitor-Id.
    @Test func anonymousAndSignedInRequestsKeepSeparateVisitorIDsWithTheScrapeOn() async throws {
        let html = """
        <script>ytcfg.set({"INNERTUBE_API_KEY":"AIzaFAKEKEY","INNERTUBE_CLIENT_VERSION":"1.20261013.15.00",\
        "VISITOR_DATA":"ANON-SCRAPED-VISITOR"});</script>
        """
        let t = FakeTransport()
        t.enqueue("/", data: Data(html.utf8))
        t.enqueue("browse", json: ["responseContext": ["visitorData": "SIGNED-IN-VISITOR"]])
        t.enqueue("browse", json: [:])
        t.enqueue("search", json: ["responseContext": ["visitorData": "OTHER-ANON-VISITOR"]])
        t.enqueue("search", json: [:])
        let client = QTInnerTubeClient(configuration: QTInnerTubeConfiguration(hl: "en", gl: "US"), transport: t,
                                       credentials: FakeCredentials(ClientTests.fakeCredentials), scrapesClientConfig: true,
                                       sleep: { _ in }, now: { ClientTests.fixedNow })
        _ = try await client.send("browse", body: ["browseId": "FEmusic_home"])  // first signed-in request: no visitor id yet
        _ = try await client.send("browse", body: ["browseId": "FEmusic_home"])  // later: the signed-in answer's id
        _ = try await client.search("x")      // anonymous: the scraped signed-out id
        _ = try await client.search("y")
        let api = t.recorded.filter { $0.httpMethod == "POST" }
        #expect(api.count == 4)
        func visitor(_ r: URLRequest) -> String? { r.value(forHTTPHeaderField: "X-Goog-Visitor-Id") }
        func bodyVisitor(_ r: URLRequest) -> String? { r.jsonBody[path: "context", "client", "visitorData"].string }
        #expect(isSignedIn(api[0]) && visitor(api[0]) == nil && bodyVisitor(api[0]) == nil)
        #expect(isSignedIn(api[1]) && visitor(api[1]) == "SIGNED-IN-VISITOR" && bodyVisitor(api[1]) == "SIGNED-IN-VISITOR")
        for search in api.dropFirst(2) {
            #expect(!isSignedIn(search))
            #expect(visitor(search) == "ANON-SCRAPED-VISITOR" && bodyVisitor(search) == "ANON-SCRAPED-VISITOR")
        }
        // No request ever carried the other identity's id.
        for r in api where isSignedIn(r) { #expect(visitor(r) != "ANON-SCRAPED-VISITOR") }
        for r in api where !isSignedIn(r) { #expect(visitor(r) != "SIGNED-IN-VISITOR") }
    }

    /// A new session (sign-in, account switch) never inherits the previous account's visitor id.
    @Test func changingTheSessionDropsTheSignedInVisitorID() async throws {
        let t = FakeTransport()
        t.enqueue("browse", json: ["responseContext": ["visitorData": "ACCOUNT-A-VISITOR"]])
        t.enqueue("browse", json: [:])
        let client = makeClient(t)
        _ = try? await client.home()
        await client.setCredentialsProvider(FakeCredentials(ClientTests.fakeCredentials))
        _ = try? await client.home()
        let last = try #require(t.recorded.last)
        #expect(last.value(forHTTPHeaderField: "X-Goog-Visitor-Id") == nil)
    }

    @Test func anonymousIdentityRefusesSignedInOnlyEndpoints() async throws {
        let client = makeClient(FakeTransport())
        await #expect(throws: QTInnerTubeError.notSignedIn) {
            _ = try await client.send("browse", body: ["browseId": "FEmusic_liked_videos"], identity: .anonymous)
        }
    }
}
