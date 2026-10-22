import Foundation
import QTCore
import Testing
@testable import QTLyrics

@Suite struct LRCParserTests {
    /// NetEase sends credits as JSON lines, with or without `"t"`, in plain and in timed payloads. They become
    /// "作词: …" text, which the assembler drops as a credit (they used to show as raw JSON lyric lines).
    @Test func netEaseJSONCreditLinesAreFlattenedAndDropped() {
        let plain = """
        {"c":[{"tx":"作词: "},{"tx":"Placeholder Lyricist"}]}
        {"t":0,"c":[{"tx":"作曲: "},{"tx":"Placeholder Composer"}]}
        Paper lanterns over Harbour Street
        Counting trams until the morning
        """
        let p = QTLRCParser.parse(plain)
        #expect(p.lines.map(\.text) == ["作词: Placeholder Lyricist", "作曲: Placeholder Composer",
                                         "Paper lanterns over Harbour Street", "Counting trams until the morning"])
        let doc = QTLyricsAssembler.document(from: p, source: .netease, confidence: 1, preferredTranslationLanguage: nil)
        #expect(doc.lines.map(\.text) == ["Paper lanterns over Harbour Street", "Counting trams until the morning"])

        let timed = """
        {"t":0,"c":[{"tx":"作词: "},{"tx":"Placeholder Lyricist"}]}
        [00:01.00]{"t":1000,"c":[{"tx":"编曲: "},{"tx":"Placeholder Arranger"}]}
        [00:12.00]Paper lanterns over Harbour Street
        [00:15.00]Counting trams until the morning
        """
        let t = QTLRCParser.parse(timed)
        let timedDoc = QTLyricsAssembler.document(from: t, source: .netease, confidence: 1, preferredTranslationLanguage: nil)
        #expect(timedDoc.lines.map(\.text) == ["Paper lanterns over Harbour Street", "Counting trams until the morning"])
        #expect(!timedDoc.lines.contains { $0.text.contains("{") })
    }

    /// A lyric line that merely contains braces is left alone.
    @Test func bracedLyricIsNotACredit() {
        #expect(QTLRCParser.jsonCreditText("{not json} but sung") == nil)
        #expect(QTLRCParser.jsonCreditText(#"{"a":1}"#) == nil)
        #expect(QTLRCParser.parse("{la la la}").lines.map(\.text) == ["{la la la}"])
    }

    @Test func multipleTimestampsOffsetAndMetadata() {
        let lrc = """
        [ti:Song]
        [ar:Artist]
        [length: 03:21]
        [offset:+500]
        [00:10.00][01:10.50]Chorus line
        [00:05.00]First line
        [00:20.00]
        [00:22.00]After a break
        """
        let p = QTLRCParser.parse(lrc)
        #expect(p.metadata.title == "Song")
        #expect(p.metadata.artist == "Artist")
        #expect(p.metadata.length == 201)
        #expect(p.metadata.fileOffset == 0.5)
        let texts = p.lines.map(\.text)
        #expect(texts == ["First line", "Chorus line", "", "After a break", "Chorus line"])
        // Positive [offset:] shows lyrics earlier: every timestamp moves 0.5 s earlier.
        #expect(p.lines[0].start == 4.5)
        #expect(p.lines[1].start == 9.5)
        #expect(p.lines[4].start == 70.0)
        // A line ends where the next timestamp (even an empty one) starts.
        #expect(p.lines[1].end == 19.5)
        #expect(p.syncKind == .line)
    }

    @Test func enhancedWordTags() {
        let p = QTLRCParser.parse("[00:12.00]<00:12.00>Hello <00:12.40>big <00:12.90>world<00:13.60>\n[00:15.00]Next")
        let words = try! #require(p.lines[0].words)
        #expect(words.map(\.text) == ["Hello ", "big ", "world"])
        #expect(words[0].start == 12.0)
        #expect(abs(words[0].duration - 0.4) < 0.0001)
        #expect(abs(words[2].end - 13.6) < 0.0001)
        #expect(p.lines[0].text == "Hello big world")
        #expect(p.lines[1].words == nil)
    }

    @Test func legacyCentisecondsAndPlainText() {
        #expect(QTLRCParser.parse("[01:02:50]x").lines.first?.start == 62.5)
        let plain = QTLRCParser.parse("Line one\nLine two\n")
        #expect(plain.syncKind == .plain)
        #expect(plain.lines.map(\.text) == ["Line one", "Line two"])
        #expect(plain.lines.allSatisfy { $0.start == nil })
    }

    @Test func lrclibLeadingSpaceIsTrimmed() throws {
        let data = try #require(QTFixtures.song("perfect", "lrclib_search.json"))
        let records = try JSONDecoder().decode([QTLRCLIBProvider.Record].self, from: data)
        let p = QTLRCParser.parse(try #require(records.first?.syncedLyrics))
        #expect(p.lines.first?.text == "Well, I found a girl, beautiful and sweet")
        #expect(p.lines.first?.start == 17.69)
        #expect(p.lines.count <= 8)
    }
}

@Suite struct WordTimedParserTests {
    @Test func neteaseYRCHeroLine() throws {
        let json = try #require(QTFixtures.song("doivoianh", "netease_lyric.json"))
        let object = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        let yrc = (object["yrc"] as! [String: Any])["lyric"] as! String
        let p = QTYRCParser.parse(yrc)
        #expect(p.syncKind == .word)
        #expect(p.lines.count == 6)
        let first = p.lines[0]
        #expect(first.text == "Gió cứ rít réo rắc trong đêm")
        #expect(first.start == 35.695)
        #expect(first.words?.count == 7)
        #expect(first.words?.first?.text == "Gió ")
        #expect(first.words?.last?.text == "đêm")
        #expect(abs((first.words?.last?.end ?? 0) - 39.495) < 0.0001)
    }

