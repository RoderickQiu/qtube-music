import CryptoKit
import Foundation
import Testing
@testable import QTIntegrations

/// Request building, signing, scrobble rules, offline queue and Discord IPC framing — no network, no real accounts.
@Suite struct QTLastFMRequestTests {
    static let creds = QTLastFMCredentials(apiKey: "testkey", apiSecret: "testsecret")

    static func form(_ request: URLRequest) -> [String: String] {
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        var out: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    @Test func signatureIsMD5OfSortedParamsPlusSecretWithoutFormat() {
        let params = ["method": "auth.getSession", "token": "abc", "api_key": "testkey", "format": "json"]
        let expected = Insecure.MD5.hash(data: Data("api_keytestkeymethodauth.getSessiontokenabctestsecret".utf8))
            .map { String(format: "%02x", $0) }.joined()
        #expect(QTLastFMRequest.signature(params, secret: "testsecret") == expected)
    }

    @Test func signedRequestCarriesKeySessionSignatureAndJSONFormat() {
        let s = QTScrobble(artist: "Hoàng Dũng", track: "Nàng Thơ & Me", album: "25", duration: 254, timestamp: 1_760_000_000)
        let request = QTLastFMRequest.updateNowPlaying(s, Self.creds, sessionKey: "SK")
        #expect(request.httpMethod == "POST")
        #expect(request.url == QTLastFMRequest.endpoint)
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/x-www-form-urlencoded") == true)
        let f = Self.form(request)
        #expect(f["method"] == "track.updateNowPlaying")
        #expect(f["artist"] == "Hoàng Dũng")
        #expect(f["track"] == "Nàng Thơ & Me", "& and non-ASCII survive form encoding")
        #expect(f["duration"] == "254")
        #expect(f["sk"] == "SK")
        #expect(f["format"] == "json")
        var unsigned = f
        unsigned["api_sig"] = nil
        #expect(f["api_sig"] == QTLastFMRequest.signature(unsigned, secret: "testsecret"))
        // Raw body never has a bare "&" inside a value or a "+" for spaces.
        let body = String(data: request.httpBody!, encoding: .utf8)!
        #expect(body.contains("track=N%C3%A0ng%20Th%C6%A1%20%26%20Me"))
    }

    @Test func scrobbleBatchIsIndexedAndCappedAtFifty() {
        let plays = (0..<60).map { QTScrobble(artist: "A\($0)", track: "T\($0)", duration: 200, timestamp: 1_760_000_000 + $0) }
        let f = Self.form(QTLastFMRequest.scrobble(plays, Self.creds, sessionKey: "SK"))
        #expect(f["artist[0]"] == "A0")
        #expect(f["timestamp[49]"] == "1760000049")
        #expect(f["artist[50]"] == nil)
        #expect(f["method"] == "track.scrobble")
    }

    @Test func authorizeURLAndResponses() throws {
        let url = QTLastFMRequest.authorizeURL(apiKey: "k", token: "t")
        #expect(url.absoluteString == "https://www.last.fm/api/auth/?api_key=k&token=t")
        let ok = HTTPURLResponse(url: QTLastFMRequest.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let session = try QTLastFMRequest.session(from: QTLastFMRequest.check(
            Data(#"{"session":{"name":"rj","key":"d580d57f32848f5dcf574d1ce18d78b2","subscriber":0}}"#.utf8), ok))
        #expect(session == QTLastFMSession(name: "rj", key: "d580d57f32848f5dcf574d1ce18d78b2"))
        let bad = HTTPURLResponse(url: QTLastFMRequest.endpoint, statusCode: 403, httpVersion: nil, headerFields: nil)!
        #expect(throws: QTLastFMError.api(code: 9, message: "Invalid session key")) {
            try QTLastFMRequest.check(Data(#"{"error":9,"message":"Invalid session key"}"#.utf8), bad)
        }
        #expect(QTLastFMError.api(code: 29, message: "").isTemporary)
        #expect(QTLastFMError.api(code: 9, message: "").isInvalidSession)
        #expect(!QTLastFMError.api(code: 6, message: "").isTemporary)
    }
}

@Suite struct QTScrobbleRuleTests {
    @Test func thresholdIsHalfOrFourMinutes() {
        #expect(!QTScrobbleRules.isEligible(duration: 30))
        #expect(QTScrobbleRules.isEligible(duration: 31))
        #expect(QTScrobbleRules.threshold(duration: 200) == 100)
        #expect(QTScrobbleRules.threshold(duration: 600) == 240)
        #expect(!QTScrobbleRules.shouldScrobble(duration: 200, listened: 99))
        #expect(QTScrobbleRules.shouldScrobble(duration: 200, listened: 100))
        #expect(!QTScrobbleRules.shouldScrobble(duration: 20, listened: 20))
    }

    @Test func pausesDontCountAndATrackScrobblesOnce() {
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        var tracker = QTListenTracker()
        let play = QTScrobble(artist: "A", track: "T", duration: 200, timestamp: Int(t0.timeIntervalSince1970))
        tracker.start(play, playing: true, at: t0)
        tracker.setPlaying(false, at: t0.addingTimeInterval(60)) // 60 s listened
        // Paused for ten minutes: still 60 s.
        #expect(tracker.scrobbleIfDue(at: t0.addingTimeInterval(660)) == nil)
        tracker.setPlaying(true, at: t0.addingTimeInterval(660))
        #expect(tracker.scrobbleIfDue(at: t0.addingTimeInterval(699)) == nil) // 99 s
        #expect(tracker.scrobbleIfDue(at: t0.addingTimeInterval(700)) == play) // 100 s
        #expect(tracker.scrobbleIfDue(at: t0.addingTimeInterval(800)) == nil, "once per play")
    }
}

/// Records Last.fm requests; fails with a chosen error while `failing` is set.
final class QTRecordingLastFM: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [[String: String]] = []
    var failure: QTLastFMError?
    var requests: [[String: String]] { lock.withLock { _requests } }

    var transport: QTLastFMClient.Transport {
        { [self] request in
            let f = QTLastFMRequestTests.form(request)
            let failure: QTLastFMError? = lock.withLock {
                _requests.append(f)
                return self.failure
            }
            if let failure {
                if case .network = failure { throw URLError(.notConnectedToInternet) }
                if case .api(let code, let message) = failure {
                    let body = try JSONSerialization.data(withJSONObject: ["error": code, "message": message])
                    return (body, HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
                }
            }
            return (Data(#"{"scrobbles":{"@attr":{"accepted":1,"ignored":0}}}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
}

final class QTTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    init(_ t: Date) { self.t = t }
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
}

@Suite struct QTScrobblerTests {
    static let creds = QTLastFMCredentials(apiKey: "testkey", apiSecret: "testsecret")

    @Test func nowPlayingThenScrobbleAtThreshold() async {
        let clock = QTTestClock(Date(timeIntervalSince1970: 1_760_000_000))
        let lastfm = QTRecordingLastFM()
        let scrobbler = QTScrobbler(queueURL: nil, now: { clock.now })
        await scrobbler.configure(client: QTLastFMClient(credentials: Self.creds, transport: lastfm.transport), sessionKey: "SK")
        let play = QTScrobble(artist: "A", track: "T", duration: 200, timestamp: 1_760_000_000)
        await scrobbler.trackChanged(to: play, playing: true)
        #expect(lastfm.requests.map { $0["method"] } == ["track.updateNowPlaying"])
        clock.advance(99)
        await scrobbler.tick()
        #expect(lastfm.requests.count == 1)
        clock.advance(1)
        await scrobbler.tick()
        #expect(lastfm.requests.last?["method"] == "track.scrobble")
        #expect(lastfm.requests.last?["timestamp[0]"] == "1760000000")
        #expect(await scrobbler.queue.items.isEmpty)
    }

    @Test func offlinePlaysWaitInTheQueueAndSurviveRelaunch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qt-scrobbles-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = QTTestClock(Date(timeIntervalSince1970: 1_760_000_000))
        let lastfm = QTRecordingLastFM()
        lastfm.failure = .network
        let scrobbler = QTScrobbler(queueURL: url, now: { clock.now })
        await scrobbler.configure(client: QTLastFMClient(credentials: Self.creds, transport: lastfm.transport), sessionKey: "SK",
                                  sendsNowPlaying: false)
        await scrobbler.trackChanged(to: QTScrobble(artist: "A", track: "One", duration: 100, timestamp: 1_760_000_000), playing: true)
        clock.advance(60)
        await scrobbler.trackChanged(to: QTScrobble(artist: "A", track: "Two", duration: 100, timestamp: 1_760_000_060), playing: true)
        #expect(await scrobbler.queue.items.map(\.track) == ["One"])

        // Relaunch: the queue is read back and sent once Last.fm answers.
        lastfm.failure = nil
        let relaunched = QTScrobbler(queueURL: url, now: { clock.now })
        #expect(await relaunched.queue.items.map(\.track) == ["One"])
        await relaunched.configure(client: QTLastFMClient(credentials: Self.creds, transport: lastfm.transport), sessionKey: "SK")
        await relaunched.flush()
        #expect(await relaunched.queue.items.isEmpty)
        #expect(lastfm.requests.last?["track[0]"] == "One")
    }

    @Test func invalidSessionStopsSendingAndTellsTheApp() async {
        let lastfm = QTRecordingLastFM()
        lastfm.failure = .api(code: 9, message: "Invalid session key")
        let flag = QTTestFlag()
        let scrobbler = QTScrobbler(queueURL: nil)
        await scrobbler.configure(client: QTLastFMClient(credentials: Self.creds, transport: lastfm.transport), sessionKey: "SK",
                                  onInvalidSession: { flag.set() })
        await scrobbler.trackChanged(to: QTScrobble(artist: "A", track: "T", duration: 200, timestamp: 1), playing: true)
        #expect(flag.isSet)
        #expect(await !scrobbler.isActive)
    }

    @Test func inactiveScrobblerSendsNothing() async {
        let scrobbler = QTScrobbler(queueURL: nil)
        await scrobbler.trackChanged(to: QTScrobble(artist: "A", track: "T", duration: 200, timestamp: 1), playing: true)
        #expect(await !scrobbler.isActive)
    }

    @Test func oldPlaysArePrunedBeforeSending() {
        var q = QTScrobbleQueue(fileURL: nil)
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        q.append(QTScrobble(artist: "A", track: "Old", timestamp: Int(now.timeIntervalSince1970) - 15 * 86_400))
        q.append(QTScrobble(artist: "A", track: "New", timestamp: Int(now.timeIntervalSince1970) - 3600))
        q.pruneExpired(now: now)
        #expect(q.items.map(\.track) == ["New"])
    }
}

final class QTTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

@Suite struct QTDiscordIPCTests {
    @Test func framesAreLittleEndianOpcodeLengthJSON() throws {
        let frame = try QTDiscordIPC.handshake(clientID: "123456789012345678")
        #expect(Array(frame.prefix(4)) == [0, 0, 0, 0])
        let length = Int(frame[4]) | Int(frame[5]) << 8 | Int(frame[6]) << 16 | Int(frame[7]) << 24
        #expect(length == frame.count - 8)
        let decoded = try #require(QTDiscordIPC.decode(frame))
        #expect(decoded.opcode == 0)
        #expect(decoded.consumed == frame.count)
        let json = try JSONSerialization.jsonObject(with: decoded.payload) as? [String: Any]
        #expect(json?["v"] as? Int == 1)
        #expect(json?["client_id"] as? String == "123456789012345678")
        // Incomplete frames wait for more bytes.
        #expect(QTDiscordIPC.decode(frame.prefix(frame.count - 1)) == nil)
        #expect(QTDiscordIPC.decode(Data([1, 0, 0])) == nil)
    }

    @Test func twoFramesInOneBufferDecodeInOrder() throws {
        let a = QTDiscordIPC.encode(.frame, payload: Data("{\"a\":1}".utf8))
        let b = QTDiscordIPC.encode(.pong, payload: Data("{}".utf8))
        let buffer = a + b
        let first = try #require(QTDiscordIPC.decode(buffer))
        #expect(first.opcode == 1)
        let second = try #require(QTDiscordIPC.decode(buffer.dropFirst(first.consumed)))
        #expect(second.opcode == 4)
        #expect(second.payload == Data("{}".utf8))
    }

    @Test func setActivityShowsListeningWithTimestampsAndArtwork() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let track = QTDiscordTrack(title: "Đối Với Anh", artist: "Hoàng Dũng", album: "25",
                                   artworkURL: URL(string: "https://lh3.googleusercontent.com/abc=w544-h544"),
                                   link: URL(string: "https://music.youtube.com/watch?v=abc"),
                                   duration: 240, elapsed: 40, isPlaying: true)
        let activity = QTDiscordActivity.payload(for: track, now: now, buttonTitle: "Open in YouTube Music")
        #expect(activity["type"] as? Int == 2)
        #expect(activity["details"] as? String == "Đối Với Anh")
        #expect(activity["state"] as? String == "Hoàng Dũng")
        let ts = try #require(activity["timestamps"] as? [String: Int])
        #expect(ts["start"] == 1_759_999_960_000)
        #expect(ts["end"] == 1_760_000_200_000)
        let assets = try #require(activity["assets"] as? [String: Any])
        #expect(assets["large_image"] as? String == "https://lh3.googleusercontent.com/abc=w544-h544")
        #expect(assets["large_text"] as? String == "25")
        let frame = try QTDiscordIPC.setActivity(activity, pid: 42, nonce: "n1")
        let decoded = try #require(QTDiscordIPC.decode(frame))
        #expect(decoded.opcode == 1)
        let json = try #require(JSONSerialization.jsonObject(with: decoded.payload) as? [String: Any])
        #expect(json["cmd"] as? String == "SET_ACTIVITY")
        #expect(json["nonce"] as? String == "n1")
        #expect((json["args"] as? [String: Any])?["pid"] as? Int == 42)

        // Paused: no timestamps. Clearing: activity null.
        var paused = track
        paused.isPlaying = false
        #expect(QTDiscordActivity.payload(for: paused, now: now)["timestamps"] == nil)
        let clear = try #require(QTDiscordIPC.decode(try QTDiscordIPC.setActivity(nil, pid: 42, nonce: "n2")))
        let clearJSON = try #require(JSONSerialization.jsonObject(with: clear.payload) as? [String: Any])
        #expect((clearJSON["args"] as? [String: Any])?["activity"] is NSNull)
    }

    @Test func stringsAreClampedToDiscordLimits() {
        #expect(QTDiscordActivity.clamp("A").count == 2)
        #expect(QTDiscordActivity.clamp(String(repeating: "x", count: 300)).count == 128)
    }

    @Test func socketPathsFollowDiscordsSearchOrder() {
        let paths = QTDiscordIPC.socketPaths(environment: ["TMPDIR": "/var/folders/xy/T/"])
        #expect(paths.first == "/var/folders/xy/T/discord-ipc-0")
        #expect(paths.contains("/tmp/discord-ipc-9"))
        #expect(paths.count == 20)
    }

    @Test func noDiscordRunningMeansNoPresenceAndNoCrash() async {
        let presence = QTDiscordPresence(paths: ["/tmp/qt-no-such-discord-ipc-\(UUID().uuidString)"])
        let shown = await presence.update(clientID: "123456789012345678", track: nil)
        #expect(!shown)
        #expect(await !presence.isConnected)
    }

    @Test func clientIDValidation() {
        var p = QTDiscordPrefs()
        p.clientID = "123456789012345678"
        #expect(p.hasValidClientID)
        p.clientID = "12345"
        #expect(!p.hasValidClientID)
        p.clientID = "12345678901234567a"
        #expect(!p.hasValidClientID)
    }
}

@MainActor
@Suite struct QTIntegrationsStoreTests {
    @Test func everythingIsOffByDefaultAndSecretsStayOutOfDefaults() throws {
        let suite = "qt.tests.integrations.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = QTMemorySecretStore()
        let store = QTIntegrationsStore(defaults: defaults, secrets: secrets)
        #expect(!store.settings.lastFM.isEnabled)
        #expect(!store.settings.discord.isEnabled)
        #expect(!store.settings.notifiesTrackChanges)
        #expect(store.lastFMCredentials() == nil)

        store.update { $0.lastFM.apiKey = "key" }
        store.setLastFMSecret("  secret  ")
        #expect(store.lastFMCredentials() == QTLastFMCredentials(apiKey: "key", apiSecret: "secret"))
        store.connectLastFM(session: QTLastFMSession(name: "rj", key: "SESSIONKEY"))
        #expect(store.lastFMSessionKey == "SESSIONKEY")
        #expect(store.settings.lastFM.isEnabled)

        let saved = String(data: defaults.data(forKey: QTIntegrationsStore.defaultsKey) ?? Data(), encoding: .utf8) ?? ""
        #expect(!saved.contains("secret") && !saved.contains("SESSIONKEY"), "secrets live in the Keychain only")
        #expect(QTIntegrationsStore(defaults: defaults, secrets: secrets).settings.lastFM.username == "rj")

        store.disconnectLastFM()
        #expect(store.lastFMSessionKey == nil)
        #expect(secrets.get(.lastFMSessionKey) == nil)
        #expect(!store.settings.lastFM.isEnabled)
    }
}
