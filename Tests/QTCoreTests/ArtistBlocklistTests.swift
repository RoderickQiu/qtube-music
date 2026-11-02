import Foundation
import Testing
@testable import QTCore

/// "Don't Play This Artist": the matching rules and the filters every surface uses.
@Suite struct ArtistBlocklistTests {
    let velvet = QTBlockedArtist(channelID: "UCvelvet", name: "The Velvet Sundown")
    let byName = QTBlockedArtist(name: "Aurora")

    func track(_ id: String, _ artists: QTArtistRef...) -> QTTrack {
        QTTrack(videoId: id, title: id, artists: artists, duration: 180)
    }

    @Test func matchesTheChannelIDOrTheExactNameLowerCased() {
        let list = QTArtistBlocklist([velvet, byName])
        #expect(list.blocks(QTArtistRef(id: "UCvelvet", name: "Renamed Band")), "the id matches whatever the name")
        #expect(list.blocks(QTArtistRef(id: "MPLAUCvelvet", name: "x")), "a library artist id is the channel")
        #expect(list.blocks(QTArtistRef(name: "the velvet sundown")))
        #expect(list.blocks(QTArtistRef(name: "  THE VELVET SUNDOWN ")))
        #expect(list.blocks(QTArtistRef(id: "UCother", name: "AURORA")))
        #expect(!list.blocks(QTArtistRef(name: "Aurora Aksnes")), "no fuzzy matching")
        #expect(!list.blocks(QTArtistRef(name: "Auroras")))
        #expect(!list.blocks(QTArtistRef(name: "The Velvet Sundown Band")))
        #expect(!list.blocks(QTArtistRef(name: "Velvet Sundown")))
        #expect(!QTArtistBlocklist().blocks(QTArtistRef(name: "Aurora")))
    }

    @Test func comparesNamesInOneUnicodeForm() {
        let list = QTArtistBlocklist([QTBlockedArtist(name: "Sơn Tùng M-TP")])
        let decomposed = "Sơn Tùng M-TP".decomposedStringWithCanonicalMapping
        #expect(list.blocks(QTArtistRef(name: decomposed)))
        #expect(!list.blocks(QTArtistRef(name: "Son Tung M-TP")), "diacritics are not folded")
        let han = QTArtistBlocklist([QTBlockedArtist(name: "李健")])
        #expect(han.blocks(QTArtistRef(name: "李健")))
        #expect(!han.blocks(QTArtistRef(name: "李健 Li Jian")))
    }

    @Test func aSongIsBlockedWhenAnyArtistIs() {
        let list = QTArtistBlocklist([byName])
        #expect(list.blocks(track("a", QTArtistRef(name: "Someone"), QTArtistRef(name: "Aurora"))))
        #expect(!list.blocks(track("b", QTArtistRef(name: "Someone"))))
    }

    @Test func addingIsOnceAndRemovingAllowsByIDAndName() {
        var list = QTArtistBlocklist()
        let first = list.add(velvet)
        let sameID = list.add(QTBlockedArtist(channelID: "UCvelvet", name: "Other spelling"))
        let sameName = list.add(QTBlockedArtist(name: "THE VELVET SUNDOWN"))
        #expect(first && !sameID && !sameName)
        #expect(list.entries == [velvet])
        list = QTArtistBlocklist([velvet, QTBlockedArtist(name: "the velvet sundown"), byName])
        let removed = list.remove(QTArtistRef(id: "UCvelvet", name: "The Velvet Sundown"))
        #expect(removed.count == 2)
        #expect(list.entries == [byName])
        #expect(list.remove(QTArtistRef(name: "Nobody")).isEmpty)
    }

    @Test func entryIDsAreStable() {
        #expect(velvet.id == "id:UCvelvet")
        #expect(byName.id == "name:aurora")
        #expect(QTBlockedArtist(channelID: "MPLAUCx", name: "X").channelID == "UCx")
    }

    @Test func shelvesLoseBlockedItemsAndEmptyShelvesGo() {
        let list = QTArtistBlocklist([velvet])
        let v = QTArtistRef(id: "UCvelvet", name: "The Velvet Sundown")
        let other = QTArtistRef(id: "UCok", name: "Real Band")
        let shelves = [
            QTShelf(id: "quick", title: .verbatim("Quick picks"), style: .quickPicks, items: [
                .track(track("a", v)), .track(track("b", other)), .video(track("c", other, v)),
            ]),
            QTShelf(id: "albums", title: .verbatim("Albums"), style: .cards, items: [
                .album(QTAlbum(id: "MPREb_1", title: "Floating", artists: [v])),
                .playlist(QTPlaylist(id: "VLPL1", title: .verbatim("Mix"))),
            ]),
            QTShelf(id: "artists", title: .verbatim("Fans also like"), style: .cards, items: [
                .artist(QTArtist(id: "UCvelvet", name: "The Velvet Sundown")),
            ]),
        ]
        let filtered = list.filter(shelves)
        #expect(filtered.map(\.id) == ["quick", "albums"])
        #expect(filtered[0].items.map(\.id) == ["track:b"])
        #expect(filtered[1].items.map(\.id) == ["playlist:VLPL1"], "playlists stay: who is in them isn't known")

        // The artist's own page keeps its rows.
        let own = list.filter(shelves, keeping: v)
        #expect(own.map(\.id) == ["quick", "albums", "artists"])
        #expect(own[0].items.count == 3)
        #expect(QTArtistBlocklist().filter(shelves) == shelves)
    }

    @Test func aSearchThatNamesABlockedArtistShowsThem() {
        let list = QTArtistBlocklist([velvet, byName])
        let asked = list.ignoringArtists(named: " the velvet sundown ")
        #expect(!asked.blocks(QTArtistRef(name: "The Velvet Sundown")))
        #expect(asked.blocks(QTArtistRef(name: "Aurora")))
        #expect(list.ignoringArtists(named: "velvet") == list)
    }

    @Test func settingsKeepTheListAndOldSettingsStillDecode() throws {
        let old = try JSONDecoder().decode(QTSettings.self, from: Data(#"{"theme":"dark","preferVideos":true}"#.utf8))
        #expect(old.blockedArtists.isEmpty)
        #expect(old.preferVideos)
        var s = QTSettings()
        s.blockedArtists = [velvet, byName]
        let back = try JSONDecoder().decode(QTSettings.self, from: JSONEncoder().encode(s))
        #expect(back.blockedArtists == [velvet, byName])
        #expect(back.artistBlocklist.blocks(QTArtistRef(name: "aurora")))
        let bad = try JSONDecoder().decode(QTSettings.self, from: Data(#"{"blockedArtists":"bogus","theme":"light"}"#.utf8))
        #expect(bad.blockedArtists.isEmpty && bad.theme == .light, "a bad list never loses the other settings")
    }
}
