import Foundation
import QTCore
import SQLite3
import Testing
@testable import QTLyrics

// Wrong-lyrics defences (prelaunch §8): reports that stick, "No Lyrics for This Song", same text for different
// songs, script / gibberish / coverage penalties, unofficial sources without a length, offsets per version and the
// cache migration. Every lyric line here is invented placeholder text.

/// Serves one fixed text for whatever is asked (the Pear #4684 pattern), word-synced so it would rank first.
struct QTDecoyLyricsProvider: QTLyricsSourceProvider {
    static let lines = ["Paper lanterns over Harbour Street", "Counting trams until the morning", "Every window keeps a little light",
                        "Somebody hums the same old tune", "Rain on the awnings, rain on the rails", "We walk the long way home again",
                        "Pockets full of ticket stubs", "And nothing else to say tonight"]
    let source = QTLyricsSource(id: "decoy", name: "Decoy")

    func search(_ query: QTLyricsQuery) async throws -> [QTLyricsCandidate] {
        [QTLyricsCandidate(source: source, remoteID: "same", title: query.title, artists: query.artists, duration: query.duration)]
    }

    func lyrics(for candidate: QTLyricsCandidate) async throws -> QTParsedLyrics? {
        QTLyricsSanityTests.parsed(Self.lines, wordSynced: true)
    }
}

/// Line-synced lyrics of its own for every song (the text follows the title), several versions per song.
struct QTHonestLyricsProvider: QTLyricsSourceProvider {
    let source = QTLyricsSource.lrclib
    var ids = ["1"]

    func search(_ query: QTLyricsQuery) async throws -> [QTLyricsCandidate] {
        ids.map { QTLyricsCandidate(source: source, remoteID: "\(query.title)#\($0)", title: query.title, artists: query.artists,
                                    duration: query.duration) }
    }

    func lyrics(for candidate: QTLyricsCandidate) async throws -> QTParsedLyrics? {
        QTLyricsSanityTests.parsed((1...8).map { "\(candidate.remoteID) placeholder line number \($0) goes here" })
    }
}

@Suite struct QTLyricsSanityTests {
    /// Lines every 6 s from 2 s (the last one ends near 50 s of a 60 s track).
    static func parsed(_ texts: [String], wordSynced: Bool = false) -> QTParsedLyrics {
        QTParsedLyrics(lines: texts.enumerated().map { i, text in
            let start = Double(i) * 6 + 2
            let words = wordSynced ? [QTLyricsWord(start: start, duration: 4, text: text)] : nil
            return QTParsedLyricsLine(start: start, end: start + 4, text: text, words: words)
        })
    }

    static func query(_ videoId: String, _ title: String, duration: TimeInterval = 60) -> QTLyricsQuery {
        QTLyricsQuery(videoId: videoId, title: title, artists: ["Test Artist"], duration: duration)
    }

