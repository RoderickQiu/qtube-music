import AppKit
import Foundation
import QTCore
import QTPlayback
import Testing
@testable import QTUI

// Owner: builder "lyrics-ui". Layout, karaoke timing, row building and translation-lane resolution.

@Suite struct QTLyricsScriptTests {
    @Test func detectsScriptsPerLine() {
        #expect(QTLyricScript.detect("Đối Với Anh Em Không Còn Cảm Giác") == .vietnamese)
        #expect(QTLyricScript.detect("Hạ Phỏm") == .vietnamese)
        #expect(QTLyricScript.detect("Trú Mưa") == .vietnamese)
        #expect(QTLyricScript.detect("故事的小黄花") == .han)
        #expect(QTLyricScript.detect("夜に駆ける") == .japanese)
        #expect(QTLyricScript.detect("우리의 밤") == .hangul)
        #expect(QTLyricScript.detect("I found a love for me") == .latin)
        #expect(QTLyricScript.detect("") == .other)
    }

    @Test func hanFallsBackToSimplifiedChineseNotJapanese() {
        #expect(QTLyricScript.han.languageTag(documentLanguage: nil) == "zh-Hans")
        #expect(QTLyricScript.han.languageTag(documentLanguage: "zh-Hant") == "zh-Hant")
        #expect(QTLyricScript.vietnamese.languageTag(documentLanguage: "zh-Hans") == "vi")
        #expect(QTLyricScript.latin.languageTag(documentLanguage: "zh-Hans") == "en")
    }
}

@Suite struct QTLyricsLayoutTests {
    let style = QTLyricTextStyle(size: 34, weight: .bold, lineHeight: 1.22, centered: false)

    @Test func systemFontFirstAndRoomForStackedDiacritics() {
        let l = QTLyricTextLayout(string: "Đối Với Anh Em", style: style, maxWidth: 2000, documentLanguage: "vi")
        let font = l.attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.familyName?.contains("SF") == true || font?.fontName.hasPrefix(".") == true)
        #expect(l.fragments.count == 1)
        #expect(l.padding.top >= 34 * 0.3)
        #expect(l.attributed.attribute(NSAttributedString.Key(kCTLanguageAttributeName as String), at: 0, effectiveRange: nil) as? String == "vi")
    }

    @Test func balancedWrapping() {
        let text = "Khuyện tình yêu lúc trước anh đã không trân trọng"
        let l = QTLyricTextLayout(string: text, style: style, maxWidth: 520, documentLanguage: "vi")
        #expect(l.fragments.count == 2)
        #expect(l.size.width <= 520)
        let widths = l.fragments.map(\.width)
        #expect(abs(widths[0] - widths[1]) < 140, "balanced lines \(widths)")
        #expect(l.size.height == 2 * l.lineHeight)
    }

    @Test func wordSpansAreOrderedAndInsideTheLine() {
        let l = QTLyricTextLayout(string: "Bao đêm qua em", style: style, maxWidth: 2000, documentLanguage: "vi")
        let a = l.xSpans(for: NSRange(location: 0, length: 3))
        let b = l.xSpans(for: NSRange(location: 4, length: 3))
        #expect(a.count == 1 && b.count == 1)
        #expect(a[0].x0 == 0 && a[0].x1 > 0)
        #expect(b[0].x0 > a[0].x1)
        #expect(b[0].x1 <= l.size.width + 0.5)
    }

    @Test func rendersAnImageWithPadding() throws {
        let l = QTLyricTextLayout(string: "Trú Mưa", style: style, maxWidth: 2000, documentLanguage: "vi")
        let img = try #require(l.render(color: .white, scale: 2))
        #expect(CGFloat(img.width) == ceil(l.imageSize.width * 2))
        #expect(CGFloat(img.height) == ceil(l.imageSize.height * 2))
    }
}

