import Foundation
import Testing
@testable import QTCore

@Suite struct LyricsDocumentTests {
    let doc = QTLyricsDocument(lines: [
        QTLyricsLine(start: 10, duration: 2, text: "a", words: [QTLyricsWord(start: 10, duration: 1, text: "a ")]),
        QTLyricsLine(start: 12, text: "b"),
        QTLyricsLine(start: 15, text: "c"),
    ], syncKind: .word, source: .lrclib)

    @Test func lineIndexBinarySearch() {
        #expect(doc.lineIndex(atPlaybackTime: 5) == nil)
        #expect(doc.lineIndex(atPlaybackTime: 10) == 0)
        #expect(doc.lineIndex(atPlaybackTime: 13.9) == 1)
        #expect(doc.lineIndex(atPlaybackTime: 999) == 2)
    }

    @Test func positiveOffsetShowsLyricsEarlier() {
        let earlier = doc.withOffset(nudgedBy: 0.1).withOffset(nudgedBy: 0.1).withOffset(nudgedBy: 0.1)
        #expect(earlier.offset == 0.3)
        #expect(earlier.lineIndex(atPlaybackTime: 11.75) == 1) // 11.75 + 0.3 ≥ 12
        #expect(doc.lineIndex(atPlaybackTime: 11.75) == 0)
        #expect(abs(earlier.playbackTime(forLine: 1) - 11.72) < 1e-9)
    }

    @Test func plainLyricsHaveNoCurrentLine() {
        var plain = doc
        plain.syncKind = .plain
        #expect(plain.lineIndex(atPlaybackTime: 13) == nil)
    }

    @Test func wordProgressAndSyncOrdering() {
        let w = QTLyricsWord(start: 10, duration: 2, text: "x")
        #expect(w.progress(at: 9) == 0)
        #expect(w.progress(at: 11) == 0.5)
        #expect(w.progress(at: 13) == 1)
        #expect(QTLyricsSyncKind.word > .line && QTLyricsSyncKind.line > .plain)
    }
}

@Suite struct SettingsTests {
    @Test func defaultsMatchTheSpec() {
        let s = QTSettings()
        #expect(s.interfaceLanguage == .automatic)
        #expect(s.lyricsTranslation == .interfaceLanguage)
        #expect(s.translateWithAppleIntelligence)
        #expect(!s.unofficialLyricsSources.anyEnabled)
        #expect(!s.preferVideos)
        #expect(s.stageLayout == .standard && s.stageBackground == .blur)
        #expect(s.theme == .automatic)
        #expect(s.closeWindowKeepsPlaying)
    }

    @Test func decodingToleratesMissingAndUnknownValues() throws {
        let s = try JSONDecoder().decode(QTSettings.self, from: Data(#"{"theme":"dark","stageBackground":"bogus","preferVideos":true}"#.utf8))
        #expect(s.theme == .dark)
        #expect(s.stageBackground == .blur)
        #expect(s.preferVideos)
        #expect(s.translateWithAppleIntelligence)
    }

    @Test func translationTargetResolution() {
        #expect(QTLyricsTranslationTarget.interfaceLanguage.resolvedLanguage(interface: .zhHans) == "zh-Hans")
        #expect(QTLyricsTranslationTarget.interfaceLanguage.resolvedLanguage(interface: .en) == "en")
        #expect(QTLyricsTranslationTarget.off.resolvedLanguage(interface: .en) == nil)
        #expect(QTLyricsTranslationTarget.ko.resolvedLanguage(interface: .zhHans) == "ko")
        #expect(QTLyricsTranslationTarget.languages.count == 9)
        #expect(QTLyricsTranslationTarget.nativeName(for: "vi") == "Tiếng Việt")
        #expect(QTLyricsTranslationTarget.isSameLanguage("zh-Hant", "zh-Hans"))
        #expect(!QTLyricsTranslationTarget.isSameLanguage("vi", "en"))
    }

    @Test func argumentParsing() {
        #expect(QTInterfaceLanguage(argument: "zh-CN") == .zhCN)
        #expect(QTInterfaceLanguage(argument: "en") == .enUS)
        #expect(QTStageBackground(argument: "visual") == .visualizer)
        #expect(QTStageBackground(argument: "visualizer") == .visualizer)
    }

    @MainActor @Test func storePersistsUpdatesButNotOverrides() throws {
        let suite = "qt.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = QTSettingsStore(defaults: defaults)
        store.update { $0.stageLayout = .artOnly }
        store.override { $0.theme = .dark }
        #expect(store.settings.theme == .dark)
        let reloaded = QTSettingsStore(defaults: defaults)
        #expect(reloaded.settings.stageLayout == .artOnly)
        #expect(reloaded.settings.theme == .automatic)
        QTLoc.setInterfaceLanguage(.enUS)
    }
}

@Suite struct MockCatalogTests {
    @Test func loadsAndResolvesTheFixtureCatalog() throws {
        let folder = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil)).appendingPathComponent("mini-catalog")
        let c = try QTMockCatalog.load(from: folder)
        #expect(c.tracks.count == 2)
        let t1 = try #require(c.track(id: "t1"))
        #expect(t1.artwork.first?.url == folder.appendingPathComponent("covers/t1.jpg"))
        #expect(t1.counterpart?.artwork.first?.url.isFileURL == true)
        #expect(t1.palette?.accent.hex == "#703635")
        #expect(c.track(id: "t2")?.musicVideoType == .other)
        #expect(c.liked.tracks?.count == 2)
        #expect(c.playlists.first?.tracks?.map(\.videoId) == ["t2"]) // unknown ids dropped
        #expect(c.home.shelves.map(\.style) == [.cards, .videos, .cards])
        #expect(c.home.shelves[0].items.count == 1)
        if case .video(let v) = c.home.shelves[1].items[0] { #expect(v.videoId == "t1") } else { Issue.record("expected video") }
        #expect(c.lyrics["t1"]?.lines.first?.words?.count == 2)
    }

    @Test func locatePrefersExplicitPathAndReportsMissing() throws {
        let folder = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil)).appendingPathComponent("mini-catalog")
        #expect(QTMockCatalog.locate(explicitPath: folder.path, bundle: Bundle(for: BundleToken.self), environment: [:], sourceFile: "/nonexistent/a/b/c/d.swift") == folder)
        #expect(QTMockCatalog.locate(explicitPath: "/nonexistent", bundle: Bundle(for: BundleToken.self), environment: [:], sourceFile: "/nonexistent/a/b/c/d.swift") == nil)
        #expect(throws: QTCatalogError.self) { try QTMockCatalog.load(from: URL(fileURLWithPath: "/nonexistent")) }
    }

    /// When the real generated catalog exists (main checkout, after make-mock-catalog.py), it must decode.
    @Test func generatedCatalogDecodesWhenPresent() throws {
        guard let url = QTMockCatalog.locate(bundle: Bundle(for: BundleToken.self), environment: [:]) else { return }
        let c = try QTMockCatalog.load(from: url)
        #expect(c.tracks.count == 12)
        #expect(c.liked.trackCount == 12)
        #expect(c.home.shelves.count == 4)
        #expect(c.tracks.contains { $0.availability == .regionLocked })
        #expect(c.lyrics.values.contains { $0.syncKind == .word && $0.hasTranslation })
    }
}

final class BundleToken {}