    static func tempCacheURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("qt-lyrics-sanity-\(UUID().uuidString)/Lyrics.sqlite")
    }

    // MARK: Same text for different songs

    @Test func decoyServingOneTextForThreeSongsIsRejected() async throws {
        let cache = try QTLyricsCache(url: nil)
        let resolver = QTLyricsResolver(providers: [QTDecoyLyricsProvider(), QTHonestLyricsProvider()], cache: cache)
        let a = Self.query("vidA", "Northern Kettle"), b = Self.query("vidB", "Velvet Compass"), c = Self.query("vidC", "Orange Ferry")

        // First song: nothing to compare with yet, the word-synced decoy wins.
        #expect(await resolver.resolve(a).chosenID == "decoy:same")
        // Second and third: the same text for songs with other titles is filler, never chosen nor offered.
        for q in [b, c] {
            let r = await resolver.resolve(q)
            #expect(r.document?.source == .lrclib, "\(q.title)")
            #expect(!r.versions.contains { $0.id == "decoy:same" })
        }
        // The first song looks again (its cached pick was dropped) and gets its own lyrics too.
        let again = await resolver.resolve(a)
        #expect(!again.fromCache)
        #expect(again.document?.source == .lrclib)
        #expect(again.document?.lines.first?.text.hasPrefix("Northern Kettle") == true)
    }

    @Test func coversAndReReleasesMayShareLyrics() async throws {
        let resolver = QTLyricsResolver(providers: [QTDecoyLyricsProvider()], cache: try QTLyricsCache(url: nil))
        // One song: studio, live and a remaster share their text (titles ≥ 90 % alike).
        for (id, title) in [("v1", "Harbour Lights"), ("v2", "Harbour Lights (Live)"), ("v3", "Harbour Lights - 2015 Remaster")] {
            #expect(await resolver.resolve(Self.query(id, title)).chosenID == "decoy:same", "\(title)")
        }
    }

    // MARK: Report Wrong Lyrics

    @Test func reportedVersionStaysRejectedAcrossResolvers() async throws {
        let url = Self.tempCacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let q = Self.query("vidR", "Silver Teacup")
        let first = QTLyricsResolver(providers: [QTHonestLyricsProvider(ids: ["1", "2"])], cache: try QTLyricsCache(url: url))
        let wrong = try #require(await first.resolve(q).chosenID)
        // One call: the next best version shows at once.
        let next = await first.reject(versionID: wrong, for: q)
        #expect(next.chosenID != nil)
        #expect(next.chosenID != wrong)
        #expect(!next.versions.contains { $0.id == wrong })

        // A relaunch (new cache connection, new resolver, forced lookup) still never shows it.
        let relaunched = QTLyricsResolver(providers: [QTHonestLyricsProvider(ids: ["1", "2"])], cache: try QTLyricsCache(url: url))
        let r = await relaunched.resolve(q, forceRefresh: true)
        #expect(r.chosenID == next.chosenID)
        #expect(!r.versions.contains { $0.id == wrong })
        // Picking it on purpose takes the report back.
        #expect(await relaunched.pin(versionID: wrong, for: q).chosenID == wrong)
        #expect(await relaunched.unpin(for: q).versions.contains { $0.id == wrong })
    }

    @Test func reportingTheOnlyVersionLeavesNoLyrics() async throws {
        let resolver = QTLyricsResolver(providers: [QTHonestLyricsProvider()], cache: try QTLyricsCache(url: nil))
        let q = Self.query("vidO", "Lonely Lighthouse")
        let id = try #require(await resolver.resolve(q).chosenID)
        let r = await resolver.reject(versionID: id, for: q)
        #expect(r.document == nil)
        #expect(r.isComplete)
    }

    // MARK: No Lyrics for This Song

    @Test func noLyricsPinHidesLyricsAndPersists() async throws {
        let url = Self.tempCacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let q = Self.query("vidN", "Quiet Orchard")
        let resolver = QTLyricsResolver(providers: [QTHonestLyricsProvider(ids: ["1", "2"])], cache: try QTLyricsCache(url: url))
        let shown = await resolver.resolve(q)
        #expect(shown.document != nil)

        let off = await resolver.turnOffLyrics(for: q)
        #expect(off.document == nil)
        #expect(off.isLyricsOff)
        #expect(off.isPinned)
        // The versions stay listed so one can be picked again.
        #expect(off.versions.count == 2)

        let relaunched = QTLyricsResolver(providers: [QTHonestLyricsProvider(ids: ["1", "2"])], cache: try QTLyricsCache(url: url))
        #expect(await relaunched.resolve(q).isLyricsOff)
        #expect(await relaunched.pinnedVersionID(for: q.videoId) == QTLyricsCache.noLyricsPin)

        // Automatic brings the lyrics back.
        let back = await relaunched.unpin(for: q)
        #expect(!back.isLyricsOff)
        #expect(back.chosenID == shown.chosenID)
        #expect(back.document != nil)
    }

    // MARK: Script, gibberish, coverage

    static let mash = ["Xkq vbrz plo mnyt qwe dazz", "Zzlp fruk ghanto wxv krrt", "Blorp quazzle frim opu vlinx",
                       "Mnop rtsq vwxy zab quirp lob", "Dranx feek jkdfh sdkjfh weuiry", "Qpwoeiru zmxncb lkajsdhf poiu",
                       "Ytrewq asdfgh zxcvbn mnbvzx", "Lkjhgf poiuqwer zxcvqwer tyui"]

    @Test func latinGibberishOnACJKTitleIsPenalisedNotRejected() {
        let scorer = QTLyricsMatchScorer()
        let q = QTLyricsQuery(videoId: "v", title: "晴空测试曲", artists: ["测试歌手"], duration: 60)
        let candidate = QTLyricsCandidate(source: .lrclib, remoteID: "1", title: "晴空测试曲", artists: ["测试歌手"], duration: 60)
        let before = scorer.score(candidate, for: q)
        let after = scorer.rescore(before, candidate: candidate, lyrics: Self.parsed(Self.mash), for: q)
        #expect(after.flags.contains(.scriptMismatch))
        #expect(after.flags.contains(.gibberish))
        #expect(after.total < before.total)
        #expect(after.total < QTLyricsMatchThreshold.accept)
        // A penalty, never a rejection: it may be the only lyrics there are.
        #expect(after.rejection == nil)
        #expect(after.isAcceptable(for: .lrclib))

        // Chinese placeholder lyrics under the same title: nothing to flag.
        let zh = ["第一行 测试歌词 晴空", "第二行 测试歌词 远方", "第三行 测试歌词 灯火", "第四行 测试歌词 归途"]
        #expect(scorer.rescore(before, candidate: candidate, lyrics: Self.parsed(zh), for: q).flags.isEmpty)
        // Latin titles over CJK lyrics are everyday (K-pop, romanized titles): no script flag.
        let latin = QTLyricsQuery(videoId: "v", title: "Blue Window", artists: ["Test Artist"], duration: 60)
        #expect(!QTLyricsSanity.isScriptMismatch(title: latin.title, lyrics: zh))
        // Plain readable English is not gibberish.
        #expect(!QTLyricsSanity.isGibberish(QTDecoyLyricsProvider.lines))
    }

    @Test func syncedLyricsEndingEarlyArePenalised() {
        let scorer = QTLyricsMatchScorer()
        // 8 lines ending near 50 s on a 200 s track: under 40 %.
        let q = Self.query("v", "Short Story", duration: 200)
        let candidate = QTLyricsCandidate(source: .lrclib, remoteID: "1", title: "Short Story", artists: ["Test Artist"], duration: 200)
        let s = scorer.rescore(scorer.score(candidate, for: q), candidate: candidate, lyrics: Self.parsed(QTDecoyLyricsProvider.lines), for: q)
        #expect(s.flags == [.lowCoverage])
        #expect(s.rejection == nil)
    }

    @Test func earlyEndIsFineWhenEveryVersionEndsEarly() async throws {
        // A long instrumental outro: only one version, so ending early isn't held against it.
        let resolver = QTLyricsResolver(providers: [QTHonestLyricsProvider()], cache: try QTLyricsCache(url: nil))
        let r = await resolver.resolve(Self.query("vidL", "Long Outro", duration: 200))
        #expect(r.versions.first?.flags == [])
        #expect(r.isPossibleMismatch == false)
    }

    @Test func flaggedVersionsShowPossibleMismatch() async throws {
        struct Mash: QTLyricsSourceProvider {
            let source = QTLyricsSource.lrclib
            func search(_ q: QTLyricsQuery) async throws -> [QTLyricsCandidate] {
                [QTLyricsCandidate(source: source, remoteID: "m", title: q.title, artists: q.artists, duration: q.duration)]
            }
            func lyrics(for c: QTLyricsCandidate) async throws -> QTParsedLyrics? { QTLyricsSanityTests.parsed(QTLyricsSanityTests.mash) }
        }
        let resolver = QTLyricsResolver(providers: [Mash()], cache: try QTLyricsCache(url: nil))
        let r = await resolver.resolve(QTLyricsQuery(videoId: "v", title: "晴空测试曲", artists: ["测试歌手"], duration: 60))
        // Still shown (nothing better), but badged.
        #expect(r.document != nil)
        #expect(r.isPossibleMismatch)
        #expect(r.versions.first?.isPossibleMismatch == true)
        #expect(Set(r.versions.first?.flags ?? []) == [.scriptMismatch, .gibberish])
    }

    // MARK: Unofficial sources need a length

    @Test func unofficialSourcesNeedAKnownDuration() {
        let scorer = QTLyricsMatchScorer()
        let q = Self.query("v", "Copper Bell", duration: 60)
        let undated = QTLyricsCandidate(source: .qq, remoteID: "1", title: "Copper Bell", artists: ["Test Artist"])
        let before = scorer.score(undated, for: q)
        // Plain lyrics say nothing about the recording's length: rejected.
        let plain = QTParsedLyrics(lines: QTDecoyLyricsProvider.lines.map { QTParsedLyricsLine(start: nil, text: $0) })
        #expect(scorer.rescore(before, candidate: undated, lyrics: plain, for: q).rejection == .unknownDuration)
        // Synced lyrics sung most of the way through (to ~50 s of 60 s) show it.
        #expect(scorer.rescore(before, candidate: undated, lyrics: Self.parsed(QTDecoyLyricsProvider.lines), for: q).rejection == nil)
        // A length the payload declares counts too.
        var declared = plain
        declared.metadata.length = 61
        #expect(scorer.rescore(before, candidate: undated, lyrics: declared, for: q).rejection != .unknownDuration)
        // Official sources are not held to it.
        let lrclib = QTLyricsCandidate(source: .lrclib, remoteID: "1", title: "Copper Bell", artists: ["Test Artist"])
        #expect(scorer.rescore(scorer.score(lrclib, for: q), candidate: lrclib, lyrics: plain, for: q).rejection == nil)
    }

    // MARK: Offsets per version and the schema migration

    @Test func offsetIsKeptPerVersion() async throws {
        let resolver = QTLyricsResolver(providers: [QTHonestLyricsProvider(ids: ["1", "2"])], cache: try QTLyricsCache(url: nil))
        let q = Self.query("vidT", "Timing Test")
        let auto = await resolver.resolve(q)
        let autoID = try #require(auto.chosenID)
        let otherID = try #require(auto.versions.first { $0.id != autoID }?.id)
        await resolver.setOffset(0.4, for: q.videoId, version: autoID)
        #expect(await resolver.resolve(q).document?.offset == 0.4)
        // A newly pinned version starts at zero and keeps its own nudge.
        #expect(await resolver.pin(versionID: otherID, for: q).document?.offset == 0)
        await resolver.setOffset(-0.2, for: q.videoId, version: otherID)
        #expect(await resolver.resolve(q).document?.offset == -0.2)
        #expect(await resolver.unpin(for: q).document?.offset == 0.4)
    }

    /// A Lyrics.sqlite written by 0.1.1 (offsets per track, `user_version` 0) opens, and each offset moves to the
    /// version it was tuned for: the pinned one, else the cached automatic pick, else the first version shown.
    @Test func migratesPerTrackOffsetsFromTheCurrentSchema() async throws {
        let url = Self.tempCacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let doc = QTLyricsDocument(lines: [QTLyricsLine(start: 1, text: "Placeholder line one")], syncKind: .line, source: .lrclib)
        let entry = try JSONEncoder().encode(QTLyricsCacheEntry(videoId: "auto", document: doc, versions: [], chosenID: "lrclib:7",
                                                                attribution: nil, sourcesKey: "k"))
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let old = """
        CREATE TABLE lyrics (video_id TEXT PRIMARY KEY, entry BLOB NOT NULL, updated REAL NOT NULL);
        CREATE TABLE offsets (video_id TEXT PRIMARY KEY, offset REAL NOT NULL);
        CREATE TABLE pins (video_id TEXT PRIMARY KEY, version_id TEXT NOT NULL);
        CREATE TABLE aliases (a TEXT NOT NULL, b TEXT NOT NULL, origin TEXT, PRIMARY KEY (a, b));
        CREATE TABLE translations (video_id TEXT NOT NULL, language TEXT NOT NULL, engine TEXT NOT NULL,
            lines BLOB NOT NULL, updated REAL NOT NULL, PRIMARY KEY (video_id, language, engine));
        CREATE TABLE blobs (name TEXT PRIMARY KEY, data BLOB NOT NULL, updated REAL NOT NULL);
        INSERT INTO offsets VALUES ('pinned', 0.5), ('auto', -0.3), ('unknown', 0.2), ('off', 0.1);
        INSERT INTO pins VALUES ('pinned', 'netease:9'), ('off', 'none');
        INSERT INTO aliases VALUES ('a', 'b', 'netease');
        """
        #expect(sqlite3_exec(db, old, nil, nil, nil) == SQLITE_OK)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO lyrics VALUES ('auto', ?, 0)", -1, &stmt, nil)
        _ = entry.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        #expect(sqlite3_step(stmt) == SQLITE_DONE)
        sqlite3_finalize(stmt)
        sqlite3_close(db)

        let cache = try QTLyricsCache(url: url)
        #expect(await cache.offset(for: "pinned", version: "netease:9") == 0.5)
        #expect(await cache.offset(for: "pinned", version: "lrclib:1") == nil)
        #expect(await cache.offset(for: "auto", version: "lrclib:7") == -0.3)
        #expect(await cache.offset(for: "auto", version: "kugou:1") == nil)
        // Unknown version: the first version shown claims it, others don't inherit it.
        #expect(await cache.offset(for: "unknown", version: "amll:1") == 0.2)
        #expect(await cache.offset(for: "unknown", version: "lrclib:2") == nil)
        #expect(await cache.offset(for: "off", version: "lrclib:3") == 0.1)
        // Everything else survives, and a second open doesn't migrate again.
        #expect(await cache.pinnedVersionID(for: "pinned") == "netease:9")
        #expect(await cache.entry(for: "auto")?.chosenID == "lrclib:7")
        #expect(await cache.aliasPairs().count == 1)
        let reopened = try QTLyricsCache(url: url)
        #expect(await reopened.offset(for: "pinned", version: "netease:9") == 0.5)
        #expect(await reopened.offset(for: "unknown", version: "amll:1") == 0.2)
    }
}
