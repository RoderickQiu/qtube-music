import Foundation
import QTCore

/// Thresholds from HANDOFF §6.
public enum QTLyricsMatchThreshold {
    /// Auto-accept.
    public static let accept = 0.80
    /// 0.60–0.80 shows a "possible mismatch" badge; below is discarded.
    public static let possible = 0.60
    /// Community/unofficial sources must clear this.
    public static let unofficial = 0.80
    /// Reject outright beyond this duration difference (seconds).
    public static let maxDurationDelta: TimeInterval = 20
    /// Reject when the last timestamp runs past the track by more than this (seconds).
    public static let overrunTolerance: TimeInterval = 5
    /// Synced lyrics that stop before this share of the track are probably for another (shorter) song.
    public static let minimumCoverage = 0.4
    /// An unofficial candidate that declares no length is taken for this recording when it is synced and sung at
    /// least this far into the track; otherwise it is flagged `unknownLength`.
    public static let undatedCoverage = 0.6
}

/// Why a fetched version looks doubtful although its title, artist and length match. Each lowers the score
/// (`QTLyricsMatchScore.sanityPenalty`); all but `gibberish` show "Possible mismatch" (`forcesBadge`). None rejects
/// on its own.
public enum QTLyricsMatchFlag: String, Sendable, Hashable, Codable, CaseIterable {
    /// The title is written in a non-Latin script (Chinese, Korean, Cyrillic…) and the lyrics have none of it.
    case scriptMismatch
    /// The language recognizer can't tell what language the lyrics are in (keyboard mash, placeholder text).
    case gibberish
    /// Synced lyrics end before 40 % of the track while another version of the song goes on (the resolver drops
    /// the flag when every version ends that early: a long instrumental outro).
    case lowCoverage
    /// An unofficial version that doesn't say how long its recording is, and whose timing doesn't show it either
    /// (QQ lists no lengths). The resolver keeps it only when no other version covers the song.
    case unknownLength
    /// The same text a source served for other songs (titles and artists unlike this one's): its filler, not this
    /// song's lyrics. Never chosen automatically; still listed, badged, so it can be picked.
    case sharedText

    /// Shows "Possible mismatch" on its own. The language recognizer doesn't know every language (Welsh or Zulu
    /// lyrics read as low-confidence guesses), so `gibberish` only lowers the rank.
    public var forcesBadge: Bool { self != .gibberish }
}

public struct QTLyricsMatchScore: Sendable, Hashable, Codable {
    public var title: Double
    public var artist: Double
    public var duration: Double
    /// Penalty subtracted for version mismatches (Live/Remix/… on one side only).
    public var penalty: Double
    public var rejection: Rejection?
    /// Post-fetch sanity checks (`flags`): lowers the rank and the shown confidence, never the acceptance.
    public var sanityPenalty: Double = 0
    public var flags: Set<QTLyricsMatchFlag> = []

    public enum Rejection: String, Sendable, Hashable, Codable {
        case durationMismatch, overrunsTrack, belowThreshold, emptyLyrics
    }

    /// 0.40 title + 0.40 artist + 0.20 duration − penalties, clamped to 0…1. Rejected scores are 0.
    public var total: Double {
        guard rejection == nil else { return 0 }
        return min(1, max(0, base - sanityPenalty))
    }

    /// The metadata match alone (before the sanity penalty).
    var base: Double { 0.4 * title + 0.4 * artist + 0.2 * duration - penalty }

    public static let exact = QTLyricsMatchScore(title: 1, artist: 1, duration: 1, penalty: 0, rejection: nil)

    /// Accepted for this source (unofficial sources need ≥ 0.80, safe ones ≥ 0.60). Judged on the metadata match:
    /// a sanity penalty ranks a version lower but never hides it — it may still be the only lyrics there are.
    public func isAcceptable(for source: QTLyricsSource) -> Bool {
        rejection == nil && min(1, base) >= (source.isUnofficial ? QTLyricsMatchThreshold.unofficial : QTLyricsMatchThreshold.possible)
    }
}

/// Learned equivalences between names written in different scripts/languages (周杰伦 = Jay Chou,
/// Hạ Phỏm = 出牌). Stored as comparison keys; symmetric.
public struct QTLyricsAliasBook: Sendable, Hashable {
    private(set) var groups: [String: Set<String>] = [:]

    public init() {}

    public init(pairs: [(String, String)]) {
        for (a, b) in pairs { add(a, b) }
    }

    /// Records that `a` and `b` name the same thing. Returns true if this is new.
    @discardableResult
    public mutating func add(_ a: String, _ b: String) -> Bool {
        let ka = QTLyricsTextFolding.comparisonKey(a), kb = QTLyricsTextFolding.comparisonKey(b)
        guard !ka.isEmpty, !kb.isEmpty, ka != kb, groups[ka]?.contains(kb) != true else { return false }
        let merged = (groups[ka] ?? [ka]).union(groups[kb] ?? [kb])
        for k in merged { groups[k] = merged }
        return true
    }

    /// All keys equivalent to `key` (including itself).
    public func equivalents(ofKey key: String) -> Set<String> { groups[key] ?? [key] }

    public var isEmpty: Bool { groups.isEmpty }
}

/// Scores a candidate against the query (HANDOFF §6).
public struct QTLyricsMatchScorer: Sendable {
    public var aliases: QTLyricsAliasBook

    public init(aliases: QTLyricsAliasBook = .init()) {
        self.aliases = aliases
    }

