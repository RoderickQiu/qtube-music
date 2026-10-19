import Foundation
import QTCore

extension QTTrack {
    /// "Artist — Album" for now-playing subtitles (Stage, panel), or just the artist when the album adds nothing:
    /// no album, or a single named after the song ("Song", "Song - Single", "Song (EP)"), which would otherwise
    /// repeat the title right under it.
    func qtNowPlayingSubtitle(separator: String) -> String {
        guard let album = album?.title, !QTTrackSubtitle.albumRepeatsTitle(album, title: title) else { return artistLine }
        return "\(artistLine)\(separator)\(album)"
    }
}

enum QTTrackSubtitle {
    /// True when `album` is empty or the same name as `title` (ignoring case, width, Unicode normalisation and a
    /// trailing single/EP marker).
    static func albumRepeatsTitle(_ album: String, title: String) -> Bool {
        let a = stripReleaseMarker(album)
        if a.isEmpty { return true }
        let options: String.CompareOptions = [.caseInsensitive, .widthInsensitive]
        return a.compare(stripReleaseMarker(title), options: options) == .orderedSame
    }

    private static let markers = [" - single", " - ep", " (single)", " (ep)", " – single", " – ep"]

    private static func stripReleaseMarker(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        if let m = markers.first(where: { lower.hasSuffix($0) }) {
            t = String(t.dropLast(m.count)).trimmingCharacters(in: .whitespaces)
        }
        return t
    }
}
