import Foundation
import QTCore
import Testing
@testable import QTInnerTube

/// `QT_DUMP=1 swift test --filter Dump` prints what every parser makes of the fixtures (for eyeballing).
@Suite("Dump", .enabled(if: ProcessInfo.processInfo.environment["QT_DUMP"] == "1"))
struct DumpTests {
    func describe(_ item: QTShelfItem) -> String {
        switch item {
        case .track(let t), .video(let t):
            let cp = t.counterpart.map { " ⇄\($0.videoId)" } ?? ""
            return "\(item.id) “\(t.title)” — \(t.artistLine) [\(t.album?.title ?? "-")] \(Int(t.duration))s \(t.musicVideoType.rawValue.suffix(3)) art:\(t.artwork.count)\(cp)"
        case .album(let a): return "\(item.id) “\(a.title)” — \(a.artists.map(\.name)) \(a.kind) \(a.year.map(String.init) ?? "-")"
        case .playlist(let p): return "\(item.id) “\(p.title.resolved)” by \(p.owner ?? "-") \(p.kind)"
        case .artist(let a): return "\(item.id) “\(a.name)” art:\(a.artwork.count)"
        }
    }

    func dump(_ shelves: [QTShelf]) {
        for s in shelves {
            print("  ▸ \(s.title.resolved) [\(s.style)] \(s.items.count) id=\(s.id)")
            for i in s.items.prefix(3) { print("     \(describe(i))") }
        }
    }

    @Test func dumpAll() throws {
        for name in ["home-en", "home-zh", "home-continuation-en", "home-continuation-podcasts-en"] {
            let p = QTInnerTubeParser.home(try Fixture.json(name))
            print("== \(name) moods=\(p.feed.moods.map { $0.title.resolved }) cont=\(p.continuation != nil)")
            dump(p.feed.shelves)
        }
        let e = QTInnerTubeParser.explore(try Fixture.json("explore-en"))
        print("== explore dest=\(e.destinations.map { $0.title.resolved }) moods=\(e.moods.count)")
        dump(e.shelves)
        for name in ["new-releases-en", "charts-en"] {
            print("== \(name)")
            dump(QTInnerTubeParser.shelves(try Fixture.json(name)))
        }
        let m = QTInnerTubeParser.moods(try Fixture.json("moods-en"))
        print("== moods \(m.groups.map { "\($0.title):\($0.moods.count)" }) first=\(m.groups.first?.moods.first?.id ?? "")")
        for (name, filter) in [("search-trumua-en", QTSearchFilter.all), ("search-trumua-songs-en", .songs),
                               ("search-trumua-videos-en", .videos), ("search-trumua-playlists-en", .playlists),
                               ("search-qingtian-zh", .all), ("search-qingtian-albums-zh", .albums),
                               ("search-trumua-songs-continuation-en", .songs)] {
            let r = QTInnerTubeParser.search(try Fixture.json(name), filter: filter)
            print("== \(name) top=\(r.topResult.map(describe) ?? "-") cont=\(r.continuation != nil)")
            for i in r.items { print("   \(describe(i))") }
        }
        for (name, id) in [("album-qilixiang-zh", "MPREb_ScDJHCiomAo"), ("album-hkt-en", "MPREb_JR856gupBGZ")] {
            let a = QTInnerTubeParser.album(try Fixture.json(name), browseId: id)!
            print("== \(name) “\(a.album.title)” \(a.album.artists.map(\.name)) \(a.album.year ?? 0) \(a.album.kind) pl=\(a.playlistId ?? "-") \(a.summary ?? "") art=\(a.album.artwork.count)")
            for t in a.album.tracks ?? [] { print("   \(describe(.track(t)))") }
            dump(a.shelves)
        }
        for (name, id) in [("artist-hkt-en", "UCjF7hNeaqArVJmijVgz-bjg"), ("artist-jay-zh", "UCL2MDNdwEtV6aYUgNjFQGZA")] {
            let a = QTInnerTubeParser.artist(try Fixture.json(name), browseId: id)!
            print("== \(name) \(a.artist.name) aud=\(a.audience ?? "-") songsPl=\(a.songsPlaylistId ?? "-") vidPl=\(a.videosPlaylistId ?? "-") desc=\(a.description?.prefix(30) ?? "-")")
            print("   songs \(a.songs.map { describe(.track($0)) })")
            print("   albums \(a.albums.map(\.title)) singles \(a.singles.map(\.title)) videos \(a.videos.map(\.title)) playlists \(a.playlists.map { $0.title.resolved }) related \(a.relatedArtists.map(\.name))")
        }
        for (name, id) in [("playlist-jay-zh", "VLRDCLAK5uy_l12ynH8dyLsBmE11ToAHLm9P04NS2i9ME"),
                           ("playlist-classic-rock-en", "VLPL0GvsLQil0MmYC96KEs_7dTNsLm1PS6JX")] {
            let p = QTInnerTubeParser.playlist(try Fixture.json(name), browseId: id)!
            print("== \(name) “\(p.playlist.title.resolved)” by \(p.playlist.owner ?? "-") total=\(p.totalTrackCount ?? -1) \(p.summary ?? "") cont=\(p.continuation != nil) art=\(p.playlist.artwork.count)")
            for t in p.playlist.tracks ?? [] { print("   \(describe(.track(t)))") }
        }
        let c = QTInnerTubeParser.trackContinuation(try Fixture.json("playlist-classic-rock-continuation-en"))
        print("== playlist cont \(c.tracks.count) cont=\(c.continuation != nil)")
        for name in ["next-trumua-en", "next-radio-trumua-en", "next-radio-trumua-continuation-en", "next-loiyeudo-song-en",
                     "next-loiyeudo-video-en"] {
            let n = QTInnerTubeParser.next(try Fixture.json(name))
            print("== \(name) sel=\(n.selectedIndex ?? -1) pl=\(n.playlistId ?? "-") automix=\(n.automix?.browseId ?? "-") cont=\(n.continuation != nil) lyrics=\(n.lyricsBrowseId ?? "-") related=\(n.relatedBrowseId ?? "-")")
            for t in n.tracks.prefix(4) { print("   \(describe(.track(t)))") }
        }
        print("== queue \(QTInnerTubeParser.queue(try Fixture.json("queue-loiyeudo-en")).map { describe(.track($0)) })")
        print("== player \(String(describing: QTInnerTubeParser.player(try Fixture.json("player-loiyeudo-en"))))")
    }
}
