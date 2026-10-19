import Foundation
import Testing
@testable import QTInnerTube

/// Google's "unusual traffic" check answering instead of YouTube Music: typed as `.botCheck`, never retried, never a
/// lost session. Fake URLs and bodies only; nothing here touches the network.
@Suite struct BotCheckTests {
    static let sorry = URL(string: "https://www.google.com/sorry/index?continue=https://music.youtube.com/youtubei/v1/browse&q=FAKE")!

    /// Every request lands on the sorry page (what URLSession reports after following YouTube's redirect).
    final class SorryTransport: QTHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let status: Int
        let url: URL
        let body: Data
        init(status: Int = 429, url: URL = BotCheckTests.sorry,
             body: Data = Data("<html><body>Our systems have detected unusual traffic from your computer network.</body></html>".utf8)) {
            self.status = status
            self.url = url
            self.body = body
        }
        var requests: Int { lock.withLock { count } }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { count += 1 }
            return (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!)
        }
    }

    func client(_ transport: QTHTTPTransport) -> QTInnerTubeClient {
        QTInnerTubeClient(configuration: QTInnerTubeConfiguration(hl: "en", gl: "US"), transport: transport,
                          retry: QTRetryPolicy(maxAttempts: 3), scrapesClientConfig: false, sleep: { _ in })
    }

    @Test func detectsTheSorryPage() {
        #expect(QTInnerTubeError.isBotCheck(url: Self.sorry))
        #expect(QTInnerTubeError.isBotCheck(url: URL(string: "https://google.com/sorry/index")))
        #expect(QTInnerTubeError.isBotCheck(url: URL(string: "https://www.google.co.uk/sorry/index?continue=x")))
        #expect(!QTInnerTubeError.isBotCheck(url: URL(string: "https://music.youtube.com/watch?v=dQw4w9WgXcQ")))
        #expect(!QTInnerTubeError.isBotCheck(url: URL(string: "https://www.google.com/search?q=sorry")))
        #expect(!QTInnerTubeError.isBotCheck(url: URL(string: "https://notgoogle.example/sorry")))
        #expect(!QTInnerTubeError.isBotCheck(url: nil))
        // A captcha page under another URL, by its text; JSON never reads as one.
        #expect(QTInnerTubeError.isBotCheck(url: nil, body: Data("<form action=\"/sorry/index\"><div class=\"g-recaptcha\"></div></form>".utf8)))
        #expect(!QTInnerTubeError.isBotCheck(url: nil, body: Data(#"{"note":"unusual traffic from your computer network"}"#.utf8)))
    }

    @Test func aRedirectToTheSorryPageIsABotCheckAndIsNotRetried() async throws {
        let t = SorryTransport()
        await #expect(throws: QTInnerTubeError.botCheck) { try await client(t).explore() }
        #expect(t.requests == 1, "a bot check is not retried")
    }

    @Test func aCaptchaBodyIsABotCheckEvenWithoutTheRedirect() async throws {
        let t = SorryTransport(status: 200, url: URL(string: "https://music.youtube.com/youtubei/v1/search")!,
                               body: Data("<html><div class=\"g-recaptcha\"></div><a href=\"/sorry/index\">sorry</a></html>".utf8))
        await #expect(throws: QTInnerTubeError.botCheck) { try await client(t).search("Trú Mưa") }
    }

    @Test func isNeitherTransientNorConnectivity() {
        #expect(!QTInnerTubeError.botCheck.isTransient)
        #expect(!QTInnerTubeError.botCheck.isConnectivity)
    }
}
