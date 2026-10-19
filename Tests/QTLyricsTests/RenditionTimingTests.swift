import Foundation
import QTCore
import Testing
@testable import QTLyrics

// Song⇄Video timing (QTLyricsRenditionTiming): a 5:38 MV around a 4:17 song gets lyrics timed for its own cut, or
// unsynced lyrics — never the song's, drifting — and the shift between the two maps positions across a switch.

@Suite struct RenditionTimingTests {
    static let texts = ["晚风吹过街角", "你说你会回来", "我在原地等待", "灯火一盏一盏", "直到夜色褪去", "晚风吹过街角"]

    static func doc(shift: TimeInterval = 0, sync: QTLyricsSyncKind = .line, texts: [String] = texts,
                    jitter: [TimeInterval] = []) -> QTLyricsDocument {
        let lines = texts.enumerated().map { i, t in
            QTLyricsLine(start: 12 + Double(i) * 8 + shift + (jitter.indices.contains(i) ? jitter[i] : 0), duration: 6, text: t)
        }
        return QTLyricsDocument(lines: lines, syncKind: sync, source: .lrclib, language: "zh-Hans")
    }

    static let mv = QTLyricsRendition(videoId: "mvVideoId01", duration: 338, isCounterpart: true)

    @Test func sameCutKeepsTheSongLyrics() {
        let r = QTLyricsRendition(videoId: "mvVideoId01", duration: 258.5, isCounterpart: true)
        let d = QTLyricsRenditionTiming.decide(base: Self.doc(), baseDuration: 257, rendition: r, own: nil, ownDuration: nil,
                                               ownLookupDone: false)
        #expect(d == .base)
        #expect(!QTLyricsRenditionTiming.needsOwnTiming(baseDuration: 257, renditionDuration: 259))
        #expect(QTLyricsRenditionTiming.needsOwnTiming(baseDuration: 257, renditionDuration: 338))
    }

