import Foundation
import QTCore

/// Provider-neutral result of parsing one lyrics payload (LRC, YRC, QRC, KRC, TTML, YouTube Music cues).
/// Richer than `QTLyricsDocument`: keeps metadata, background vocals and every translation/romanization lane
/// so the resolver can score, align and pick before it builds the document the UI sees.
public struct QTParsedLyrics: Sendable, Hashable {
    public var lines: [QTParsedLyricsLine]
    public var metadata: QTParsedLyricsMetadata
    /// Translation / romanization lanes that came with this payload (same source as `lines`).
    public var lanes: [QTLyricsLane]

    public init(lines: [QTParsedLyricsLine], metadata: QTParsedLyricsMetadata = .init(), lanes: [QTLyricsLane] = []) {
        self.lines = lines
        self.metadata = metadata
        self.lanes = lanes
    }

    /// Word timing on (almost) every line beats line timing beats plain text.
    public var syncKind: QTLyricsSyncKind {
        let sung = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !sung.isEmpty, sung.contains(where: { $0.start != nil }) else { return .plain }
        let worded = sung.filter { ($0.words?.count ?? 0) > 0 }.count
        return Double(worded) >= Double(sung.count) * 0.8 ? .word : .line
    }

    /// Latest time any line is still sung; used for the "runs past duration + 5 s" rejection.
    public var lastTimestamp: TimeInterval? {
        lines.compactMap { line in
            if let w = line.words?.last { return w.end }
            if let e = line.end { return e }
            return line.start
        }.max()
    }

    public var isEmpty: Bool { lines.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty } }
}

public struct QTParsedLyricsLine: Sendable, Hashable {
    /// Seconds from track start; nil for plain lyrics.
    public var start: TimeInterval?
    public var end: TimeInterval?
    public var text: String
    public var words: [QTLyricsWord]?
    /// Background vocals (TTML `ttm:role="x-bg"`), word-timed when available.
    public var backgroundWords: [QTLyricsWord]?
    /// Inline translation (TTML `x-translation`), keyed by BCP-47 language ("" when unknown).
    public var inlineTranslations: [String: String]
    /// Inline romanization (TTML `x-roman`).
    public var inlineRomanization: String?

    public init(start: TimeInterval?, end: TimeInterval? = nil, text: String, words: [QTLyricsWord]? = nil,
                backgroundWords: [QTLyricsWord]? = nil, inlineTranslations: [String: String] = [:],
                inlineRomanization: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.words = words
        self.backgroundWords = backgroundWords
        self.inlineTranslations = inlineTranslations
        self.inlineRomanization = inlineRomanization
    }
}

public struct QTParsedLyricsMetadata: Sendable, Hashable {
    public var title: String?
    public var artist: String?
    public var album: String?
    /// Track length in seconds as the payload declares it (LRC `[length:]`, KRC `[total:]`).
    public var length: TimeInterval?
    /// `[offset:]` in seconds as written in the file (already applied to the timestamps).
    public var fileOffset: TimeInterval?
    /// Declared language of the lyric text, if the format carries one.
    public var language: String?
    /// Attribution shown under the lyrics ("Source: LyricFind").
    public var attribution: String?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil, length: TimeInterval? = nil,
                fileOffset: TimeInterval? = nil, language: String? = nil, attribution: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.length = length
        self.fileOffset = fileOffset
        self.language = language
        self.attribution = attribution
    }
}

/// A timed side lane: translation or romanization, as delivered by a provider.
public struct QTLyricsLane: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable { case translation, romanization }

    public struct Entry: Sendable, Hashable, Codable {
        /// Seconds; nil when the lane is index-aligned only.
        public var start: TimeInterval?
        public var text: String
        public init(start: TimeInterval?, text: String) {
            self.start = start
            self.text = text
        }
    }

    public var kind: Kind
    /// BCP-47 (`zh-Hans`, `en`…); nil when unknown.
    public var language: String?
    public var entries: [Entry]
    /// True when `entries[i]` belongs to `lines[i]` (KRC language lanes, TTML inline spans).
    public var isIndexAligned: Bool

    public init(kind: Kind, language: String?, entries: [Entry], isIndexAligned: Bool = false) {
        self.kind = kind
        self.language = language
        self.entries = entries
        self.isIndexAligned = isIndexAligned
    }
}

public extension QTLyricsSource {
    /// Romanization generated on device with ICU transforms.
    static let onDeviceRomanization = QTLyricsSource(id: "onDevice", name: "On-device")
    /// Lyric translation by Apple's Foundation Models (macOS 26+, M6).
    static let appleIntelligenceEngine = QTLyricsSource(id: "appleIntelligence", name: "Apple Intelligence")
    /// Lyric translation by the Translation framework (macOS 15+, M6).
    static let translationFrameworkEngine = QTLyricsSource(id: "translationFramework", name: "On-device translation")
}
