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
}

public struct QTLyricsMatchScore: Sendable, Hashable, Codable {
    public var title: Double
    public var artist: Double
    public var duration: Double
    /// Penalty subtracted for version mismatches (Live/Remix/… on one side only).
    public var penalty: Double
    public var rejection: Rejection?

    public enum Rejection: String, Sendable, Hashable, Codable {
        case durationMismatch, overrunsTrack, belowThreshold, emptyLyrics
    }

    /// 0.40 title + 0.40 artist + 0.20 duration − penalty, clamped to 0…1. Rejected scores are 0.
    public var total: Double {
        guard rejection == nil else { return 0 }
        return min(1, max(0, 0.4 * title + 0.4 * artist + 0.2 * duration - penalty))
    }

    public static let exact = QTLyricsMatchScore(title: 1, artist: 1, duration: 1, penalty: 0, rejection: nil)

    /// Accepted for this source (unofficial sources need ≥ 0.80, safe ones ≥ 0.60).
    public func isAcceptable(for source: QTLyricsSource) -> Bool {
        rejection == nil && total >= (source.isUnofficial ? QTLyricsMatchThreshold.unofficial : QTLyricsMatchThreshold.possible)
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
    /// title/artist/length the payload itself declares (Kugou's `[ti:]…Remix` / `[total:]`).
    public func rescore(_ score: QTLyricsMatchScore, candidate: QTLyricsCandidate, lyrics: QTParsedLyrics,
                        for query: QTLyricsQuery) -> QTLyricsMatchScore {
        var s = score
        if lyrics.isEmpty { s.rejection = .emptyLyrics; return s }
        if query.duration > 0, let last = lyrics.lastTimestamp,
           last > query.duration + QTLyricsMatchThreshold.overrunTolerance {
            s.rejection = .overrunsTrack
            return s
        }
        guard !candidate.isExactMatch else { return s }
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
        guard changed else { return s }
        let again = self.score(declared, for: query)
        if again.rejection != nil || again.total < s.total { s = again }
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
