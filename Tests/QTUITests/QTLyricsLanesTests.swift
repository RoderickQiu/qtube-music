import AppKit
import Foundation
import QTCore
import QTLyrics
import Testing
@testable import QTPlayback
@testable import QTUI

// Owner: lyrics. Pronunciation lane policy, the pinyin lane that keeps to its lyric's line count, machine-translation
// echoes, and the web engine's Song⇄Video shift.

@Suite struct QTLyricsLanesTests {
    @Test func pronunciationPrefersTheTranslation() {
        #expect(!QTLyricsPronunciation.automatic.shows(withTranslation: true))
        #expect(QTLyricsPronunciation.automatic.shows(withTranslation: false))
        #expect(QTLyricsPronunciation.on.shows(withTranslation: true))
        #expect(!QTLyricsPronunciation.off.shows(withTranslation: false))
        #expect(QTSettings().lyricsPronunciation == .automatic)
        // Old settings without the key decode to Automatic.
        let old = try? JSONDecoder().decode(QTSettings.self, from: Data("{}".utf8))
        #expect(old?.lyricsPronunciation == .automatic)
    }

    @Test func translationOnItsWayCountsAsATranslation() {
        let lanes = QTLyricsLanes(translations: ["The wind", nil], translationLanguage: "en")
        #expect(QTLyricsTranslationResolution(status: .onDevice, lanes: lanes).expectsTranslation)
        #expect(QTLyricsTranslationResolution(status: .translating, lanes: .init()).expectsTranslation)
        #expect(!QTLyricsTranslationResolution(status: .needsDownload("en"), lanes: .init()).expectsTranslation)
        #expect(!QTLyricsTranslationResolution(status: .onDevice, lanes: .init(translations: [nil, ""], translationLanguage: "en")).expectsTranslation)
    }

    @MainActor
    @Test func pinyinKeepsToItsLyricsLineCount() {
        let m = QTLyricsMetrics.make(.panel)
        let width: CGFloat = 324
        let line = QTLyricsLine(start: 1, text: "让海风吹走喧嚣腐烂的爱", romanization: "ràng hǎi fēng chuī zǒu xuān xiāo fǔ làn de ài")
        let doc = QTLyricsDocument(lines: [line], syncKind: .line, source: .lrclib, language: "zh-Hans")
        let rows = QTLyricsRowBuilder.rows(for: doc, lanes: .init(), metrics: m, width: width, includeGaps: false)
        let row = try! #require(rows.first)
        #expect(row.main?.fragments.count == 1)
        #expect(row.romanization?.fragments.count == 1)
        #expect((row.romanization?.style.size ?? 0) >= m.romanization.size * QTLyricsRowBuilder.romanizationMinimumScale - 0.01)
        // Narrower: the lane would wrap at its own size, so it is set smaller instead.
        let narrow = QTLyricsRowBuilder.rows(for: doc, lanes: .init(), metrics: m, width: 236, includeGaps: false).first
        let natural = QTLyricTextLayout(string: line.romanization!, style: m.romanization, maxWidth: 236, documentLanguage: "en")
        #expect(narrow?.main?.fragments.count == 1)
        #expect(natural.fragments.count == 2)
        #expect(narrow?.romanization?.fragments.count == 1)
        #expect((narrow?.romanization?.style.size ?? 99) < m.romanization.size)
        // A short line keeps the lane's own size.
        let short = QTLyricsLine(start: 1, text: "晴天", romanization: "qíng tiān")
        let shortRow = QTLyricsRowBuilder.rows(for: .init(lines: [short], syncKind: .line, source: .lrclib, language: "zh-Hans"),
                                               lanes: .init(), metrics: m, width: width, includeGaps: false).first
        #expect(shortRow?.romanization?.style.size == m.romanization.size)
        // Hidden lane: nothing laid out.
        var hidden = QTLyricsLanes()
        hidden.showsRomanization = false
        #expect(QTLyricsRowBuilder.rows(for: doc, lanes: hidden, metrics: m, width: width, includeGaps: false).first?.romanization == nil)
    }

    @Test func untranslatedEchoesGetNoTranslationLine() {
        let p = QTLyricsTranslationPolish.self
        #expect(p.line("Re So So Si Do Si La", source: "Re So So Si Do Si La") == "")
        #expect(p.line("re so so si do si la.", source: "Re So So Si Do Si La") == "")
        #expect(p.line("Swinging in childhood", source: "童年的荡秋千") == "Swinging in childhood")
    }

    @MainActor
    @Test func webEngineShiftsOnlyForAnotherCut() {
        #expect(QTWebPlaybackEngine.modeSwitchShift(requested: 60.02, clock: 60) == 0)
        #expect(QTWebPlaybackEngine.modeSwitchShift(requested: 101, clock: 60) == 41)
        #expect(QTWebPlaybackEngine.modeSwitchShift(requested: 19, clock: 60) == -41)
    }
}
