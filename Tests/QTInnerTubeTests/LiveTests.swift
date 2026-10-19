import Foundation
import QTCore
import Testing
@testable import QTInnerTube

// Live tests: anonymous, read-only requests to music.youtube.com. Off by default.
//   QT_LIVE=1 swift test --scratch-path .build/<you> --filter QTInnerTubeTests.Live
//   QT_LIVE=1 QT_RECORD=1 …  re-records Fixtures/*.json (trimmed; review the diff before committing).

@Suite("Live", .enabled(if: QTLive.isEnabled), .serialized)
struct LiveTests {
    func client(hl: String = "en") -> QTInnerTubeClient {
        QTInnerTubeClient(configuration: QTInnerTubeConfiguration(hl: hl, gl: "US"))
    }

    @Test func scrapesClientConfig() async {
        let config = await client().clientConfig()
        #expect(config.isScraped)
        #expect(config.clientVersion.hasPrefix("1."))
        #expect(config.apiKey?.hasPrefix("AIza") == true)
    }

    @Test func homeExploreSearch() async throws {
        let c = client()
        let home = try await c.home()
        #expect(!home.feed.shelves.isEmpty)
        #expect(home.continuation != nil)
        let explore = try await c.explore()
        #expect(!explore.shelves.isEmpty)
        let results = try await c.search("Trú Mưa")
        #expect(!results.songs.isEmpty)
        let videos = try await c.search("Trú Mưa", filter: .videos)
        #expect(!videos.videos.isEmpty)
        #expect(videos.songs.isEmpty)
    }

    @Test func zhSearchAlbumArtistPlaylist() async throws {
        let c = client(hl: "zh-CN")
        let results = try await c.search("晴天 周杰伦")
        #expect(results.songs.contains { $0.title == "晴天" })
        let album = try await c.album("MPREb_ScDJHCiomAo")
        #expect(album.album.tracks?.count ?? 0 >= 10)
        let artist = try await c.artist("UCL2MDNdwEtV6aYUgNjFQGZA")
        #expect(!artist.songs.isEmpty && !artist.albums.isEmpty && !artist.videos.isEmpty)
        let playlist = try await c.playlistAllTracks("PL0GvsLQil0MmYC96KEs_7dTNsLm1PS6JX", maxPages: 3)
        #expect((playlist.tracks?.count ?? 0) > 100)
    }

    @Test func nextAndQueue() async throws {
        let c = client()
        let next = try await c.next(videoId: "AeXLsAPORb4")
        #expect(next.lyricsBrowseId?.hasPrefix("MPLY") == true)
        // Official video rows in album/playlist/search lists carry the Song id (credits menu).
        let album = try await c.album("MPREb_JR856gupBGZ")
        let video = album.album.tracks?.first { $0.videoId == "QtP9V_G24QM" }
        #expect(video?.counterpart?.videoId == "wmw4rkwsA90")
        // Song → official video, anonymously (search fallback).
        let song = try #require(try await c.search("Trú Mưa", filter: .songs).songs.first { $0.videoId == "AeXLsAPORb4" })
        let cp = try await c.counterpart(for: song)
        #expect(cp?.videoId == "25efj4hluVQ")
    }

    // MARK: Recording

    struct Recording {
        var name: String
        var hl: String
        var endpoint: String
        var body: [String: QTJSON]
    }

