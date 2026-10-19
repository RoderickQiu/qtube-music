import Foundation
import QTCore

/// Finds the Song⇄Video counterpart of a track.
///
/// Sources, most to least authoritative:
/// 1. the track's own `counterpart` (album/playlist/search rows of official videos carry the Song id in their
///    credits menu);
/// 2. `next` — signed-in clients get `playlistPanelVideoWrapperRenderer` rows with an explicit counterpart;
/// 3. a conservative search match (same normalised title, overlapping artist; official videos only for Song→Video).
///    Anonymous `next` never includes counterparts (verified 2026-10-18), so this keeps the switch usable signed out.
public enum QTCounterpartMatcher {
    /// Lowercased, diacritics folded (Vietnamese "đ" → "d"), widths normalised, bracketed decorations
    /// ("(Official Video)", "【MV】", "[Lyrics]") and "Artist - " prefixes removed.
    public static func normalizedTitle(_ title: String, artists: [String] = []) -> String {
        var t = title.precomposedStringWithCompatibilityMapping.lowercased()
        // Bracketed decorations.
        for (open, close) in [("(", ")"), ("[", "]"), ("【", "】"), ("（", "）"), ("「", "」")] {
            while let o = t.range(of: open), let c = t.range(of: close, range: o.upperBound..<t.endIndex) {
                let inner = t[o.upperBound..<c.lowerBound]
                // Keep meaningful qualifiers that make a different recording.
                if ["live", "remix", "acoustic", "instrumental", "lofi", "piano", "cover", "version"].contains(where: inner.contains) {
                    break
                }
                t.removeSubrange(o.lowerBound..<c.upperBound)
            }
        }
        // "Artist - Title" → "Title".
        for artist in artists.map({ $0.lowercased() }) where !artist.isEmpty {
            for sep in [" - ", " – ", " — "] where t.hasPrefix(artist + sep) {
                t.removeFirst(artist.count + sep.count)
            }
        }
        for noise in ["official music video", "official video", "official mv", "music video"] {
            t = t.replacingOccurrences(of: noise, with: " ")
        }
        return fold(t).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0 != "mv" }
            .joined(separator: " ")
    }

    public static func fold(_ s: String) -> String {
        s.replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "d")
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
    }

    static func artistsOverlap(_ a: [QTArtistRef], _ b: [QTArtistRef]) -> Bool {
        if !Set(a.compactMap(\.id)).isDisjoint(with: b.compactMap(\.id)) { return true }
        let an = a.map { fold($0.name).lowercased() }
        let bn = b.map { fold($0.name).lowercased() }
        return an.contains { x in bn.contains { y in !x.isEmpty && !y.isEmpty && (x.contains(y) || y.contains(x)) } }
    }

    /// The best counterpart candidate for `track` among `candidates`, or nil.
    public static func match(_ track: QTTrack, in candidates: [QTTrack]) -> QTTrack? {
        let wantVideo = !track.musicVideoType.isVideo
        let key = normalizedTitle(track.title, artists: track.artists.map(\.name))
        guard !key.isEmpty else { return nil }
        return candidates.first { c in
            guard c.videoId != track.videoId else { return false }
            if wantVideo { guard c.musicVideoType == .omv else { return false } } else { guard c.musicVideoType == .atv else { return false } }
            guard normalizedTitle(c.title, artists: c.artists.map(\.name)) == key, artistsOverlap(track.artists, c.artists)
            else { return false }
            // Audio versions must be the same recording length (±15 s); videos may have intros/outros.
            if !wantVideo, track.duration > 0, c.duration > 0, track.duration < c.duration - 15 { return false }
            return true
        }
    }
}

extension QTInnerTubeClient {
    /// Song⇄Video counterpart for a track (see `QTCounterpartMatcher` for the order of sources).
    ///
    /// Privacy: `next` goes out with the session when there is one — it is the same read the web player makes for
    /// what's playing, and only signed-in answers carry counterparts. The search fallback runs on its own for the
    /// current and the next track, so it is always **anonymous** (`identity: .anonymous`): a signed-in search would
    /// land in the account's search history.
    public func counterpart(for track: QTTrack) async throws -> QTCounterpart? {
        if let c = track.counterpart { return c }
        if let c = try? await counterpart(for: track.videoId) { return c }
        let query = ([track.title] + track.artists.prefix(1).map(\.name)).joined(separator: " ")
        let filter: QTSearchFilter = track.musicVideoType.isVideo ? .songs : .videos
        let results = try await search(query, filter: filter, identity: .anonymous)
        guard let hit = QTCounterpartMatcher.match(track, in: results.songs + results.videos) else { return nil }
        return QTCounterpart(videoId: hit.videoId, musicVideoType: hit.musicVideoType, artwork: hit.artwork)
    }
}
