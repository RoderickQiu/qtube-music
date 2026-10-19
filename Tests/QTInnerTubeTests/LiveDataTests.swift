import Foundation
import QTCore
import Testing
@testable import QTInnerTube

/// Signed-in shapes found while wiring the real library (2026-10-18), as small synthetic responses — no user data.
@Suite struct LiveDataTests {
    @Test func accountContextFromSignedInPage() {
        let html = """
        <script>ytcfg.set({"INNERTUBE_CONTEXT_GL": "US", "INNERTUBE_CONTEXT_HL":"zh-CN", "LOGGED_IN": true,
        "IS_SUBSCRIBER": true, "GL": "XX"});</script>
        """
        let c = QTAccountContext.scrape(html: html)
        #expect(c.isSubscriber == true)
        #expect(c.gl == "US")
        #expect(c.hl == "zh-CN")
        #expect(c.isLoggedIn == true)

        let free = QTAccountContext.scrape(html: #"{"LOGGED_IN":true,"IS_SUBSCRIBER":false,"GL":"VN"}"#)
        #expect(free.isSubscriber == false)
        #expect(free.gl == "VN")
        // Anonymous page: no subscriber key at all — unknown, not "free".
        let anonymous = QTAccountContext.scrape(html: #"{"LOGGED_IN":false}"#)
        #expect(anonymous.isSubscriber == nil)
        #expect(anonymous.isLoggedIn == false)
    }

    @Test func libraryArtistIdsUnwrapToChannels() {
        #expect(QTInnerTubeClient.channelId("MPLAUCmDeopFVXcEkdkd2vKw91_Q") == "UCmDeopFVXcEkdkd2vKw91_Q")
        #expect(QTInnerTubeClient.channelId("UCL2MDNdwEtV6aYUgNjFQGZA") == "UCL2MDNdwEtV6aYUgNjFQGZA")
    }

    /// Liked / playlist rows are all kept, so counts agree with YouTube Music: official-source uploads are music, and a
    /// greyed-out row without a playable id stays as a greyed (unplayable) row. Podcast episodes are still dropped.
    @Test func playlistKeepsOfficialSourceAndGreyedOutRows() throws {
        func row(_ title: String, video: String?, type: String?, greyed: Bool = false, setID: String? = nil) -> String {
            let nav = video.map { v in
                #","navigationEndpoint":{"watchEndpoint":{"videoId":"\#(v)","watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"\#(type ?? "MUSIC_VIDEO_TYPE_ATV")"}}}}"#
            } ?? ""
            var data: [String] = []
            if let video { data.append(#""videoId":"\#(video)""#) }
            if let setID { data.append(#""playlistSetVideoId":"\#(setID)""#) }
            return """
            {"musicResponsiveListItemRenderer":{"flexColumns":[
              {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"\(title)"\(nav)}]}}},
              {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Someone"}]}}}
            ],"fixedColumns":[{"musicResponsiveListItemFixedColumnRenderer":{"text":{"runs":[{"text":"3:30"}]}}}],
            "playlistItemData":{\(data.joined(separator: ","))}\(greyed ? #","musicItemRendererDisplayPolicy":"MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT""# : "")}}
            """
        }
        let rows = [
            row("Song", video: "aaaaaaaaaaa", type: "MUSIC_VIDEO_TYPE_ATV"),
            row("Official source", video: "bbbbbbbbbbb", type: "MUSIC_VIDEO_TYPE_OFFICIAL_SOURCE_MUSIC"),
            row("Upload", video: "ccccccccccc", type: "MUSIC_VIDEO_TYPE_PRIVATELY_OWNED_TRACK"),
            row("Gone here", video: nil, type: nil, greyed: true, setID: "SETID1"),
            row("Greyed with id", video: "ddddddddddd", type: "MUSIC_VIDEO_TYPE_ATV", greyed: true),
            row("Episode", video: "eeeeeeeeeee", type: "MUSIC_VIDEO_TYPE_PODCAST_EPISODE"),
            row("No id, not greyed", video: nil, type: nil),
        ]
        let json = """
        {"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[
          {"musicPlaylistShelfRenderer":{"contents":[\(rows.joined(separator: ","))]}}
        ]}}}}]}},"header":{"musicResponsiveHeaderRenderer":{"title":{"runs":[{"text":"Liked Music"}]}}}}
        """
        let page = try #require(QTInnerTubeParser.playlist(try QTJSON(data: Data(json.utf8)), browseId: "VLLM"))
        let tracks = page.playlist.tracks ?? []
        #expect(tracks.map(\.title) == ["Song", "Official source", "Upload", "Gone here", "Greyed with id"])
        #expect(tracks[1].musicVideoType == .ugc && tracks[1].availability == .playable)
        #expect(tracks[2].musicVideoType == .atv)
        #expect(tracks[3].videoId == "unavailable:SETID1" && tracks[3].availability == .regionLocked)
        #expect(tracks[4].videoId == "ddddddddddd" && tracks[4].availability == .regionLocked)
        #expect(Set(tracks.map(\.videoId)).count == tracks.count)
    }

    /// An artist top-result card lists that artist's songs as "Song • 4:45" with no artist run.
    @Test func artistCardSongsInheritTheArtist() throws {
        func run(_ text: String, browse: String? = nil, pageType: String? = nil, video: String? = nil) -> String {
            if let browse {
                return #"{"text":"\#(text)","navigationEndpoint":{"browseEndpoint":{"browseId":"\#(browse)","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"\#(pageType!)"}}}}}"#
            }
            if let video {
                return #"{"text":"\#(text)","navigationEndpoint":{"watchEndpoint":{"videoId":"\#(video)","watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"MUSIC_VIDEO_TYPE_ATV"}}}}}"#
            }
            return #"{"text":"\#(text)"}"#
        }
        let song = """
        {"musicResponsiveListItemRenderer":{"flexColumns":[
          {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[\(run("開不了口", video: "abcdefghijk"))]}}},
          {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[\(run("Song")),\(run(" • ")),\(run("4:45"))]}}}
        ],"playlistItemData":{"videoId":"abcdefghijk"}}}
        """
        let json = """
        {"contents":{"tabbedSearchResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[
          {"musicCardShelfRenderer":{
            "title":{"runs":[\(run("Jay Chou", browse: "UCL2MDNdwEtV6aYUgNjFQGZA", pageType: "MUSIC_PAGE_TYPE_ARTIST"))]},
            "subtitle":{"runs":[\(run("Artist"))]},
            "contents":[\(song)]}}
        ]}}}}]}}}
        """
        let results = QTInnerTubeParser.search(try QTJSON(data: Data(json.utf8)))
        guard case .artist(let artist)? = results.topResult else {
            Issue.record("expected an artist top result")
            return
        }
        #expect(artist.id == "UCL2MDNdwEtV6aYUgNjFQGZA")
        let first = try #require(results.songs.first)
        #expect(first.title == "開不了口")
        #expect(first.duration == 285)
        #expect(first.artists == [QTArtistRef(id: "UCL2MDNdwEtV6aYUgNjFQGZA", name: "Jay Chou")])
    }
}
