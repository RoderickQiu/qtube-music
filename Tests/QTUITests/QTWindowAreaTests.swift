import AppKit
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

    /// The A–Z strip only helps long, title-sorted lists; it's script-aware (pinyin initials for Han, "#" else).
    @Test @MainActor func alphabetStripOnlyForLongTitleSortedLists() {
        #expect(!QTTrackTableCoordinator.wantsAlphabet(rowCount: 12, sort: .title))
        #expect(!QTTrackTableCoordinator.wantsAlphabet(rowCount: 60, sort: .title))
        #expect(QTTrackTableCoordinator.wantsAlphabet(rowCount: 156, sort: .title))
        for key in [QTTrackSort.Key.added, .album, .artist, .time] {
            #expect(!QTTrackTableCoordinator.wantsAlphabet(rowCount: 156, sort: key))
        }
        #expect(QTTextFolding.indexLetter("晴天") == "Q")
        #expect(QTTextFolding.indexLetter("周杰伦") == "Z")
        #expect(QTTextFolding.indexLetter("「告白气球」") == "G" || QTTextFolding.indexLetter("「告白气球」") == "#")
    }
}

/// Library › Albums / Artists from the demo library (the live library brings its own).
@Suite struct QTLibraryIndexTests {
    @Test func albumsAndArtistsFromSongs() {
        let tracks = QTTrackListingTests.tracks + [QTTrackListingTests.track("5", "B side", album: "B", artist: "Y")]
        let albums = QTLibraryIndex.albums(tracks)
        #expect(albums.map(\.title) == ["A", "B", "C", "D"])
        #expect(albums.first { $0.title == "B" }?.tracks?.map(\.videoId) == ["1", "5"])
        #expect(albums.allSatisfy { $0.id == $0.title }) // demo browse pages open albums by title
        let artists = QTLibraryIndex.artists(tracks)
        #expect(artists.map(\.name) == ["X", "Y"])
        #expect(artists.allSatisfy { $0.id == $0.name })
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

@Suite @MainActor struct QTBrowseServiceTests {
    static func t(_ id: String, _ title: String, artist: String, album: String, video: Bool = false) -> QTTrack {
        QTTrack(videoId: id, title: title, artists: [QTArtistRef(name: artist)], album: QTAlbumRef(title: album),
                duration: 200, musicVideoType: video ? .omv : .atv)
    }

    static let catalog = QTMockCatalog(
        tracks: [
            t("a", "Hạ Phỏm", artist: "Hoàng Thùy Linh", album: "LINK", video: true),
            t("b", "丽江", artist: "李健", album: "拾光", video: true),
            t("c", "蓝色夜曲", artist: "李健", album: "蓝色夜曲"),
        ],
        liked: QTPlaylist(id: "LM", title: .verbatim("Liked Songs"), kind: .liked, tracks: []),
        playlists: [QTPlaylist(id: "pl-1", title: .verbatim("Lì xì"), tracks: [])],
        home: QTHomeFeed(moods: [QTMoodChip(id: "mood-relax", title: .verbatim("Relax"))]))

    @Test func searchGroupsMusicResults() {
        let service = QTMockBrowseService(catalog: Self.catalog)
        let r = service.searchNow("李健")
        // An artist named exactly like the query is the top result; their songs follow.
        #expect(r.topResult == .artist(QTArtist(id: "李健", name: "李健", artwork: [])))
        #expect(Set(r.songs.map(\.videoId)) == ["b", "c"])
        #expect(r.videos.map(\.videoId) == ["b"])
        #expect(service.searchNow("ha phom").topResult == .track(Self.catalog.tracks[0]))
        #expect(service.searchNow("li xi").playlists.map(\.id) == ["pl-1"])
        #expect(service.searchNow("   ").items.isEmpty)
        #expect(service.searchNow("   ").topResult == nil)
    }

    @Test func artistAndAlbumPages() throws {
        let service = QTMockBrowseService(catalog: Self.catalog)
        let artist = try #require(service.artistNow("李健"))
        #expect(artist.songs.count == 2)
        #expect(artist.albums.map(\.title) == ["拾光"])
        #expect(artist.singles.map(\.title) == ["蓝色夜曲"]) // one song named like its album
        #expect(artist.videos.map(\.videoId) == ["b"])
        #expect(artist.relatedArtists.map(\.name) == ["Hoàng Thùy Linh"])
        #expect(service.albumNow("LINK")?.album.tracks?.map(\.videoId) == ["a"])
        #expect(service.albumNow("nope") == nil)
        // The artist page's rows, in display order, like the live parser's `shelves`.
        #expect(artist.shelves.map(\.id) == ["artist.albums", "artist.singles", "artist.videos", "artist.related"])
        // Pages answer through the shared request API too (no loading state for the demo catalog).
        #expect(service.cached(.artist("李健"))?.artist == artist)
        #expect(service.cached(.album("LINK"))?.album?.album.title == "LINK")
        #expect(service.cached(.album("nope")) == nil)
    }

    @Test func exploreHasEverySection() {
        let service = QTMockBrowseService(catalog: Self.catalog)
        let e = service.exploreNow()
        #expect(e.shelves.map(\.id) == ["explore.new", "explore.charts", "explore.videos"])
        #expect(e.shelves[0].items.count == 3)
        #expect(e.shelves[1].items.count == 3)
        #expect(e.shelves[2].items.count == 2)
        #expect(service.exploreSectionNow(.charts).map(\.id) == ["explore.charts"])
        #expect(service.exploreSectionNow(.newReleases).first?.id == "explore.new")
        let moods = service.moodsNow()
        #expect(moods.groups.count == 2)
        #expect(moods.groups[0].moods.map(\.id) == ["mood-relax"])
        #expect(moods.groups[1].moods.count == QTMockBrowseService.genres.count)
        // Stable chart order across runs.
        #expect(e.shelves[1] == QTMockBrowseService(catalog: Self.catalog).exploreNow().shelves[1])
    }

    @Test func destinationsAddressByIDWhenKnown() {
        #expect(QTDestination.album(QTAlbumRef(id: "MPREb_x", title: "LINK")) == .album("MPREb_x"))
        #expect(QTDestination.album(QTAlbumRef(title: "LINK")) == .album("LINK"))
        #expect(QTDestination.artist(QTArtistRef(id: "UCabc", name: "李健")) == .artist("UCabc"))
        #expect(QTDestination.artist(QTArtistRef(name: "李健")) == .artist("李健"))
        #expect(QTWindowTitle.isBrowseID("MPREb_abcdefghij"))
        #expect(!QTWindowTitle.isBrowseID("Ultraviolet"))
    }

    @Test func moodDestinationHasItsOwnState() {
        let chip = QTMoodChip(id: "genre:Pop", title: .verbatim("Pop"))
        #expect(QTDestination.mood(chip).stateKey == "mood:genre:Pop")
        #expect(QTDestination.mood(chip).sidebarItem == nil)
        #expect(QTTrackCollection.listKey(for: .mood(chip)) == nil)
    }

    @Test func filteredCountLine() {
        let en = QTLocalizer(preference: .enUS)
        #expect(en.format("%lld of %lld songs", table: .main, arguments: [2, 12]) == "2 of 12 songs")
        #expect(en.format("%lld of %lld songs", table: .main, arguments: [1, 1]) == "1 of 1 song")
        let zh = QTLocalizer(preference: .zhCN)
        #expect(zh.format("%lld of %lld songs", table: .main, arguments: [2, 12]) == "2 / 12 首")
    }
}

/// Sidebar rename in place, like Finder and Music: however it ends, it ends once; only Esc drops the typed name.
@Suite @MainActor struct QTInPlaceRenameTests {
    @Test func endsOnceAndOnlyEscDropsTheName() {
        var rename = QTInPlaceRename()
        // Not started: nothing to end.
        #expect(rename.end(draft: "New", original: "Old") == nil)
        rename.begin()
        // A click outside (or ↩, focus leaving, the window losing key) keeps the trimmed name…
        #expect(rename.end(draft: "  Night Renamed ", original: "Night") == "Night Renamed")
        // …once: the focus loss that follows the same click saves nothing more.
        #expect(rename.isEnded)
        #expect(rename.end(draft: "Night Renamed", original: "Night") == nil)
        // Esc, then the focus loss it causes: nothing saved.
        rename.begin()
        #expect(rename.end(cancelled: true, draft: "Typed", original: "Night") == nil)
        #expect(rename.end(draft: "Typed", original: "Night") == nil)
        // Blank or unchanged: nothing to save.
        rename.begin()
        #expect(rename.end(draft: "   ", original: "Night") == nil)
        rename.begin()
        #expect(rename.end(draft: "Night", original: "Night") == nil)
    }

    @Test func clicksOutsideTheFieldOrInAnotherWindowCount() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                             backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        other.isReleasedWhenClosed = false
        let field = NSRect(x: 40, y: 200, width: 160, height: 22)
        func outside(_ x: CGFloat, _ y: CGFloat, in w: NSWindow?) -> Bool {
            QTClickOutsideMonitor.isOutside(click: NSPoint(x: x, y: y), clickWindow: w, frame: field, frameWindow: window)
        }
        #expect(!outside(100, 210, in: window))      // in the field: keeps editing
        #expect(outside(300, 100, in: window))       // empty content
        #expect(outside(100, 260, in: window))       // the row above, the toolbar
        #expect(outside(100, 210, in: other))        // same spot, another window
        #expect(outside(100, 210, in: nil))          // a click with no window (menu bar extra, Dock)
    }
}
