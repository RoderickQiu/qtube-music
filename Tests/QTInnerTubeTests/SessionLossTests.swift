import Foundation
import Testing
@testable import QTInnerTube

/// 401/403 on a signed-in request only expires the session when the signed-in web client confirms the login is gone.
@Suite struct SessionLossTests {
    func makeClient(_ transport: FakeTransport, credentials: FakeCredentials) -> QTInnerTubeClient {
        QTInnerTubeClient(configuration: QTInnerTubeConfiguration(hl: "en", gl: "US"), transport: transport,
                          credentials: credentials, retry: QTRetryPolicy(maxAttempts: 1), scrapesClientConfig: false,
                          sleep: { _ in }, now: { ClientTests.fixedNow })
    }

    static func page(loggedIn: Bool) -> Data {
        Data(#"<script>ytcfg.set({"LOGGED_IN": \#(loggedIn), "IS_SUBSCRIBER": true});</script>"#.utf8)
    }

    @Test func forbiddenWithAStillSignedInPageIsJustAnHTTPError() async throws {
        let t = FakeTransport()
        t.enqueue("next", status: 403, data: Data())
        t.enqueue("/", data: Self.page(loggedIn: true))
        let creds = FakeCredentials(ClientTests.fakeCredentials)
        let client = makeClient(t, credentials: creds)
        await #expect(throws: QTInnerTubeError.http(status: 403)) { try await client.next(videoId: "dQw4w9WgXcQ") }
        #expect(await creds.expiredCalls == 0)
        #expect(await creds.credentials() != nil)
        // The probe was a signed-in GET of the web client.
        let probe = try #require(t.recorded.last)
        #expect(probe.httpMethod == "GET" && probe.url?.host == "music.youtube.com")
        #expect(probe.value(forHTTPHeaderField: "Cookie")?.contains("SAPISID=") == true)
    }

    @Test func refusalAndAProbeThatFailsKeepsTheSession() async throws {
        let t = FakeTransport()
        t.enqueue("browse", status: 401, data: Data())
        t.enqueue("/", status: 503, data: Data())
        let creds = FakeCredentials(ClientTests.fakeCredentials)
        let client = makeClient(t, credentials: creds)
        await #expect(throws: QTInnerTubeError.http(status: 401)) { try await client.libraryPlaylists() }
        #expect(await creds.expiredCalls == 0)
    }

    @Test func confirmedLossExpiresAndBurstsShareOneProbe() async throws {
        let t = FakeTransport()
        t.enqueue("browse", status: 403, data: Data())
        t.enqueue("next", status: 403, data: Data())
        t.enqueue("/", data: Self.page(loggedIn: false))
        let creds = FakeCredentials(ClientTests.fakeCredentials)
        let client = makeClient(t, credentials: creds)
        await #expect(throws: QTInnerTubeError.sessionExpired) { try await client.libraryPlaylists() }
        #expect(await creds.expiredCalls == 1)
        // A second refusal within the probe's lifetime reuses the answer (no second page request).
        await creds.restore(ClientTests.fakeCredentials)
        await #expect(throws: QTInnerTubeError.sessionExpired) { try await client.next(videoId: "dQw4w9WgXcQ") }
        #expect(t.recorded.filter { $0.httpMethod == "GET" }.count == 1)
    }

    @Test func connectivityAndCancellationAreTold() {
        #expect(QTInnerTubeError.network(code: URLError.Code.notConnectedToInternet.rawValue).isConnectivity)
        #expect(QTInnerTubeError.network(code: URLError.Code.timedOut.rawValue).isConnectivity)
        #expect(!QTInnerTubeError.network(code: URLError.Code.secureConnectionFailed.rawValue).isConnectivity)
        #expect(!QTInnerTubeError.network(code: URLError.Code.badServerResponse.rawValue).isConnectivity)
        #expect(!QTInnerTubeError.network(code: URLError.Code.cancelled.rawValue).isConnectivity)
        #expect(QTInnerTubeError.network(code: URLError.Code.cancelled.rawValue).isCancellation)
        #expect(!QTInnerTubeError.http(status: 403).isConnectivity)
    }
}

extension FakeCredentials {
    func restore(_ value: QTInnerTubeCredentials) { self.value = value }
}
