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

/// One source listing a song three times: entries "a" and "b" carry the same (word-synced) words, "c" its own.
struct QTTwinLyricsProvider: QTLyricsSourceProvider {
    let source = QTLyricsSource.lrclib

    func search(_ query: QTLyricsQuery) async throws -> [QTLyricsCandidate] {
        ["a", "b", "c"].map { QTLyricsCandidate(source: source, remoteID: $0, title: query.title, artists: query.artists,
                                                duration: query.duration) }
    }

    func lyrics(for candidate: QTLyricsCandidate) async throws -> QTParsedLyrics? {
        candidate.remoteID == "c"
            ? QTLyricsSanityTests.parsed((1...8).map { "Own placeholder verse \($0) for the third entry" })
            : QTLyricsSanityTests.parsed((1...8).map { "Twin placeholder verse \($0) shared by two entries" }, wordSynced: true)
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

    static func query(_ videoId: String, _ title: String, artist: String = "Test Artist", duration: TimeInterval = 60) -> QTLyricsQuery {
        QTLyricsQuery(videoId: videoId, title: title, artists: [artist], duration: duration)
    }

    static func tempCacheURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("qt-lyrics-sanity-\(UUID().uuidString)/Lyrics.sqlite")
    }

    // MARK: Same text for different songs

    @Test func decoyServingOneTextForManySongsIsFlaggedNotDropped() async throws {
        let cache = try QTLyricsCache(url: nil)
        let resolver = QTLyricsResolver(providers: [QTDecoyLyricsProvider(), QTHonestLyricsProvider()], cache: cache)
        let a = Self.query("vidA", "Northern Kettle", artist: "Ann"), b = Self.query("vidB", "Velvet Compass", artist: "Ben")
        let c = Self.query("vidC", "Orange Ferry", artist: "Cleo")

        // One other song with the same text proves nothing: the word-synced decoy wins for the first two.
        #expect(await resolver.resolve(a).chosenID == "decoy:same")
        #expect(await resolver.resolve(b).chosenID == "decoy:same")
        // Chosen for two other titles by two other artists: filler. Not picked, but still offered, badged and last.
        let r = await resolver.resolve(c)
        #expect(r.document?.source == .lrclib)
        let decoy = try #require(r.versions.first { $0.id == "decoy:same" })
        #expect(decoy.flags?.contains(.sharedText) == true)
        #expect(decoy.isPossibleMismatch)
        #expect(r.versions.last?.id == "decoy:same")
        // Picking it anyway works.
        #expect(await resolver.pin(versionID: "decoy:same", for: c).chosenID == "decoy:same")
        // The other songs' cached lyrics are left alone (no other track's entry is deleted from a lookup).
        #expect(await cache.entry(for: "vidA")?.chosenID == "decoy:same")
    }

    /// Finding 2: only the version actually chosen is recorded, so versions that were merely fetched for other songs
    /// can never mark the right lyrics as filler.
    @Test func onlyTheChosenTextIsRecorded() async throws {
        let cache = try QTLyricsCache(url: nil)
        let resolver = QTLyricsResolver(providers: [QTDecoyLyricsProvider(), QTHonestLyricsProvider()], cache: cache)
        let a = Self.query("vidA", "Northern Kettle", artist: "Ann")
        let chosen = await resolver.resolve(a)
        #expect(chosen.chosenID == "decoy:same")
        let decoy = try #require(QTLyricsSanity.fingerprint(Self.parsed(QTDecoyLyricsProvider.lines)))
        let honest = try #require(QTLyricsSanity.fingerprint(Self.parsed((1...8).map { "Northern Kettle#1 placeholder line number \($0) goes here" })))
        #expect(await cache.fingerprintTracks(decoy, excluding: "-").map(\.videoId) == ["vidA"])
        #expect(await cache.fingerprintTracks(honest, excluding: "-").isEmpty)
        // Reporting it clears the track's fingerprint before the next pick is recorded.
        let next = await resolver.reject(versionID: "decoy:same", for: a)
        #expect(next.document?.source == .lrclib)
        #expect(await cache.fingerprintTracks(decoy, excluding: "-").isEmpty)
        #expect(await cache.fingerprintTracks(honest, excluding: "-").map(\.videoId) == ["vidA"])
    }

