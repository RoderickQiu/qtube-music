import Foundation
import QTCore

/// Lyrics the user imported from a file for one song ("Import Lyrics…"): LRC (line or enhanced word timing), TTML,
/// or plain text. Kept in the lyrics database on this Mac, listed in "Lyrics Source" as a version of its own and
/// pinned when imported, so it shows until another version or Automatic is picked.
public struct QTImportedLyrics: Codable, Sendable, Hashable {
    /// The version id it is listed and pinned under.
    public static let versionID = QTLyricsSource.imported.id + ":file"

    /// The file's name, shown under the menu row.
    public var fileName: String
    public var text: String

    public init(fileName: String, text: String) {
        self.fileName = fileName
        self.text = text
    }

    /// Reads a lyrics file: nil when it holds no lyrics (empty, binary, or a format the parsers don't know).
    public init?(fileName: String, data: Data) {
        guard let text = Self.decode(data), Self.parse(text) != nil else { return nil }
        self.init(fileName: fileName, text: text)
    }

    /// The lyrics in the file; nil when there are none.
    public var parsed: QTParsedLyrics? { Self.parse(text) }

    static func parse(_ text: String) -> QTParsedLyrics? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\u{0}") else { return nil }
        let parsed = trimmed.hasPrefix("<") ? QTTTMLParser.parse(trimmed) : QTLRCParser.parse(trimmed)
        guard let parsed, !parsed.isEmpty else { return nil }
        return parsed
    }

    /// UTF-8 (with or without a BOM), UTF-16 with a BOM, else the legacy Chinese encodings many LRC files still use
    /// (GB 18030, Big5).
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        if let s = String(data: data, encoding: .utf8) { return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s }
        for cf in [CFStringEncodings.GB_18030_2000, .big5] {
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue)))
            if let s = String(data: data, encoding: encoding) { return s }
        }
        return nil
    }

    func version(_ document: QTLyricsDocument) -> QTResolvedLyricsVersion {
        QTResolvedLyricsVersion(candidate: QTLyricsCandidate(source: .imported, remoteID: "file", title: fileName,
                                                             artists: [], isExactMatch: true),
                                score: 1, syncKind: document.syncKind, hasTranslation: document.translationLanguage != nil,
                                translationLanguage: document.translationLanguage)
    }

    static func blobName(_ videoId: String) -> String { "imported-lyrics:" + videoId }
}
