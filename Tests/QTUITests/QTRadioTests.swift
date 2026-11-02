import Foundation
import QTAuth
import QTCore
import QTInnerTube
import QTLyrics
@testable import QTPlayback
import Testing
@testable import QTUI

/// Start Radio end to end in the app layer: `QTLiveCatalogStore` builds the station from a song, album, playlist or
/// artist (requests checked, answered from recorded anonymous fixtures), `QTRadioActions` plays it — the song first,
/// Up Next kept — or, on the song playing now, lets it play on; Autoplay goes on with the station's own continuation;
/// failures are toasts and leave the queue alone. Guest and signed-in (fake cookies, in-memory Keychain). No network.
@MainActor
@Suite(.serialized) struct QTRadioTests {
    /// Answers `next` (radios and their continuation) and the album/artist pages from fixtures; records every body.
    final class RadioTransport: QTHTTPTransport, @unchecked Sendable {
        enum Next { case answers, fails, empty }
        private let lock = NSLock()
        private var bodies: [(endpoint: String, body: QTJSON)] = []
        private var nextMode = Next.answers
        let signedIn: Bool

        init(signedIn: Bool) { self.signedIn = signedIn }

        var next: Next {
            get { lock.withLock { nextMode } }
            set { lock.withLock { nextMode = newValue } }
        }

        /// Bodies of the `next` requests, in order.
        var nextBodies: [QTJSON] { lock.withLock { bodies.filter { $0.endpoint == "next" }.map(\.body) } }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let endpoint = request.url?.lastPathComponent ?? ""
            let body = request.httpBody.flatMap { try? QTJSON(data: $0) } ?? .null
            lock.withLock { bodies.append((endpoint, body)) }
            let name: String?
            switch endpoint {
            case "next":
                switch next {
                case .fails: throw URLError(.notConnectedToInternet)
                case .empty: return reply(Data("{}".utf8), request)
                case .answers:
                    name = body["continuation"].isNull ? "next-radio-trumua-en" : "next-radio-trumua-continuation-en"
                }
            case "browse":
                name = ["MPREb_JR856gupBGZ": "album-hkt-en", "UCjF7hNeaqArVJmijVgz-bjg": "artist-hkt-en"][body["browseId"].string ?? ""]
            default:
                name = nil
            }
            guard let name else { throw URLError(.notConnectedToInternet) }
            var text = try String(contentsOf: QTLiveCatalogStoreTests.StubTransport.fixtures.appendingPathComponent(name + ".json"),
                                  encoding: .utf8)
            // Recorded anonymously; signed in, answer as the account would or the client sees a lost session.
            if signedIn {
                text = text.replacingOccurrences(of: #""logged_in","value":"0""#, with: #""logged_in","value":"1""#)
            }
            return reply(Data(text.utf8), request)
        }

        private func reply(_ data: Data, _ request: URLRequest) -> (Data, HTTPURLResponse) {
            (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
        }
    }

    @MainActor struct Harness {
        let store: QTLiveCatalogStore
        let model: QTAppModel
        let transport: RadioTransport
        var player: QTPlayerModel { model.player }
    }