@Suite struct QTKaraokeTests {
    @Test func frontMovesMonotonicallyAcrossWordTimings() {
        let words: [(start: Double, end: Double, spans: [(fragment: Int, x0: CGFloat, x1: CGFloat)])] = [
            (10, 10.5, [(0, 0, 40)]), (10.5, 11, [(0, 50, 90)]), (11, 12, [(0, 100, 160)]),
        ]
        let tracks = QTKaraoke.tracks(words: words, fragments: [(0, 160)], edge: 10)
        #expect(tracks.count == 1)
        let t = tracks[0]
        #expect(zip(t.fronts, t.fronts.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(zip(t.times, t.times.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(t.front(at: 9) == -10)          // nothing lit before the line
        #expect(t.front(at: 10.5) == 40)        // first word fully lit at its end
        #expect(t.front(at: 13) == 160)         // everything lit after the last word
        #expect(t.front(at: 11.5) > 100 && t.front(at: 11.5) < 160)
    }

    @Test func wrappedWordSplitsTimeByWidth() {
        let words: [(start: Double, end: Double, spans: [(fragment: Int, x0: CGFloat, x1: CGFloat)])] = [
            (0, 2, [(0, 100, 150), (1, 0, 150)]),
        ]
        let tracks = QTKaraoke.tracks(words: words, fragments: [(0, 150), (0, 150)], edge: 8)
        #expect(tracks.count == 2)
        // 50 pt on the first visual line, 150 on the second → first quarter of the time on line one.
        #expect(abs((tracks[0].times.last ?? 0) - 0.5) < 0.01)
        #expect(tracks[1].front(at: 2) == 150)
    }

    @Test func rowBuilderMapsWordsToGlyphs() {
        let line = QTLyricsLine(start: 39.759, duration: 3.675, text: "Bao đêm qua", words: [
            QTLyricsWord(start: 39.759, duration: 0.526, text: "Bao "),
            QTLyricsWord(start: 40.285, duration: 0.434, text: "đêm "),
            QTLyricsWord(start: 40.719, duration: 0.519, text: "qua"),
        ])
        let doc = QTLyricsDocument(lines: [line], syncKind: .word, source: .netease, language: "vi")
        let rows = QTLyricsRowBuilder.rows(for: doc, lanes: .init(), metrics: .make(.stage(centered: false)), width: 600, includeGaps: true)
        let row = rows.last!
        #expect(row.karaoke.count == 1)
        let track = row.karaoke[0]
        #expect(track.times.first == 39.759)
        #expect(abs((track.times.last ?? 0) - 41.238) < 0.01)
        #expect(track.front(at: 41.3) >= (row.main?.size.width ?? 0) - 0.5)
    }
}

@Suite struct QTLyricsRowTests {
    /// The translation lane is a secondary level of the hierarchy, not a fraction of the dimmed row: under an
    /// inactive line it stays close to that line's own level (r3 review: it vanished into the tinted panel).
    @Test func translationLaneStaysLegibleOnInactiveRows() {
        for style in [QTLyricsStyle.panel, .stage(centered: false), .mini, .desktop] {
            let m = QTLyricsMetrics.make(style)
            let current = m.laneOpacity(rowOpacity: 1)
            let inactive = m.inactiveOpacity * m.laneOpacity(rowOpacity: m.inactiveOpacity)
            #expect(current >= 0.6 && current < 1 || style == .desktop)
            #expect(inactive >= m.inactiveOpacity * 0.8, "inactive lane \(inactive) vs row \(m.inactiveOpacity)")
            #expect(inactive <= m.inactiveOpacity)
            let hover = m.laneOpacity(rowOpacity: m.hoverOpacity)
            #expect(hover >= current && hover <= m.laneOpacity(rowOpacity: m.inactiveOpacity))
        }
        let contrast = QTLyricsMetrics.make(.panel, increaseContrast: true)
        #expect(contrast.inactiveOpacity * contrast.laneOpacity(rowOpacity: contrast.inactiveOpacity) >= 0.45)
    }

