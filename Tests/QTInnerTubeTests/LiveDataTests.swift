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