    /// `fixtures`: answered by the app's own DEBUG `QTFixtureTransport` (`-qt.live.fixtures`), as screenshots are.
    static func makeHarness(signedIn: Bool = false, catalog: String = "live", launch: [String: String] = [:],
                            fixtures: Bool = false) async throws -> Harness {
        let keychain = QTLiveCatalogStoreTests.CountingSecureStore()
        if signedIn {
            try await QTSessionStore(store: keychain).save(QTAuthSession(cookies: QTLiveCatalogStoreTests.fakeLogin()))
        }
        let transport = RadioTransport(signedIn: signedIn)
        let client = QTInnerTubeClient(transport: fixtures ? QTFixtureTransport() : transport, retry: .none,
                                       scrapesClientConfig: false, sleep: { _ in })
        let auth = QTAuthController(sessionStore: QTSessionStore(store: keychain), cookieStore: QTMemoryWebCookieStore(),
                                    client: client)
        let store = QTLiveCatalogStore(client: client, auth: auth)
        let defaults = UserDefaults(suiteName: "qt.tests.radio.\(UUID().uuidString)")!
        let empty = QTMockCatalog(tracks: [], liked: QTPlaylist(id: "LM", title: .localized("Liked Songs"), kind: .liked, tracks: []))
        let engine = QTSimulatedPlaybackEngine(account: .premium, tickInterval: nil)
        let player = QTPlayerModel(engine: engine, lyricsProvider: QTMockLyricsProvider(catalog: empty))
        let model = QTAppModel(settings: QTSettingsStore(defaults: defaults), player: player, catalog: empty,
                               launch: QTLaunchOptions(arguments: launch.merging(["qt.catalog": catalog]) { a, _ in a }))
        store.attach(model)
        if catalog == "live" {
            // Generous: the whole suite runs in parallel, and a busy machine slows the session restore down.
            await QTLiveCatalogStoreTests.waitUntil("YouTube Music", timeout: .seconds(30)) {
                store.mode == (signedIn ? .live : .guest)
            }
        }
        return Harness(store: store, model: model, transport: transport)
    }

    static let truMua = QTTrack(videoId: "AeXLsAPORb4", title: "Trú Mưa", artists: [QTArtistRef(name: "HKT")], duration: 303)

    static func track(_ id: String) -> QTTrack {
        QTTrack(videoId: id, title: "Title \(id)", artists: [QTArtistRef(name: "Artist")], duration: 200)
    }

    // MARK: Songs

    @Test func aSongsRadioPlaysTheSongFirstThenTheStation() async throws {
        defer { QTLiveCatalogStoreTests.cleanUp() }
        let h = try await Self.makeHarness()
        await h.player.play([Self.track("aaaaaaaaaa1"), Self.track("aaaaaaaaaa2")])
        h.player.addToQueue([Self.track("mine0000001")])
        #expect(await QTRadioActions.start(.song(Self.truMua), store: h.store, model: h.model))

        let body = try #require(h.transport.nextBodies.first)
        #expect(body["videoId"].string == "AeXLsAPORb4")
        #expect(body["playlistId"].string == "RDAMVMAeXLsAPORb4")
        #expect(body["params"].string == "wAEB")

        let queue = h.player.queue
        #expect(queue.nowPlaying?.track == Self.truMua, "the song as the list showed it, first")
        let radio = QTInnerTubeParser.next(try Fixture.json("next-radio-trumua-en")).tracks.map(\.videoId)
        #expect(queue.autoplay.map(\.track.videoId) == radio.filter { $0 != "AeXLsAPORb4" })
        #expect(queue.upNext.map(\.track.videoId) == ["mine0000001"], "Up Next stays")
        #expect(queue.autoplaySource?.kind == .radio)
        #expect(queue.autoplaySource?.id == "RDAMVMAeXLsAPORb4")
        #expect(queue.autoplaySource?.title.resolved == QTLoc.tr("%@ Radio", table: .live, "Trú Mưa"))
        #expect(queue.isAutoplayEnabled)
        #expect(h.store.radioContinuations["RDAMVMAeXLsAPORb4"] != nil)
    }

