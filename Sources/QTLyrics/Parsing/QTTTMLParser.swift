import Foundation
import QTCore

/// Apple Music / AMLL TTML: `<p begin end>` lines with `<span begin end>` words, background vocals
/// (`ttm:role="x-bg"`), inline translations (`ttm:role="x-translation" xml:lang`), inline romanization
/// (`ttm:role="x-roman"`), Apple's head `<iTunesMetadata><translations>/<transliterations>` keyed by
/// `itunes:key`, and AMLL `<amll:meta key value>` metadata.
public enum QTTTMLParser {
    public static func parse(_ text: String) -> QTParsedLyrics? {
        guard let data = text.data(using: .utf8) else { return nil }
        return parse(data)
    }

    public static func parse(_ data: Data) -> QTParsedLyrics? {
        let delegate = QTTTMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse() || !delegate.lines.isEmpty else { return nil }
        return delegate.result()
    }
}

private final class QTTTMLParserDelegate: NSObject, XMLParserDelegate {
    struct LineBuilder {
        var begin: TimeInterval?
        var end: TimeInterval?
        var key: String?
        var words: [QTLyricsWord] = []
        var background: [QTLyricsWord] = []
        var looseText = ""
        var translations: [String: String] = [:]
        var romanization: String?
    }

    struct SpanFrame {
        var role: String?
        var begin: TimeInterval?
        var end: TimeInterval?
        var lang: String?
        var text = ""
    }

    var lines: [(LineBuilder)] = []
    private var metadata = QTParsedLyricsMetadata()
    private var current: LineBuilder?
    private var spans: [SpanFrame] = []

    // Head translations: language → key → text.
    private var headTranslations: [String: [String: String]] = [:]
    private var headRomanizations: [String: [String: String]] = [:]
    private var headSection: QTLyricsLane.Kind?
    private var headLanguage: String?
    private var headTextKey: String?
    private var headText = ""

