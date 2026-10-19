import Foundation
import QTCore
import Testing
@testable import QTInnerTube

/// Every parser against recorded anonymous responses (Fixtures/, recorded 2026-10-18, trimmed).
@Suite struct ParserTests {
    /// Every non-music signal anywhere in a list of parsed items.
    func assertMusicOnly(_ items: [QTShelfItem], sourceLocation: SourceLocation = #_sourceLocation) {
        for item in items {
            switch item {
            case .track(let t), .video(let t):
                #expect(t.musicVideoType != .other, "\(t.title) is not music", sourceLocation: sourceLocation)
            case .playlist(let p):
                #expect(!p.id.hasPrefix("MPSP"), sourceLocation: sourceLocation)
            case .album, .artist:
                break
            }
        }
    }

    // MARK: Home

    @Test func homeEnglish() throws {
        let page = QTInnerTubeParser.home(try Fixture.json("home-en"))
        #expect(page.continuation != nil)
        let quickPicks = try #require(page.feed.shelves.first)
        #expect(quickPicks.title == .verbatim("Quick picks"))
        #expect(quickPicks.style == .quickPicks)
        let first = try #require(quickPicks.items.first?.track)
        #expect(first.videoId == "xukbqwRuN5w")
        #expect(first.title == "Choosin' Texas")
        #expect(first.artists.first?.name == "Ella Langley")
        #expect(first.artists.first?.id == "UCecnyZYofHiBVDJpx1XNYOQ")
        #expect(first.album?.id == "MPREb_QC0L98k1tGe")
        #expect(first.musicVideoType == .atv)
        // Square art is offered large enough for Stage.
        #expect(first.artwork.last?.width == 1200)
        #expect(first.artwork.last?.url.absoluteString.contains("=w1200-h1200") == true)
        let playlists = page.feed.shelves[1]
        #expect(playlists.style == .cards)
        guard case .playlist(let p)? = playlists.items.first else { Issue.record("expected playlist"); return }
        #expect(p.id == "VLPLkpaQgbH2nStd0401Ul7-ffbGc-equxdB")
        #expect(p.owner == "Brando")
        #expect(p.kind == .user)
    }

    @Test func homeMoodChipsDropPodcasts() throws {
        let en = QTInnerTubeParser.home(try Fixture.json("home-en")).feed.moods
        let zh = QTInnerTubeParser.home(try Fixture.json("home-zh")).feed.moods
        #expect(!en.isEmpty && !zh.isEmpty)
        #expect(!en.contains { $0.title.resolved == "Podcasts" })
        #expect(!zh.contains { $0.title.resolved == "播客" })
        #expect(zh.first?.title == .verbatim("睡眠"))
        let target = QTBrowseTarget(moodChipID: try #require(en.first).id)
        #expect(target.browseId == "FEmusic_home")
        #expect(target.params?.isEmpty == false)
        #expect(QTParse.isPodcastChip(params: "ggNCSgQIDBADSgQIBRAB", title: "x"))
    }

    @Test func homeContinuation() throws {
        let page = QTInnerTubeParser.home(try Fixture.json("home-continuation-en"))
        #expect(page.feed.shelves.count >= 2)
        #expect(page.continuation != nil)
        #expect(page.feed.moods.isEmpty)
    }

    @Test func homePodcastShelfIsDropped() throws {
        let json = try Fixture.json("home-continuation-podcasts-en")
        // The raw page is a podcast shelf…
        #expect(json.all("browseId").contains { $0.string?.hasPrefix("MPSP") == true })
        // …which the music-only filter removes entirely.
        let page = QTInnerTubeParser.home(json)
        #expect(page.feed.shelves.isEmpty)
    }

    @Test func homeZhTitlesAreLocalizedByServer() throws {
        let page = QTInnerTubeParser.home(try Fixture.json("home-zh"))
        #expect(page.feed.shelves.first?.title == .verbatim("猜你喜欢"))
    }

    // MARK: Explore, new releases, charts, moods

    @Test func explore() throws {
        let page = QTInnerTubeParser.explore(try Fixture.json("explore-en"))
        #expect(page.destinations.map { QTBrowseTarget(moodChipID: $0.id).browseId }
            == ["FEmusic_new_releases", "FEmusic_charts", "FEmusic_moods_and_genres"])
        #expect(!page.moods.isEmpty)
        #expect(page.moods.allSatisfy { QTBrowseTarget(moodChipID: $0.id).browseId == "FEmusic_moods_and_genres_category" })
        let titles = page.shelves.map { $0.title.resolved }
        #expect(titles.contains("New albums & singles"))
        #expect(titles.contains("New music videos"))
        // "Popular episodes" (podcast episodes) is gone.
        #expect(!titles.contains("Popular episodes"))
        let videos = try #require(page.shelves.first { $0.title.resolved == "New music videos" })
        #expect(videos.style == .videos)
        #expect(videos.items.allSatisfy { if case .video = $0 { true } else { false } })
        for shelf in page.shelves { assertMusicOnly(shelf.items) }
    }