    @Test func autoplayGoesOnWithTheStationsOwnContinuation() async throws {
        defer { QTLiveCatalogStoreTests.cleanUp() }
        let h = try await Self.makeHarness()
        let station = try await h.store.radioStation(for: .song(Self.truMua))
        let token = try #require(h.store.radioContinuations["RDAMVMAeXLsAPORb4"])
        let fetch = try #require(h.player.playback.autoplayContinuation)
        let more = try await fetch(QTAutoplayRequest(source: station.source, seed: station.tracks.last,
                                                     excludingVideoIDs: Set(station.tracks.map(\.videoId))))
        let body = try #require(h.transport.nextBodies.last)
        #expect(body["continuation"].string == token.token, "the station's next page, not a new radio of its last song")
        #expect(body["playlistId"].string == "RDAMVMAeXLsAPORb4")
        #expect(!more.isEmpty)
        #expect(Set(more.map { $0.videoId }).isDisjoint(with: station.tracks.map { $0.videoId }))

        // Any other source (or a station from before a relaunch, with no page kept) radios from the last song.
        let album = QTQueueSource(kind: .album, title: .verbatim("Album"))
        _ = try await fetch(QTAutoplayRequest(source: album, seed: Self.truMua, excludingVideoIDs: []))
        #expect(h.transport.nextBodies.last?["continuation"].isNull == true)
        #expect(h.transport.nextBodies.last?["playlistId"].string == "RDAMVMAeXLsAPORb4")
    }

    @Test func theSongPlayingNowPlaysOnAndTheStationFollows() async throws {
        defer { QTLiveCatalogStoreTests.cleanUp() }
        let h = try await Self.makeHarness()
        await h.player.play([Self.truMua, Self.track("aaaaaaaaaa2")])
        let current = try #require(h.player.queue.nowPlaying)
        #expect(await QTRadioActions.start(.song(Self.truMua), store: h.store, model: h.model))
        #expect(h.player.queue.nowPlaying?.id == current.id, "not restarted")
        #expect(h.player.queue.autoplaySource?.id == "RDAMVMAeXLsAPORb4")
        #expect(!h.player.queue.autoplay.contains { $0.track.videoId == "aaaaaaaaaa2" })
        #expect(!h.player.queue.autoplay.contains { $0.track.videoId == "AeXLsAPORb4" })
    }

    // MARK: Albums, playlists, artists

    @Test func anAlbumRadiosThroughItsPlaylist() async throws {
        defer { QTLiveCatalogStoreTests.cleanUp() }
        let h = try await Self.makeHarness()
        let station = try await h.store.radioStation(for: .album(id: "MPREb_JR856gupBGZ", title: "Album"))
        let body = try #require(h.transport.nextBodies.last)
        #expect(body["videoId"].isNull)
        #expect(body["playlistId"].string == "RDAMPLOLAK5uy_lQix0l2y0koemYPBfk7LYrCeg8aWAPd1E")
        #expect(body["params"].string == "wAEB")
        #expect(station.source.id == "RDAMPLOLAK5uy_lQix0l2y0koemYPBfk7LYrCeg8aWAPd1E")
        #expect(!station.tracks.isEmpty)

        // Known from the album page (its More menu): no page fetch.
        let before = h.transport.nextBodies.count
        _ = try await h.store.radioStation(for: .album(id: "MPREb_other", title: "Other", playlistId: "OLAK5uy_known"))
        #expect(h.transport.nextBodies.count == before + 1)
        #expect(h.transport.nextBodies.last?["playlistId"].string == "RDAMPLOLAK5uy_known")
    }

