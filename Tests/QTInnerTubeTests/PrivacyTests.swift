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

    @Test func anonymousIdentityRefusesSignedInOnlyEndpoints() async throws {
        let client = makeClient(FakeTransport())
        await #expect(throws: QTInnerTubeError.notSignedIn) {
            _ = try await client.send("browse", body: ["browseId": "FEmusic_liked_videos"], identity: .anonymous)
        }
    }
}
