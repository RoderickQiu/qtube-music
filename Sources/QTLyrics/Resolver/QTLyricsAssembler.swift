import Foundation
import QTCore

/// Line hygiene shared by every source.
enum QTLyricsCleanup {
    private static let creditPattern = try! NSRegularExpression(
        pattern: #"^\s*(作词|作詞|作曲|编曲|編曲|词|詞|曲|制作人|製作人|监制|監製|混音|母带|录音|和声|吉他|贝斯|鼓|弦乐|出品|发行|OP|SP|Lyrics?( by)?|Lyricist|Written by|Compose[dr]?( by)?|Arrange[dr]?( by)?|Produce[dr]?( by)?|Mix(ed|ing)?( by)?|Master(ed|ing)?( by)?)\s*[:：]"#,
        options: [.caseInsensitive])

    static func isCredit(_ text: String) -> Bool {
        creditPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// "♪", "♫ ♫", "…" — instrumental markers, not lyrics.
    static func isMusicNoteOnly(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { "♪♫♬♩🎵🎶…·. ".contains($0) }
    }

    static func keep(_ line: QTParsedLyricsLine) -> Bool {
        let t = line.text.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && !isMusicNoteOnly(t) && !isCredit(t)
    }
}

/// Turns a parsed payload into the `QTLyricsDocument` the UI renders: drops credits and note-only lines, fills the
/// translation lane (same source: within 1.5 s; second source: only after offset estimation and ≥ 70 % alignment),
/// fills romanization (provider lane first, else ICU on device), detects the language.
public enum QTLyricsAssembler {
    /// Same-source lane tolerance (NetEase translation timestamps drift by up to ~1.5 s).
    static let sameSourceTolerance: TimeInterval = 1.5
    /// Second-source lane tolerance after removing the estimated constant offset.
    static let foreignTolerance: TimeInterval = 0.75
    /// Minimum share of lines that must align before a second-source lane is used.
    static let foreignCoverage = 0.7

    public static func document(from parsed: QTParsedLyrics, source: QTLyricsSource, confidence: Double,
                                preferredTranslationLanguage target: String?, romanize: Bool = true) -> QTLyricsDocument {
        let kept = parsed.lines.filter(QTLyricsCleanup.keep)
        let syncKind = QTParsedLyrics(lines: kept).syncKind
        let language = parsed.metadata.language.map(QTLanguageCode.normalize)
            ?? QTLyricsLanguageDetector.detect(kept.prefix(40).map(\.text))

        var lines = kept.map { l -> QTLyricsLine in
            let start = syncKind == .plain ? 0 : (l.start ?? 0)
            let duration = l.end.map { max(0, $0 - start) }
            return QTLyricsLine(start: start, duration: syncKind == .plain ? nil : duration, text: l.text,
                                words: syncKind == .word ? l.words : nil)
        }

        // Translation: the lane in the target language if there is one, else the provider's own.
        var translationLanguage: String?
        let translationLanes = parsed.lanes.filter { $0.kind == .translation }
        let ordered = translationLanes.sorted { a, b in
            QTLanguageCode.isSame(a.language, target) && !QTLanguageCode.isSame(b.language, target)
        }
        if syncKind != .plain, let first = ordered.first {
            let sameLanguage = ordered.filter { $0.language == first.language }
            for lane in sameLanguage {
                let aligned = align(lane, to: kept, tolerance: sameSourceTolerance)
                for i in lines.indices where lines[i].translation == nil {
                    if let t = aligned[i], !t.isEmpty, t != lines[i].text { lines[i].translation = t }
                }
            }
            if lines.contains(where: { $0.translation != nil }) { translationLanguage = first.language }
        }

        // Romanization: provider lane, else on-device ICU.
        var romanizationSource: QTLyricsSource?
        if syncKind != .plain, let lane = parsed.lanes.first(where: { $0.kind == .romanization }) {
            let aligned = align(lane, to: kept, tolerance: sameSourceTolerance)
            for i in lines.indices { if let r = aligned[i], !r.isEmpty, r != lines[i].text { lines[i].romanization = r } }
            if lines.contains(where: { $0.romanization != nil }) { romanizationSource = source }
        }
        if romanize, romanizationSource == nil, QTLyricsRomanizer.needsRomanization(language) {
            for i in lines.indices { lines[i].romanization = QTLyricsRomanizer.romanize(lines[i].text, language: language) }
            if lines.contains(where: { $0.romanization != nil }) { romanizationSource = .onDeviceRomanization }
        }

        return QTLyricsDocument(lines: lines, syncKind: syncKind, source: source, language: language,
                                translationLanguage: translationLanguage,
                                translationSource: translationLanguage == nil ? nil : source,
                                romanizationSource: romanizationSource, confidence: confidence)
    }

    /// Same-source alignment: index-aligned lanes map 1:1 by start time, timed lanes take the nearest unused
    /// entry within `tolerance`, moving forward only (lyrics are monotonic).
    static func align(_ lane: QTLyricsLane, to lines: [QTParsedLyricsLine], tolerance: TimeInterval) -> [String?] {
        var out = [String?](repeating: nil, count: lines.count)
        let entries = lane.entries.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !entries.isEmpty else { return out }
        let timed = entries.allSatisfy { $0.start != nil }
        if !timed {
            // Untimed lane: only trust it when it is exactly line-for-line.
            if entries.count == lines.count { for i in lines.indices { out[i] = entries[i].text } }
            return out
        }
        var cursor = 0
        for (i, line) in lines.enumerated() {
            guard let s = line.start else { continue }
            var best: (index: Int, distance: Double)?
            var j = cursor
            while j < entries.count {
                let d = entries[j].start! - s
                if d > tolerance { break }
                if abs(d) <= tolerance, abs(d) < (best?.distance ?? .infinity) { best = (j, abs(d)) }
                j += 1
            }
            if let b = best {
                // Don't steal an entry that is clearly the next line's.
                if i + 1 < lines.count, let ns = lines[i + 1].start, abs(entries[b.index].start! - ns) < b.distance { continue }
                out[i] = entries[b.index].text
                cursor = b.index + 1
            }
        }
        return out
    }

    /// Second-source lane: estimate the constant offset between the sources (median nearest-line delta), shift,
    /// align tightly, and accept only when ≥ 70 % of lines get a lane entry. nil = timestamps don't line up.
    static func alignForeign(_ lane: QTLyricsLane, to lines: [QTLyricsLine]) -> [String?]? {
        let entries = lane.entries.filter { $0.start != nil && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty, entries.count >= 2 else { return nil }
        let starts = lines.map(\.start)
        var deltas: [Double] = []
        for e in entries {
            let nearest = starts.min { abs($0 - e.start!) < abs($1 - e.start!) }!
            deltas.append(e.start! - nearest)
        }
        deltas.sort()
        let shift = deltas[deltas.count / 2]
        let shifted = QTLyricsLane(kind: lane.kind, language: lane.language,
                                   entries: entries.map { .init(start: $0.start! - shift, text: $0.text) })
        let parsedLines = lines.map { QTParsedLyricsLine(start: $0.start, text: $0.text) }
        let aligned = align(shifted, to: parsedLines, tolerance: foreignTolerance)
        let matched = aligned.compactMap { $0 }.count
        guard Double(matched) >= Double(lines.count) * foreignCoverage,
              Double(matched) >= Double(entries.count) * foreignCoverage else { return nil }
        return aligned
    }
}
