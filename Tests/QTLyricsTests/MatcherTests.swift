import Foundation
import QTCore
import Testing
@testable import QTLyrics

@Suite struct FoldingTests {
    @Test func comparisonKeys() {
        #expect(QTLyricsTextFolding.comparisonKey("Đối Với Anh Em") == "doivoianhem")
        #expect(QTLyricsTextFolding.comparisonKey("Hạ Phỏm") == "haphom")
        #expect(QTLyricsTextFolding.comparisonKey("ha phom") == "haphom")
        #expect(QTLyricsTextFolding.comparisonKey("周杰倫") == QTLyricsTextFolding.comparisonKey("周杰伦"))
        #expect(QTLyricsTextFolding.comparisonKey("華語歌曲") == "华语歌曲")
        #expect(QTLyricsTextFolding.comparisonKey("カタカナ") == "かたかな")
        #expect(QTLyricsTextFolding.comparisonKey("ガラス") == "がらす")
        #expect(QTLyricsTextFolding.comparisonKey("Sơn Tùng M-TP") == "sontungmtp")
        #expect(QTLyricsTextFolding.comparisonKey("ＦＵＬＬ　ＷＩＤＴＨ") == "fullwidth")
        #expect(QTLyricsTextFolding.comparisonKey("사랑해") == "사랑해")
    }

    @Test func hanziTableIsCompactAndCorrect() {
        #expect(QTHanziConversion.map.count > 2500)
        #expect(QTHanziConversion.simplified("臺灣的國語歌") == "台湾的国语歌")
        #expect(QTHanziConversion.isMostlyTraditional("故事的小黃花從出生那年就飄著"))
        #expect(!QTHanziConversion.isMostlyTraditional("故事的小黄花从出生那年就飘着"))
    }

    @Test func titleCleaning() {
        let a = QTTitleCleaner.clean("Đối Với Anh Em Không Còn Cảm Giác (Official Music Video) 【MV】 4K")
        #expect(a.core == "Đối Với Anh Em Không Còn Cảm Giác")
        #expect(a.tags.isEmpty)
        let b = QTTitleCleaner.clean("Hạ Phỏm (出牌)")
        #expect(b.core == "Hạ Phỏm")
        #expect(b.alternates == ["出牌"])
        let c = QTTitleCleaner.clean("Perfect (Live)")
        #expect(c.core == "Perfect")
        #expect(c.tags == [.live])
        let d = QTTitleCleaner.clean("夜に駆ける - From THE FIRST TAKE")
        #expect(d.core == "夜に駆ける")
        #expect(d.tags.contains(.live))
        #expect(QTTitleCleaner.clean("Arz Kiya Hai | Coke Studio Bharat").core == "Arz Kiya Hai")
        #expect(QTTitleCleaner.clean("Perfect feat. Beyoncé").core == "Perfect")
        #expect(QTTitleCleaner.clean("晴天 (原唱 周杰伦)").tags.contains(.cover))
        #expect(QTTitleCleaner.cleanArtist("Kim Ny Ngọc - Topic") == "Kim Ny Ngọc")
        #expect(QTTitleCleaner.splitArtists("Hoàng Thùy Linh/Dtap") == ["Hoàng Thùy Linh", "Dtap"])
    }

    @Test func jaroWinkler() {
        #expect(QTJaroWinkler.similarity("martha", "marhta") > 0.96)
        #expect(QTJaroWinkler.similarity("abc", "abc") == 1)
        #expect(QTJaroWinkler.similarity("abc", "xyz") == 0)
        #expect(QTJaroWinkler.similarity("", "") == 0)
    }
}

@Suite struct ScorerTests {
    let hero = QTFixtureSong.named("doivoianh").query