    public func score(_ candidate: QTLyricsCandidate, for query: QTLyricsQuery) -> QTLyricsMatchScore {
        // Strict timing: a candidate that doesn't say how long it is, or is another cut, is never used.
        if let tolerance = query.durationTolerance {
            guard query.duration > 0, let d = candidate.duration, d > 0, abs(d - query.duration) <= tolerance else {
                return QTLyricsMatchScore(title: 0, artist: 0, duration: 0, penalty: 0, rejection: .durationMismatch)
            }
        }
        if candidate.isExactMatch { return .exact }
        let q = query.cleanTitle
        let c = QTTitleCleaner.clean(candidate.title)

        // Title: best pair over every spelling on both sides (+ learned aliases).
        var queryTitles = [q.core] + q.alternates
        if let sub = query.subtitle { queryTitles += [sub] + QTTitleCleaner.clean(sub).alternates }
        let candidateTitles = [c.core] + c.alternates + candidate.titleAliases.map { QTTitleCleaner.clean($0).core }
        let title = best(queryTitles, candidateTitles)

        // Artist: best individual pairing, or the whole line when credits are split differently.
        let queryArtists = query.artists.flatMap(QTTitleCleaner.splitArtists)
        let candidateArtists = candidate.artists.flatMap(QTTitleCleaner.splitArtists) + candidate.artistAliases
        var artist = best(queryArtists, candidateArtists)
        if !query.artists.isEmpty, !candidate.artists.isEmpty {
            artist = max(artist, similarity(query.artists.joined(separator: " "), candidate.artists.joined(separator: " ")))
        } else {
            artist = 0.5   // unknown artist on one side: neutral
        }

        // Duration: 1 within ±2 s → 0 at ±15 s; reject beyond ±20 s; unknown = neutral 0.5.
        var duration = 0.5
        var rejection: QTLyricsMatchScore.Rejection?
        if query.duration > 0, let d = candidate.duration, d > 0 {
            let delta = abs(query.duration - d)
            duration = delta <= 2 ? 1 : max(0, 1 - (delta - 2) / 13)
            if delta > QTLyricsMatchThreshold.maxDurationDelta { rejection = .durationMismatch }
        }

        // Version tags only one side has (Live vs studio, Remix…).
        let diff = q.tags.symmetricDifference(c.tags)
        let penalty = min(0.3, Double(diff.count) * 0.15)
        return QTLyricsMatchScore(title: title, artist: artist, duration: duration, penalty: penalty, rejection: rejection)
    }

    /// Post-fetch checks: lyrics longer than the track (+5 s) are for another recording; re-score with the
    /// title/artist/length the payload itself declares (Kugou's `[ti:]…Remix` / `[total:]`); an unofficial version
    /// that can't show how long its recording is gets `unknownLength`; then the sanity checks (`QTLyricsSanity`:
    /// script, gibberish, coverage).
    public func rescore(_ score: QTLyricsMatchScore, candidate: QTLyricsCandidate, lyrics: QTParsedLyrics,
                        for query: QTLyricsQuery) -> QTLyricsMatchScore {
        var s = score
        if lyrics.isEmpty { s.rejection = .emptyLyrics; return s }
        if query.duration > 0, let last = lyrics.lastTimestamp,
           last > query.duration + QTLyricsMatchThreshold.overrunTolerance {
            s.rejection = .overrunsTrack
            return s
        }
        // Unofficial sources match loosely on names, so the length is the evidence that this is the recording. QQ's
        // search lists none: its synced lyrics must then run most of the way through the track instead. Without
        // either the version is doubtful, not wrong (plain QQ lyrics may be all there is for a song).
        var undated = false
        if candidate.source.isUnofficial, (candidate.duration ?? 0) <= 0, (lyrics.metadata.length ?? 0) <= 0 {
            undated = !(query.duration > 0 && lyrics.syncKind != .plain
                        && (lyrics.lastTimestamp ?? 0) >= query.duration * QTLyricsMatchThreshold.undatedCoverage)
        }
        if !candidate.isExactMatch {
            var declared = candidate
            var changed = false
            if let t = lyrics.metadata.title, !t.isEmpty, QTTitleCleaner.clean(t).tags != QTTitleCleaner.clean(candidate.title).tags {
                declared.title = t
                changed = true
            }
            if let len = lyrics.metadata.length, len > 30, candidate.duration == nil || abs((candidate.duration ?? 0) - len) > 2 {
                declared.duration = len
                changed = true
            }
            if changed {
                let again = self.score(declared, for: query)
                if again.rejection != nil || again.total < s.total { s = again }
            }
        }
        guard s.rejection == nil else { return s }
        s.flags = QTLyricsSanity.flags(lyrics, for: query)
        if undated { s.flags.insert(.unknownLength) }
        s.sanityPenalty = QTLyricsSanity.penalty(for: s.flags)
        return s
    }

    private func best(_ lhs: [String], _ rhs: [String]) -> Double {
        var top = 0.0
        for a in lhs where !a.isEmpty {
            for b in rhs where !b.isEmpty {
                top = max(top, similarity(a, b))
                if top >= 1 { return 1 }
            }
        }
        return top
    }

    /// Jaro-Winkler on comparison keys, 1.0 when the alias book links them.
    public func similarity(_ a: String, _ b: String) -> Double {
        let ka = QTLyricsTextFolding.comparisonKey(a), kb = QTLyricsTextFolding.comparisonKey(b)
        guard !ka.isEmpty, !kb.isEmpty else { return 0 }
        if ka == kb || aliases.equivalents(ofKey: ka).contains(kb) { return 1 }
        return QTJaroWinkler.similarity(ka, kb)
    }
}
