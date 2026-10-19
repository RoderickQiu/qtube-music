import Foundation
import QTCore

/// The three Chinese-provider word-timed formats share a `[lineStartMs,lineDurMs]` prefix and differ in how
/// word tags are written:
/// - NetEase YRC: `[35695,3800](35695,575,0)Gió (36270,358,0)cứ` — tag before the word, absolute ms.
/// - QQ QRC:      `[1801,7400]沈(1801,472)む(2273,420)` — tag after the word, absolute ms.
/// - Kugou KRC:   `[51382,2879]<0,337,0>Gió <337,248,0>cứ` — tag before the word, ms relative to the line.
enum QTWordTimedStyle {
    case yrc, qrc, krc

    var open: Character { self == .krc ? "<" : "(" }
    var close: Character { self == .krc ? ">" : ")" }
    var tagBeforeWord: Bool { self != .qrc }
    var relative: Bool { self == .krc }
}

struct QTWordTimedLine {
    var start: TimeInterval
    var duration: TimeInterval
    var words: [QTLyricsWord]
    var text: String
}

enum QTWordTimedLineParser {
    /// Parses one `[start,dur]…` line; nil when the line has another shape (tags, JSON credits, LRC).
    static func parse(_ raw: Substring, style: QTWordTimedStyle) -> QTWordTimedLine? {
        guard raw.first == "[", let close = raw.firstIndex(of: "]") else { return nil }
        let head = raw[raw.index(after: raw.startIndex)..<close].split(separator: ",")
        guard head.count == 2, let s = Int(head[0]), let d = Int(head[1]) else { return nil }
        let lineStart = Double(s) / 1000
        let body = raw[raw.index(after: close)...]
        var words: [QTLyricsWord] = []
        var pendingText = ""            // QRC: text waiting for its tag
        var pendingTag: (TimeInterval, TimeInterval)?   // YRC/KRC: tag waiting for its text
        var i = body.startIndex

        func flushTagged(_ text: String) {
            guard let tag = pendingTag else { return }
            if !text.isEmpty { words.append(QTLyricsWord(start: tag.0, duration: tag.1, text: text)) }
            pendingTag = nil
        }

        var textRun = ""
        while i < body.endIndex {
            let c = body[i]
            if c == style.open, let tagEnd = body[i...].firstIndex(of: style.close),
               let tag = parseTag(body[body.index(after: i)..<tagEnd], lineStart: lineStart, relative: style.relative) {
                if style.tagBeforeWord {
                    flushTagged(textRun)
                    if pendingTag == nil, !textRun.isEmpty, words.isEmpty {
                        // Untagged lead-in text: give it the time up to the first tag.
                        words.append(QTLyricsWord(start: lineStart, duration: max(0, tag.0 - lineStart), text: textRun))
                    }
                    pendingTag = tag
                } else {
                    pendingText += textRun
                    if !pendingText.isEmpty {
                        words.append(QTLyricsWord(start: tag.0, duration: tag.1, text: pendingText))
                    }
                    pendingText = ""
                }
                textRun = ""
                i = body.index(after: tagEnd)
                continue
            }
            textRun.append(c)
            i = body.index(after: i)
        }
        if style.tagBeforeWord { flushTagged(textRun) } else if !(pendingText + textRun).isEmpty, var last = words.popLast() {
            last.text += pendingText + textRun
            words.append(last)
        }
        // Trailing whitespace on the final word never renders.
        if var last = words.popLast() {
            while last.text.last?.isWhitespace == true { last.text.removeLast() }
            if !last.text.isEmpty { words.append(last) }
        }
        let text = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        return QTWordTimedLine(start: lineStart, duration: Double(d) / 1000, words: words, text: text)
    }

    private static func parseTag(_ inner: Substring, lineStart: TimeInterval, relative: Bool) -> (TimeInterval, TimeInterval)? {
        let parts = inner.split(separator: ",")
        guard parts.count >= 2, let a = Int(parts[0]), let b = Int(parts[1]) else { return nil }
        let start = Double(a) / 1000 + (relative ? lineStart : 0)
        return (start, Double(b) / 1000)
    }

    static func makeLines(_ parsed: [QTWordTimedLine]) -> [QTParsedLyricsLine] {
        let sorted = parsed.sorted { $0.start < $1.start }
        return sorted.map { l in
            let end = max(l.start + l.duration, l.words.last?.end ?? 0)
            return QTParsedLyricsLine(start: l.start, end: end, text: l.text, words: l.words.isEmpty ? nil : l.words)
        }
    }
}

/// NetEase YRC. JSON credit lines (`{"t":0,"c":[…]}`) are skipped.
public enum QTYRCParser {
    public static func parse(_ text: String) -> QTParsedLyrics {
        var lines: [QTWordTimedLine] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.drop { $0 == " " }
            if let l = QTWordTimedLineParser.parse(line, style: .yrc), !l.text.isEmpty { lines.append(l) }
        }
        return QTParsedLyrics(lines: QTWordTimedLineParser.makeLines(lines))
    }
}