    /// One translation-lane level on every surface (r5): the rails and the mini player dim the lane layer, the
    /// desktop overlay bakes the same level into the fill so its outline stays full.
    @Test func translationLaneLevelIsSharedAcrossSurfaces() {
        for contrast in [false, true] {
            let level = QTLyricsLaneLevel.current(increaseContrast: contrast)
            for style in [QTLyricsStyle.panel, .stage(centered: true), .mini] {
                let m = QTLyricsMetrics.make(style, increaseContrast: contrast)
                #expect(m.laneOpacity(rowOpacity: 1) == level)
                #expect(m.laneColor.alphaComponent == m.mainColor.alphaComponent)
            }
            let desktop = QTLyricsMetrics.make(.desktop, increaseContrast: contrast)
            #expect(desktop.laneOpacity(rowOpacity: 1) == 1)
            #expect(abs(Float(desktop.laneColor.alphaComponent) - level) < 0.001)
        }
    }

    func doc(_ starts: [Double], durations: [Double?]) -> QTLyricsDocument {
        QTLyricsDocument(lines: zip(starts, durations).enumerated().map { i, p in
            QTLyricsLine(start: p.0, duration: p.1, text: "Line \(i)")
        }, syncKind: .line, source: .lrclib, language: "en")
    }

    @Test func introAndInterludeGetDotsRows() {
        let d = doc([12, 15, 40], durations: [3, 2.5, 3])
        let rows = QTLyricsRowBuilder.rows(for: d, lanes: .init(), metrics: .make(.panel), width: 300, includeGaps: true)
        #expect(rows.map(\.isGap) == [true, false, false, true, false])
        // Only the intro is marked: it never takes layout space, so the first line sits at the anchor.
        #expect(rows.map(\.isIntro) == [true, false, false, false, false])
        if case .gap(let s, let e) = rows[3].kind {
            #expect(s > 17.5 && e < 40)
        }
    }

    @Test func noGapWhenLineEndsAreUnknown() {
        let d = doc([1, 4, 40], durations: [nil, nil, nil])
        let rows = QTLyricsRowBuilder.rows(for: d, lanes: .init(), metrics: .make(.panel), width: 300, includeGaps: true)
        #expect(rows.allSatisfy { !$0.isGap })
    }

    @Test func instrumentalMarkers() {
        let inst = QTLyricsDocument(lines: [QTLyricsLine(start: 0, text: "纯音乐，请欣赏")], syncKind: .line, source: .netease)
        #expect(QTLyricsRowBuilder.isInstrumental(inst))
        let empty = QTLyricsDocument(lines: [], syncKind: .line, source: .netease)
        #expect(!QTLyricsRowBuilder.isInstrumental(empty))
        #expect(!QTLyricsRowBuilder.isInstrumental(doc([1, 2], durations: [1, 1])))
    }

    @Test func clockMapsLyricTimeOntoMediaTime() {
        let tl = QTPlaybackTimeline(time: 40, rate: 1, anchorUptime: ProcessInfo.processInfo.systemUptime, duration: 300)
        let clock = QTLyricsClock(timeline: tl, offset: 0.3, stalled: false)
        let now = clock.now()
        #expect(abs(now.lyric - 40.3) < 0.05)
        #expect(abs(clock.mediaTime(forLyric: now.lyric + 2, at: now) - (now.media + 2)) < 0.0001)
        let stalled = QTLyricsClock(timeline: tl, offset: 0, stalled: true)
        #expect(stalled.rate == 0)
    }
}

@Suite @MainActor struct QTLyricsTranslationTests {
    let center = QTLyricsTranslationCenter(launch: QTLaunchOptions(arguments: [:]))
    let vi = QTLyricsDocument(lines: [QTLyricsLine(start: 1, text: "Bao đêm qua", translation: "多少个夜晚我还是这样哽咽")],
                              syncKind: .line, source: .netease, language: "vi", translationLanguage: "zh-Hans")

    @Test func providerLaneWhenItMatches() {
        let r = center.resolve(vi, target: "zh-Hans")
        #expect(r.status == .provider("NetEase"))
        #expect(r.lanes.translations == ["多少个夜晚我还是这样哽咽"])
    }