    @Test func newReleasesAndCharts() throws {
        let releases = QTInnerTubeParser.shelves(try Fixture.json("new-releases-en"))
        let albums = try #require(releases.first { $0.title.resolved == "Albums & singles" })
        guard case .album(let a)? = albums.items.first else { Issue.record("expected album"); return }
        #expect(a.id.hasPrefix("MPREb_"))
        #expect(!a.artists.isEmpty)
        let charts = QTInnerTubeParser.shelves(try Fixture.json("charts-en"))
        let titles = charts.map { $0.title.resolved }
        #expect(titles.contains("Top artists"))
        #expect(!titles.contains("Weekly top podcast shows"))
        let artists = try #require(charts.first { $0.title.resolved == "Top artists" })
        #expect(artists.items.allSatisfy { if case .artist = $0 { true } else { false } })
    }

    @Test func explicitBadge() throws {
        let json = try Fixture.json("explore-en")
        let explicitRaw = Set(json.all("musicTwoRowItemRenderer").filter {
            $0["subtitleBadges"].array.contains { $0[path: "musicInlineBadgeRenderer", "icon", "iconType"].string == "MUSIC_EXPLICIT_BADGE" }
        }.compactMap { $0[path: "navigationEndpoint", "watchEndpoint", "videoId"].string })
        let tracks = QTInnerTubeParser.explore(json).shelves.flatMap(\.items).compactMap(\.track)
        let parsedExplicit = Set(tracks.filter(\.isExplicit).map(\.videoId))
        #expect(parsedExplicit == explicitRaw.intersection(tracks.map(\.videoId)))
    }

    @Test func moodsAndGenres() throws {
        let page = QTInnerTubeParser.moods(try Fixture.json("moods-en"))
        #expect(page.groups.map(\.title) == ["Moods & moments", "Genres"])
        #expect(page.groups.allSatisfy { !$0.moods.isEmpty })
    }

    // MARK: Search

    @Test func searchTopLevelVietnamese() throws {
        let r = QTInnerTubeParser.search(try Fixture.json("search-trumua-en"))
        guard case .video(let top)? = r.topResult else { Issue.record("expected video top result"); return }
        #expect(top.videoId == "25efj4hluVQ")
        #expect(top.musicVideoType == .omv)
        #expect(top.duration == 309)
        #expect(top.artists.first?.name == "Nhom HKT")
        let song = try #require(r.songs.first)
        #expect(song.videoId == "AeXLsAPORb4")
        #expect(song.title == "Trú Mưa")
        // The "Song" label is not mistaken for an artist.
        #expect(song.artists.map(\.name) == ["HKT"])
        #expect(!r.videos.isEmpty && !r.albums.isEmpty && !r.playlists.isEmpty && !r.artists.isEmpty)
        #expect(r.artists.contains { $0.id == "UCjF7hNeaqArVJmijVgz-bjg" })
    }