/// QQ Music QRC (decrypted). Accepts the XML wrapper (`<Lyric_1 LyricContent="…"/>`) or bare content;
/// falls back to LRC when the payload is line-timed (QQ's `trans` lane is LRC).
public enum QTQRCParser {
    public static func parse(_ text: String) -> QTParsedLyrics {
        let content = lyricContent(from: text) ?? text
        var lines: [QTWordTimedLine] = []
        var metadata = QTParsedLyricsMetadata()
        for raw in content.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let l = QTWordTimedLineParser.parse(Substring(line), style: .qrc) {
                if !l.text.isEmpty { lines.append(l) }
            } else if line.hasPrefix("[ti:") { metadata.title = String(line.dropFirst(4).dropLast()).nilIfEmpty }
            else if line.hasPrefix("[ar:") { metadata.artist = String(line.dropFirst(4).dropLast()).nilIfEmpty }
            else if line.hasPrefix("[al:") { metadata.album = String(line.dropFirst(4).dropLast()).nilIfEmpty }
        }
        if lines.isEmpty { return QTLRCParser.parse(content) }
        return QTParsedLyrics(lines: QTWordTimedLineParser.makeLines(lines), metadata: metadata)
    }

    /// The `LyricContent` attribute of a QRC XML document, XML-unescaped.
    static func lyricContent(from xml: String) -> String? {
        guard let r = xml.range(of: "LyricContent=\"") else { return nil }
        let after = xml[r.upperBound...]
        guard let end = after.range(of: "\"/>", options: .backwards) ?? after.range(of: "\"", options: .backwards) else { return nil }
        return String(after[..<end.lowerBound]).qtXMLUnescaped
    }
}

/// Kugou KRC (decrypted), including the `[language:]` lanes: base64 JSON whose `content[]` entries have
/// `type` 0 = romanization (per-word syllables) and 1 = translation (one string per line), index-aligned
/// with the KRC lines.
public enum QTKRCParser {
    public static func parse(_ text: String) -> QTParsedLyrics {
        var metadata = QTParsedLyricsMetadata()
        var raw: [QTWordTimedLine] = []
        var languageTag: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let l = QTWordTimedLineParser.parse(Substring(line), style: .krc) {
                raw.append(l)
                continue
            }
            guard line.hasPrefix("["), line.hasSuffix("]"), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.index(after: line.startIndex)..<colon]
            let value = String(line[line.index(after: colon)..<line.index(before: line.endIndex)])
            switch key {
            case "ti": metadata.title = value.nilIfEmpty
            case "ar": metadata.artist = value.nilIfEmpty
            case "al": metadata.album = value.nilIfEmpty
            case "total": metadata.length = Double(value).map { $0 / 1000 }
            case "offset": metadata.fileOffset = Double(value).map { $0 / 1000 }
            case "language": languageTag = value
            default: break
            }
        }
        var lanes: [QTLyricsLane] = []
        if let tag = languageTag, let json = Data(base64Encoded: tag),
           let decoded = try? JSONDecoder().decode(KugouLanguage.self, from: json) {
            for entry in decoded.content {
                let kind: QTLyricsLane.Kind = entry.type == 0 ? .romanization : .translation
                var entries: [QTLyricsLane.Entry] = []
                for (i, line) in raw.enumerated() {
                    let parts = i < entry.lyricContent.count ? entry.lyricContent[i] : []
                    let joined = kind == .romanization ? parts.joined(separator: "") : parts.joined(separator: " ")
                    let text = joined.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces)
                    entries.append(.init(start: line.start, text: text))
                }
                lanes.append(QTLyricsLane(kind: kind, language: kind == .translation ? "zh-Hans" : nil,
                                          entries: entries, isIndexAligned: false))
            }
        }
        let kept = raw.filter { !$0.text.isEmpty }
        return QTParsedLyrics(lines: QTWordTimedLineParser.makeLines(kept), metadata: metadata, lanes: lanes)
    }

    private struct KugouLanguage: Decodable {
        struct Entry: Decodable {
            var type: Int
            var lyricContent: [[String]]
        }
        var content: [Entry]
    }
}

extension String {
    /// Decodes the five predefined XML entities and numeric character references.
    var qtXMLUnescaped: String {
        guard contains("&") else { return self }
        var out = ""
        var i = startIndex
        while i < endIndex {
            if self[i] == "&", let semi = self[i...].firstIndex(of: ";"), distance(from: i, to: semi) <= 10 {
                let entity = self[index(after: i)..<semi]
                var replacement: String?
                switch entity {
                case "amp": replacement = "&"
                case "lt": replacement = "<"
                case "gt": replacement = ">"
                case "quot": replacement = "\""
                case "apos": replacement = "'"
                default:
                    if entity.hasPrefix("#x") || entity.hasPrefix("#X"), let v = UInt32(entity.dropFirst(2), radix: 16),
                       let u = Unicode.Scalar(v) { replacement = String(Character(u)) }
                    else if entity.hasPrefix("#"), let v = UInt32(entity.dropFirst()), let u = Unicode.Scalar(v) {
                        replacement = String(Character(u))
                    }
                }
                if let r = replacement {
                    out += r
                    i = index(after: semi)
                    continue
                }
            }
            out.append(self[i])
            i = index(after: i)
        }
        return out
    }
}