    @Test func weightsAndThresholds() {
        let scorer = QTLyricsMatchScorer()
        let exact = QTLyricsCandidate(source: .netease, remoteID: "1", title: "Đối Với Anh Em Không Còn Cảm Giác",
                                      artists: ["Kim Ny Ngọc"], duration: 257.3)
        let s = scorer.score(exact, for: hero)
        #expect(s.total == 1)
        #expect(s.isAcceptable(for: .netease))

        // Folded spelling still matches.
        var folded = exact
        folded.title = "Doi Voi Anh Em Khong Con Cam Giac"
        folded.artists = ["Kim Ny Ngoc"]
        #expect(scorer.score(folded, for: hero).total == 1)

        // Duration: 1 within ±2 s, linear to 0 at ±15 s, rejected beyond ±20 s.
        var off = exact
        off.duration = 257 + 8.5
        #expect(abs(scorer.score(off, for: hero).duration - 0.5) < 0.001)
        off.duration = 257 + 21
        #expect(scorer.score(off, for: hero).rejection == .durationMismatch)
        #expect(scorer.score(off, for: hero).total == 0)

        // Unknown duration is neutral: perfect title + artist = 0.9.
        var unknown = exact
        unknown.duration = nil
        #expect(abs(scorer.score(unknown, for: hero).total - 0.9) < 0.001)

        // Version tags only one side has cost 0.15 each.
        var live = exact
        live.title += " (Live)"
        #expect(abs(scorer.score(live, for: hero).total - 0.85) < 0.001)
    }

    @Test func unofficialSourcesNeedEightyPercent() {
        let s = QTLyricsMatchScore(title: 1, artist: 0.5, duration: 1, penalty: 0, rejection: nil)   // 0.8
        #expect(s.isAcceptable(for: .netease))
        let t = QTLyricsMatchScore(title: 1, artist: 0.45, duration: 1, penalty: 0, rejection: nil)  // 0.78
        #expect(!t.isAcceptable(for: .kugou))
        #expect(t.isAcceptable(for: .lrclib))   // safe: 0.60–0.80 → "possible mismatch"
        let u = QTLyricsMatchScore(title: 0.5, artist: 0.5, duration: 0.5, penalty: 0, rejection: nil) // 0.5
        #expect(!u.isAcceptable(for: .lrclib))
    }

    /// 周杰伦 = Jay Chou: cross-script names only match once the alias is known (learned from provider metadata).
    @Test func jayChouAlias() {
        let query = QTLyricsQuery(videoId: "SJKoWAd5ySo", title: "晴天", artists: ["Jay Chou"], duration: 269)
        let kugou = QTLyricsCandidate(source: .kugou, remoteID: "34988004", title: "晴天", artists: ["周杰伦"], duration: 269)
        let cold = QTLyricsMatchScorer().score(kugou, for: query)
        #expect(cold.total < QTLyricsMatchThreshold.unofficial)

        // NetEase lists the alias on the artist → the candidate itself matches…
        let netease = QTLyricsCandidate(source: .netease, remoteID: "186016", title: "晴天", artists: ["周杰伦"],
                                        artistAliases: ["Jay Chou"], duration: 269)
        #expect(QTLyricsMatchScorer().score(netease, for: query).total == 1)

        // …and once learned, every other provider's 周杰伦 (or 周杰倫) matches "Jay Chou".
        var book = QTLyricsAliasBook()
        let added = book.add("周杰伦", "Jay Chou")
        let addedAgain = book.add("周杰倫", "Jay Chou")   // same keys after T→S folding
        #expect(added)
        #expect(!addedAgain)
        let warm = QTLyricsMatchScorer(aliases: book)
        #expect(warm.score(kugou, for: query).total == 1)
        var traditional = kugou
        traditional.artists = ["周杰倫"]
        #expect(warm.score(traditional, for: query).total == 1)
    }