    @Test func searchDropsEpisodesPodcastsAndProfiles() throws {
        let json = try Fixture.json("search-trumua-en")
        let raw = json.all("musicResponsiveListItemRenderer").count
        let r = QTInnerTubeParser.search(json)
        assertMusicOnly(r.items)
        // Episodes, podcast shows and profiles were present in the raw response.
        let rawIds = Set(json.all("browseId").compactMap(\.string))
        #expect(rawIds.contains { $0.hasPrefix("MPSP") })
        #expect(r.items.count < raw)
        #expect(!r.items.contains { $0.id.hasPrefix("artist:") && ($0.id.contains("UCZZGieModkceRIZiDlB1eIw")) })
        let zh = QTInnerTubeParser.search(try Fixture.json("search-qingtian-zh"))
        assertMusicOnly(zh.items)
    }

    @Test func searchChinese() throws {
        let r = QTInnerTubeParser.search(try Fixture.json("search-qingtian-zh"))
        let qingtian = try #require(r.songs.first { $0.videoId == "SJKoWAd5ySo" })
        #expect(qingtian.title == "晴天")
        #expect(qingtian.artists.map(\.name) == ["周杰倫"])
        #expect(r.artists.first?.name == "周杰倫")
        // "歌曲" / "视频" labels never leak into artist names.
        for t in r.songs + r.videos {
            #expect(!t.artists.contains { ["歌曲", "视频", "Song", "Video"].contains($0.name) })
        }
    }

    @Test func searchFilters() throws {
        let songs = QTInnerTubeParser.search(try Fixture.json("search-trumua-songs-en"), filter: .songs)
        #expect(songs.items.allSatisfy { if case .track = $0 { true } else { false } })
        let first = try #require(songs.songs.first)
        #expect(first.duration == 303)
        #expect(first.album?.title == "Mặt Trái Của Sự Thật")
        #expect(songs.continuation != nil)
        #expect(songs.songs.contains { $0.artists.count == 2 })

        let videos = QTInnerTubeParser.search(try Fixture.json("search-trumua-videos-en"), filter: .videos)
        #expect(!videos.videos.isEmpty)
        #expect(videos.songs.isEmpty)
        let omv = try #require(videos.videos.first { $0.videoId == "25efj4hluVQ" })
        #expect(omv.artists.first?.name == "Nhom HKT")
        #expect(omv.duration == 309)
        // Unlinked uploader is the artist, not the view count.
        #expect(videos.videos.allSatisfy { !($0.artists.first?.name.contains("views") ?? true) })

        let playlists = QTInnerTubeParser.search(try Fixture.json("search-trumua-playlists-en"), filter: .playlists)
        #expect(!playlists.playlists.isEmpty)
        #expect(playlists.items.count == playlists.playlists.count)

        let albums = QTInnerTubeParser.search(try Fixture.json("search-qingtian-albums-zh"), filter: .albums)
        let qilixiang = try #require(albums.albums.first { $0.id == "MPREb_ScDJHCiomAo" })
        #expect(qilixiang.year == 2004)
        #expect(qilixiang.kind == .album)
        #expect(qilixiang.artists.first?.name == "周杰倫")
    }

    @Test func searchContinuation() throws {
        let r = QTInnerTubeParser.search(try Fixture.json("search-trumua-songs-continuation-en"), filter: .songs)
        #expect(!r.songs.isEmpty)
        #expect(r.continuation != nil)
        #expect(r.songs.allSatisfy { $0.duration > 0 })
    }

    @Test func videosOnlyParamIsTheVerifiedOne() {
        #expect(QTSearchFilter.videos.params == "EgWKAQIQAWoKEAkQChAFEAMQBA%3D%3D")
        #expect(QTSearchFilter.all.params == nil)
    }

    // MARK: Album

    @Test func albumChinese() throws {
        let page = try #require(QTInnerTubeParser.album(try Fixture.json("album-qilixiang-zh"), browseId: "MPREb_ScDJHCiomAo"))
        #expect(page.album.title == "七里香")
        #expect(page.album.year == 2004)
        #expect(page.album.kind == .album)
        #expect(page.album.artists.first?.name == "周杰倫")
        #expect(page.album.artists.first?.id == "UCL2MDNdwEtV6aYUgNjFQGZA")
        #expect(page.playlistId == "OLAK5uy_llF9VkFj8c_8hgw02TFvGZbZkczomMG_c")
        #expect(page.summary?.contains("10") == true)
        let tracks = try #require(page.album.tracks)
        #expect(!tracks.isEmpty)
        // Rows inherit the album, its artists and artwork.
        #expect(tracks.allSatisfy { $0.album?.id == "MPREb_ScDJHCiomAo" && $0.artists.first?.name == "周杰倫" })
        #expect(tracks.allSatisfy { !$0.artwork.isEmpty && $0.duration > 0 })
        #expect(tracks[1].title == "七里香")
    }