    @Test func yrcSkipsJSONCreditLines() {
        let yrc = """
        {"t":0,"c":[{"tx":"作词: "},{"tx":"Someone"}]}
        [1000,2000](1000,500,0)Hi (1500,1500,0)there
        """
        let p = QTYRCParser.parse(yrc)
        #expect(p.lines.map(\.text) == ["Hi there"])
    }

    @Test func qrcFromQQFixture() throws {
        let text = try #require(QTFixtures.text("songs/yoruni/qq_plain_lyric.txt"))
        let p = QTQRCParser.parse(text)
        #expect(p.metadata.title == "夜に駆ける")
        #expect(p.syncKind == .word)
        let line = try #require(p.lines.first { $0.text == "沈むように溶けてゆくように" })
        #expect(line.start == 1.801)
        #expect(line.words?.first?.text == "沈")
        #expect(line.words?.first?.duration == 0.472)
        // The composer credit is parsed as a line; the assembler drops it.
        #expect(p.lines.contains { $0.text.hasPrefix("曲") })
    }

    @Test func qrcFallsBackToLRCForTranslationLane() throws {
        let text = try #require(QTFixtures.text("songs/yoruni/qq_plain_trans.txt"))
        let p = QTQRCParser.parse(text)
        #expect(p.syncKind == .line)
        #expect(p.lines.contains { $0.text == "像是沉溺溶化一般" })
    }

    @Test func krcRelativeWordTimesAndLanguageLanes() throws {
        let text = try #require(QTFixtures.text("songs/haphom/kugou_plain.krc"))
        let p = QTKRCParser.parse(text)
        #expect(p.metadata.title == "Hạ Phỏm")
        #expect(p.syncKind == .word)
        let first = p.lines[0]
        #expect(first.start == 20.679)
        #expect(first.text == "Nhưng em biết việc này rất là có hại")
        // KRC word offsets are relative to the line start.
        #expect(first.words?[1].start == 20.679 + 0.184)
        let translation = try #require(p.lanes.first { $0.kind == .translation })
        #expect(translation.language == "zh-Hans")
        #expect(translation.entries.first?.start == 20.679)
        #expect(translation.entries.first?.text.isEmpty == false)
    }

    @Test func krcRomajiLaneFromYOASOBI() throws {
        let text = try #require(QTFixtures.text("songs/yoruni/kugou_plain.krc"))
        let p = QTKRCParser.parse(text)
        #expect(p.lines.first?.text == "沈むように")
        #expect(p.lanes.isEmpty == false)
    }
}

@Suite struct TTMLParserTests {
    @Test func amllWordTimingTranslationAndRomanization() throws {
        let data = try #require(QTFixtures.song("yoruni", "amll.ttml"))
        let p = try #require(QTTTMLParser.parse(data))
        #expect(p.metadata.title == "夜に駆ける")
        #expect(p.metadata.artist == "YOASOBI")
        #expect(p.syncKind == .word)
        let first = p.lines[0]
        #expect(first.text == "沈むように溶けてゆくように")
        #expect(first.start == 1.737)
        #expect(first.words?.count == 13)
        #expect(first.inlineTranslations["zh-CN"] == "像是沉溺溶化一般")
        #expect(first.inlineRomanization?.hasPrefix("si zu mu") == true)
        let lane = try #require(p.lanes.first { $0.kind == .translation })
        #expect(lane.language == "zh-Hans")
        #expect(p.lines.count <= 8)
    }

    @Test func backgroundVocalsHeadTranslationsAndSpaces() throws {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" xml:lang="en">
        <head><metadata><iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal">
        <translations><translation type="replacement" xml:lang="zh-Hans"><text for="L1">你好世界</text></translation></translations>
        </iTunesMetadata></metadata></head>
        <body dur="1:00.000"><div>
        <p begin="1.000" end="3.000" itunes:key="L1"><span begin="1.000" end="1.500">Hello</span> <span begin="1.600" end="2.200">world</span><span ttm:role="x-bg"><span begin="2.300" end="2.900">(world)</span></span></p>
        <p begin="00:04.000" end="00:06.000" itunes:key="L2">Line without words</p>
        </div></body></tt>
        """
        let p = try #require(QTTTMLParser.parse(ttml))
        #expect(p.metadata.language == "en")
        #expect(p.metadata.length == nil)
        #expect(p.lines.count == 2)
        #expect(p.lines[0].text == "Hello world")
        #expect(p.lines[0].words?.map(\.text) == ["Hello ", "world"])
        #expect(p.lines[0].backgroundWords?.map(\.text) == ["(world)"])
        #expect(p.lines[0].inlineTranslations["zh-Hans"] == "你好世界")
        #expect(p.lines[1].text == "Line without words")
        #expect(p.lines[1].words == nil)
        #expect(p.lines[1].start == 4)
    }
}

@Suite struct TimeFormatTests {
    @Test func clockFormats() {
        #expect(QTLyricsTimeFormat.seconds("01:02.5") == 62.5)
        #expect(QTLyricsTimeFormat.seconds("1:00:02.5") == 3602.5)
        #expect(QTLyricsTimeFormat.seconds("12.5s") == 12.5)
        #expect(QTLyricsTimeFormat.seconds("1500ms") == 1.5)
        #expect(QTLyricsTimeFormat.seconds("4.2") == 4.2)
        #expect(QTLyricsTimeFormat.seconds("ab:cd") == nil)
        #expect("a &amp; b &#x4E2D; &lt;&quot;".qtXMLUnescaped == "a & b 中 <\"")
    }
}
