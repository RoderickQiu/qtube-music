import Foundation

/// Traditional → Simplified Chinese for comparison keys, from the bundled compact table (`QTHanziTable`).
public enum QTHanziConversion {
    static let map: [Character: Character] = {
        var m: [Character: Character] = [:]
        let chars = Array(QTHanziTable.traditionalToSimplifiedPairs.filter { !$0.isNewline })
        m.reserveCapacity(chars.count / 2)
        var i = 0
        while i + 1 < chars.count {
            m[chars[i]] = chars[i + 1]
            i += 2
        }
        return m
    }()

    public static func simplified(_ text: String) -> String {
        String(text.map { map[$0] ?? $0 })
    }

    /// True when more Han characters in `text` are Traditional-only forms than not (≥ 10 % of Han characters
    /// and at least two of them), used to tell zh-Hant lyrics from zh-Hans.
    public static func isMostlyTraditional(_ text: String) -> Bool {
        var han = 0, traditional = 0
        for c in text {
            guard let s = c.unicodeScalars.first, (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value) else { continue }
            han += 1
            if map[c] != nil { traditional += 1 }
        }
        return traditional >= 2 && Double(traditional) >= Double(han) * 0.1
    }
}

/// Comparison keys (HANDOFF §6): lowercase → NFKD → strip combining marks → `đ→d` → Traditional→Simplified →
/// katakana→hiragana → drop everything that is not a letter or digit. Keys are only for comparing; providers
/// always get the original spelling.
public enum QTLyricsTextFolding {
    public static func comparisonKey(_ text: String) -> String {
        let lowered = text.precomposedStringWithCompatibilityMapping.lowercased()
        let decomposed = lowered.decomposedStringWithCompatibilityMapping
        var scalars = String.UnicodeScalarView()
        for s in decomposed.unicodeScalars {
            // Kana voicing marks distinguish が from か; keep them so recomposition restores the syllable.
            if s.value == 0x3099 || s.value == 0x309A { scalars.append(s); continue }
            if s.properties.generalCategory == .nonspacingMark || s.properties.generalCategory == .enclosingMark
                || s.properties.generalCategory == .spacingMark && !isIndicVowelSign(s) {
                continue
            }
            switch s.value {
            case 0x0111: scalars.append("d")                       // đ
            case 0x00F0: scalars.append("d")                       // ð
            case 0x0142: scalars.append("l")                       // ł
            case 0x00F8: scalars.append("o")                       // ø
            case 0x00DF: scalars.append(contentsOf: "ss".unicodeScalars)
            case 0x30A1...0x30F6:                                  // katakana → hiragana
                scalars.append(Unicode.Scalar(s.value - 0x60)!)
            default:
                if s.properties.isAlphabetic || s.properties.numericType != nil { scalars.append(s) }
            }
        }
        // Recompose so Hangul syllables and Indic clusters compare as written.
        return QTHanziConversion.simplified(String(scalars).precomposedStringWithCanonicalMapping)
    }

    private static func isIndicVowelSign(_ s: Unicode.Scalar) -> Bool {
        (0x0900...0x0DFF).contains(s.value)
    }
}

/// Version markers that distinguish recordings of the same song.
public enum QTVersionTag: String, Sendable, Hashable, Codable, CaseIterable {
    case live, remix, acoustic, instrumental, cover, karaoke, speedUp, slowed, demo, piano

    static let patterns: [(QTVersionTag, [String])] = [
        (.live, ["live", "現場", "现场", "live at", "the first take", "from the first take", "concert", "演唱会", "演唱會"]),
        (.remix, ["remix", "rmx", "mix)", "dj版", "dj", "edit", "bootleg", "lofi", "lo-fi"]),
        (.acoustic, ["acoustic", "unplugged", "不插电", "不插電"]),
        (.instrumental, ["instrumental", "伴奏", "inst.", "off vocal", "karaoke version"]),
        (.cover, ["cover", "翻唱", "原唱", "翻自"]),
        (.karaoke, ["karaoke", "卡拉ok"]),
        (.speedUp, ["sped up", "speed up", "nightcore", "加速", "倍速"]),
        (.slowed, ["slowed", "reverb", "降速", "减速"]),
        (.demo, ["demo"]),
        (.piano, ["piano version", "钢琴版", "鋼琴版"]),
    ]
}

public struct QTCleanTitle: Sendable, Hashable {
    /// Title without noise and version markers, original spelling (send this to providers).
    public var core: String
    /// Extra spellings found in the title: "Hạ Phỏm (出牌)" → ["出牌"], "Arz Kiya Hai | Coke Studio" → [].
    public var alternates: [String]
    public var tags: Set<QTVersionTag>
}

/// Title cleaning (HANDOFF §6): NFKC; drop "(Official Video/MV/Lyric/Audio)", 4K, 【MV】, feat.; keep
/// Live/Remix/Acoustic… as tags (they become penalties when only one side has them).
public enum QTTitleCleaner {
    private static let noise: [String] = [
        "official music video", "official video", "official mv", "official audio", "official lyric video",
        "official lyrics video", "official visualizer", "official visualiser", "lyric video", "lyrics video",
        "music video", "lyrics", "lyric", "audio", "visualizer", "visualiser", "mv", "m/v", "pv", "4k", "hd", "hq",
        "explicit", "clean", "video", "official", "vietsub", "engsub", "中字", "高清", "完整版", "官方", "动态歌词",
        "動態歌詞", "歌词", "歌詞",
    ]