    @Test func coversAndReReleasesMayShareLyrics() async throws {
        let resolver = QTLyricsResolver(providers: [QTDecoyLyricsProvider()], cache: try QTLyricsCache(url: nil))
        // One song: studio, live and a remaster share their text (titles ≥ 90 % alike).
        for (id, title) in [("v1", "Harbour Lights"), ("v2", "Harbour Lights (Live)"), ("v3", "Harbour Lights - 2015 Remaster")] {
            #expect(await resolver.resolve(Self.query(id, title)).chosenID == "decoy:same", "\(title)")
        }
        // One artist's song under translated titles, and a cover of it under yet another title: still one song.
        let other = QTLyricsResolver(providers: [QTDecoyLyricsProvider()], cache: try QTLyricsCache(url: nil))
        for (id, title, artist) in [("t1", "Sunny Day", "Jay"), ("t2", "Clear Sky", "Jay"), ("t3", "Bright Weather", "Mia")] {
            #expect(await other.resolve(Self.query(id, title, artist: artist)).chosenID == "decoy:same", "\(title)")
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
        // Still listed — last, as reported — so the report can be taken back.
        #expect(next.versions.last?.id == wrong)
        #expect(next.versions.last?.isReported == true)

        // A relaunch (new cache connection, new resolver, forced lookup) still never chooses it.
        let relaunched = QTLyricsResolver(providers: [QTHonestLyricsProvider(ids: ["1", "2"])], cache: try QTLyricsCache(url: url))
        let r = await relaunched.resolve(q, forceRefresh: true)
        #expect(r.chosenID == next.chosenID)
        #expect(r.versions.last.map { $0.id == wrong && $0.isReported == true } == true)
        // Picking it on purpose takes the report back.
        #expect(await relaunched.pin(versionID: wrong, for: q).chosenID == wrong)
        let back = await relaunched.unpin(for: q)
        #expect(back.versions.contains { $0.id == wrong && $0.isReported != true })
    }

    /// A report covers the reported words, not only that entry: the source's other entry with the same words is
    /// never picked automatically either (listed as reported), and Undo takes both back.
    @Test func reportingAVersionAlsoBlocksItsTwinEntry() async throws {
        let resolver = QTLyricsResolver(providers: [QTTwinLyricsProvider()], cache: try QTLyricsCache(url: nil))
        let q = Self.query("vidT", "Twin Entries")
        let first = try #require(await resolver.resolve(q).chosenID)
        #expect(first == "lrclib:a" || first == "lrclib:b")
        let twin = first == "lrclib:a" ? "lrclib:b" : "lrclib:a"
        let reported = await resolver.reject(versionID: first, for: q)
        #expect(reported.chosenID == "lrclib:c")
        #expect(reported.versions.contains { $0.id == twin && $0.isReported == true })
        #expect(reported.versions.contains { $0.id == first && $0.isReported == true })
        // A relaunch-style forced lookup keeps both out.
        #expect(await resolver.resolve(q, forceRefresh: true).chosenID == "lrclib:c")
        let undone = await resolver.undoReject(versionID: first, wasPinned: false, for: q)
        #expect(undone.chosenID == first || undone.chosenID == twin)
        #expect(!undone.versions.contains { $0.isReported == true })
    }

    /// Finding 10: Undo on the "Reported" toast restores the version, and the pin the report dropped.
    @Test func undoingAReportRestoresThePin() async throws {
        let resolver = QTLyricsResolver(providers: [QTHonestLyricsProvider(ids: ["1", "2"])], cache: try QTLyricsCache(url: nil))
        let q = Self.query("vidU", "Undo Song")
        let auto = try #require(await resolver.resolve(q).chosenID)
        let other = try #require(await resolver.resolve(q).versions.first { $0.id != auto }?.id)
        #expect(await resolver.pin(versionID: other, for: q).pinnedID == other)
        let reported = await resolver.reject(versionID: other, for: q)
        #expect(reported.chosenID == auto)
        #expect(reported.pinnedID == nil)
        let undone = await resolver.undoReject(versionID: other, wasPinned: true, for: q)
        #expect(undone.chosenID == other)
        #expect(undone.pinnedID == other)
        #expect(!undone.versions.contains { $0.isReported == true })
    }

    /// Finding 16: a pinned version that can't be fetched any more still reads as pinned, and Automatic clears it.
    @Test func stalePinIsReportedAndAutomaticClearsIt() async throws {
        let cache = try QTLyricsCache(url: nil)
        let resolver = QTLyricsResolver(providers: [QTHonestLyricsProvider()], cache: cache)
        let q = Self.query("vidS", "Stale Pin")
        await cache.setPinnedVersionID("lrclib:gone", for: q.videoId)
        let r = await resolver.resolve(q)
        #expect(r.chosenID == "lrclib:Stale Pin#1")
        #expect(r.pinnedID == "lrclib:gone")
        #expect(r.isPinned)
        let auto = await resolver.unpin(for: q)
        #expect(auto.pinnedID == nil)
        #expect(!auto.isPinned)
        #expect(await cache.pinnedVersionID(for: q.videoId) == nil)
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

    @Test func unofficialSourcesWithoutALengthAreDoubtful() {
        let scorer = QTLyricsMatchScorer()
        let q = Self.query("v", "Copper Bell", duration: 60)
        let undated = QTLyricsCandidate(source: .qq, remoteID: "1", title: "Copper Bell", artists: ["Test Artist"])
        let before = scorer.score(undated, for: q)
        // Plain lyrics say nothing about the recording's length: a penalty and a badge, not a rejection.
        let plain = QTParsedLyrics(lines: QTDecoyLyricsProvider.lines.map { QTParsedLyricsLine(start: nil, text: $0) })
        let doubtful = scorer.rescore(before, candidate: undated, lyrics: plain, for: q)
        #expect(doubtful.rejection == nil)
        #expect(doubtful.flags == [.unknownLength])
        #expect(doubtful.total < before.total)
        // Synced lyrics sung most of the way through (to ~50 s of 60 s) show it.
        #expect(scorer.rescore(before, candidate: undated, lyrics: Self.parsed(QTDecoyLyricsProvider.lines), for: q).flags.isEmpty)
        // A length the payload declares counts too.
        var declared = plain
        declared.metadata.length = 61
        #expect(!scorer.rescore(before, candidate: undated, lyrics: declared, for: q).flags.contains(.unknownLength))
        // Official sources are not held to it.
        let lrclib = QTLyricsCandidate(source: .lrclib, remoteID: "1", title: "Copper Bell", artists: ["Test Artist"])
        #expect(scorer.rescore(scorer.score(lrclib, for: q), candidate: lrclib, lyrics: plain, for: q).flags.isEmpty)
    }

    /// Finding 22: plain QQ lyrics (QQ lists no lengths) show when they are all there is, badged; another version of
    /// the song wins over them.
    @Test func undatedQQLyricsShowOnlyWhenNothingElseIs() async throws {
        struct PlainQQ: QTLyricsSourceProvider {
            let source = QTLyricsSource.qq
            func search(_ q: QTLyricsQuery) async throws -> [QTLyricsCandidate] {
                [QTLyricsCandidate(source: source, remoteID: "qq1", title: q.title, artists: q.artists)]
            }
            func lyrics(for c: QTLyricsCandidate) async throws -> QTParsedLyrics? {
                QTParsedLyrics(lines: QTDecoyLyricsProvider.lines.map { QTParsedLyricsLine(start: nil, text: $0) })
            }
        }
        let config = QTLyricsResolverConfiguration(unofficialSources: .init(qq: true))
        let alone = QTLyricsResolver(providers: [PlainQQ()], cache: try QTLyricsCache(url: nil), configuration: config)
        let r = await alone.resolve(Self.query("vidQ", "Copper Bell"))
        #expect(r.chosenID == "qq:qq1")
        #expect(r.isPossibleMismatch)
        let both = QTLyricsResolver(providers: [PlainQQ(), QTHonestLyricsProvider()], cache: try QTLyricsCache(url: nil), configuration: config)
        let r2 = await both.resolve(Self.query("vidQ", "Copper Bell"))
        #expect(r2.document?.source == .lrclib)
        #expect(!r2.versions.contains { $0.id == "qq:qq1" })
    }

    /// Finding 12: lyrics in a language the recognizer doesn't know (invented Welsh lines here, ~0.59 confidence)
    /// aren't gibberish; and the hint alone never forces the badge.
    @Test func unknownLanguagesAreNotGibberish() async throws {
        let welsh = ["Mae'r glaw yn disgyn ar y bryniau llwyd", "Rydw i'n cerdded adref ar hyd y lôn", "Mae golau bach yn ffenest y tŷ",
                     "Canwn gân i'r môr a'r mynyddoedd", "Daw'r haul yn ôl ar ôl y storm", "Arhosaf yma tan y bore bach"]
        #expect(!QTLyricsSanity.isGibberish(welsh))
        #expect(QTLyricsSanity.isGibberish(Self.mash))
        #expect(!QTLyricsMatchFlag.gibberish.forcesBadge)
        let v = QTResolvedLyricsVersion(candidate: QTLyricsCandidate(source: .lrclib, remoteID: "1", title: "T", artists: []),
                                        score: 0.85, syncKind: .line, hasTranslation: false, flags: [.gibberish])
        #expect(!v.isPossibleMismatch)
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

    /// Finding 13: a migration step that fails rolls everything back, and the cache still opens and saves.
    @Test func failedMigrationRollsBackAndStillOpens() async throws {
        let url = Self.tempCacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        // A 0.1.1-style file whose carry-over insert fails half-way (a trigger refuses one row).
        let old = """
        CREATE TABLE offsets (video_id TEXT PRIMARY KEY, offset REAL NOT NULL);
        CREATE TABLE version_offsets (video_id TEXT NOT NULL, version_id TEXT NOT NULL, offset REAL NOT NULL,
            PRIMARY KEY (video_id, version_id));
        CREATE TRIGGER refuse BEFORE INSERT ON version_offsets WHEN NEW.video_id = 'boom' BEGIN SELECT RAISE(ABORT, 'no'); END;
        INSERT INTO offsets VALUES ('a', 0.5), ('boom', 0.1);
        """
        #expect(sqlite3_exec(db, old, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let cache = try QTLyricsCache(url: url)
        // Rolled back: nothing half-migrated, the old table is still there for the next launch.
        #expect(await cache.offset(for: "a", version: "lrclib:1") == nil)
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM offsets", -1, &stmt, nil) == SQLITE_OK)
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        #expect(sqlite3_column_int(stmt, 0) == 2)
        sqlite3_finalize(stmt)
        sqlite3_close(db)
        // Persistence keeps working meanwhile.
        await cache.setPinnedVersionID("lrclib:1", for: "a")
        await cache.addRejection("lrclib:2", for: "a")
        let reopened = try QTLyricsCache(url: url)
        #expect(await reopened.pinnedVersionID(for: "a") == "lrclib:1")
        #expect(await reopened.rejectedVersionIDs(for: "a") == ["lrclib:2"])
    }
}