    @Test func simplifiedLaneConvertedForTraditional() {
        let r = center.resolve(vi, target: "zh-Hant")
        #expect(r.lanes.translations?.first??.contains("這樣") == true)
    }

    @Test func offAndSameLanguage() {
        #expect(center.resolve(vi, target: nil).status == .off)
        #expect(center.resolve(vi, target: "vi").status == .sameLanguage("vi"))
        let zh = QTLyricsDocument(lines: [QTLyricsLine(start: 1, text: "故事的小黄花")], syncKind: .line, source: .netease)
        #expect(center.resolve(zh, target: "zh-Hant").status == .sameLanguage("zh-Hant"))
        #expect(center.resolve(nil, target: "en").status == .noLyrics)
    }

    @Test func otherTargetsGoOnDevice() {
        let r = center.resolve(vi, target: "ko")
        #expect(r.machineKey?.source == "vi" && r.machineKey?.target == "ko")
        #expect(r.status == .translating)
        #expect(r.lanes.translations == nil)
    }

    @Test func forcedStatusForScreenshots() {
        let forced = QTLyricsTranslationCenter(launch: QTLaunchOptions(arguments: ["qt.lyrics.translationState": "download"]))
        #expect(forced.resolve(vi, target: "ko").status == .needsDownload("ko"))
    }

    /// Every surface reads `QTResolvedLyrics`: a provider lane in another language never shows up as "the translation".
    @Test func resolvedLyricsNeverLeakTheProviderLaneIntoAnotherTarget() {
        let english = QTResolvedLyrics(document: vi, resolution: center.resolve(vi, target: "en"))
        #expect(english.currentLine(atPlaybackTime: 2)?.line.text == "Bao đêm qua")
        #expect(english.currentLine(atPlaybackTime: 2)?.translation == nil)
        #expect(english.translation(forLine: 0) == nil)
        let chinese = QTResolvedLyrics(document: vi, resolution: center.resolve(vi, target: "zh-Hans"))
        #expect(chinese.currentLine(atPlaybackTime: 2)?.translation == "多少个夜晚我还是这样哽咽")
        let off = QTResolvedLyrics(document: vi, resolution: center.resolve(vi, target: nil))
        #expect(off.translation(forLine: 0) == nil)
    }

    @Test func resolvedLyricsInstrumentalBeforeTheFirstLine() {
        let r = QTResolvedLyrics(document: vi, resolution: center.resolve(vi, target: nil))
        #expect(r.isInstrumental(atPlaybackTime: 0.5))
        #expect(!r.isInstrumental(atPlaybackTime: 1.5))
        #expect(!QTResolvedLyrics.none.isInstrumental(atPlaybackTime: 0))
    }
}

@Suite @MainActor struct QTLyricsVersionTests {
    @Test func othersExcludeTheShownVersionAndPinsNotify() {
        let store = QTLyricsVersionStore()
        let a = QTLyricsVersion(id: "netease", source: .netease, syncKind: .word)
        let b = QTLyricsVersion(id: "lrclib", source: .lrclib, syncKind: .line)
        store.publish([a, b], for: "v1", selected: "netease")
        #expect(store.others(for: "v1") == [b])
        var pinned: String?
        store.onPin = { _, v in pinned = v.id }
        store.pin(b, for: "v1")
        #expect(pinned == "lrclib")
        #expect(store.others(for: "v1") == [a])
        // A report moves the version to the end of the menu as reported, at once, and reaches the lyrics session
        // (which keeps it).
        var reported: String?
        store.onReport = { _, id in reported = id; return true }
        #expect(store.canReport("v1"))
        #expect(store.reportWrong("v1") == "lrclib")
        #expect(reported == "lrclib")
        #expect(store.versions["v1"]?.map(\.id) == ["netease", "lrclib"])
        #expect(store.versions["v1"]?.last?.isReported == true)
        #expect(store.choice(for: "v1") == .automatic)
        // Nothing showing: nothing to report, and no "Reported" toast (finding 23).
        #expect(!store.canReport("v1"))
        #expect(store.reportWrong("v1") == nil)
        // Undo marks it back and reaches the session.
        var undone: String?
        store.onUndoReport = { _, id in undone = id }
        store.undoReport("lrclib", for: "v1")
        #expect(undone == "lrclib")
        #expect(store.versions["v1"]?.last?.isReported == false)
        // A session that can't act on it reports nothing.
        store.publish([a, b], for: "v2", selected: "netease")
        store.onReport = { _, _ in false }
        #expect(store.reportWrong("v2") == nil)
        #expect(store.versions["v2"] == [a, b])
        // Publishing with nothing showing clears the old selection.
        store.publish([a, b], for: "v2", selected: nil)
        #expect(!store.canReport("v2"))
    }