    static let recordings: [Recording] = [
        .init(name: "home-en", hl: "en", endpoint: "browse", body: ["browseId": "FEmusic_home"]),
        .init(name: "home-zh", hl: "zh-CN", endpoint: "browse", body: ["browseId": "FEmusic_home"]),
        .init(name: "explore-en", hl: "en", endpoint: "browse", body: ["browseId": "FEmusic_explore"]),
        .init(name: "new-releases-en", hl: "en", endpoint: "browse", body: ["browseId": "FEmusic_new_releases"]),
        .init(name: "charts-en", hl: "en", endpoint: "browse", body: ["browseId": "FEmusic_charts"]),
        .init(name: "moods-en", hl: "en", endpoint: "browse", body: ["browseId": "FEmusic_moods_and_genres"]),
        .init(name: "search-trumua-en", hl: "en", endpoint: "search", body: ["query": "Trú Mưa"]),
        .init(name: "search-trumua-songs-en", hl: "en", endpoint: "search",
              body: ["query": "Trú Mưa", "params": .string(QTSearchFilter.songs.params!)]),
        .init(name: "search-trumua-videos-en", hl: "en", endpoint: "search",
              body: ["query": "Trú Mưa", "params": .string(QTSearchFilter.videos.params!.removingPercentEncoding!)]),
        .init(name: "search-trumua-playlists-en", hl: "en", endpoint: "search",
              body: ["query": "Trú Mưa", "params": .string(QTSearchFilter.playlists.params!)]),
        .init(name: "search-qingtian-zh", hl: "zh-CN", endpoint: "search", body: ["query": "晴天 周杰伦"]),
        .init(name: "search-qingtian-albums-zh", hl: "zh-CN", endpoint: "search",
              body: ["query": "晴天 周杰伦", "params": .string(QTSearchFilter.albums.params!)]),
        .init(name: "album-qilixiang-zh", hl: "zh-CN", endpoint: "browse", body: ["browseId": "MPREb_ScDJHCiomAo"]),
        .init(name: "album-hkt-en", hl: "en", endpoint: "browse", body: ["browseId": "MPREb_JR856gupBGZ"]),
        .init(name: "artist-hkt-en", hl: "en", endpoint: "browse", body: ["browseId": "UCjF7hNeaqArVJmijVgz-bjg"]),
        .init(name: "artist-jay-zh", hl: "zh-CN", endpoint: "browse", body: ["browseId": "UCL2MDNdwEtV6aYUgNjFQGZA"]),
        .init(name: "playlist-jay-zh", hl: "zh-CN", endpoint: "browse",
              body: ["browseId": "VLRDCLAK5uy_l12ynH8dyLsBmE11ToAHLm9P04NS2i9ME"]),
        .init(name: "playlist-classic-rock-en", hl: "en", endpoint: "browse",
              body: ["browseId": "VLPL0GvsLQil0MmYC96KEs_7dTNsLm1PS6JX"]),
        .init(name: "next-trumua-en", hl: "en", endpoint: "next",
              body: ["videoId": "AeXLsAPORb4", "isAudioOnly": true, "enablePersistentPlaylistPanel": true]),
        .init(name: "next-radio-trumua-en", hl: "en", endpoint: "next",
              body: ["videoId": "AeXLsAPORb4", "playlistId": "RDAMVMAeXLsAPORb4", "isAudioOnly": true,
                     "enablePersistentPlaylistPanel": true, "tunerSettingValue": "AUTOMIX_SETTING_NORMAL"]),
        .init(name: "next-loiyeudo-song-en", hl: "en", endpoint: "next",
              body: ["videoId": "wmw4rkwsA90", "enablePersistentPlaylistPanel": true]),
        .init(name: "next-loiyeudo-video-en", hl: "en", endpoint: "next",
              body: ["videoId": "QtP9V_G24QM", "enablePersistentPlaylistPanel": true]),
        .init(name: "queue-loiyeudo-en", hl: "en", endpoint: "music/get_queue",
              body: ["videoIds": ["QtP9V_G24QM", "wmw4rkwsA90"]]),
        .init(name: "player-loiyeudo-en", hl: "en", endpoint: "player", body: ["videoId": "wmw4rkwsA90"]),
    ]

    @Test(.enabled(if: QTLive.isRecording)) func recordFixtures() async throws {
        let en = client(hl: "en")
        let zh = client(hl: "zh-CN")
        var raw: [String: QTJSON] = [:]
        for r in Self.recordings {
            let c = r.hl == "en" ? en : zh
            let json = try await c.send(r.endpoint, body: r.body)
            raw[r.name] = json
            try write(r.name, json)
        }
        // Continuations: home pages until one holds a podcast shelf; second page of the big playlist; search.
        var token = QTInnerTubeParser.home(raw["home-en"]!).continuation
        var page = 1
        while let t = token, page <= 6 {
            let json = try await en.send("browse", body: ["continuation": .string(t.token)])
            let hasPodcasts = json.all("watchEndpoint").contains {
                $0[path: "watchEndpointMusicSupportedConfigs", "watchEndpointMusicConfig", "musicVideoType"].string?
                    .contains("PODCAST") == true
            } || json.all("browseId").contains { $0.string?.hasPrefix("MPSP") == true }
            if page == 1 { try write("home-continuation-en", json) }
            if hasPodcasts {
                try write("home-continuation-podcasts-en", json)
                break
            }
            token = QTInnerTubeParser.home(json).continuation
            page += 1
        }
        if let t = QTInnerTubeParser.playlist(raw["playlist-classic-rock-en"]!, browseId: "VLPL0GvsLQil0MmYC96KEs_7dTNsLm1PS6JX")?
            .continuation {
            try write("playlist-classic-rock-continuation-en",
                      try await en.send("browse", body: ["continuation": .string(t.token)]))
        }
        if let t = QTInnerTubeParser.search(raw["search-trumua-songs-en"]!, filter: .songs).continuation {
            try write("search-trumua-songs-continuation-en",
                      try await en.send("search", body: ["continuation": .string(t.token)]))
        }
        if let t = QTInnerTubeParser.next(raw["next-radio-trumua-en"]!).continuation {
            try write("next-radio-trumua-continuation-en",
                      try await en.send("next", body: ["continuation": .string(t.token), "playlistId": "RDAMVMAeXLsAPORb4",
                                                       "isAudioOnly": true, "enablePersistentPlaylistPanel": true]))
        }
    }

    func write(_ name: String, _ json: QTJSON) throws {
        let url = Fixture.sourceFolder.appendingPathComponent(name + ".json")
        try FixtureTrimmer.trim(json).data().write(to: url)
    }
}
