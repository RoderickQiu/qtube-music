import Foundation
import QTCore

/// LRC with the common extensions:
/// - several timestamps on one line (`[00:12.00][01:30.50]chorus`),
/// - enhanced word tags (`[00:12.00]<00:12.00>Hello <00:12.40>world<00:13.10>`),
/// - `[offset:+250]` (milliseconds; positive shows lyrics earlier) applied to every timestamp,
/// - metadata tags (`ti`, `ar`, `al`, `length`, `la`/`lang`),
/// - plain text files (no timestamps at all) → plain lyrics.
public enum QTLRCParser {
    public static func parse(_ text: String) -> QTParsedLyrics {
        var metadata = QTParsedLyricsMetadata()
        var timed: [(start: TimeInterval, body: Substring, order: Int)] = []
        var plain: [String] = []
        var order = 0

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var rest = Substring(line)
            var stamps: [TimeInterval] = []
            var sawTag = false
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let inner = rest[rest.index(after: rest.startIndex)..<close]
                if let t = QTLyricsTimeFormat.seconds(inner, lrcLegacy: true), inner.first?.isNumber == true {
                    stamps.append(t)
                } else if let colon = inner.firstIndex(of: ":"), inner[..<colon].allSatisfy({ $0.isLetter || $0 == "#" }) {
                    applyTag(String(inner[..<colon]).lowercased(),
                             value: String(inner[inner.index(after: colon)...]).trimmingCharacters(in: .whitespaces),
                             to: &metadata)
                    sawTag = true
                } else {
                    break
                }
                rest = rest[rest.index(after: close)...]
            }
            if stamps.isEmpty {
                if !sawTag, !rest.isEmpty { plain.append(String(rest).trimmingCharacters(in: .whitespaces)) }
                continue
            }
            for t in stamps {
                timed.append((t, rest, order))
                order += 1
            }
        }

        guard !timed.isEmpty else {
            return QTParsedLyrics(lines: plain.map { QTParsedLyricsLine(start: nil, text: $0) }, metadata: metadata)
        }

        let shift = -(metadata.fileOffset ?? 0)
        timed.sort { $0.start == $1.start ? $0.order < $1.order : $0.start < $1.start }
        var lines: [QTParsedLyricsLine] = []
        lines.reserveCapacity(timed.count)
        for (i, entry) in timed.enumerated() {
            let start = max(0, entry.start + shift)
            let next = i + 1 < timed.count ? max(0, timed[i + 1].start + shift) : nil
            let (text, words) = parseBody(entry.body, lineStart: start, nextLineStart: next, shift: shift)
            var line = QTParsedLyricsLine(start: start, end: next, text: text, words: words)
            if let last = words?.last { line.end = max(next ?? last.end, last.end) }
            lines.append(line)
        }
        return QTParsedLyrics(lines: lines, metadata: metadata)
    }

    private static func applyTag(_ key: String, value: String, to m: inout QTParsedLyricsMetadata) {
        switch key {
        case "ti": m.title = value.nilIfEmpty
        case "ar": m.artist = value.nilIfEmpty
        case "al": m.album = value.nilIfEmpty
        case "length": m.length = QTLyricsTimeFormat.seconds(value)
        case "offset": m.fileOffset = Double(value.replacingOccurrences(of: "+", with: "")).map { $0 / 1000 }
        case "la", "lang", "language":
            if !value.isEmpty, value.count <= 16 { m.language = value }
        default: break
        }
    }

    /// Splits `<mm:ss.xx>word<mm:ss.xx>word…` into words; returns the visible text and the words (nil when untagged).
    static func parseBody(_ body: Substring, lineStart: TimeInterval, nextLineStart: TimeInterval?,
                          shift: TimeInterval) -> (String, [QTLyricsWord]?) {
        guard body.contains("<") else { return (String(body).trimmingCharacters(in: .whitespaces), nil) }
        var stamps: [(TimeInterval, Substring)] = []   // tag time, text that follows it
        var leading = ""
        var rest = body
        var trailingStamp: TimeInterval?
        while !rest.isEmpty {
            if rest.first == "<", let close = rest.firstIndex(of: ">"),
               let t = QTLyricsTimeFormat.seconds(rest[rest.index(after: rest.startIndex)..<close], lrcLegacy: true) {
                let after = rest[rest.index(after: close)...]
                let nextOpen = after.firstIndex(of: "<") ?? after.endIndex
                let chunk = after[..<nextOpen]
                if chunk.isEmpty, nextOpen == after.endIndex { trailingStamp = max(0, t + shift) }
                stamps.append((max(0, t + shift), chunk))
                rest = after[nextOpen...]
            } else {
                let nextOpen = rest.dropFirst().firstIndex(of: "<") ?? rest.endIndex
                if stamps.isEmpty { leading += rest[..<nextOpen] } else { stamps[stamps.count - 1].1 += rest[..<nextOpen] }
                rest = rest[nextOpen...]
            }
        }
        let wordStamps = stamps.filter { !$0.1.isEmpty }
        guard !wordStamps.isEmpty else { return ((leading).trimmingCharacters(in: .whitespaces), nil) }
        var words: [QTLyricsWord] = []
        if !leading.trimmingCharacters(in: .whitespaces).isEmpty {
            words.append(QTLyricsWord(start: lineStart, duration: max(0, wordStamps[0].0 - lineStart), text: leading))
        }
        for (i, (t, chunk)) in stamps.enumerated() where !chunk.isEmpty {
            let end = i + 1 < stamps.count ? stamps[i + 1].0 : (trailingStamp ?? nextLineStart ?? t + 0.6)
            words.append(QTLyricsWord(start: t, duration: max(0, min(end, nextLineStart ?? end) - t), text: String(chunk)))
        }
        if var last = words.popLast() {
            last.text = last.text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            words.append(last)
        }
        let text = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        return (text, words)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