    @Test func aPlaylistsRadio() async throws {
        defer { QTLiveCatalogStoreTests.cleanUp() }
        let h = try await Self.makeHarness()
        #expect(await QTRadioActions.start(.playlist(id: "VLPL0GvsLQil0MmYC96KEs_7dTNsLm1PS6JX", title: "Classic Rock"),
                                           store: h.store, model: h.model))
        #expect(h.transport.nextBodies.last?["playlistId"].string == "RDAMPLPL0GvsLQil0MmYC96KEs_7dTNsLm1PS6JX")
        #expect(h.player.queue.autoplaySource?.title.resolved == QTLoc.tr("%@ Radio", table: .live, "Classic Rock"))
        // The station as YouTube ordered it: its first song plays.
        let first = QTInnerTubeParser.next(try Fixture.json("next-radio-trumua-en")).tracks.first?.videoId
        #expect(h.player.queue.nowPlaying?.track.videoId == first)
    }

    @Test func anArtistsRadioIsTheirPagesMix() async throws {
        defer { QTLiveCatalogStoreTests.cleanUp() }
        let h = try await Self.makeHarness()
        _ = try await h.store.radioStation(for: .artist(id: "UCjF7hNeaqArVJmijVgz-bjg", name: "Hoàng Thùy Linh"))
        let body = try #require(h.transport.nextBodies.last)
        #expect(body["playlistId"].string == "RDEMCuN3Jsa6KTUlVtqNg3YsTw")
        #expect(body["videoId"].string == "-z890u7e5X4")
        #expect(body["params"].string == "wAEB")
    }

    @Test func signedInWorksTheSameWay() async throws {
        defer { QTLiveCatalogStoreTests.cleanUp() }
        let h = try await Self.makeHarness(signedIn: true)
        #expect(await QTRadioActions.start(.song(Self.truMua), store: h.store, model: h.model))
        #expect(h.player.queue.nowPlaying?.track.videoId == "AeXLsAPORb4")
        #expect(h.player.queue.autoplaySource?.kind == .radio)
    }

    // MARK: Failures and availability

    @Test func aRadioThatFailsIsAToastWithTryAgainAndLeavesTheQueue() async throws {
        defer { QTLiveCatalogStoreTests.cleanUp() }
        let h = try await Self.makeHarness()
        await h.player.play([Self.track("aaaaaaaaaa1"), Self.track("aaaaaaaaaa2")])
        let before = h.player.queue
        h.transport.next = .fails
        #expect(await QTRadioActions.start(.song(Self.truMua), store: h.store, model: h.model) == false)
        #expect(h.player.queue == before)
        #expect(h.model.toast?.message == QTLoc.tr("Couldn’t start a radio for “%@”", table: .live, "Trú Mưa"))
        #expect(h.model.toast?.actionTitle == QTLoc.tr("Try Again", table: .live))
    }

    @Test func noRadioIsAToastWithoutTryAgain() async throws {
        defer { QTLiveCatalogStoreTests.cleanUp() }
        let h = try await Self.makeHarness()
        h.transport.next = .empty
        #expect(await QTRadioActions.start(.playlist(id: "PL123", title: "Mine"), store: h.store, model: h.model) == false)
        #expect(h.model.toast?.message == QTLoc.tr("Couldn’t start a radio for “%@”", table: .live, "Mine"))
        #expect(h.model.toast?.actionTitle == nil)
        #expect(h.player.queue.nowPlaying == nil)
    }

    @Test func aBotCheckSaysSoAndOffersSignIn() {
        let (message, retries) = QTRadioActions.message(for: QTInnerTubeError.botCheck, seed: .song(Self.truMua))
        #expect(message == QTLoc.tr("YouTube wants to check this connection", table: .live))
        #expect(!retries)
        #expect(QTRadioActions.message(for: QTInnerTubeError.network(code: -1009), seed: .song(Self.truMua)).retries)
        #expect(!QTRadioActions.message(for: QTRadioUnavailable(), seed: .song(Self.truMua)).retries)
    }

    @Test func whatHasARadio() async throws {
        defer { QTLiveCatalogStoreTests.cleanUp() }
        let h = try await Self.makeHarness()
        let s = h.store
        #expect(s.canStartRadio(.song(Self.truMua)))
        var upload = Self.truMua
        upload.isPrivatelyOwned = true
        #expect(!s.canStartRadio(.song(upload)), "uploads aren't in YouTube's catalog")
        #expect(!s.canStartRadio(.song(QTTrack(videoId: "AeXLsAPORb5", title: "x", artists: [], duration: 1, availability: .regionLocked))))
        #expect(!s.canStartRadio(.playlist(id: "LM", title: "Liked Songs")))
        #expect(!s.canStartRadio(.playlist(id: "local:1", title: "Made here")))
        #expect(s.canStartRadio(.playlist(id: "VLPL123", title: "A playlist")))
        #expect(s.canStartRadio(.album(id: "MPREb_JR856gupBGZ", title: "Album")))
        #expect(!s.canStartRadio(.album(id: QTUploads.albumPrefix + "x", title: "Uploaded")))
        #expect(s.canStartRadio(.artist(id: "UCjF7hNeaqArVJmijVgz-bjg", name: "Artist")))

        // The demo library has no YouTube behind it.
        let demo = try await Self.makeHarness(catalog: "mock")
        #expect(!demo.store.canStartRadio(.song(Self.truMua)))
        #expect(await QTRadioActions.start(.song(Self.truMua), store: demo.store, model: demo.model) == false)
        #expect(demo.transport.nextBodies.isEmpty)
    }

    // MARK: Screenshot states (DEBUG `-qt.live.radio` with `-qt.live.fixtures`)

    @Test func theLaunchArgumentCuesASongsStationFromTheRecordings() async throws {
        defer { QTLiveCatalogStoreTests.cleanUp() }
        let h = try await Self.makeHarness(launch: ["qt.live.radio": "song:AeXLsAPORb4"], fixtures: true)
        await QTLiveCatalogStoreTests.waitUntil("station", timeout: .seconds(30)) { h.player.queue.autoplaySource?.kind == .radio }
        #expect(h.player.queue.nowPlaying?.track.videoId == "AeXLsAPORb4")
        #expect(!h.player.queue.autoplay.isEmpty)
        #expect(!h.player.isPlaying, "cued: launches don't play by themselves")
    }

    @Test func theLaunchArgumentShowsTheFailureToastForAnythingElse() async throws {
        defer { QTLiveCatalogStoreTests.cleanUp() }
        let h = try await Self.makeHarness(launch: ["qt.live.radio": "album:MPREb_JR856gupBGZ"], fixtures: true)
        await QTLiveCatalogStoreTests.waitUntil("toast", timeout: .seconds(30)) { h.model.toast != nil }
        let title = try #require(QTInnerTubeParser.album(try Fixture.json("album-hkt-en"), browseId: "MPREb_JR856gupBGZ")?.album.title)
        #expect(h.model.toast?.message == QTLoc.tr("Couldn’t start a radio for “%@”", table: .live, title))
        #expect(h.model.toast?.actionTitle == QTLoc.tr("Try Again", table: .live))
        #expect(h.player.queue.nowPlaying == nil)
    }

    @Test func menusOfferItWhereThereIsARadio() {
        #expect(QTRadioActions.offersRadio(playlistID: "VLPL123"))
        #expect(!QTRadioActions.offersRadio(playlistID: "LM"))
        var album = QTTrackCollection(id: "album:MPREb_x", kind: .album, title: "Album", tracks: [])
        album.libraryID = "OLAK5uy_x"
        #expect(QTRadioActions.seed(for: album) == .album(id: "MPREb_x", title: "Album", playlistId: "OLAK5uy_x"))
        let playlist = QTTrackCollection(id: "playlist:PL1", kind: .playlist, title: "P", tracks: [], playlistID: "PL1")
        #expect(QTRadioActions.seed(for: playlist) == .playlist(id: "PL1", title: "P"))
        let liked = QTTrackCollection(id: "liked", kind: .playlist, title: "Liked", tracks: [], playlistID: "LM")
        #expect(QTRadioActions.seed(for: liked) == nil)
        #expect(QTRadioActions.seed(for: QTTrackCollection(id: "songs", kind: .songs, title: "Songs", tracks: [])) == nil)
        #expect(QTRadioActions.menuItem(nil).isEnabled == false)
    }
}

/// Fixture access for the UI tests (the InnerTube tests' recorded responses).
private enum Fixture {
    static func json(_ name: String) throws -> QTJSON {
        try QTJSON(data: Data(contentsOf: QTLiveCatalogStoreTests.StubTransport.fixtures.appendingPathComponent(name + ".json")))
    }
}
