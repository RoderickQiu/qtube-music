import AppKit
import Foundation
import QTCore
import SwiftUI
import Testing
@testable import QTUI

@Suite struct LaunchOptionsTests {
    @Test func parsesPrototypeParameters() {
        let o = QTLaunchOptions(arguments: [
            "qt.surface": "desktop", "qt.section": "playlist:pl-1", "qt.stageLayout": "lyrics-only",
            "qt.stageBackground": "visual", "qt.theme": "light", "qt.account": "free", "qt.translation": "ko",
            "qt.track": "ne186016", "qt.time": "62.5", "qt.paused": "YES", "qt.panelTab": "queue", "qt.panelHidden": "1",
            "qt.videoMode": "true", "qt.ad": "", "qt.lang": "zh-CN", "qt.screen": "U270CA", "qt.window": "1280x800",
            "qt.show": "mini, desktopLyrics,bogus", "qt.stage.chrome": "hidden", "AppleLanguages": "(en)",
        ])
        #expect(o.surface == .mini)
        #expect(o.section == .playlist("pl-1"))
        #expect(o.stageLayout == .lyricsOnly)
        #expect(o.stageBackground == .visualizer)
        #expect(o.theme == .light)
        #expect(o.account == .free)
        #expect(o.translation == .ko)
        #expect(o.trackID == "ne186016")
        #expect(o.time == 62.5)
        #expect(o.paused == true)
        #expect(o.panelTab == .queue)
        #expect(o.panelHidden == true)
        #expect(o.videoMode == true)
        #expect(o.forceAd)
        #expect(o.language == .zhCN)
        #expect(o.effectiveScreenName == "U270CA")
        #expect(o.windowSize == CGSize(width: 1280, height: 800))
        #expect(o.extraWindows == [.mini, .desktopLyrics])
        #expect(o.string("qt.stage.chrome") == "hidden")
        #expect(o.raw["AppleLanguages"] == nil)
    }

    @Test func absentOptionsAreNil() {
        let o = QTLaunchOptions(arguments: [:])
        #expect(o.surface == nil && o.section == nil && o.paused == nil && !o.forceAd && o.extraWindows.isEmpty)
        #expect(QTSidebarItem(argument: "liked")?.argument == "liked")
        #expect(QTSidebarItem(argument: "nope") == nil)
    }
}

@Suite struct ThemeAndIconTests {
    @Test func everyIconIsARealSFSymbol() {
        for icon in QTIcon.allCases {
            #expect(NSImage(systemSymbolName: icon.systemName, accessibilityDescription: nil) != nil, "\(icon) → \(icon.systemName)")
        }
    }

    @Test func accentFallsBackToSystemAccent() {
        #expect(QTTheme.Colors.accent(nil, scheme: .dark) == QTTheme.Colors.systemAccent)
        let p = QTArtworkPalette(accent: QTRGBColor(hex: "#1791c8")!, deep: QTRGBColor(hex: "#040507")!)
        #expect(QTTheme.Colors.accent(p, scheme: .dark, increaseContrast: true) == QTTheme.Colors.systemAccent)
        #expect(QTTheme.Colors.accent(p, scheme: .dark) != QTTheme.Colors.accent(p, scheme: .light))
    }

    @Test func greetingBuckets() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ h: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: h))! }
        #expect(QTHomeView.greeting(at: at(3), calendar: cal) == QTLoc.tr("Good night"))
        #expect(QTHomeView.greeting(at: at(9), calendar: cal) == QTLoc.tr("Good morning"))
        #expect(QTHomeView.greeting(at: at(15), calendar: cal) == QTLoc.tr("Good afternoon"))
        #expect(QTHomeView.greeting(at: at(21), calendar: cal) == QTLoc.tr("Good evening"))
    }

    @Test func windowIdentifiersAreUnique() {
        #expect(Set(QTWindowID.allCases.map(\.rawValue)).count == QTWindowID.allCases.count)
        #expect(Set(QTWindowID.allCases.map(\.captureTitle)).count == QTWindowID.allCases.count)
    }
}

@MainActor
@Suite struct ArtistPlayAllTests {
    private func track(_ title: String) -> QTTrack {
        QTTrack(videoId: title, title: title, artists: [QTArtistRef(name: "司南")], album: nil, duration: 200)
    }

    @Test func backingTracksAreLeftOut() {
        let titles = ["冬眠", "冬眠 (伴奏)", "吹灭小山河（伴奏版）", "春三月 伴奏", "Karaoke", "Song (Instrumental)",
                      "Song - Inst.", "Song (Off Vocal)", "Song (Karaoke Version)", "Song (Live)", "星星在唱歌 (官方女声版)"]
        let kept = QTBrowseActions.withoutBackingTracks(titles.map(track)).map(\.title)
        #expect(kept == ["冬眠", "Karaoke", "Song (Live)", "星星在唱歌 (官方女声版)"])
    }

    @Test func aListOfOnlyBackingTracksIsKept() {
        let list = [track("A (伴奏)"), track("B (Instrumental)")]
        #expect(QTBrowseActions.withoutBackingTracks(list) == list)
    }
}
