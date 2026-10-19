import Foundation
import QTCore

// Owner: lyrics. Song⇄Video timing. A track's song and its music video are often different cuts (a 5:38 MV with a
// spoken intro and an outro around a 4:17 song). Lyrics timed for the song drift in the video, so in the other
// rendition the lyrics are either looked up again for that rendition's own length (providers match by duration —
// LRCLIB and NetEase often list the MV cut too), or shown unsynced. Never synced lyrics that drift.
//
// When both timings are known and the same lines line up at one constant shift, that shift also maps the playback
// position across a Song⇄Video switch, so the music carries on from the same place.

/// The playing rendition of a track, as the lyrics see it.
public struct QTLyricsRendition: Sendable, Hashable {
    /// The id of what plays (the counterpart's video id when the other rendition plays).
    public var videoId: String
    /// Length of what plays, in seconds (the engine's duration once it is known).
    public var duration: TimeInterval
    /// True when this is not the rendition the track's own lyrics were looked up for.
    public var isCounterpart: Bool

    public init(videoId: String, duration: TimeInterval, isCounterpart: Bool) {
        self.videoId = videoId
        self.duration = duration
        self.isCounterpart = isCounterpart
    }
}

/// Decisions about lyrics for a rendition whose length differs from the track's (pure; unit-tested).
public enum QTLyricsRenditionTiming {
    /// Up to this length difference both renditions are treated as the same cut (encodes differ by a second or two).
    public static let sameCutTolerance: TimeInterval = 2.5
    /// A version looked up for a rendition must declare a length this close to it.
    public static let lookupTolerance: TimeInterval = 3
    /// Lines shared by both versions needed before a shift is trusted.
    public static let minimumAnchors = 3
    /// How far the shared lines may disagree with the shift (s).
    public static let anchorAgreement: TimeInterval = 0.75

    /// What the lyrics show in a rendition.
    public enum Decision: Equatable, Sendable {
        /// Same cut: the track's lyrics as they are.
        case base
        /// Another cut, and no lyrics for it yet: look them up (show `plain` meanwhile).
        case lookUp
        /// Lyrics timed for this rendition.
        case own(QTLyricsDocument)
        /// Nothing trustworthy is timed for this cut: the track's lyrics, unsynced.
        case plain(QTLyricsDocument)
    }

    /// True when the rendition is another cut than the one the lyrics were found for.
    public static func needsOwnTiming(baseDuration: TimeInterval, renditionDuration: TimeInterval) -> Bool {
        guard baseDuration > 0, renditionDuration > 0, renditionDuration.isFinite else { return false }
        return abs(renditionDuration - baseDuration) > sameCutTolerance
    }

    /// The query for a rendition's own lyrics: its own length, strict about it, and without YouTube Music (keyed by
    /// the song's id, its lyrics are timed for the song). Cached under a key of its own.
    public static func query(for base: QTLyricsQuery, rendition: QTLyricsRendition) -> QTLyricsQuery {
        var q = base
        q.videoId = cacheKey(for: rendition)
        q.lyricsVideoId = ""
        q.duration = rendition.duration
        q.durationTolerance = lookupTolerance
        return q
    }

    /// Cache / offset key of a rendition's own lyrics (apart from the same id played as a track of its own).
    public static func cacheKey(for rendition: QTLyricsRendition) -> String {
        "\(rendition.videoId)~\(Int(rendition.duration.rounded()))s"
    }

    /// - Parameters:
    ///   - base: the track's lyrics (timed for `baseDuration`).
    ///   - own: the rendition lookup's chosen document, nil while it hasn't run; `ownLookupDone` says it ran.
    ///   - ownDuration: the length the chosen version declares.
    public static func decide(base: QTLyricsDocument?, baseDuration: TimeInterval, rendition: QTLyricsRendition?,
                              own: QTLyricsDocument?, ownDuration: TimeInterval?, ownLookupDone: Bool) -> Decision {
        guard let base, let rendition, rendition.isCounterpart,
              needsOwnTiming(baseDuration: baseDuration, renditionDuration: rendition.duration) else { return .base }
        // Unsynced lyrics don't drift.
        guard base.syncKind != .plain else { return .base }
        if let own, own.syncKind != .plain, let d = ownDuration, abs(d - rendition.duration) <= lookupTolerance,
           let last = own.lines.last?.start, last <= rendition.duration + QTLyricsMatchThreshold.overrunTolerance {
            return .own(own)
        }
        return ownLookupDone ? .plain(plain(base)) : .lookUp
    }

    /// The same lyrics without timing (no current line, no karaoke).
    public static func plain(_ doc: QTLyricsDocument) -> QTLyricsDocument {
        var d = doc
        d.syncKind = .plain
        d.offset = 0
        for i in d.lines.indices {
            d.lines[i].start = 0
            d.lines[i].duration = nil
            d.lines[i].words = nil
        }
        return d
    }

    /// The constant shift `own` lyric time − `base` lyric time, when the lines both versions share agree on one
    /// (an intro added or cut). nil when there are too few shared lines or they disagree (a scene in the middle, a
    /// different edit) — then positions are not mapped.
    public static func shift(from base: QTLyricsDocument, to own: QTLyricsDocument) -> TimeInterval? {
        guard base.syncKind != .plain, own.syncKind != .plain else { return nil }
        let a = base.lines.map { QTLyricsTextFolding.comparisonKey($0.text) }
        let b = own.lines.map { QTLyricsTextFolding.comparisonKey($0.text) }
        // In-order pairing of identical lines, looking a few lines ahead on the other side (repeated choruses stay
        // in order; an extra or missing line doesn't derail the rest).
        var deltas: [TimeInterval] = []
        var j = 0
        for (i, key) in a.enumerated() where !key.isEmpty {
            guard j < b.count else { break }
            if let k = (j..<min(b.count, j + 6)).first(where: { b[$0] == key }) {
                deltas.append(own.lines[k].start - base.lines[i].start)
                j = k + 1
            }
        }
        guard deltas.count >= minimumAnchors else { return nil }
        let median = deltas.sorted()[deltas.count / 2]
        let agreeing = deltas.filter { abs($0 - median) <= anchorAgreement }.count
        // The first sung line must agree (that is where the switch usually lands), and most of the rest.
        guard abs(deltas[0] - median) <= anchorAgreement, Double(agreeing) >= Double(deltas.count) * 0.8 else { return nil }
        return (median * 20).rounded() / 20
    }

    /// Maps a playback position across a switch. `shift` is the rendition's lyric time minus the base's; document
    /// offsets (user nudges) are part of each side's own timeline.
    /// - Parameter toRendition: true for base → rendition, false for the way back.
    public static func map(_ t: TimeInterval, shift: TimeInterval, baseOffset: TimeInterval = 0, renditionOffset: TimeInterval = 0,
                           toRendition: Bool, renditionDuration: TimeInterval? = nil) -> TimeInterval {
        let mapped: TimeInterval
        if toRendition {
            mapped = t + baseOffset + shift - renditionOffset
        } else {
            mapped = t + renditionOffset - shift - baseOffset
        }
        var out = max(0, mapped)
        if let d = renditionDuration, toRendition, d > 0 { out = min(out, max(0, d - 1)) }
        return out
    }
}
