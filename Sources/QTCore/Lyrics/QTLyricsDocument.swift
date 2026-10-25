import Foundation

/// How precisely a lyrics document is timed. Ordered: word beats line beats plain.
public enum QTLyricsSyncKind: String, Codable, Sendable, Hashable, Comparable, CaseIterable {
    case plain, line, word

    private var rank: Int { switch self { case .plain: 0; case .line: 1; case .word: 2 } }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

/// Where lyrics (or a translation lane) came from.
public struct QTLyricsSource: Codable, Sendable, Hashable {
    /// Stable provider id: `youtubeMusic`, `lrclib`, `amll`, `netease`, `kugou`, `qq`, `appleIntelligence`,
    /// `translationFramework`, `mock`, `imported` (a file the user imported for the song).
    public var id: String
    /// Display name; provider brand names are not translated except where the shared table has a key ("NetEase").
    public var name: String
    /// Community/unofficial sources are opt-in (Settings › Lyrics › Unofficial sources).
    public var isUnofficial: Bool

    public init(id: String, name: String, isUnofficial: Bool = false) {
        self.id = id
        self.name = name
        self.isUnofficial = isUnofficial
    }

    public static let youtubeMusic = QTLyricsSource(id: "youtubeMusic", name: "YouTube Music")
    public static let lrclib = QTLyricsSource(id: "lrclib", name: "LRCLIB")
    public static let amll = QTLyricsSource(id: "amll", name: "AMLL TTML DB")
    public static let netease = QTLyricsSource(id: "netease", name: "NetEase", isUnofficial: true)
    public static let kugou = QTLyricsSource(id: "kugou", name: "Kugou", isUnofficial: true)
    public static let qq = QTLyricsSource(id: "qq", name: "QQ Music", isUnofficial: true)
    /// Lyrics the user imported from a file for one song ("Import Lyrics…").
    public static let imported = QTLyricsSource(id: "imported", name: "Imported")
}

public struct QTLyricsWord: Codable, Sendable, Hashable {
    /// Seconds from track start.
    public var start: TimeInterval
    public var duration: TimeInterval
    /// Includes trailing whitespace exactly as it should render.
    public var text: String

    public init(start: TimeInterval, duration: TimeInterval, text: String) {
        self.start = start
        self.duration = duration
        self.text = text
    }

    public var end: TimeInterval { start + duration }

    /// 0…1 karaoke fill for a lyric time.
    public func progress(at lyricTime: TimeInterval) -> Double {
        guard duration > 0.05 else { return lyricTime >= start ? 1 : 0 }
        return ((lyricTime - start) / duration).clamped(to: 0...1)
    }
}

public struct QTLyricsLine: Codable, Sendable, Hashable {
    /// Seconds from track start (0 for plain lyrics).
    public var start: TimeInterval
    public var duration: TimeInterval?
    public var text: String
    /// Word timing when `syncKind == .word`.
    public var words: [QTLyricsWord]?
    /// Translation lane (in `QTLyricsDocument.translationLanguage`).
    public var translation: String?
    /// Romanization lane (pinyin, romaji, Revised Romanization…).
    public var romanization: String?

    public init(start: TimeInterval, duration: TimeInterval? = nil, text: String, words: [QTLyricsWord]? = nil,
                translation: String? = nil, romanization: String? = nil) {
        self.start = start
        self.duration = duration
        self.text = text
        self.words = words
        self.translation = translation
        self.romanization = romanization
    }
}

/// Lyrics for one track: lines → words, plus translation/romanization lanes.
/// Never mixes lines from two sources; only the lanes may come from a second source (after alignment).
public struct QTLyricsDocument: Codable, Sendable, Hashable {
    public var lines: [QTLyricsLine]
    public var syncKind: QTLyricsSyncKind
    public var source: QTLyricsSource
    /// BCP-47 language of the lyric text (`vi`, `zh-Hans`, `en`, `ja`…), nil if unknown.
    public var language: String?
    /// Language of the translation lane, nil if there is none.
    public var translationLanguage: String?
    public var translationSource: QTLyricsSource?
    public var romanizationSource: QTLyricsSource?
    /// Match score 0…1 (≥ 0.80 accept, 0.60–0.80 "possible mismatch", see docs/redesign-draft.md §6).
    public var confidence: Double
    /// Per-track user offset in seconds. Positive = lyrics appear earlier (⌥↑ "Lyrics Earlier" adds +0.1).
    public var offset: TimeInterval
    /// Set when the lyric lines were converted from the other Chinese script (Traditional ⇄ Simplified) to match the
    /// translation target: the script they arrived in (`zh-Hant` / `zh-Hans`). Nil for lyrics shown as written.
    public var scriptConvertedFrom: String?

    public init(lines: [QTLyricsLine], syncKind: QTLyricsSyncKind, source: QTLyricsSource, language: String? = nil,
                translationLanguage: String? = nil, translationSource: QTLyricsSource? = nil,
                romanizationSource: QTLyricsSource? = nil, confidence: Double = 1, offset: TimeInterval = 0) {
        self.lines = lines
        self.syncKind = syncKind
        self.source = source
        self.language = language
        self.translationLanguage = translationLanguage
        self.translationSource = translationSource
        self.romanizationSource = romanizationSource
        self.confidence = confidence
        self.offset = offset
    }

    public var hasTranslation: Bool { lines.contains { $0.translation?.isEmpty == false } }

    /// The time on the lyric timeline for a playback position.
    public func lyricTime(forPlaybackTime t: TimeInterval) -> TimeInterval { t + offset }

    /// Index of the line being sung at a playback position (last line whose start ≤ lyric time), nil before the first.
    /// Plain lyrics have no current line.
    public func lineIndex(atPlaybackTime t: TimeInterval) -> Int? {
        guard syncKind != .plain, !lines.isEmpty else { return nil }
        let lt = lyricTime(forPlaybackTime: t)
        var lo = 0, hi = lines.count - 1, ans: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].start <= lt { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }

    /// Playback position to seek to so that line `index` becomes current.
    public func playbackTime(forLine index: Int) -> TimeInterval {
        max(0, lines[index].start - offset + 0.02)
    }

    /// Offset nudged by `delta`, rounded to 0.1 s (⌥↑ / ⌥↓).
    public func withOffset(nudgedBy delta: TimeInterval) -> QTLyricsDocument {
        var d = self
        d.offset = ((offset + delta) * 10).rounded() / 10
        return d
    }
}