    @Test func theTrackItselfIsAlwaysItsOwnTiming() {
        let r = QTLyricsRendition(videoId: "songVideoId", duration: 338, isCounterpart: false)
        #expect(QTLyricsRenditionTiming.decide(base: Self.doc(), baseDuration: 257, rendition: r, own: nil, ownDuration: nil,
                                               ownLookupDone: true) == .base)
    }

    @Test func anotherCutLooksUpThenFallsBackToUnsynced() {
        let base = Self.doc()
        #expect(QTLyricsRenditionTiming.decide(base: base, baseDuration: 257, rendition: Self.mv, own: nil, ownDuration: nil,
                                               ownLookupDone: false) == .lookUp)
        let done = QTLyricsRenditionTiming.decide(base: base, baseDuration: 257, rendition: Self.mv, own: nil, ownDuration: nil,
                                                  ownLookupDone: true)
        guard case .plain(let plain) = done else { Issue.record("expected unsynced, got \(done)"); return }
        #expect(plain.syncKind == .plain)
        #expect(plain.lines.map(\.text) == base.lines.map(\.text))
        #expect(plain.lines.allSatisfy { $0.start == 0 && $0.words == nil })
        #expect(plain.lineIndex(atPlaybackTime: 100) == nil)
    }

    @Test func ownCutLyricsAreUsedOnlyWhenTheyAreForThatLength() {
        let base = Self.doc()
        let own = Self.doc(shift: 41)
        #expect(QTLyricsRenditionTiming.decide(base: base, baseDuration: 257, rendition: Self.mv, own: own, ownDuration: 337,
                                               ownLookupDone: true) == .own(own))
        // A version for the song's length (or of unknown length) would drift: unsynced instead.
        if case .own = QTLyricsRenditionTiming.decide(base: base, baseDuration: 257, rendition: Self.mv, own: own, ownDuration: 257,
                                                      ownLookupDone: true) { Issue.record("song-length version used for the MV") }
        if case .own = QTLyricsRenditionTiming.decide(base: base, baseDuration: 257, rendition: Self.mv, own: own, ownDuration: nil,
                                                      ownLookupDone: true) { Issue.record("version of unknown length used") }
        // Unsynced lyrics for the cut don't count as timing for it.
        if case .own = QTLyricsRenditionTiming.decide(base: base, baseDuration: 257, rendition: Self.mv,
                                                      own: Self.doc(shift: 41, sync: .plain), ownDuration: 338,
                                                      ownLookupDone: true) { Issue.record("plain version used as timing") }
    }

    @Test func unsyncedSongLyricsNeverNeedALookup() {
        #expect(QTLyricsRenditionTiming.decide(base: Self.doc(sync: .plain), baseDuration: 257, rendition: Self.mv, own: nil,
                                               ownDuration: nil, ownLookupDone: false) == .base)
    }

    @Test func shiftFromTheLinesBothVersionsShare() {
        #expect(QTLyricsRenditionTiming.shift(from: Self.doc(), to: Self.doc(shift: 41.02)) == 41)
        // Small disagreement (different transcribers) is fine.
        #expect(abs((QTLyricsRenditionTiming.shift(from: Self.doc(), to: Self.doc(shift: 41, jitter: [0.3, -0.2, 0.1, 0, 0.4, -0.3])) ?? 0) - 41) <= 0.2)
        // An extra spoken line in the MV doesn't derail the pairing.
        var withMonologue = Self.doc(shift: 41)
        withMonologue.lines.insert(QTLyricsLine(start: withMonologue.lines[1].start + 4, text: "（独白）"), at: 2)
        #expect(QTLyricsRenditionTiming.shift(from: Self.doc(), to: withMonologue) == 41)
    }

    @Test func noShiftWhenTheCutsDontLineUp() {
        // A scene in the middle: the second half moves by another 20 s.
        let edited = Self.doc(shift: 41, jitter: [0, 0, 0, 20, 20, 20])
        #expect(QTLyricsRenditionTiming.shift(from: Self.doc(), to: edited) == nil)
        // Too few shared lines.
        #expect(QTLyricsRenditionTiming.shift(from: Self.doc(), to: Self.doc(shift: 41, texts: ["晚风吹过街角", "a", "b", "c", "d", "e"])) == nil)
        // Nothing to line up in unsynced lyrics.
        #expect(QTLyricsRenditionTiming.shift(from: Self.doc(sync: .plain), to: Self.doc(shift: 41)) == nil)
    }

    @Test func positionsMapAcrossTheSwitch() {
        // Song at 1:00 → the MV (41 s of intro) at 1:41, and back.
        #expect(QTLyricsRenditionTiming.map(60, shift: 41, toRendition: true) == 101)
        #expect(QTLyricsRenditionTiming.map(101, shift: 41, toRendition: false) == 60)
        // The intro has no song equivalent: the song starts at 0.
        #expect(QTLyricsRenditionTiming.map(10, shift: 41, toRendition: false) == 0)
        // User offsets are part of each side's timeline (positive = lyrics earlier).
        #expect(QTLyricsRenditionTiming.map(60, shift: 41, baseOffset: 0.5, renditionOffset: 0, toRendition: true) == 101.5)
        #expect(QTLyricsRenditionTiming.map(60, shift: 41, baseOffset: 0, renditionOffset: 0.5, toRendition: true) == 100.5)
        // Never past the end of the rendition.
        #expect(QTLyricsRenditionTiming.map(320, shift: 41, toRendition: true, renditionDuration: 338) == 337)
    }

    @Test func renditionQueryIsStrictAndKeyedApart() {
        let base = QTLyricsQuery(videoId: "songVideoId", title: "晚风告白", artists: ["星野"], duration: 257)
        let q = QTLyricsRenditionTiming.query(for: base, rendition: Self.mv)
        #expect(q.duration == 338)
        #expect(q.durationTolerance == QTLyricsRenditionTiming.lookupTolerance)
        #expect(q.lyricsVideoId.isEmpty)
        #expect(q.videoId == "mvVideoId01~338s")
        #expect(q.title == base.title)
    }

    @Test func strictQueriesRejectOtherCutsAndUnknownLengths() {
        let scorer = QTLyricsMatchScorer()
        var q = QTLyricsQuery(videoId: "x~338s", lyricsVideoId: "", title: "晚风告白", artists: ["星野"], duration: 338)
        q.durationTolerance = 3
        let mvCut = QTLyricsCandidate(source: .lrclib, remoteID: "1", title: "晚风告白", artists: ["星野"], duration: 337)
        let songCut = QTLyricsCandidate(source: .lrclib, remoteID: "2", title: "晚风告白", artists: ["星野"], duration: 324)
        let unknown = QTLyricsCandidate(source: .amll, remoteID: "3", title: "晚风告白", artists: ["星野"], duration: nil)
        let exact = QTLyricsCandidate(source: .youtubeMusic, remoteID: "songVideoId", title: "晚风告白", artists: ["星野"],
                                      isExactMatch: true)
        #expect(scorer.score(mvCut, for: q).isAcceptable(for: .lrclib))
        #expect(scorer.score(songCut, for: q).rejection == .durationMismatch)
        #expect(scorer.score(unknown, for: q).rejection == .durationMismatch)
        #expect(scorer.score(exact, for: q).rejection == .durationMismatch)
        // The usual lookup still scores fuzzily (14 s apart is a weak but not rejected match).
        q.durationTolerance = nil
        #expect(scorer.score(songCut, for: q).rejection == nil)
    }
}