    @Test func albumOfficialVideoRowsCarryTheSongCounterpart() throws {
        let page = try #require(QTInnerTubeParser.album(try Fixture.json("album-hkt-en"), browseId: "MPREb_JR856gupBGZ"))
        let tracks = try #require(page.album.tracks)
        let video = try #require(tracks.first { $0.videoId == "QtP9V_G24QM" })
        #expect(video.musicVideoType == .omv)
        #expect(video.counterpart == QTCounterpart(videoId: "wmw4rkwsA90", musicVideoType: .atv))
        #expect(video.hasVideo)
        // Audio rows don't get a self-referencing counterpart.
        let song = try #require(tracks.first { $0.videoId == "wismvcAOd0g" })
        #expect(song.musicVideoType == .atv)
        #expect(song.counterpart == nil)
    }

    // MARK: Artist

    @Test func artistVietnamese() throws {
        let page = try #require(QTInnerTubeParser.artist(try Fixture.json("artist-hkt-en"), browseId: "UCjF7hNeaqArVJmijVgz-bjg"))
        #expect(page.artist.name == "hkt")
        #expect(!page.artist.artwork.isEmpty)
        #expect(page.songs.count == 5)
        #expect(page.songs.contains { $0.videoId == "AeXLsAPORb4" })
        #expect(page.songsPlaylistId?.hasPrefix("VL") == true)
        #expect(!page.albums.isEmpty)
        #expect(!page.singles.isEmpty)
        #expect(page.singles.contains { $0.kind == .ep || $0.kind == .single })
        #expect(!page.videos.isEmpty)
        #expect(page.videos.allSatisfy { $0.musicVideoType.isVideo })
        #expect(page.videosPlaylistId?.hasPrefix("VL") == true)
        #expect(!page.relatedArtists.isEmpty)
    }

    @Test func artistChinese() throws {
        let page = try #require(QTInnerTubeParser.artist(try Fixture.json("artist-jay-zh"), browseId: "UCL2MDNdwEtV6aYUgNjFQGZA"))
        #expect(page.artist.name == "周杰倫")
        #expect(page.audience?.contains("1260") == true)
        #expect(page.description?.isEmpty == false)
        #expect(page.songs.first?.title == "晴天")
        #expect(page.albums.contains { $0.title == "太陽之子" })
        #expect(page.videos.contains { $0.title == "晴天" })
        #expect(!page.playlists.isEmpty)
        #expect(page.relatedArtists.allSatisfy { $0.name == $0.name.trimmingCharacters(in: .whitespaces) })
        for shelf in page.shelves { assertMusicOnly(shelf.items) }
    }

    // MARK: Playlist