    func result() -> QTParsedLyrics {
        var out: [QTParsedLyricsLine] = []
        for b in lines {
            var words = b.words
            if var last = words.popLast() {
                while last.text.last?.isWhitespace == true { last.text.removeLast() }
                words.append(last)
            }
            var bg = b.background
            if var last = bg.popLast() {
                while last.text.last?.isWhitespace == true { last.text.removeLast() }
                bg.append(last)
            }
            let text = words.isEmpty ? b.looseText.qtCollapsedWhitespace : words.map(\.text).joined().qtCollapsedWhitespace
            var translations = b.translations
            var roman = b.romanization
            if let key = b.key {
                for (lang, table) in headTranslations { if let t = table[key], translations[lang] == nil { translations[lang] = t } }
                if roman == nil { roman = headRomanizations.values.compactMap { $0[key] }.first }
            }
            guard !text.isEmpty || !bg.isEmpty else { continue }
            out.append(QTParsedLyricsLine(start: b.begin ?? words.first?.start, end: b.end ?? words.last?.end, text: text,
                                          words: words.isEmpty ? nil : words, backgroundWords: bg.isEmpty ? nil : bg,
                                          inlineTranslations: translations, inlineRomanization: roman))
        }
        // Lanes mirror the inline spans so the assembler treats every format the same way.
        var lanes: [QTLyricsLane] = []
        let languages = Set(out.flatMap { $0.inlineTranslations.keys })
        for lang in languages.sorted() {
            lanes.append(QTLyricsLane(kind: .translation, language: lang.isEmpty ? nil : QTLanguageCode.normalize(lang),
                                      entries: out.map { .init(start: $0.start, text: $0.inlineTranslations[lang] ?? "") },
                                      isIndexAligned: true))
        }
        if out.contains(where: { $0.inlineRomanization?.isEmpty == false }) {
            lanes.append(QTLyricsLane(kind: .romanization, language: nil,
                                      entries: out.map { .init(start: $0.start, text: $0.inlineRomanization ?? "") },
                                      isIndexAligned: true))
        }
        return QTParsedLyrics(lines: out, metadata: metadata, lanes: lanes)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes a: [String: String] = [:]) {
        switch name {
        case "tt":
            if let lang = a["xml:lang"], !lang.isEmpty { metadata.language = QTLanguageCode.normalize(lang) }
        case "body":
            // `body@dur` is where the lyrics end, not the track length — never used for matching.
            break
        case "amll:meta":
            switch a["key"] {
            case "musicName": metadata.title = metadata.title ?? a["value"]
            case "artists": metadata.artist = metadata.artist.map { $0 + ", " + (a["value"] ?? "") } ?? a["value"]
            case "album": metadata.album = metadata.album ?? a["value"]
            default: break
            }
        case "translations": headSection = .translation
        case "transliterations": headSection = .romanization
        case "translation", "transliteration": headLanguage = a["xml:lang"] ?? ""
        case "text" where headSection != nil && current == nil:
            headTextKey = a["for"]
            headText = ""
        case "p":
            current = LineBuilder(begin: a["begin"].flatMap { QTLyricsTimeFormat.seconds($0) },
                                  end: a["end"].flatMap { QTLyricsTimeFormat.seconds($0) },
                                  key: a["itunes:key"])
            spans = []
        case "span" where current != nil:
            spans.append(SpanFrame(role: a["ttm:role"], begin: a["begin"].flatMap { QTLyricsTimeFormat.seconds($0) },
                                   end: a["end"].flatMap { QTLyricsTimeFormat.seconds($0) }, lang: a["xml:lang"]))
        case "br" where current != nil:
            appendText(" ")
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if current != nil {
            appendText(string)
        } else if headTextKey != nil {
            headText += string
        }
    }

    private var inBackground: Bool { spans.contains { $0.role == "x-bg" } }

    private func appendText(_ string: String) {
        guard current != nil else { return }
        if let i = spans.lastIndex(where: { $0.role != "x-bg" }), i == spans.count - 1 {
            spans[i].text += string
            return
        }
        // Text directly inside <p> or an x-bg span: whitespace joins words; anything else is loose text.
        if string.allSatisfy(\.isWhitespace) {
            if inBackground {
                if !current!.background.isEmpty { current!.background[current!.background.count - 1].text += " " }
            } else if !current!.words.isEmpty {
                if current!.words[current!.words.count - 1].text.last?.isWhitespace != true {
                    current!.words[current!.words.count - 1].text += " "
                }
            } else {
                current!.looseText += string
            }
        } else if !inBackground {
            current!.looseText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "span" where current != nil && !spans.isEmpty:
            let frame = spans.removeLast()
            switch frame.role {
            case "x-translation":
                current!.translations[frame.lang ?? ""] = frame.text.qtCollapsedWhitespace
            case "x-roman":
                current!.romanization = frame.text.qtCollapsedWhitespace
            case "x-bg":
                break
            default:
                let text = frame.text.replacingOccurrences(of: "\n", with: " ")
                guard !text.isEmpty else { break }
                if let b = frame.begin {
                    let word = QTLyricsWord(start: b, duration: max(0, (frame.end ?? b) - b), text: text)
                    if inBackground { current!.background.append(word) } else { current!.words.append(word) }
                } else if inBackground {
                    if !current!.background.isEmpty { current!.background[current!.background.count - 1].text += text }
                } else if let i = spans.indices.last, spans[i].role == nil {
                    spans[i].text += text
                } else {
                    current!.looseText += text
                }
            }
        case "p":
            if let c = current { lines.append(c) }
            current = nil
            spans = []
        case "text" where headTextKey != nil:
            let lang = QTLanguageCode.normalize(headLanguage ?? "")
            let value = headText.qtCollapsedWhitespace
            if headSection == .romanization {
                headRomanizations[lang, default: [:]][headTextKey!] = value
            } else {
                headTranslations[lang, default: [:]][headTextKey!] = value
            }
            headTextKey = nil
        case "translations", "transliterations": headSection = nil
        default: break
        }
    }
}

extension String {
    /// Whitespace runs collapsed to one space, trimmed.
    var qtCollapsedWhitespace: String {
        split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