    @Test func reportedRowsSayReported() {
        let v = QTLyricsVersion(id: "lrclib:1", source: .lrclib, syncKind: .line, confidence: 0.95, isPossibleMismatch: true,
                                isReported: true)
        #expect(v.menuDetail(isBest: true) == QTLoc.tr("Reported"))
    }

    @Test func choicesNotifyTheSession() {
        let store = QTLyricsVersionStore()
        var events: [String] = []
        store.onLyricsOff = { events.append("off:" + $0) }
        store.onUnpin = { events.append("auto:" + $0) }
        store.turnOffLyrics("v1")
        #expect(store.choice(for: "v1") == .off)
        store.unpin("v1")
        #expect(store.choice(for: "v1") == .automatic)
        store.setChoice(.version("lrclib"), for: "v1")
        #expect(store.choice(for: "v1") == .version("lrclib"))
        #expect(events == ["off:v1", "auto:v1"])
    }

    /// Menu rows read plainly: source and timing, then "Best match" / "Possible mismatch" and a noticeable length
    /// difference — never a raw score.
    @Test func menuLabelsWithDurationDelta() {
        let sep = " · "
        let best = QTLoc.tr("Best match", table: .lyrics), mismatch = QTLoc.tr("Possible mismatch", table: .lyrics)
        let lrclib = QTLyricsVersion(id: "lrclib:1", source: .lrclib, syncKind: .line, confidence: 0.86, durationDelta: 3.2)
        #expect(lrclib.menuTitle == QTLoc.tr("LRCLIB") + sep + QTLoc.tr("Line timing"))
        #expect(lrclib.menuDetail(isBest: true) == best + sep + QTLoc.tr("%lld s longer", table: .lyrics, 3))
        #expect(lrclib.menuDetail(isBest: false) == QTLoc.tr("%lld s longer", table: .lyrics, 3))
        let shorter = QTLyricsVersion(id: "netease:1", source: .netease, syncKind: .word, translationLanguage: "zh-Hans",
                                      confidence: 0.7, durationDelta: -12)
        #expect(shorter.menuTitle == QTLoc.tr("NetEase") + sep + QTLoc.tr("Word timing") + sep + "简体中文")
        #expect(shorter.menuDetail(isBest: true) == mismatch + sep + QTLoc.tr("%lld s shorter", table: .lyrics, 12))
        // Within ±2 s the timing lines up: not worth a mention.
        let same = QTLyricsVersion(id: "kugou:1", source: .kugou, syncKind: .word, confidence: 0.95, durationDelta: 1.4)
        #expect(same.menuDetail(isBest: false) == nil)
        // A failed sanity check is a mismatch whatever the score.
        let flagged = QTLyricsVersion(id: "amll:1", source: .amll, syncKind: .word, confidence: 0.95, isPossibleMismatch: true)
        #expect(flagged.menuDetail(isBest: true) == mismatch)
        // Both languages read plainly.
        let en = QTLocalizer(preference: .enUS), zh = QTLocalizer(preference: .zhCN)
        #expect(en.format("%lld s longer", table: .lyrics, arguments: [3]) == "3 s longer")
        #expect(zh.format("%lld s longer", table: .lyrics, arguments: [3]) == "长 3 秒")
        #expect(zh.string("No Lyrics for This Song", table: .lyrics) == "此歌曲不显示歌词")
    }
}
