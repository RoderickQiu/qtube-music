import Foundation
import NaturalLanguage
import QTCore

/// Checks on fetched lyrics that a title/artist/length match can't make: is the text plausibly in the title's
/// script, in any language at all, sung through the track — and is it the same text a source served for other songs
/// (the "same gibberish on every song" failure, Pear #4684). The first three are penalties (`QTLyricsMatchFlag`); the
/// shared-text check needs the cache, so the resolver runs it with `fingerprint(_:)`.
public enum QTLyricsSanity {
    /// Penalty per flag; several add up to at most `maximumPenalty`.
    static func penalty(for flag: QTLyricsMatchFlag) -> Double {
        switch flag {
        case .scriptMismatch: 0.25
        case .gibberish: 0.15
        case .lowCoverage: 0.15
        case .unknownLength: 0.15
        case .sharedText: 0.25
        }
    }

    static let maximumPenalty = 0.4
    /// `NLLanguageRecognizer`'s mean per-line top hypothesis below this means it can't name a language. Real lyrics
    /// in a language it knows average 0.9+; in one it doesn't (Welsh, Zulu, Basque, Māori) 0.48–0.65; keyboard mash
    /// about 0.4.
    static let gibberishConfidence = 0.45
    /// …and only when its per-line guesses scatter over at least this many languages, none taking half the lines
    /// (a language it doesn't know is often guessed the same way line after line).
    static let gibberishLanguages = 3
    /// Lines that make a fingerprint, and the fewest a text needs to have one.
    static let fingerprintLines = 8
    static let fingerprintMinimumLines = 4
    /// Songs whose titles are at least this alike may share lyrics (covers, re-releases, live cuts); so may songs by
    /// artists this alike (one artist's song under a translated title).
    static let sameSongTitleSimilarity = 0.9
    static let sameArtistSimilarity = 0.9
    /// A text chosen for at least this many other songs (other titles, other artists) is a source's filler.
    static let sharedTextSongs = 2

    public static func penalty(for flags: Set<QTLyricsMatchFlag>) -> Double {
        min(maximumPenalty, flags.reduce(0) { $0 + penalty(for: $1) })
    }

    public static func flags(_ lyrics: QTParsedLyrics, for query: QTLyricsQuery) -> Set<QTLyricsMatchFlag> {
        let sung = lyrics.lines.filter(QTLyricsCleanup.keep).map(\.text)
        var flags: Set<QTLyricsMatchFlag> = []
        if isScriptMismatch(title: query.title, lyrics: sung) { flags.insert(.scriptMismatch) }
        if isGibberish(sung) { flags.insert(.gibberish) }
        if query.duration > 0, lyrics.syncKind != .plain, let last = lyrics.lastTimestamp,
           last < query.duration * QTLyricsMatchThreshold.minimumCoverage {
            flags.insert(.lowCoverage)
        }
        return flags
    }

    // MARK: Script

    enum Script: Hashable { case latin, cjk, cyrillic, greek, arabic, hebrew, thai, devanagari }

    /// Chinese, Japanese and Korean count as one family: a Korean title over Hanja lyrics, or a Japanese one over
    /// kanji, is fine.
    static func script(of s: Unicode.Scalar) -> Script? {
        guard s.properties.isAlphabetic else { return nil }
        switch s.value {
        case 0x0041...0x024F, 0x1E00...0x1EFF: return .latin
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F, 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF,
             0x20000...0x2FFFF, 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: return .cjk
        case 0x0400...0x04FF: return .cyrillic
        case 0x0370...0x03FF: return .greek
        case 0x0600...0x06FF: return .arabic
        case 0x0590...0x05FF: return .hebrew
        case 0x0E00...0x0E7F: return .thai
        case 0x0900...0x097F: return .devanagari
        default: return nil
        }
    }

