import Foundation
import QTCore
import QTLyrics
import QTPlayback
import Testing
@testable import QTUI

// Owner: lyrics. The session in video mode: a counterpart of another length gets lyrics timed for its own cut (when a
// provider lists one) or unsynced lyrics, and the shift between the two maps Song⇄Video positions.

/// LRCLIB-like source: the song cut (4:17) always; the MV cut (5:38, 41 s of intro) only when `hasMVCut`.
struct QTRenditionStubProvider: QTLyricsSourceProvider {
    let source = QTLyricsSource.lrclib
    var hasMVCut = true
    static let texts = ["晚风吹过街角", "你说你会回来", "我在原地等待", "灯火一盏一盏", "直到夜色褪去"]

    func search(_ query: QTLyricsQuery) async throws -> [QTLyricsCandidate] {
        var out = [QTLyricsCandidate(source: source, remoteID: "song", title: query.title, artists: query.artists, duration: 257)]
        if hasMVCut { out.append(QTLyricsCandidate(source: source, remoteID: "mv", title: query.title, artists: query.artists, duration: 338)) }
        return out
    }

    func lyrics(for candidate: QTLyricsCandidate) async throws -> QTParsedLyrics? {
        let shift: TimeInterval = candidate.remoteID == "mv" ? 41 : 0
        let lines = Self.texts.enumerated().map {
            QTParsedLyricsLine(start: 12 + Double($0.offset) * 8 + shift, end: 18 + Double($0.offset) * 8 + shift, text: $0.element)
        }
        return QTParsedLyrics(lines: lines)
    }
}

@MainActor
@Suite struct QTLyricsRenditionSessionTests {
    static let song = QTTrack(videoId: "songVideoI1", title: "晚风告白", artists: [QTArtistRef(name: "星野")], duration: 257,
                              musicVideoType: .atv, counterpart: QTCounterpart(videoId: "mvVideoId01", musicVideoType: .omv))

    func makeSession(hasMVCut: Bool) throws -> QTLyricsSession {
        let settings = QTSettingsStore(defaults: UserDefaults(suiteName: "qt.lyrics-rendition.tests.\(UUID().uuidString)")!)
        settings.override { $0.lyricsTranslation = .off }
        let resolver = QTLyricsResolver(providers: [QTRenditionStubProvider(hasMVCut: hasMVCut)], cache: try QTLyricsCache(url: nil))
        return QTLyricsSession(settings: settings, resolver: resolver)
    }

