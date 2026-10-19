import Foundation
import QTCore
import QTLyrics
import Testing
@testable import QTUI

// Owner: lyrics-translate (M6). Engine order and fallbacks as the lyrics surfaces see them, through
// `QTLyricsTranslationCenter` with scripted engines (no Apple Intelligence / Translation framework needed).

/// A scripted engine.
struct QTScriptedTranslationEngine: QTLyricsTranslationEngine {
    enum Behaviour: Sendable { case translate, refuse, dropLine }
    let kind: QTLyricsTranslationEngineKind
    var state: QTLyricsTranslationAvailability = .available
    var behaviour: Behaviour = .translate
    var translatesDirectly = true

    func availability(from source: String?, to target: String) async -> QTLyricsTranslationAvailability { state }

    func translate(_ lines: [String], context: QTLyricsTranslationContext) async throws -> [String] {
        switch behaviour {
        case .translate: return lines.map { $0.isEmpty ? "" : "\(kind == .appleIntelligence ? "AI" : "TF")[\(context.targetLanguage)] \($0)" }
        case .refuse: throw QTLyricsTranslationError.refused
        case .dropLine: return Array(lines.dropLast())
        }
    }
}

@Suite @MainActor struct QTLyricsTranslationEngineTests {
    let vi = QTLyricsDocument(lines: [QTLyricsLine(start: 1, text: "Gió cứ rít réo rắc trong đêm"),
                                      QTLyricsLine(start: 4, text: "♪"),
                                      QTLyricsLine(start: 7, text: "Bao đêm qua em vẫn thế")],
                              syncKind: .line, source: .youtubeMusic, language: "vi")

    func center(ai: QTScriptedTranslationEngine? = .init(kind: .appleIntelligence),
                tf: QTScriptedTranslationEngine? = .init(kind: .translationFramework),
                cache: QTLyricsCache? = nil, allowsAI: Bool = true) -> QTLyricsTranslationCenter {
        let engines: [any QTLyricsTranslationEngine] = [ai, tf].compactMap { $0 }
        let c = QTLyricsTranslationCenter(launch: QTLaunchOptions(arguments: [:]),
                                          coordinator: QTLyricsTranslationCoordinator(engines: engines, cache: cache))
        let settings = QTSettingsStore(defaults: UserDefaults(suiteName: "qt.lyrics-translate.tests.\(UUID().uuidString)")!)
        settings.override { $0.translateWithAppleIntelligence = allowsAI }
        c.settings = settings
        return c
    }

    func translate(_ c: QTLyricsTranslationCenter, to target: String) async -> QTLyricsTranslationResolution {
        let key = try! #require(c.resolve(vi, target: target).machineKey)
        await c.prepareAndWait(key, document: vi, title: "Đối Với Anh Em Không Còn Cảm Giác", artist: "Kim Ny Ngọc")
        return c.resolve(vi, target: target)
    }

    @Test func appleIntelligenceFirstWhenOnAndAvailable() async {
        let r = await translate(center(), to: "en")
        #expect(r.status == .appleIntelligence)
        #expect(r.lanes.translations == ["AI[en] Gió cứ rít réo rắc trong đêm", nil, "AI[en] Bao đêm qua em vẫn thế"])
        #expect(r.lanes.translationLanguage == "en")
    }

    @Test func refusalOrMisalignmentFallsBackToTheTranslationFrameworkForTheWholeSong() async {
        for behaviour in [QTScriptedTranslationEngine.Behaviour.refuse, .dropLine] {
            let r = await translate(center(ai: .init(kind: .appleIntelligence, behaviour: behaviour)), to: "ko")
            #expect(r.status == .onDevice)
            #expect(r.lanes.translations?.compactMap { $0 }.allSatisfy { $0.hasPrefix("TF[ko]") } == true)
        }
    }

    @Test func toggleOffOrModelUnavailableUsesTheTranslationFramework() async {
        let off = await translate(center(allowsAI: false), to: "en")
        #expect(off.status == .onDevice)
        let notReady = await translate(center(ai: .init(kind: .appleIntelligence, state: .unavailable(reason: "modelNotReady"))), to: "en")
        #expect(notReady.status == .onDevice)
        #expect(notReady.lanes.translations?.first == "TF[en] Gió cứ rít réo rắc trong đêm")
    }