    static func scripts(in text: String) -> (counts: [Script: Int], letters: Int) {
        var counts: [Script: Int] = [:]
        var letters = 0
        for s in text.unicodeScalars where s.properties.isAlphabetic {
            letters += 1
            if let k = script(of: s) { counts[k, default: 0] += 1 }
        }
        return (counts, letters)
    }

    /// The title is mostly in a non-Latin script and the lyrics are Latin with (almost) none of it. Only that way
    /// round: Latin titles over Korean, Japanese or Chinese lyrics are everyday (K-pop, romanized titles).
    static func isScriptMismatch(title: String, lyrics: [String]) -> Bool {
        let t = scripts(in: QTTitleCleaner.clean(title).core)
        guard t.letters > 0, let (family, n) = t.counts.max(by: { $0.value < $1.value }), family != .latin,
              Double(n) >= Double(t.letters) * 0.5 else { return false }
        let l = scripts(in: lyrics.prefix(40).joined(separator: "\n"))
        guard l.letters >= 20 else { return false }
        let share = { (k: Script) in Double(l.counts[k] ?? 0) / Double(l.letters) }
        return share(family) < 0.02 && share(.latin) >= 0.9
    }

    // MARK: Language

    /// Enough text that the recognizer has no idea what language it is in. Judged line by line: a line of real lyrics
    /// is in one language even when the song switches between two (whole-text confidence drops to ~0.6 for a
    /// bilingual song, as low as keyboard mash), while mash stays uncertain on every line and gets a different guess
    /// on most. Short lines and short texts ("Oh oh oh") are left alone. A hint only (`forcesBadge` is false).
    static func isGibberish(_ lines: [String]) -> Bool {
        let wordy = lines.prefix(30).filter { $0.unicodeScalars.filter(\.properties.isAlphabetic).count >= 12 }
        guard wordy.count >= 4 else { return false }
        let recognizer = NLLanguageRecognizer()
        var total = 0.0
        var guesses: [NLLanguage: Int] = [:]
        for line in wordy {
            recognizer.reset()
            recognizer.processString(line)
            guard let (language, p) = recognizer.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }) else { continue }
            total += p
            guesses[language, default: 0] += 1
        }
        let spread = guesses.count >= gibberishLanguages && 2 * (guesses.values.max() ?? 0) < wordy.count
        return spread && total / Double(wordy.count) < gibberishConfidence
    }

    // MARK: Same text for different songs

    /// FNV-1a over the comparison keys of the first sung lines (credits, notes and punctuation ignored, so two
    /// sources' copies of one text agree). nil for texts too short to tell apart.
    public static func fingerprint(_ lyrics: QTParsedLyrics) -> String? {
        let keys = lyrics.lines.filter(QTLyricsCleanup.keep).map { QTLyricsTextFolding.comparisonKey($0.text) }.filter { !$0.isEmpty }
        guard keys.count >= fingerprintMinimumLines else { return nil }
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for key in keys.prefix(fingerprintLines) {
            for b in key.utf8 {
                h ^= UInt64(b)
                h &*= 0x0000_0100_0000_01b3
            }
            h ^= 0x0a
            h &*= 0x0000_0100_0000_01b3
        }
        return String(h, radix: 16)
    }

    /// Two titles name the same song (cover, re-release, "(Live)") — so sharing lyrics is expected.
    static func isSameSong(_ a: String, _ b: String, scorer: QTLyricsMatchScorer) -> Bool {
        scorer.similarity(QTTitleCleaner.clean(a).core, QTTitleCleaner.clean(b).core) >= sameSongTitleSimilarity
    }

    /// Two artist lines name the same artist (or share one: "A & B" and "A"). Unknown artists ("") never match.
    static func isSameArtist(_ a: String, _ b: String, scorer: QTLyricsMatchScorer) -> Bool {
        let x = QTTitleCleaner.splitArtists(a), y = QTTitleCleaner.splitArtists(b)
        return x.contains { p in y.contains { scorer.similarity(p, $0) >= sameArtistSimilarity } }
    }
}
