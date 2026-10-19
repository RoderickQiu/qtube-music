import Foundation
import QTCore
import Testing
@testable import QTInnerTube

/// One card per release in album rows; official music videos ahead of compilations in search.
@Suite struct ResultTidyingTests {
    let hcy = QTArtistRef(id: "UC9O_FFbTBlJYW8apcu_Anrg", name: "华晨宇")

    func album(_ id: String, _ title: String, year: Int? = 2020, kind: QTAlbumKind = .album, artist: QTArtistRef? = nil) -> QTShelfItem {
        .album(QTAlbum(id: id, title: title, artists: [artist ?? hcy], year: year, kind: kind))
    }

    func titles(_ items: [QTShelfItem]) -> [String] {
        items.compactMap { if case .album(let a) = $0 { a.title } else { nil } }
    }

    /// The live artist page (2026-10-19, 华晨宇): "新世界" and "新世界 NEW WORLD" (2020), and two "H" (2016) under
    /// different browse ids.
    @Test func sameReleaseShowsOnce() {
        let items = [
            album("MPREb_Q0Tsp7zsD7V", "量變臨界點 TIPPING POINT", year: 2025),
            album("MPREb_SR563z0siCP", "希忘Hope", year: 2023),
            album("MPREb_p18w1jKdXpA", "新世界"),
            album("MPREb_xhksYq6sBWh", "新世界 NEW WORLD"),
            album("MPREb_JonFrALts1x", "H", year: 2016),
            album("MPREb_jFx15RokZqh", "H", year: 2016),
            album("MPREb_7UXUi4B62zi", "異類（合作音乐人：楊宗緯）", year: 2015),
        ]
        #expect(titles(QTResultTidying.dedupingReleases(items))
                == ["量變臨界點 TIPPING POINT", "希忘Hope", "新世界", "H", "異類（合作音乐人：楊宗緯）"])
    }

    @Test func differentReleasesStay() {
        let items = [
            album("a1", "新世界"),
            album("a2", "新世界 (Deluxe)"),                       // different title → different release
            album("a3", "新世界", year: 2021),                     // another year
            album("a4", "新世界", kind: .single),                  // single vs album
            album("a5", "新世界", artist: QTArtistRef(id: "UCother", name: "Other")),   // another artist
            album("a1", "新世界"),                                 // same id → dropped
        ]
        #expect(QTResultTidying.dedupingReleases(items).map(\.id)
                == ["album:a1", "album:a2", "album:a3", "album:a4", "album:a5"])
    }

    @Test func samePlaylistIDIsTheSameRelease() {
        let items = [album("a1", "One"), album("a2", "Another title")]
        #expect(QTResultTidying.dedupingReleases(items, playlistIDs: ["a1": "OLAK5uy_x", "a2": "OLAK5uy_x"]).count == 1)
    }

    @Test func titleKeys() {
        #expect(QTResultTidying.releaseTitleKey("新世界 NEW WORLD") == QTResultTidying.releaseTitleKey("新世界"))
        #expect(QTResultTidying.releaseTitleKey("異類") == QTResultTidying.releaseTitleKey("异类"))
        #expect(QTResultTidying.releaseTitleKey("Ｈ") == QTResultTidying.releaseTitleKey("h"))
        #expect(QTResultTidying.releaseTitleKey("Bad (Explicit)") == QTResultTidying.releaseTitleKey("Bad"))
        #expect(QTResultTidying.releaseTitleKey("Bad (Deluxe)") != QTResultTidying.releaseTitleKey("Bad"))
        // Latin titles, and CJK at the end, are left alone.
        #expect(QTResultTidying.releaseTitleKey("New World 新世界") != QTResultTidying.releaseTitleKey("New World"))
        #expect(QTResultTidying.releaseTitleKey("Đối Với Anh") == "đối với anh")
        // A Latin tail glued to the Han title isn't a re-title.
        #expect(QTResultTidying.releaseTitleKey("希忘Hope") != QTResultTidying.releaseTitleKey("希忘"))
        // Editions are other releases.
        #expect(QTResultTidying.releaseTitleKey("新世界 Live") != QTResultTidying.releaseTitleKey("新世界"))
        #expect(QTResultTidying.releaseTitleKey("新世界 (Deluxe)") != QTResultTidying.releaseTitleKey("新世界"))
    }

    // MARK: Music videos

    func video(_ id: String, _ type: QTMusicVideoType, minutes: Double, by artist: QTArtistRef) -> QTTrack {
        QTTrack(videoId: id, title: id, artists: [artist], duration: minutes * 60, musicVideoType: type)
    }

    /// The "Jay Chou" search (2026-10-19): three long UGC compilations led the row.
    @Test func officialVideosBeforeCompilations() {
        let jay = QTArtistRef(id: "UCL2MDNdwEtV6aYUgNjFQGZA", name: "周杰倫")
        let lyricChannel = QTArtistRef(id: "UCsMWXIFViw8KxCl1i7X8deA", name: "JVR Lyric MV")
        let label = QTArtistRef(id: "UClabel", name: "Label")
        let videos = [
            video("best20", .ugc, minutes: 86, by: lyricChannel),
            video("concert", .ugc, minutes: 143, by: QTArtistRef(id: "UCx", name: "Soundwave Station")),
            video("riceField", .ugc, minutes: 3.6, by: QTArtistRef(id: "UCy", name: "Pinyin Learner")),
            video("labelMV", .omv, minutes: 4.2, by: label),
            video("ownMV", .omv, minutes: 4.5, by: jay),
            video("ownLive", .ugc, minutes: 5, by: jay),
            video("unknownLength", .ugc, minutes: 0, by: lyricChannel),
        ]
        let ranked = QTResultTidying.rankingMusicVideos(videos, artistIDs: [jay.id!]).map(\.videoId)
        #expect(ranked == ["ownMV", "ownLive", "labelMV", "riceField", "unknownLength", "best20", "concert"])
        // Without a known artist: official first, compilations last, server order otherwise.
        #expect(QTResultTidying.rankingMusicVideos(videos).map(\.videoId)
                == ["labelMV", "ownMV", "riceField", "ownLive", "unknownLength", "best20", "concert"])
    }

    @Test func videosFilterFoldsIntoResults() {
        let a = QTArtistRef(id: "UCa", name: "A")
        var unfiltered = QTSearchResults(topResult: .artist(QTArtist(id: "UCa", name: "A")))
        unfiltered.items = [.track(QTTrack(videoId: "s1", title: "S", artists: [a], duration: 200)),
                            .video(QTTrack(videoId: "v1", title: "Comp", artists: [a], duration: 0, musicVideoType: .ugc))]
        let filtered = QTSearchResults(items: [
            .video(QTTrack(videoId: "v1", title: "Comp", artists: [a], duration: 3600, musicVideoType: .ugc)),
            .video(QTTrack(videoId: "v2", title: "MV", artists: [a], duration: 240, musicVideoType: .omv)),
        ])
        let merged = unfiltered.mergingVideos(from: filtered)
        #expect(merged.songs.map(\.videoId) == ["s1"])
        #expect(merged.videos.map(\.videoId) == ["v1", "v2"])
        #expect(merged.videos.first?.duration == 3600)
        #expect(merged.rankedVideos.map(\.videoId) == ["v2", "v1"])
        #expect(unfiltered.mergingVideos(from: QTSearchResults()) == unfiltered)
    }

    /// Recorded fixtures still parse with release de-duplication in the shelf parser.
    @Test func fixturesKeepTheirAlbums() throws {
        let page = try #require(QTInnerTubeParser.artist(try Fixture.json("artist-jay-zh"), browseId: "UCL2MDNdwEtV6aYUgNjFQGZA"))
        #expect(!page.albums.isEmpty)
        let ids = page.albums.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