    public static func clean(_ raw: String) -> QTCleanTitle {
        var s = raw.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        var tags = Set<QTVersionTag>()
        var alternates: [String] = []

        // Bracketed segments: noise is dropped, version markers become tags, the rest are alternates.
        let pairs: [(Character, Character)] = [("(", ")"), ("[", "]"), ("【", "】"), ("「", "」"), ("（", "）"), ("《", "》"), ("〈", "〉")]
        var changed = true
        while changed {
            changed = false
            for (open, close) in pairs {
                guard let o = s.firstIndex(of: open), let c = s[o...].firstIndex(of: close), o < c else { continue }
                let inner = String(s[s.index(after: o)..<c]).trimmingCharacters(in: .whitespaces)
                s.removeSubrange(o...c)
                classify(inner, tags: &tags, alternates: &alternates, bracketed: true)
                changed = true
            }
        }
        // " - Remix", " | Coke Studio Bharat", " / From THE FIRST TAKE", "feat. X".
        for separator in [" | ", " - ", " – ", " — ", " / "] {
            if let r = s.range(of: separator) {
                let tail = String(s[r.upperBound...])
                s = String(s[..<r.lowerBound])
                classify(tail, tags: &tags, alternates: &alternates, bracketed: false)
            }
        }
        if let r = s.range(of: #"\s+(feat\.?|ft\.?|featuring|with)\s+.*$"#, options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(r)
        }
        // Bare trailing noise: "… 4K", "… MV", "… Official Video".
        while let r = s.range(of: #"\s+(4k|8k|hd|hq|mv|m/v|pv|official|video|audio|lyrics?)\s*$"#,
                              options: [.regularExpression, .caseInsensitive]), r.lowerBound > s.startIndex {
            s.removeSubrange(r)
        }
        for tag in tagsIn(s.lowercased()) where [.live, .remix, .acoustic, .instrumental, .speedUp, .slowed].contains(tag) {
            // Only whole-word markers in the bare title count ("Live" alone is a real word in many titles).
            if s.lowercased().hasSuffix(" " + tag.rawValue.lowercased()) { tags.insert(tag) }
        }
        let core = s.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "-–—|/·")))
        return QTCleanTitle(core: core.isEmpty ? raw : core, alternates: alternates, tags: tags)
    }

    private static func classify(_ segment: String, tags: inout Set<QTVersionTag>, alternates: inout [String], bracketed: Bool) {
        let lower = segment.lowercased()
        let found = tagsIn(lower)
        if !found.isEmpty {
            tags.formUnion(found)
            return
        }
        let stripped = lower.replacingOccurrences(of: #"[\s\.\-_/]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if stripped.isEmpty || noise.contains(stripped) || noise.contains(where: { stripped == $0 || stripped.hasPrefix($0 + " ") && stripped.count <= $0.count + 12 }) {
            return
        }
        if lower.hasPrefix("feat") || lower.hasPrefix("ft.") || lower.hasPrefix("with ") || lower.hasPrefix("prod") { return }
        if bracketed { alternates.append(segment) }
    }

    static func tagsIn(_ lower: String) -> Set<QTVersionTag> {
        var out = Set<QTVersionTag>()
        let words = Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        for (tag, needles) in QTVersionTag.patterns {
            for n in needles {
                let isWord = n.allSatisfy { $0.isLetter && $0.isASCII }
                if isWord ? words.contains(n) : lower.contains(n) { out.insert(tag); break }
            }
        }
        return out
    }

    /// Artist names: "Artist - Topic", "ArtistVEVO", "Artist Official" lose the suffix.
    public static func cleanArtist(_ raw: String) -> String {
        var s = raw.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespaces)
        for suffix in [" - Topic", "VEVO", " Official", " official"] where s.hasSuffix(suffix) && s.count > suffix.count {
            s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    /// Splits "A & B", "A, B", "A/B", "A x B", "A feat. B" into names.
    public static func splitArtists(_ raw: String) -> [String] {
        let parts = raw.components(separatedBy: CharacterSet(charactersIn: ",/&、，;"))
            .flatMap { $0.components(separatedBy: " x ") }
            .flatMap { $0.components(separatedBy: " feat. ") }
            .flatMap { $0.components(separatedBy: " ft. ") }
            .map { cleanArtist($0) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [raw] : parts
    }
}

/// Jaro-Winkler similarity on Characters (0…1).
public enum QTJaroWinkler {
    public static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return a.isEmpty ? 0 : 1 }
        let s = Array(a), t = Array(b)
        guard !s.isEmpty, !t.isEmpty else { return 0 }
        let window = max(0, max(s.count, t.count) / 2 - 1)
        var sMatched = [Bool](repeating: false, count: s.count)
        var tMatched = [Bool](repeating: false, count: t.count)
        var matches = 0
        for i in s.indices {
            let lo = max(0, i - window), hi = min(t.count - 1, i + window)
            guard lo <= hi else { continue }
            for j in lo...hi where !tMatched[j] && s[i] == t[j] {
                sMatched[i] = true
                tMatched[j] = true
                matches += 1
                break
            }
        }
        guard matches > 0 else { return 0 }
        var transpositions = 0, k = 0
        for i in s.indices where sMatched[i] {
            while !tMatched[k] { k += 1 }
            if s[i] != t[k] { transpositions += 1 }
            k += 1
        }
        let m = Double(matches)
        let jaro = (m / Double(s.count) + m / Double(t.count) + (m - Double(transpositions) / 2) / m) / 3
        var prefix = 0
        for (x, y) in zip(s, t).prefix(4) { if x == y { prefix += 1 } else { break } }
        return jaro + Double(prefix) * 0.1 * (1 - jaro)
    }
}