    @Test func missingLanguageModelWaitsForConsent() async {
        let c = center(ai: nil, tf: .init(kind: .translationFramework, state: .needsDownload))
        let r = await translate(c, to: "ko")
        #expect(r.status == .needsDownload("ko"))
        #expect(r.lanes.translations == nil)
        // Nothing is prepared for a hosted session until the user clicks Download.
        #expect(c.configuration(for: r.machineKey) == nil)
        c.requestDownload(r.machineKey!)
        #expect(c.configuration(for: r.machineKey) != nil)
    }

    @Test func hostedSessionBeforeMacOS26() async {
        let c = center(ai: nil, tf: .init(kind: .translationFramework, translatesDirectly: false))
        let r = await translate(c, to: "en")
        #expect(r.status == .translating)
        #expect(c.configuration(for: r.machineKey) != nil)
    }

    @Test func nothingCanTranslate() async {
        let r = await translate(center(ai: .init(kind: .appleIntelligence, behaviour: .refuse),
                                       tf: .init(kind: .translationFramework, state: .unavailable(reason: "unsupportedPair"))), to: "en")
        #expect(r.status == .unavailable)
        #expect(r.lanes.translations == nil)
    }

    @Test func cachedTranslationsAreReusedAcrossLaunches() async throws {
        let cache = try QTLyricsCache(url: nil)
        _ = await translate(center(cache: cache), to: "ko")
        // Next launch: Apple Intelligence not ready yet, yet the song's translation is there at once.
        let later = center(ai: .init(kind: .appleIntelligence, state: .unavailable(reason: "modelNotReady")),
                           tf: .init(kind: .translationFramework, state: .needsDownload), cache: cache)
        let r = await translate(later, to: "ko")
        #expect(r.status == .appleIntelligence)
        #expect(r.lanes.translations?.first == "AI[ko] Gió cứ rít réo rắc trong đêm")
    }

    @Test func chineseSongWithChineseTargetIsNotTranslated() {
        let zh = QTLyricsDocument(lines: [QTLyricsLine(start: 1, text: "故事的小黄花")], syncKind: .line, source: .lrclib, language: "zh-Hans")
        let r = center().resolve(zh, target: "zh-Hans")
        #expect(r.status == .sameLanguage("zh-Hans"))
        #expect(r.machineKey == nil)
        #expect(r.lanes.translations == nil)
    }

    /// Traditional lyrics with a 简体中文 target are shown converted: "Shown in 简体中文", no translation line.
    @Test func traditionalSongWithSimplifiedTargetSaysShownIn() {
        let zh = QTLyricsDocument(lines: [QTLyricsLine(start: 1, text: "愛情你比我想的閣較偉大"), QTLyricsLine(start: 5, text: "你是我的未來")],
                                  syncKind: .line, source: .youtubeMusic, language: "zh-Hant")
        let shown = QTLyricsTranslationPolicy.applyProviderLane(to: zh, target: "zh-Hans")
        #expect(shown.lines[0].text == "爱情你比我想的阁较伟大")
        let r = center().resolve(shown, target: "zh-Hans")
        #expect(r.status == .convertedScript("zh-Hans"))
        #expect(r.machineKey == nil)
        #expect(r.lanes.translations == nil)
        // As written (the target's own script): still "Song is already in 繁體中文".
        #expect(center().resolve(QTLyricsTranslationPolicy.applyProviderLane(to: zh, target: "zh-Hant"), target: "zh-Hant").status
            == .sameLanguage("zh-Hant"))
    }

    @Test func fingerprintIsStableAndContentBased() {
        #expect(QTLyricsTranslationCenter.fingerprint(vi) == QTLyricsTranslationCenter.fingerprint(vi))
        var other = vi
        other.lines[0].text = "Gió"
        #expect(QTLyricsTranslationCenter.fingerprint(other) != QTLyricsTranslationCenter.fingerprint(vi))
    }

    @Test func automaticUnpinsTheChosenVersion() {
        let store = QTLyricsVersionStore()
        let b = QTLyricsVersion(id: "lrclib", source: .lrclib, syncKind: .line)
        store.pin(b, for: "v1")
        #expect(store.pinned["v1"] == "lrclib")
        store.unpin("v1")
        #expect(store.pinned["v1"] == nil)
    }
}