    @Test func playlistChinese() throws {
        let page = try #require(QTInnerTubeParser.playlist(try Fixture.json("playlist-jay-zh"),
                                                           browseId: "VLRDCLAK5uy_l12ynH8dyLsBmE11ToAHLm9P04NS2i9ME"))
        #expect(page.playlist.title == .verbatim("Presenting Jay Chou (周杰倫)"))
        #expect(page.playlist.owner == "YouTube Music")
        #expect(page.totalTrackCount == 56)
        #expect(page.playlist.kind == .user)
        let first = try #require(page.playlist.tracks?.first)
        #expect(first.artists.first?.name == "周杰伦")
        #expect(first.duration == 183)
    }

    @Test func playlistPaging() throws {
        let page = try #require(QTInnerTubeParser.playlist(try Fixture.json("playlist-classic-rock-en"),
                                                           browseId: "VLPL0GvsLQil0MmYC96KEs_7dTNsLm1PS6JX"))
        #expect(page.totalTrackCount == 248)
        #expect(page.playlist.owner == "1503 Recording")
        #expect(page.continuation != nil)
        #expect(page.playlist.tracks?.isEmpty == false)
        let next = QTInnerTubeParser.trackContinuation(try Fixture.json("playlist-classic-rock-continuation-en"))
        #expect(!next.tracks.isEmpty)
        #expect(next.continuation != nil)
        #expect(Set(next.tracks.map(\.videoId)).isDisjoint(with: page.playlist.tracks!.map(\.videoId)))
    }

    @Test func playlistKinds() {
        #expect(QTParse.playlistKind("VLLM") == .liked)
        #expect(QTParse.playlistKind("RDAMVMAeXLsAPORb4") == .mix)
        #expect(QTParse.playlistKind("VLRDCLAK5uy_l12ynH8dyLsBmE11ToAHLm9P04NS2i9ME") == .user)
        #expect(QTParse.playlistBrowseId("PL123") == "VLPL123")
        #expect(QTParse.rawPlaylistId("VLPL123") == "PL123")
    }

    // MARK: Watch

    @Test func nextSongHasLyricsAndRelatedTabs() throws {
        let n = QTInnerTubeParser.next(try Fixture.json("next-trumua-en"))
        #expect(n.current?.videoId == "AeXLsAPORb4")
        #expect(n.current?.duration == 303)
        #expect(n.current?.album?.title == "Mặt Trái Của Sự Thật")
        #expect(n.lyricsBrowseId?.hasPrefix("MPLY") == true)
        #expect(n.relatedBrowseId?.hasPrefix("MPTR") == true)
        #expect(n.automix?.browseId == "RDAMVMAeXLsAPORb4")
    }

    @Test func nextRadioQueueAndContinuation() throws {
        let n = QTInnerTubeParser.next(try Fixture.json("next-radio-trumua-en"))
        #expect(n.playlistId == "RDAMVMAeXLsAPORb4")
        #expect(n.selectedIndex == 0)
        #expect(n.tracks.count > 1)
        #expect(n.continuation != nil)
        let more = QTInnerTubeParser.next(try Fixture.json("next-radio-trumua-continuation-en"))
        #expect(!more.tracks.isEmpty)
        #expect(more.selectedIndex == nil)
        assertMusicOnly(more.tracks.map(QTItemParser.shelfItem(for:)))
    }

    @Test func nextOfficialVideoAndSong() throws {
        let video = QTInnerTubeParser.next(try Fixture.json("next-loiyeudo-video-en"))
        #expect(video.current?.musicVideoType == .omv)
        let song = QTInnerTubeParser.next(try Fixture.json("next-loiyeudo-song-en"))
        #expect(song.current?.musicVideoType == .atv)
        #expect(song.current?.counterpart == nil)
    }

    /// Signed-in `next` rows come wrapped with their Song⇄Video counterpart. Anonymous responses don't include the
    /// wrapper, so this builds one from the two real recorded renditions of "Lời Yêu Đó".
    @Test func nextCounterpartWrapper() throws {
        let song = try Fixture.json("next-loiyeudo-song-en")
        let video = try Fixture.json("next-loiyeudo-video-en")
        let songRow = try #require(song.all("playlistPanelVideoRenderer").first)
        let videoRow = try #require(video.all("playlistPanelVideoRenderer").first)
        var selectedSong = songRow
        if case .object(var o) = selectedSong { o["selected"] = true; selectedSong = .object(o) }
        let wrapper: QTJSON = ["playlistPanelVideoWrapperRenderer": [
            "primaryRenderer": ["playlistPanelVideoRenderer": selectedSong],
            "counterpart": [["counterpartRenderer": ["playlistPanelVideoRenderer": videoRow],
                             "segmentMap": ["segment": []]]],
        ]]
        let response: QTJSON = ["contents": ["singleColumnMusicWatchNextResultsRenderer": ["tabbedRenderer": [
            "watchNextTabbedResultsRenderer": ["tabs": [["tabRenderer": ["content": ["musicQueueRenderer": [
                "content": ["playlistPanelRenderer": ["contents": [wrapper]]]]]]]]]]]]]
        let n = QTInnerTubeParser.next(response)
        let current = try #require(n.current)
        #expect(current.videoId == "wmw4rkwsA90")
        #expect(current.counterpart?.videoId == "QtP9V_G24QM")
        #expect(current.counterpart?.musicVideoType == .omv)
        #expect(current.counterpart?.artwork.isEmpty == false)
        #expect(current.hasVideo)
    }

    @Test func counterpartBySearchMatch() throws {
        let songs = QTInnerTubeParser.search(try Fixture.json("search-trumua-songs-en"), filter: .songs).songs
        let videos = QTInnerTubeParser.search(try Fixture.json("search-trumua-videos-en"), filter: .videos).videos
        let song = try #require(songs.first { $0.videoId == "AeXLsAPORb4" })
        let video = try #require(videos.first { $0.videoId == "25efj4hluVQ" })
        // Song → official video ("HKT" ⊂ "Nhom HKT"); UGC re-uploads and remixes are never picked.
        #expect(QTCounterpartMatcher.match(song, in: videos)?.videoId == "25efj4hluVQ")
        // Official video → song.
        #expect(QTCounterpartMatcher.match(video, in: songs)?.videoId == "AeXLsAPORb4")
        #expect(QTCounterpartMatcher.normalizedTitle("HKT - Trú Mưa (Official Music Video)", artists: ["HKT"]) == "tru mua")
        #expect(QTCounterpartMatcher.normalizedTitle("Trú Mưa (Remix)") != QTCounterpartMatcher.normalizedTitle("Trú Mưa"))
        #expect(QTCounterpartMatcher.normalizedTitle("晴天【MV】") == "晴天")
    }

    @Test func getQueue() throws {
        let tracks = QTInnerTubeParser.queue(try Fixture.json("queue-loiyeudo-en"))
        #expect(tracks.map(\.videoId) == ["QtP9V_G24QM", "wmw4rkwsA90"])
        #expect(tracks.map(\.musicVideoType) == [.omv, .atv])
    }

    @Test func player() throws {
        let info = try #require(QTInnerTubeParser.player(try Fixture.json("player-loiyeudo-en")))
        #expect(info.videoId == "wmw4rkwsA90")
        #expect(info.title == "Lời Yêu Đó")
        #expect(info.author == "HKT")
        #expect(info.duration == 274)
        #expect(info.musicVideoType == .atv)
        // Anonymous WEB_REMIX player calls aren't playable (no PoToken/signature) — streams are the engine's job.
        #expect(info.status != .ok)
        #expect(info.track.availability != .playable)
    }

    // MARK: Library, lyrics, account (signed-in shapes; built from real public rows)

    @Test func libraryGridAndShelf() throws {
        let home = try Fixture.json("home-en")
        let twoRow = home.all("musicTwoRowItemRenderer").map { QTJSON.object(["musicTwoRowItemRenderer": $0]) }
        let listRows = home.all("musicResponsiveListItemRenderer").map { QTJSON.object(["musicResponsiveListItemRenderer": $0]) }
        let response: QTJSON = ["contents": ["singleColumnBrowseResultsRenderer": ["tabs": [["tabRenderer": [
            "content": ["sectionListRenderer": ["contents": [
                ["gridRenderer": ["items": .array(twoRow), "continuations": [["nextContinuationData": ["continuation": "GRIDTOKEN"]]]]],
                ["musicShelfRenderer": ["contents": .array(listRows)]],
            ]]]]]]]]]
        let page = QTInnerTubeParser.libraryItems(response)
        #expect(page.items.count == twoRow.count + listRows.count)
        #expect(page.continuation == QTContinuation("GRIDTOKEN"))
        let cont: QTJSON = ["continuationContents": ["gridContinuation": ["items": .array(twoRow)]]]
        #expect(QTInnerTubeParser.libraryItems(cont).items.count == twoRow.count)
    }

    @Test func plainLyricsAndAccount() {
        let lyrics: QTJSON = ["contents": ["sectionListRenderer": ["contents": [["musicDescriptionShelfRenderer": [
            "description": ["runs": [["text": "line one\nline two"]]],
            "footer": ["runs": [["text": "Source: Example"]]],
        ]]]]]]
        #expect(QTInnerTubeParser.plainLyrics(lyrics) == QTPlainLyrics(text: "line one\nline two", source: "Source: Example"))
        let account: QTJSON = ["actions": [["openPopupAction": ["popup": ["multiPageMenuRenderer": ["header": [
            "activeAccountHeaderRenderer": [
                "accountName": ["runs": [["text": "Test User"]]],
                "channelHandle": ["runs": [["text": "@test"]]],
                "accountPhoto": ["thumbnails": [["url": "https://yt3.ggpht.com/a=s88", "width": 88, "height": 88]]],
            ]]]]]]]]
        let info = QTInnerTubeParser.account(account)
        #expect(info?.name == "Test User")
        #expect(info?.handle == "@test")
        #expect(info?.photo.count == 1)
    }

    @Test func loggedInSignal() throws {
        #expect(QTInnerTubeParser.loggedIn(try Fixture.json("home-en")) == false)
        let signedIn: QTJSON = ["responseContext": ["serviceTrackingParams": [
            ["service": "GFEEDBACK", "params": [["key": "logged_in", "value": "1"]]]]]]
        #expect(QTInnerTubeParser.loggedIn(signedIn) == true)
        #expect(QTInnerTubeParser.loggedIn([:]) == nil)
    }

    // MARK: Primitives

    @Test func primitives() {
        #expect(QTParse.duration("5:03") == 303)
        #expect(QTParse.duration("1:02:03") == 3723)
        #expect(QTParse.duration("24M views") == nil)
        #expect(QTParse.year("2004年") == 2004)
        #expect(QTParse.year("2026") == 2026)
        #expect(QTParse.year("12") == nil)
        #expect(QTParse.albumKind(label: "单曲") == .single)
        #expect(QTParse.albumKind(label: "EP") == .ep)
        #expect(QTParse.albumKind(label: "专辑") == .album)
        #expect(QTParse.albumKind(label: "HKT") == nil)
        #expect(QTInnerTubeParser.leadingInteger("1,234 tracks") == 1234)
        #expect(QTInnerTubeParser.leadingInteger("56 首歌曲") == 56)
        let url = URL(string: "https://lh3.googleusercontent.com/abc=w120-h120-l90-rj")!
        #expect(QTParse.resizedSquareURL(url, size: 544)?.absoluteString == "https://lh3.googleusercontent.com/abc=w544-h544-l90-rj")
        #expect(QTParse.resizedSquareURL(URL(string: "https://i.ytimg.com/vi/x/hqdefault.jpg")!, size: 544) == nil)
        #expect(QTParse.isNonMusic(.watch(videoId: "x", playlistId: nil, params: nil,
                                          musicVideoType: "MUSIC_VIDEO_TYPE_PODCAST_EPISODE")))
        #expect(QTParse.isNonMusic(.browse(browseId: "MPSPPLxyz", params: nil, pageType: nil)))
        #expect(QTParse.isNonMusic(.browse(browseId: "FEmusic_non_music_audio", params: nil, pageType: nil)))
        #expect(!QTParse.isNonMusic(.browse(browseId: "MPREb_x", params: nil, pageType: "MUSIC_PAGE_TYPE_ALBUM")))
    }

    @Test func jsonValue() throws {
        let j = try QTJSON(data: Data(#"{"a":{"b":[1,true,"x",null]},"n":1.5}"#.utf8))
        #expect(j[path: "a", "b"][0].int == 1)
        #expect(j[path: "a", "b"][1].bool == true)
        #expect(j[path: "a", "b"][2].string == "x")
        #expect(j[path: "a", "b"][3].isNull)
        #expect(j[path: "a", "b"][9].isNull)
        #expect(j["n"].double == 1.5)
        #expect(j["missing"]["deeper"].string == nil)
        #expect(j.first("b")?.array.count == 4)
        let round = try QTJSON(data: j.data())
        #expect(round == j)
    }
}
