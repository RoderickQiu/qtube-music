import Foundation
import Testing
@testable import QTIntegrations

/// ListenBrainz payloads, client, error handling, and the scrobbler fanning one listen out to Last.fm and
/// ListenBrainz — stub transports only, never the network.

/// Records ListenBrainz requests and answers them (200 `{"status":"ok"}` unless `respond` says otherwise).
final class QTRecordingListenBrainz: @unchecked Sendable {
    struct Request {
        var url: URL
        var method: String
        var authorization: String?
        var listenType: String?
        var tracks: [String]
    }

    private let lock = NSLock()
    private var _requests: [Request] = []
    /// (status, headers, body) for a request, or nil for the default 200.
    var respond: (@Sendable (Request) -> (Int, [String: String], String)?)?
    var requests: [Request] { lock.withLock { _requests } }
    private var _accepted: [String] = []
    /// Tracks of the listens it accepted (single / import, not playing_now).
    var accepted: [String] { lock.withLock { _accepted } }

    var transport: QTListenBrainzClient.Transport {
        { [self] request in
            let json = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let payload = json?["payload"] as? [[String: Any]] ?? []
            let tracks = payload.compactMap { ($0["track_metadata"] as? [String: Any])?["track_name"] as? String }
            let r = Request(url: request.url!, method: request.httpMethod ?? "GET",
                            authorization: request.value(forHTTPHeaderField: "Authorization"),
                            listenType: json?["listen_type"] as? String, tracks: tracks)
            let answer = respond?(r)
            lock.withLock {
                _requests.append(r)
                if answer == nil || (200..<300).contains(answer!.0), r.listenType == "single" || r.listenType == "import" {
                    _accepted += tracks
                }
            }
            let (status, headers, body) = answer ?? (200, [:], #"{"status":"ok"}"#)
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
    }

    func client(token: String = "TOKEN", server: URL = QTListenBrainzRequest.defaultServer) -> QTListenBrainzClient {
        QTListenBrainzClient(token: token, server: server, version: "1.2.3", pacer: QTRequestPacer(interval: 0), transport: transport)
    }

    func service() -> QTListenBrainzScrobbleService { QTListenBrainzScrobbleService(client: client()) }
}

@Suite struct QTListenBrainzRequestTests {
    static let play = QTScrobble(artist: "Hoàng Dũng", track: "Nàng Thơ", album: "25", duration: 254, timestamp: 1_760_000_000,
                                 videoId: "abc123XYZ_-", durationMs: 254_321)

    static func object(_ data: Data) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    static func golden(_ json: String) throws -> NSDictionary { try object(Data(json.utf8)) }

    @Test func singleListenMatchesGolden() throws {
        let body = QTListenBrainzRequest.body(.single, [Self.play], version: "1.2.3")
        #expect(try Self.object(body) == Self.golden("""
        {
          "listen_type": "single",
          "payload": [{
            "listened_at": 1760000000,
            "track_metadata": {
              "artist_name": "Hoàng Dũng",
              "track_name": "Nàng Thơ",
              "release_name": "25",
              "additional_info": {
                "media_player": "QTube Music",
                "media_player_version": "1.2.3",
                "submission_client": "QTube Music",
                "submission_client_version": "1.2.3",
                "music_service": "music.youtube.com",
                "music_service_name": "YouTube Music",
                "origin_url": "https://music.youtube.com/watch?v=abc123XYZ_-",
                "duration_ms": 254321
              }
            }
          }]
        }
        """))
        // Same plays, same bytes (sorted keys, unescaped slashes).
        #expect(body == QTListenBrainzRequest.body(.single, [Self.play], version: "1.2.3"))
        #expect(String(decoding: body, as: UTF8.self).contains(#""origin_url":"https://music.youtube.com/watch?v=abc123XYZ_-""#))
    }

    @Test func playingNowHasNoTimestampMatchesGolden() throws {
        let body = QTListenBrainzRequest.body(.playingNow, [Self.play], version: "1.2.3")
        #expect(try Self.object(body) == Self.golden("""
        {
          "listen_type": "playing_now",
          "payload": [{
            "track_metadata": {
              "artist_name": "Hoàng Dũng",
              "track_name": "Nàng Thơ",
              "release_name": "25",
              "additional_info": {
                "media_player": "QTube Music",
                "media_player_version": "1.2.3",
                "submission_client": "QTube Music",
                "submission_client_version": "1.2.3",
                "music_service": "music.youtube.com",
                "music_service_name": "YouTube Music",
                "origin_url": "https://music.youtube.com/watch?v=abc123XYZ_-",
                "duration_ms": 254321
              }
            }
          }]
        }
        """))
    }

    /// An import from an old queue entry (no video id, seconds only) and an upload (private: no link).
    @Test func importMatchesGolden() throws {
        let old = QTScrobble(artist: "A", track: "Old", duration: 200, timestamp: 1_759_000_000)
        let upload = QTScrobble(artist: "Me", track: "Demo", timestamp: 1_759_000_300, videoId: "upl0ad", isPrivatelyOwned: true)
        let body = QTListenBrainzRequest.body(.import, [old, upload], version: "1.2.3")
        #expect(try Self.object(body) == Self.golden("""
        {
          "listen_type": "import",
          "payload": [{
            "listened_at": 1759000000,
            "track_metadata": {
              "artist_name": "A",
              "track_name": "Old",
              "additional_info": {
                "media_player": "QTube Music",
                "media_player_version": "1.2.3",
                "submission_client": "QTube Music",
                "submission_client_version": "1.2.3",
                "music_service": "music.youtube.com",
                "music_service_name": "YouTube Music",
                "duration_ms": 200000
              }
            }
          }, {
            "listened_at": 1759000300,
            "track_metadata": {
              "artist_name": "Me",
              "track_name": "Demo",
              "additional_info": {
                "media_player": "QTube Music",
                "media_player_version": "1.2.3",
                "submission_client": "QTube Music",
                "submission_client_version": "1.2.3",
                "music_service": "music.youtube.com",
                "music_service_name": "YouTube Music"
              }
            }
          }]
        }
        """))
    }

    @Test func importIsCappedAtAThousand() throws {
        let plays = (0..<1_200).map { QTScrobble(artist: "A", track: "T\($0)", timestamp: 1_759_000_000 + $0) }
        let json = try Self.object(QTListenBrainzRequest.body(.import, plays))
        #expect((json["payload"] as? [Any])?.count == 1_000)
    }

    @Test func requestsCarryTheTokenAndHitTheServersAPIRoot() throws {
        let submit = QTListenBrainzRequest.submit(.single, [Self.play], token: "T0K")
        #expect(submit.url?.absoluteString == "https://api.listenbrainz.org/1/submit-listens")
        #expect(submit.httpMethod == "POST")
        #expect(submit.value(forHTTPHeaderField: "Authorization") == "Token T0K")
        #expect(submit.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let maloja = try #require(QTListenBrainzRequest.server(from: " https://music.example.net/apis/listenbrainz/1/ "))
        let validate = QTListenBrainzRequest.validateToken("T0K", server: maloja)
        #expect(validate.url?.absoluteString == "https://music.example.net/apis/listenbrainz/1/validate-token")
        #expect(validate.httpMethod == "GET")
        #expect(validate.value(forHTTPHeaderField: "Authorization") == "Token T0K")
    }

    @Test func serverFieldNormalisation() {
        #expect(QTListenBrainzRequest.server(from: "") == QTListenBrainzRequest.defaultServer)
        #expect(QTListenBrainzRequest.server(from: "https://lb.example.org")?.absoluteString == "https://lb.example.org/")
        #expect(QTListenBrainzRequest.server(from: "http://nas.local:42010/apis/listenbrainz/")?.absoluteString
                == "http://nas.local:42010/apis/listenbrainz/")
        #expect(QTListenBrainzRequest.server(from: "lb.example.org") == nil, "a scheme is needed")
        #expect(QTListenBrainzRequest.server(from: "ftp://lb.example.org") == nil)
        #expect(QTListenBrainzRequest.server(from: "https://") == nil)
    }

    @Test func validateTokenGivesTheUserNameOrRefuses() async throws {
        let lb = QTRecordingListenBrainz()
        lb.respond = { _ in (200, [:], #"{"code":200,"message":"Token valid.","valid":true,"user_name":"rj"}"#) }
        #expect(try await lb.client().validateToken() == "rj")
        #expect(lb.requests.last?.authorization == "Token TOKEN")

        lb.respond = { _ in (200, [:], #"{"code":200,"message":"Token invalid.","valid":false}"#) }
        await #expect(throws: QTListenBrainzError.http(status: 401, message: "Token invalid.")) { try await lb.client().validateToken() }

        // A compatible server that doesn't say whose token it is: the host stands in.
        lb.respond = { _ in (200, [:], #"{"valid":true}"#) }
        let custom = try #require(URL(string: "https://music.example.net/apis/listenbrainz/"))
        #expect(try await lb.client(server: custom).validateToken() == "music.example.net")

        // A wrong server URL answering with a web page.
        lb.respond = { _ in (200, [:], "<html>Not here</html>") }
        await #expect(throws: QTListenBrainzError.malformed) { try await lb.client().validateToken() }
    }

    @Test func pacerSpacesCallsAndRefusesDuringAHold() async throws {
        let pacer = QTRequestPacer(interval: 0.05)
        let clock = ContinuousClock()
        let start = clock.now
        try await pacer.reserve()
        try await pacer.reserve()
        #expect(start.duration(to: clock.now) >= .milliseconds(45))
        await pacer.hold(for: 30)
        await #expect(throws: QTListenBrainzError.self) { try await pacer.reserve() }
    }

    /// A used-up window (`X-RateLimit-Remaining: 0`) stops the next call before it is sent.
    @Test func anEmptyRateLimitWindowHoldsTheNextCall() async throws {
        let lb = QTRecordingListenBrainz()
        lb.respond = { _ in (200, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset-In": "30"], #"{"status":"ok"}"#) }
        let client = lb.client()
        try await client.submit(.single, [Self.play])
        await #expect(throws: QTListenBrainzError.self) {
            try await client.submit(.single, [Self.play])
        }
        #expect(lb.requests.count == 1)
    }
}

@Suite struct QTScrobbleClassificationTests {
    static let lb = QTRecordingListenBrainz().service()
    static let lastFM = QTLastFMScrobbleService(client: QTLastFMClient(credentials: .init(apiKey: "k", apiSecret: "s")),
                                                sessionKey: "SK")

    @Test(arguments: [
        (QTListenBrainzError.http(status: 401, message: ""), QTScrobbleFailure.invalidCredentials),
        (.http(status: 400, message: "bad listen"), .rejectedPlays),
        (.rateLimited(resetIn: 12), .temporary(retryAfter: 12)),
        (.http(status: 503, message: ""), .temporary(retryAfter: nil)),
        (.http(status: 500, message: ""), .temporary(retryAfter: nil)),
        (.network, .temporary(retryAfter: nil)),
        (.http(status: 403, message: ""), .accountProblem),
        (.http(status: 404, message: ""), .accountProblem),
        (.malformed, .accountProblem),
    ])
    func listenBrainz(_ error: QTListenBrainzError, _ expected: QTScrobbleFailure) {
        #expect(Self.lb.classify(error) == expected)
    }

    @Test func listenBrainzStatusesFromResponses() throws {
        let url = URL(string: "https://api.listenbrainz.org/1/submit-listens")!
        let r429 = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["X-RateLimit-Reset-In": "7"])!
        #expect(throws: QTListenBrainzError.rateLimited(resetIn: 7)) { try QTListenBrainzRequest.check(Data(), r429) }
        let r400 = HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!
        #expect(throws: QTListenBrainzError.http(status: 400, message: "No artist")) {
            try QTListenBrainzRequest.check(Data(#"{"code":400,"error":"No artist"}"#.utf8), r400)
        }
    }

    @Test(arguments: [
        (QTLastFMError.api(code: 9, message: ""), QTScrobbleFailure.invalidCredentials),
        (.api(code: 6, message: ""), .rejectedPlays),
        (.api(code: 7, message: ""), .rejectedPlays),
        (.api(code: 11, message: ""), .temporary(retryAfter: nil)),
        (.api(code: 29, message: ""), .temporary(retryAfter: nil)),
        (.network, .temporary(retryAfter: nil)),
        (.api(code: 10, message: ""), .accountProblem),
        (.api(code: 26, message: ""), .accountProblem),
        (.api(code: 13, message: ""), .accountProblem),
        (.malformed, .accountProblem),
    ])
    func lastFM(_ error: QTLastFMError, _ expected: QTScrobbleFailure) {
        #expect(Self.lastFM.classify(error) == expected)
    }
}

@Suite struct QTScrobbleFanOutTests {
    static let creds = QTLastFMCredentials(apiKey: "testkey", apiSecret: "testsecret")

    static func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("qt-scrobbles-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func oneListenLandsInBothQueues() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = QTTestClock(Date(timeIntervalSince1970: 1_760_000_000))
        let lastfm = QTRecordingLastFM(), lb = QTRecordingListenBrainz()
        lastfm.failure = .network
        lb.respond = { _ in (503, [:], "") }
        let scrobbler = QTScrobbler(queueFolder: folder, now: { clock.now })
        await scrobbler.configure(client: QTLastFMClient(credentials: Self.creds, transport: lastfm.transport), sessionKey: "SK")
        await scrobbler.configure(.listenBrainz, service: lb.service())
        await scrobbler.trackChanged(to: QTScrobble(artist: "A", track: "One", duration: 200, timestamp: 1_760_000_000,
                                                    videoId: "v1"), playing: true)
        #expect(lastfm.requests.map { $0["method"] } == ["track.updateNowPlaying"])
        #expect(lb.requests.map(\.listenType) == ["playing_now"])
        clock.advance(100)
        await scrobbler.tick()
        #expect(await scrobbler.queue(.lastFM).items.map(\.track) == ["One"])
        #expect(await scrobbler.queue(.listenBrainz).items.map(\.track) == ["One"])

        // Each queue is its own file: both survive a relaunch, and ListenBrainz's keeps the new fields.
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Scrobbles.json").path))
        let relaunched = QTScrobbler(queueFolder: folder, now: { clock.now })
        #expect(await relaunched.queue(.listenBrainz).items.first?.videoId == "v1")

        // ListenBrainz comes back first: it sends its copy; Last.fm's waits for Last.fm.
        clock.advance(QTScrobbler.maximumBackoff)
        lb.respond = nil
        await scrobbler.tick()
        #expect(lb.accepted == ["One"])
        #expect(lb.requests.last?.listenType == "single")
        #expect(await scrobbler.queue(.listenBrainz).items.isEmpty)
        #expect(await scrobbler.queue(.lastFM).items.map(\.track) == ["One"])
    }

    @Test func aServiceThatIsOffGetsNothing() async {
        let clock = QTTestClock(Date(timeIntervalSince1970: 1_760_000_000))
        let lb = QTRecordingListenBrainz()
        let scrobbler = QTScrobbler(queueFolder: nil, now: { clock.now })
        await scrobbler.configure(.listenBrainz, service: lb.service(), sendsNowPlaying: false)
        await scrobbler.trackChanged(to: QTScrobble(artist: "A", track: "One", duration: 200, timestamp: 1), playing: true)
        clock.advance(100)
        await scrobbler.tick()
        #expect(lb.accepted == ["One"])
        #expect(lb.requests.allSatisfy { $0.listenType != "playing_now" }, "Update Now Playing off")
        #expect(await scrobbler.queue(.lastFM).items.isEmpty, "Last.fm isn't configured")
    }

    /// Connecting a service mid-listen announces the song to it right away (and only to it).
    @Test func aServiceConnectedMidListenHearsNowPlaying() async {
        let lastfm = QTRecordingLastFM(), lb = QTRecordingListenBrainz()
        let scrobbler = QTScrobbler(queueFolder: nil)
        await scrobbler.configure(client: QTLastFMClient(credentials: Self.creds, transport: lastfm.transport), sessionKey: "SK")
        await scrobbler.trackChanged(to: QTScrobble(artist: "A", track: "One", duration: 200, timestamp: 1), playing: true)
        await scrobbler.configure(.listenBrainz, service: lb.service())
        #expect(lb.requests.map(\.listenType) == ["playing_now"])
        #expect(lastfm.requests.count == 1)
    }

    /// A 400 for a batch: halve it until the bad listen is alone, drop only that one, send the rest.
    @Test func a400SplitsTheBatchAndDropsOnlyTheBadListen() async throws {
        let now = Int(Date().timeIntervalSince1970)
        let plays = (0..<9).map { QTScrobble(artist: "A", track: $0 == 6 ? "Bad" : "T\($0)", duration: 200, timestamp: now - 900 + $0) }
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(plays).write(to: folder.appendingPathComponent("ListenBrainz.json"))
        let lb = QTRecordingListenBrainz()
        lb.respond = { r in r.tracks.contains("Bad") ? (400, [:], #"{"code":400,"error":"Invalid listen"}"#) : nil }
        let scrobbler = QTScrobbler(queueFolder: folder)
        #expect(await scrobbler.queue(.listenBrainz).items.count == 9)
        await scrobbler.configure(.listenBrainz, service: lb.service(), sendsNowPlaying: false)
        await scrobbler.flush()
        #expect(await scrobbler.queue(.listenBrainz).items.isEmpty)
        #expect(lb.accepted.sorted() == plays.map(\.track).filter { $0 != "Bad" }.sorted())
        #expect(lb.requests.count <= 9, "halving, not one request per listen: \(lb.requests.count)")
        #expect(lb.requests.first?.listenType == "import")
        #expect(await !scrobbler.isPaused(.listenBrainz))
    }

    @Test func a401Disconnects() async {
        let lb = QTRecordingListenBrainz()
        lb.respond = { _ in (401, [:], #"{"code":401,"error":"Invalid authorization token."}"#) }
        let flag = QTTestFlag()
        let clock = QTTestClock(Date(timeIntervalSince1970: 1_760_000_000))
        let scrobbler = QTScrobbler(queueFolder: nil, now: { clock.now })
        await scrobbler.configure(.listenBrainz, service: lb.service(), onInvalidCredentials: { flag.set() })
        await scrobbler.trackChanged(to: QTScrobble(artist: "A", track: "One", duration: 200, timestamp: 1), playing: true)
        #expect(flag.isSet, "playing_now's 401 already disconnects")
        #expect(await !scrobbler.isActive(.listenBrainz))
    }

    /// 429 waits for as long as `X-RateLimit-Reset-In` says, then sends; 5xx backs off and keeps the listens.
    @Test func rateLimitsAndServerErrorsBackOff() async throws {
        let now = Int(Date().timeIntervalSince1970)
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode([QTScrobble(artist: "A", track: "One", timestamp: now - 60)])
            .write(to: folder.appendingPathComponent("ListenBrainz.json"))
        let clock = QTTestClock(Date())
        let lb = QTRecordingListenBrainz()
        lb.respond = { _ in (429, ["X-RateLimit-Reset-In": "40"], #"{"code":429,"error":"Too many requests"}"#) }
        let scrobbler = QTScrobbler(queueFolder: folder, now: { clock.now })
        await scrobbler.configure(.listenBrainz, service: lb.service(), sendsNowPlaying: false)
        await scrobbler.flush()
        #expect(lb.requests.count == 1)
        lb.respond = nil
        clock.advance(39)
        await scrobbler.flush()
        #expect(lb.requests.count == 1, "still inside the rate-limit window")
        clock.advance(2)
        await scrobbler.flush()
        #expect(lb.accepted == ["One"])

        await scrobbler.trackChanged(to: QTScrobble(artist: "A", track: "Two", duration: 100, timestamp: now), playing: true)
        lb.respond = { _ in (502, [:], "") }
        clock.advance(60)
        await scrobbler.trackChanged(to: nil, playing: false)
        let sent = lb.requests.count
        #expect(await scrobbler.queue(.listenBrainz).items.map(\.track) == ["Two"])
        await scrobbler.flush()
        #expect(lb.requests.count == sent, "backing off")
        lb.respond = nil
        clock.advance(QTScrobbler.minimumBackoff)
        await scrobbler.flush()
        #expect(await scrobbler.queue(.listenBrainz).items.isEmpty)
        #expect(await !scrobbler.isPaused(.listenBrainz))
    }

    @Test func aWrongServerPausesWithoutDropping() async throws {
        let lb = QTRecordingListenBrainz()
        lb.respond = { _ in (404, [:], "<html>Not Found</html>") }
        let flag = QTTestFlag()
        let clock = QTTestClock(Date())
        let scrobbler = QTScrobbler(queueFolder: nil, now: { clock.now })
        await scrobbler.configure(.listenBrainz, service: lb.service(), sendsNowPlaying: false, onPaused: { flag.set() })
        await scrobbler.trackChanged(to: QTScrobble(artist: "A", track: "One", duration: 100, timestamp: 1), playing: true)
        clock.advance(50)
        await scrobbler.tick()
        #expect(flag.isSet)
        #expect(await scrobbler.isPaused(.listenBrainz))
        #expect(await scrobbler.queue(.listenBrainz).items.count == 1)
    }
}

@Suite struct QTScrobbleQueueCompatibilityTests {
    /// A queue file written before ListenBrainz (no `videoId` / `isPrivatelyOwned` / `durationMs`) still loads.
    @Test func oldQueueFilesStillLoad() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("qt-scrobbles-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Scrobbles.json")
        try Data("""
        [{"artist":"Hoàng Dũng","track":"Nàng Thơ","album":"25","duration":254,"timestamp":1760000000},
         {"artist":"A","track":"No album","timestamp":1760000300}]
        """.utf8).write(to: url)
        let queue = QTScrobbleQueue(fileURL: url)
        #expect(queue.items.count == 2)
        #expect(queue.items[0] == QTScrobble(artist: "Hoàng Dũng", track: "Nàng Thơ", album: "25", duration: 254, timestamp: 1_760_000_000))
        #expect(queue.items[1].videoId == nil && !queue.items[1].isPrivatelyOwned && queue.items[1].durationMs == nil)
    }

    @Test func newFieldsRoundTrip() throws {
        let play = QTScrobble(artist: "A", track: "T", timestamp: 1, videoId: "v", isPrivatelyOwned: true, durationMs: 1234)
        let back = try JSONDecoder().decode(QTScrobble.self, from: JSONEncoder().encode(play))
        #expect(back == play)
    }
}

@Suite struct QTMediaTimeTests {
    static let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    static let play = QTScrobble(artist: "A", track: "T", duration: 200, timestamp: 1_760_000_000)

    /// At 2× a 200 s song reaches half (100 s of music) after 50 s; Last.fm's thresholds stay in media time.
    @Test func doubleSpeedCountsDouble() {
        var tracker = QTListenTracker()
        tracker.start(Self.play, rate: 2, at: Self.t0)
        #expect(tracker.scrobbleIfDue(at: Self.t0.addingTimeInterval(49)) == nil)
        #expect(tracker.scrobbleIfDue(at: Self.t0.addingTimeInterval(50)) == Self.play)
    }

    @Test func speedChangesAndBufferingAreCountedInMediaTime() {
        var tracker = QTListenTracker()
        tracker.start(Self.play, rate: 1, at: Self.t0)
        tracker.setRate(0, at: Self.t0.addingTimeInterval(20))     // 20 s, then buffering
        tracker.setRate(1.5, at: Self.t0.addingTimeInterval(50))   // buffering for 30 s doesn't count
        tracker.setRate(0.5, at: Self.t0.addingTimeInterval(70))   // + 30 s → 50
        #expect(tracker.listened(at: Self.t0.addingTimeInterval(170)) == 100) // + 50 s
        #expect(tracker.scrobbleIfDue(at: Self.t0.addingTimeInterval(169)) == nil)
        #expect(tracker.scrobbleIfDue(at: Self.t0.addingTimeInterval(170)) == Self.play)
    }

    /// Short songs are still never scrobbled, however fast (the > 30 s rule is about the song's length).
    @Test func shortSongsStayIneligible() {
        var tracker = QTListenTracker()
        tracker.start(QTScrobble(artist: "A", track: "Short", duration: 30, timestamp: 1), rate: 2, at: Self.t0)
        #expect(tracker.scrobbleIfDue(at: Self.t0.addingTimeInterval(600)) == nil)
    }

    @Test func theScrobblerFollowsTheRate() async {
        let clock = QTTestClock(Self.t0)
        let lb = QTRecordingListenBrainz()
        let scrobbler = QTScrobbler(queueFolder: nil, now: { clock.now })
        await scrobbler.configure(.listenBrainz, service: lb.service(), sendsNowPlaying: false)
        await scrobbler.trackChanged(to: Self.play, rate: 1)
        clock.advance(40)                        // 40 s of music
        await scrobbler.playbackChanged(rate: 2)
        clock.advance(29)                        // + 58 → 98
        await scrobbler.tick()
        #expect(lb.accepted.isEmpty)
        clock.advance(1)                         // + 2 → 100
        await scrobbler.tick()
        #expect(lb.accepted == ["T"])
    }
}

@MainActor
@Suite struct QTListenBrainzStoreTests {
    @Test func tokenStaysInTheKeychainAndOldSettingsStillLoad() async throws {
        let suite = "qt.tests.listenbrainz.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Settings saved before ListenBrainz existed.
        defaults.set(Data(#"{"lastFM":{"isEnabled":true,"apiKey":"k"},"notifiesTrackChanges":true}"#.utf8),
                     forKey: QTIntegrationsStore.defaultsKey)
        let secrets = QTMemorySecretStore()
        let store = QTIntegrationsStore(defaults: defaults, secrets: secrets)
        let prefs = store.settings
        #expect(prefs.lastFM.isEnabled && prefs.notifiesTrackChanges)
        #expect(!prefs.listenBrainz.isEnabled && !prefs.listenBrainz.isConnected && prefs.listenBrainz.sendsNowPlaying)
        #expect(prefs.listenBrainz.server == QTListenBrainzRequest.defaultServer)
        #expect(prefs.listenBrainz.customServerHost == nil)
        #expect(await store.loadListenBrainzSession() == nil)

        store.connectListenBrainz(token: " 0123-abcd \n", username: "rj")
        #expect(store.settings.listenBrainz.isEnabled)
        #expect(secrets.get(.listenBrainzToken) == "0123-abcd")
        let session = await store.loadListenBrainzSession()
        #expect(session?.token == "0123-abcd" && session?.server == QTListenBrainzRequest.defaultServer)
        let saved = String(data: defaults.data(forKey: QTIntegrationsStore.defaultsKey) ?? Data(), encoding: .utf8) ?? ""
        #expect(!saved.contains("0123-abcd"), "the token lives in the Keychain only")

        store.disconnectListenBrainz()
        #expect(secrets.get(.listenBrainzToken) == nil)
        #expect(!store.settings.listenBrainz.isEnabled)
    }

    @Test func customServerHost() {
        var prefs = QTListenBrainzPrefs()
        prefs.serverURL = "https://music.example.net/apis/listenbrainz"
        #expect(prefs.customServerHost == "music.example.net")
        prefs.serverURL = "not a url"
        #expect(prefs.server == nil)
    }
}