    func waitUntil(_ condition: () -> Bool) async {
        let start = ContinuousClock.now
        while !condition(), ContinuousClock.now - start < .seconds(5) { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func videoOfAnotherLengthGetsItsOwnTimingAndMapsTheSwitch() async throws {
        let session = try makeSession(hasMVCut: true)
        session.load(Self.song)
        await waitUntil { session.phase != .loading }
        #expect(session.document?.lines.first?.start == 12)
        #expect(session.switchTime(60, track: Self.song, toCounterpart: true) == nil)

        // The MV plays: unsynced while its own timing is looked up, then lyrics timed for the MV.
        let rendition = QTLyricsRenditionCoordinator.rendition(track: Self.song, mode: .video, duration: 338)
        #expect(rendition == QTLyricsRendition(videoId: "mvVideoId01", duration: 338, isCounterpart: true))
        session.setRendition(rendition)
        #expect(session.renditionTiming == .lookingUp)
        #expect(session.document?.syncKind == .plain)
        await waitUntil { session.renditionTiming != .lookingUp }
        #expect(session.renditionTiming == .own)
        #expect(session.document?.lines.first?.start == 53)
        #expect(session.shiftGeneration == 1)
        // Song 1:00 ↔ MV 1:41.
        #expect(session.switchTime(60, track: Self.song, toCounterpart: true) == 101)
        #expect(session.switchTime(101, track: Self.song, toCounterpart: false) == 60)

        // Back to the song: its own lyrics again.
        session.setRendition(QTLyricsRenditionCoordinator.rendition(track: Self.song, mode: .song, duration: 257))
        #expect(session.renditionTiming == .base)
        #expect(session.document?.lines.first?.start == 12)
    }

    @Test func videoWithoutLyricsForItsCutShowsThemUnsynced() async throws {
        let session = try makeSession(hasMVCut: false)
        session.load(Self.song)
        await waitUntil { session.phase != .loading }
        session.setRendition(QTLyricsRenditionCoordinator.rendition(track: Self.song, mode: .video, duration: 338))
        await waitUntil { session.renditionTiming != .lookingUp }
        #expect(session.renditionTiming == .unsynced)
        #expect(session.document?.syncKind == .plain)
        #expect(session.document?.lines.map(\.text) == QTRenditionStubProvider.texts)
        #expect(session.switchTime(60, track: Self.song, toCounterpart: true) == nil)
        // Timing nudges don't apply to unsynced lyrics.
        session.nudgeOffset(by: 0.5)
        #expect(session.document?.offset == 0)
    }

    /// Finding 11: in video mode with the video's own timing, the Lyrics Source menu, Report and Undo act on the
    /// versions of the video's cut, not on the song's.
    @Test func videoModeReportsTheVersionOnScreen() async throws {
        struct TwoMVCuts: QTLyricsSourceProvider {
            let source = QTLyricsSource.lrclib
            func search(_ query: QTLyricsQuery) async throws -> [QTLyricsCandidate] {
                [QTLyricsCandidate(source: source, remoteID: "song", title: query.title, artists: query.artists, duration: 257),
                 QTLyricsCandidate(source: source, remoteID: "mv1", title: query.title, artists: query.artists, duration: 338),
                 QTLyricsCandidate(source: source, remoteID: "mv2", title: query.title, artists: query.artists, duration: 338)]
            }
            func lyrics(for candidate: QTLyricsCandidate) async throws -> QTParsedLyrics? {
                var parsed = try await QTRenditionStubProvider().lyrics(for: QTLyricsCandidate(
                    source: source, remoteID: candidate.remoteID == "song" ? "song" : "mv", title: candidate.title, artists: candidate.artists))
                // The second cut has words of its own (a report also covers the same words under another entry).
                if candidate.remoteID == "mv2", let p = parsed {
                    parsed = QTParsedLyrics(lines: p.lines.map {
                        QTParsedLyricsLine(start: $0.start, end: $0.end, text: $0.text + "，再一次")
                    })
                }
                return parsed
            }
        }
        let settings = QTSettingsStore(defaults: UserDefaults(suiteName: "qt.lyrics-rendition.tests.\(UUID().uuidString)")!)
        settings.override { $0.lyricsTranslation = .off }
        let cache = try QTLyricsCache(url: nil)
        let store = QTLyricsVersionStore()
        let session = QTLyricsSession(settings: settings, resolver: QTLyricsResolver(providers: [TwoMVCuts()], cache: cache),
                                      versionStore: store)
        let id = Self.song.videoId
        session.load(Self.song)
        await waitUntil { session.phase != .loading }
        #expect(store.selected[id] == "lrclib:song")

        session.setRendition(QTLyricsRenditionCoordinator.rendition(track: Self.song, mode: .video, duration: 338))
        await waitUntil { session.renditionTiming == .own }
        // The menu lists the video cut's versions, the one showing selected.
        #expect(store.selected[id] == "lrclib:mv1")
        #expect(store.versions[id]?.map(\.id) == ["lrclib:mv1", "lrclib:mv2"])

        #expect(store.reportWrong(id) == "lrclib:mv1")
        await waitUntil { store.selected[id] == "lrclib:mv2" }
        #expect(session.renditionTiming == .own)
        // The reported version, and its words (`text:<fingerprint>`, so another entry with them is blocked too).
        let rejected = await cache.rejectedVersionIDs(for: "mvVideoId01~338s")
        #expect(rejected.filter { !$0.hasPrefix("text:") } == ["lrclib:mv1"])
        #expect(rejected.contains { $0.hasPrefix("text:") })
        #expect(await cache.rejectedVersionIDs(for: id).isEmpty)
        #expect(session.chosenVersionID == "lrclib:song")

        store.undoReport("lrclib:mv1", for: id)
        await waitUntil { store.selected[id] == "lrclib:mv1" }
        #expect(await cache.rejectedVersionIDs(for: "mvVideoId01~338s").isEmpty)

        // Back to the song: its own versions again.
        session.setRendition(QTLyricsRenditionCoordinator.rendition(track: Self.song, mode: .song, duration: 257))
        #expect(store.selected[id] == "lrclib:song")
    }

    @Test func sameLengthVideoKeepsTheSongTiming() async throws {
        let session = try makeSession(hasMVCut: true)
        session.load(Self.song)
        await waitUntil { session.phase != .loading }
        session.setRendition(QTLyricsRenditionCoordinator.rendition(track: Self.song, mode: .video, duration: 258))
        #expect(session.renditionTiming == .base)
        #expect(session.document?.syncKind == .line)
    }

    @Test func queueAsksWhereASwitchPicksUp() async throws {
        let engine = QTSimulatedPlaybackEngine(clock: { 1000 }, tickInterval: nil)
        let queue = QTQueueController(engine: engine, uptime: { 1000 })
        var asked: [(QTPlaybackMode, TimeInterval)] = []
        queue.modeSwitchTime = { _, mode, t in
            asked.append((mode, t))
            return t + 41
        }
        await queue.play([Self.song], startTime: 60, autoplay: false)
        await queue.setMode(.video)
        #expect(asked.count == 1)
        #expect(asked.first?.0 == .video)
        #expect(abs((asked.first?.1 ?? 0) - 60) < 0.5)
        #expect(abs((engine.state.item?.startTime ?? 0) - 101) < 0.01)
    }
}
