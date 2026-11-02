import Foundation
import QTCore
import Testing
@testable import QTInnerTube

/// Start Radio's `next` requests (`QTRadioRequest`): built the way YouTube Music's own menus send them — checked
/// against the "Start mix" endpoints the recorded album and playlist pages carry — the artist header's radio, and
/// the request bodies the client sends. No network.
@Suite struct RadioTests {
    func makeClient(_ transport: FakeTransport) -> QTInnerTubeClient {
        QTInnerTubeClient(configuration: QTInnerTubeConfiguration(hl: "en", gl: "US"), transport: transport,
                          retry: .none, scrapesClientConfig: false, sleep: { _ in })
    }

    /// The radio endpoint (`RDAMPL…`, with its params) a recorded page's header menu offers.
    func headerRadio(_ fixture: String) throws -> QTRadioRequest? {
        try Fixture.json(fixture).all("watchPlaylistEndpoint").lazy.compactMap { e -> QTRadioRequest? in
            guard let id = e["playlistId"].string, id.hasPrefix("RDAMPL") else { return nil }
            return QTRadioRequest(playlistId: id, params: e["params"].string)
        }.first
    }

    // MARK: Building

    @Test func aSongsRadioStartsFromIt() {
        let r = QTRadioRequest.song("AeXLsAPORb4")
        #expect(r.videoId == "AeXLsAPORb4")
        #expect(r.playlistId == "RDAMVMAeXLsAPORb4")
        #expect(r.params == "wAEB")
    }

    @Test func playlistRadiosMatchYouTubesOwnMenus() throws {
        // A user playlist (by browse id or raw id) and a curated `RDCLAK` one: the "Start mix" item of their pages.
        let classicRock = try #require(try headerRadio("playlist-classic-rock-en"))
        #expect(QTRadioRequest.playlist("VLPL0GvsLQil0MmYC96KEs_7dTNsLm1PS6JX") == classicRock)
        #expect(QTRadioRequest.playlist("PL0GvsLQil0MmYC96KEs_7dTNsLm1PS6JX") == classicRock)
        let curated = try #require(try headerRadio("playlist-jay-zh"))
        #expect(QTRadioRequest.playlist("VLRDCLAK5uy_l12ynH8dyLsBmE11ToAHLm9P04NS2i9ME") == curated)
    }

    @Test func anAlbumRadiosThroughItsPlaylist() throws {
        let page = try #require(QTInnerTubeParser.album(try Fixture.json("album-hkt-en"), browseId: "MPREb_JR856gupBGZ"))
        let playlistId = try #require(page.playlistId)
        #expect(playlistId.hasPrefix("OLAK5uy_"))
        let r = try #require(QTRadioRequest.playlist(playlistId))
        #expect(r.playlistId == "RDAMPL" + playlistId)
        #expect(r == (try headerRadio("album-hkt-en")))
    }

    @Test func listsWithoutARadio() {
        #expect(QTRadioRequest.playlist("LM") == nil)
        #expect(QTRadioRequest.playlist("VLLM") == nil)
        #expect(QTRadioRequest.playlist("local:1234") == nil)
        #expect(QTRadioRequest.playlist("pending:ABCD") == nil)
        #expect(QTRadioRequest.playlist("") == nil)
        // A mix is a radio already: it plays itself.
        #expect(QTRadioRequest.playlist("RDAMVMAeXLsAPORb4")?.playlistId == "RDAMVMAeXLsAPORb4")
        #expect(QTRadioRequest.playlist("VLRDEMCuN3Jsa6KTUlVtqNg3YsTw")?.playlistId == "RDEMCuN3Jsa6KTUlVtqNg3YsTw")
    }

    @Test func artistPagesCarryTheirRadio() throws {
        let hkt = try #require(QTInnerTubeParser.artist(try Fixture.json("artist-hkt-en"), browseId: "UCjF7hNeaqArVJmijVgz-bjg"))
        #expect(hkt.radio == QTRadioRequest(videoId: "-z890u7e5X4", playlistId: "RDEMCuN3Jsa6KTUlVtqNg3YsTw", params: "wAEB"))
        #expect(QTRadioRequest.artist(hkt) == hkt.radio)
        let jay = try #require(QTInnerTubeParser.artist(try Fixture.json("artist-jay-zh"), browseId: "UCL2MDNdwEtV6aYUgNjFQGZA"))
        #expect(jay.radio?.playlistId == "RDEMiTjubl5ivyhGx9AXBRWj6A")
        #expect(jay.radio?.videoId?.isEmpty == false)
    }

    @Test func anArtistWithoutARadioButtonRadiosFromTheirFirstSong() throws {
        var page = try #require(QTInnerTubeParser.artist(try Fixture.json("artist-hkt-en"), browseId: "UCjF7hNeaqArVJmijVgz-bjg"))
        page.radio = nil
        let first = try #require(page.songs.first)
        #expect(QTRadioRequest.artist(page) == .song(first.videoId))
        page.songs = []
        #expect(QTRadioRequest.artist(page) == nil)
    }

    // MARK: Requests

    @Test func songRadioRequestBody() async throws {
        let t = FakeTransport()
        t.enqueue("next", data: try Fixture.data("next-radio-trumua-en"))
        let page = try await makeClient(t).radio(.song("AeXLsAPORb4"))
        #expect(page.current?.videoId == "AeXLsAPORb4")
        #expect(page.tracks.count > 1)
        #expect(page.continuation != nil)
        let body = try #require(t.recorded.last?.jsonBody)
        #expect(body["videoId"].string == "AeXLsAPORb4")
        #expect(body["playlistId"].string == "RDAMVMAeXLsAPORb4")
        #expect(body["params"].string == "wAEB")
        #expect(body["isAudioOnly"].bool == true)
    }

    @Test func playlistRadioRequestBodyHasNoVideo() async throws {
        let t = FakeTransport()
        t.enqueue("next", data: try Fixture.data("next-radio-trumua-en"))
        _ = try await makeClient(t).radio(try #require(QTRadioRequest.playlist("VLPL0GvsLQil0MmYC96KEs_7dTNsLm1PS6JX")))
        let body = try #require(t.recorded.last?.jsonBody)
        #expect(body["videoId"].isNull)
        #expect(body["playlistId"].string == "RDAMPLPL0GvsLQil0MmYC96KEs_7dTNsLm1PS6JX")
        #expect(body["params"].string == "wAEB")
    }

    @Test func aRadioContinuesWithItsOwnToken() async throws {
        let t = FakeTransport()
        t.enqueue("next", data: try Fixture.data("next-radio-trumua-en"))
        t.enqueue("next", data: try Fixture.data("next-radio-trumua-continuation-en"))
        let client = makeClient(t)
        let first = try await client.radio(.song("AeXLsAPORb4"))
        let token = try #require(first.continuation)
        let more = try await client.nextContinuation(token, playlistId: "RDAMVMAeXLsAPORb4")
        #expect(!more.tracks.isEmpty)
        let body = try #require(t.recorded.last?.jsonBody)
        #expect(body["continuation"].string == token.token)
        #expect(body["playlistId"].string == "RDAMVMAeXLsAPORb4")
    }
}