    /// Hạ Phỏm = 出牌 via NetEase `tns`.
    @Test func haPhomAlias() throws {
        let query = QTFixtureSong.named("haphom").query
        let candidates = try QTNetEaseLyricsProvider.parseSearch(try #require(QTFixtures.song("haphom", "netease_search.json")),
                                                                  source: .netease)
        let scorer = QTLyricsMatchScorer()
        let ranked = candidates.map { ($0, scorer.score($0, for: query)) }.sorted { $0.1.total > $1.1.total }
        #expect(ranked.first?.0.remoteID == "1968907343")
        #expect(ranked.first?.0.titleAliases == ["出牌"])
        // See Tình (the first search hit) is rejected.
        let seeTinh = try #require(ranked.first { $0.0.remoteID == "1921150691" })
        #expect(!seeTinh.1.isAcceptable(for: .netease))

        var book = QTLyricsAliasBook()
        book.add("Hạ Phỏm", "出牌")
        let qq = QTLyricsCandidate(source: .qq, remoteID: "1", title: "出牌", artists: ["Hoàng Thùy Linh"])
        #expect(QTLyricsMatchScorer().score(qq, for: query).total < 0.8)
        #expect(QTLyricsMatchScorer(aliases: book).score(qq, for: query).total >= 0.8)
        // And the reverse direction: a Chinese-titled query finds the Vietnamese title.
        let zhQuery = QTLyricsQuery(videoId: "x", title: "出牌", artists: ["Hoàng Thùy Linh"], duration: 196)
        let vi = QTLyricsCandidate(source: .kugou, remoteID: "2", title: "Hạ Phỏm", artists: ["Hoàng Thùy Linh"], duration: 195.8)
        #expect(QTLyricsMatchScorer(aliases: book).score(vi, for: zhQuery).total == 1)
    }

    @Test func qingtianCoversOnNetEaseAreRejected() throws {
        let query = QTFixtureSong.named("qingtian").query
        let candidates = try QTNetEaseLyricsProvider.parseSearch(try #require(QTFixtures.song("qingtian", "netease_search.json")),
                                                                  source: .netease)
        let scorer = QTLyricsMatchScorer()
        #expect(candidates.allSatisfy { !scorer.score($0, for: query).isAcceptable(for: .netease) })
        // The spam "Jay" account lists 周杰伦 among four aliases: not trusted as aliases.
        let jay = try #require(candidates.first { $0.artists == ["Jay"] })
        #expect(jay.artistAliases.isEmpty)
    }

    @Test func kugouHeroRemixIsRejectedAfterFetch() throws {
        let query = QTFixtureSong.named("doivoianh").query
        let candidates = try QTKugouLyricsProvider.parseSearch(try #require(QTFixtures.song("doivoianh", "kugou_search.json")),
                                                                source: .kugou)
        let remix = try #require(candidates.first { $0.remoteID == "61809392" })
        #expect(remix.duration == 254)   // Kugou reports seconds here
        let scorer = QTLyricsMatchScorer()
        let pre = scorer.score(remix, for: query)
        #expect(pre.isAcceptable(for: .kugou))
        let download = try #require(QTFixtures.song("doivoianh", "kugou_download.json"))
        let parsed = try #require(try QTKugouLyricsProvider.parseDownload(download))
        #expect(parsed.metadata.title?.hasSuffix("Remix") == true)
        let post = scorer.rescore(pre, candidate: remix, lyrics: parsed, for: query)
        #expect(!post.isAcceptable(for: .kugou))
    }

    @Test func lyricsRunningPastTheTrackAreRejected() {
        let query = QTLyricsQuery(videoId: "v", title: "Song", artists: ["A"], duration: 100)
        let c = QTLyricsCandidate(source: .lrclib, remoteID: "1", title: "Song", artists: ["A"], duration: 100)
        let parsed = QTParsedLyrics(lines: [QTParsedLyricsLine(start: 10, end: 12, text: "a"),
                                            QTParsedLyricsLine(start: 106, end: 108, text: "b")])
        let s = QTLyricsMatchScorer().rescore(QTLyricsMatchScorer().score(c, for: query), candidate: c, lyrics: parsed, for: query)
        #expect(s.rejection == .overrunsTrack)
    }
}
