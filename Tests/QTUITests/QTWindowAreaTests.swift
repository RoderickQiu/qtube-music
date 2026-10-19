import Foundation
import QTCore
import Testing
@testable import QTUI

/// Window area: search folding, sorting, track listing, navigation history, playlist edits, links.
@Suite struct QTTextFoldingTests {
    @Test func searchFoldsDiacriticsAndChineseVariants() {
        #expect(QTTextFolding.matches(query: "ha phom", in: "Hạ Phỏm (出牌) Hoàng Thùy Linh"))
        #expect(QTTextFolding.matches(query: "doi voi anh", in: "Đối Với Anh Em Không Còn Cảm Giác"))
        #expect(QTTextFolding.matches(query: "現在的我們", in: "Chúng Ta Của Hiện Tại 现在的我们"))
        #expect(QTTextFolding.matches(query: "叶惠美", in: "晴天 葉惠美"))
        #expect(QTTextFolding.matches(query: "kim ngoc", in: "Kim Ny Ngọc"))
        #expect(QTTextFolding.matches(query: "ＰＥＲＦＥＣＴ", in: "Perfect Ed Sheeran"))
        #expect(!QTTextFolding.matches(query: "sunny rain", in: "晴天 Sunny Day"))
        #expect(QTTextFolding.matches(query: "  ", in: "anything"))
        #expect(QTTextFolding.matches(query: "li jian", in: "丽江 李健"))
        #expect(QTTextFolding.matches(query: "lijian", in: "李健"))
    }

    @Test func sortKeysIgnoreArticlesAndRomanizeHan() {
        #expect(QTTextFolding.sortKey("The Beatles").hasPrefix("beatles"))
        #expect(QTTextFolding.sortKey("A Day") .hasPrefix("day"))
        #expect(QTTextFolding.sortKey("Theory") .hasPrefix("theory"))
        #expect(QTTextFolding.indexLetter("蓝色夜曲") == "L")
        #expect(QTTextFolding.indexLetter("Đơn Côi") == "D")
        #expect(QTTextFolding.indexLetter("The Weeknd") == "W")
        #expect(QTTextFolding.indexLetter("2025 Sel 1") == "#")
        #expect(QTTextFolding.indexLetters.count == 27)
    }
}

@Suite struct QTTrackListingTests {
    static func track(_ id: String, _ title: String, album: String = "", seconds: TimeInterval = 200,
                      artist: String = "X", available: Bool = true) -> QTTrack {
        QTTrack(videoId: id, title: title, artists: [QTArtistRef(name: artist)], album: QTAlbumRef(title: album),
                duration: seconds, availability: available ? .playable : .regionLocked)
    }

    static let tracks = [
        track("1", "The Zoo", album: "B", seconds: 300),
        track("2", "蓝色夜曲", album: "A", seconds: 100),
        track("3", "Apple", album: "C", seconds: 200),
        track("4", "Đơn Côi", album: "D", seconds: 250, available: false),
    ]

    @Test func addedOrderAndFiltering() {
        #expect(QTTrackListing.rows(Self.tracks, filter: "", sort: .init()).map(\.videoId) == ["1", "2", "3", "4"])
        #expect(QTTrackListing.rows(Self.tracks, filter: "don coi", sort: .init()).map(\.videoId) == ["4"])
        #expect(QTTrackListing.rows(Self.tracks, filter: "nothing", sort: .init()).isEmpty)
    }

    @Test func sortsByTitleIgnoringTheAndByTime() {
        let byTitle = QTTrackListing.rows(Self.tracks, filter: "", sort: .init(key: .title))
        #expect(byTitle.map(\.videoId) == ["3", "4", "2", "1"]) // Apple, Đơn, lán…, (The) Zoo
        let desc = QTTrackListing.rows(Self.tracks, filter: "", sort: .init(key: .title, ascending: false))
        #expect(desc.map(\.videoId) == ["1", "2", "4", "3"])
        #expect(QTTrackListing.rows(Self.tracks, filter: "", sort: .init(key: .time)).map(\.videoId) == ["2", "3", "4", "1"])
        #expect(QTTrackListing.rows(Self.tracks, filter: "", sort: .init(key: .album)).map(\.videoId) == ["2", "1", "3", "4"])
    }
}

@Suite @MainActor struct QTNavigatorTests {
    @Test func backForwardHistory() {
        let nav = QTNavigator()
        #expect(!nav.canGoBack && !nav.canGoForward)
        nav.go(.section(.liked))
        nav.go(.album("LINK"))
        #expect(nav.current == .album("LINK"))
        nav.goBack()
        #expect(nav.current == .section(.liked))
        #expect(nav.canGoForward)
        nav.goBack()
        #expect(nav.current == .section(.home))
        nav.goForward()
        #expect(nav.current == .section(.liked))
        nav.go(.section(.songs))
        #expect(!nav.canGoForward) // a new page drops the forward stack
        nav.go(.section(.songs))
        #expect(nav.backStack.count == 2) // same page is a no-op
    }

    @Test func remembersPerPageState() {
        let nav = QTNavigator()
        nav.setScrollOffset(420, for: .section(.liked))
        #expect(nav.scrollOffset(for: .section(.liked)) == 420)
        #expect(nav.scrollOffset(for: .section(.home)) == 0)
        let s = nav.listState(for: "liked")
        s.filter = "perfect"
        #expect(nav.listState(for: "liked").filter == "perfect")
        #expect(QTTrackCollection.listKey(for: .section(.playlist("pl-1"))) == "playlist:pl-1")
        #expect(QTTrackCollection.listKey(for: .section(.home)) == nil)
    }

    @Test func playlistEditsAndUndo() {
        let edits = QTPlaylistEdits()
        let p = QTPlaylist(id: "pl-x", title: .verbatim("Sugar"), tracks: [QTTrackListingTests.tracks[0]])
        #expect(edits.add(["1", "2", "2", "3"], to: p) == ["2", "3"])
        #expect(edits.add(["2"], to: p).isEmpty)
        edits.undoAdd(["2", "3"], to: "pl-x")
        #expect(edits.added["pl-x"]?.isEmpty == true)
    }

    @Test func linksRoundTrip() {
        let t = QTTrackListingTests.tracks[1]
        let link = QTTrackActions.link(for: t)
        #expect(link == "https://music.youtube.com/watch?v=2")
        #expect(QTTrackActions.videoID(fromLink: link) == "2")
        #expect(QTTrackActions.videoID(fromLink: "https://www.youtube.com/watch?v=abc&list=LM") == "abc")
        #expect(QTTrackActions.videoID(fromLink: "hello") == nil)
    }
}

@Suite struct QTWindowStringsTests {
    @Test func pluralsInMainTable() {
        let en = QTLocalizer(preference: .enUS)
        #expect(en.format("%lld songs", table: .main, arguments: [1]) == "1 song")
        #expect(en.format("%lld songs", table: .main, arguments: [3]) == "3 songs")
        #expect(en.format("Added %lld songs to %@", table: .main, arguments: [2, "Sugar"]) == "Added 2 songs to Sugar")
        let zh = QTLocalizer(preference: .zhCN)
        #expect(zh.format("Added %lld songs to %@", table: .main, arguments: [2, "Sugar"]) == "已将 2 首歌曲添加到Sugar")
        #expect(zh.format("No songs match “%@”.", table: .main, arguments: ["x"]) == "没有与“x”匹配的歌曲。")
    }
}
