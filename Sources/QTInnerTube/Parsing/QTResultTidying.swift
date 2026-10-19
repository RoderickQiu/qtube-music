import Foundation
import QTCore

/// Clean-ups YouTube Music's own lists need before they read well: one card per release in album rows, and official
/// music videos ahead of compilations and re-uploads in a search's "Music videos".
public enum QTResultTidying {
    // MARK: Releases

    /// Album items reduced to one per release, everything else untouched and in order. Two albums are the same
    /// release when they share a browse id or album playlist id (`OLAK5uy_…`), or — with different ids — the same
    /// kind, primary artist, year and normalized title (`releaseTitleKey`): YouTube Music lists explicit and clean
    /// editions, regional re-issues and bilingual re-titlings ("新世界" / "新世界 NEW WORLD") side by side. Deluxe and
    /// other editions whose titles differ stay. The first one wins (YouTube Music's own order).
    public static func dedupingReleases(_ items: [QTShelfItem], playlistIDs: [String: String] = [:]) -> [QTShelfItem] {
        var seenIDs = Set<String>()
        var seenKeys = Set<String>()
        return items.filter { item in
            guard seenIDs.insert(item.id).inserted else { return false }
            guard case .album(let album) = item else { return true }
            var keys = [releaseKey(album)]
            if let pl = playlistIDs[album.id] { keys.append("pl:\(pl)") }
            guard keys.allSatisfy({ !seenKeys.contains($0) }) else { return false }
            seenKeys.formUnion(keys)
            return true
        }
    }

    public static func dedupingReleases(_ albums: [QTAlbum]) -> [QTAlbum] {
        dedupingReleases(albums.map(QTShelfItem.album)).compactMap { if case .album(let a) = $0 { a } else { nil } }
    }

    static func releaseKey(_ album: QTAlbum) -> String {
        let artist = album.artists.first.map { ($0.id ?? $0.name).lowercased() } ?? ""
        return "\(album.kind.rawValue)|\(artist)|\(album.year.map(String.init) ?? "-")|\(releaseTitleKey(album.title))"
    }

    /// Case-, width- and script-insensitive (Traditional = Simplified) title without edition markers that don't
    /// make a different release ("(Explicit)", "[Clean]") and without a Latin re-title after a CJK title
    /// ("新世界 NEW WORLD" → "新世界", "量變臨界點 TIPPING POINT" → "量变临界点").
    public static func releaseTitleKey(_ title: String) -> String {
        var s = title.precomposedStringWithCompatibilityMapping.lowercased()
        for marker in ["(explicit)", "[explicit]", "(clean)", "[clean]", "(clean version)", "(explicit version)"] {
            s = s.replacingOccurrences(of: marker, with: " ")
        }
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        s = stripLatinRetitle(s)
        s = s.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? s
        return s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// "新世界 new world" → "新世界": a title that starts in Han / Kana / Hangul and ends, after a space, in plain
    /// Latin words is the same title given twice. Left alone: Latin titles, CJK at the end, a glued tail ("希忘Hope"),
    /// anything in brackets ("(Deluxe)") and edition words ("Live", "Remix"…) — those are other releases.
    static func stripLatinRetitle(_ s: String) -> String {
        guard let first = s.unicodeScalars.first, isCJK(first),
              let lastCJK = s.unicodeScalars.lastIndex(where: isCJK) else { return s }
        let tail = String(String.UnicodeScalarView(s.unicodeScalars[s.unicodeScalars.index(after: lastCJK)...]))
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "'’&.,!?-"))
        guard tail.first?.isWhitespace == true, tail.contains(where: \.isLetter),
              tail.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) else { return s }
        let words = Set(tail.split(whereSeparator: { !$0.isLetter }).map(String.init))
        guard words.isDisjoint(with: editionWords) else { return s }
        return String(String.UnicodeScalarView(s.unicodeScalars[...lastCJK]))
    }

    static let editionWords: Set<String> = [
        "live", "remix", "remixes", "deluxe", "edition", "version", "remaster", "remastered", "instrumental",
        "acoustic", "ost", "ep", "single", "vol", "part", "pt", "explicit", "clean", "demo", "cover", "mix",
    ]

    static func isCJK(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xAC00...0xD7AF, 0x20000...0x2FA1F: true
        default: false
        }
    }

    // MARK: Music videos

    /// Longer than this is a compilation / full concert, not a music video.
    public static let compilationSeconds: TimeInterval = 15 * 60

    /// Videos for a search's "Music videos" row, best first (stable within a tier):
    /// 1. the searched-for artist's own videos (`artistIDs`: the top result's artist(s)) — their official MVs and
    ///    anything else from their channel;
    /// 2. other official videos (OMV, or ATV);
    /// 3. everything else (lyric channels, live clips, covers);
    /// 4. anything longer than 15 minutes (compilations, "best of", full concerts).
    /// An unknown duration (0) counts as short.
    public static func rankingMusicVideos(_ videos: [QTTrack], artistIDs: Set<String> = [], artistNames: Set<String> = []) -> [QTTrack] {
        let names = Set(artistNames.map { $0.lowercased() })
        func tier(_ t: QTTrack) -> Int {
            if t.duration > compilationSeconds { return 3 }
            let byArtist = t.artists.contains { a in
                (a.id.map(artistIDs.contains) ?? false) || names.contains(a.name.lowercased())
            }
            if byArtist { return 0 }
            return t.musicVideoType == .omv || t.musicVideoType == .atv ? 1 : 2
        }
        return videos.enumerated()
            .sorted { a, b in
                let (ta, tb) = (tier(a.element), tier(b.element))
                return ta != tb ? ta < tb : a.offset < b.offset
            }
            .map(\.element)
    }
}

extension QTSearchResults {
    /// The searched-for artist: the top result when it is an artist, else the top song's / video's artists.
    public var topArtistIDs: Set<String> {
        switch topResult {
        case .artist(let a)?: [a.id]
        case .track(let t)?, .video(let t)?: Set(t.artists.compactMap(\.id))
        default: []
        }
    }

    /// Music videos, best first (`QTResultTidying.rankingMusicVideos`).
    public var rankedVideos: [QTTrack] {
        QTResultTidying.rankingMusicVideos(videos, artistIDs: topArtistIDs)
    }

    /// These results with the videos of a videos-filtered search folded in: durations (which unfiltered rows lack)
    /// patched onto the videos already here, the rest appended. Everything else is untouched.
    public func mergingVideos(from filtered: QTSearchResults) -> QTSearchResults {
        let extra = filtered.videos
        guard !extra.isEmpty else { return self }
        let byID = Dictionary(extra.map { ($0.videoId, $0) }, uniquingKeysWith: { a, _ in a })
        var out = self
        var seen = Set<String>()
        out.items = items.map { item in
            guard case .video(var t) = item else { return item }
            seen.insert(t.videoId)
            if let f = byID[t.videoId] {
                if t.duration == 0 { t.duration = f.duration }
                if t.musicVideoType == .other { t.musicVideoType = f.musicVideoType }
                if t.artists.allSatisfy({ $0.id == nil }), !f.artists.isEmpty { t.artists = f.artists }
            }
            return .video(t)
        }
        out.items += extra.filter { seen.insert($0.videoId).inserted && $0.videoId != topResult?.track?.videoId }
            .map(QTShelfItem.video)
        return out
    }
}
