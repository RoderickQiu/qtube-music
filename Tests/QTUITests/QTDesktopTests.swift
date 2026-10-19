import AppKit
import QTCore
import Testing
@testable import QTUI

@MainActor
@Suite struct QTDesktopTests {
    private func key(_ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    @Test func playbackKeysThatCollideWithTextEditingAreRecognised() {
        #expect(QTKeyRouting.collidesWithTextEditing(key(49, " ")))
        #expect(QTKeyRouting.collidesWithTextEditing(key(124, "\u{F703}", .command)))
        #expect(QTKeyRouting.collidesWithTextEditing(key(126, "\u{F700}", .option)))
        #expect(!QTKeyRouting.collidesWithTextEditing(key(49, " ", .command)))      // ⌘Space is Spotlight's
        #expect(!QTKeyRouting.collidesWithTextEditing(key(37, "l", .command)))      // ⌘L isn't a text-editing key
        #expect(!QTKeyRouting.collidesWithTextEditing(key(124, "\u{F703}", [.command, .shift])))
    }

    @Test func desktopLyricsPanelFitsTwoLinesAndStaysOnScreen() {
        var p = QTDesktopLyricsPrefs()
        p.fontSize = 36
        p.lineCount = 2
        let two = QTDesktopLyricsPanel.panelSize(prefs: p, screenWidth: 1920)
        p.lineCount = 1
        let one = QTDesktopLyricsPanel.panelSize(prefs: p, screenWidth: 1920)
        #expect(two.height > one.height)
        #expect(two.height >= 36 * 1.3 + 20)
        #expect(two.width <= 1500 && two.width >= 720)
        #expect(QTDesktopLyricsPanel.panelSize(prefs: p, screenWidth: 800).width == 720)
    }

    @Test func menuBarTitleIsCappedAndTemplate() {
        let long = String(repeating: "Đối Với Anh Em Không Còn Cảm Giác ", count: 4)
        let image = QTMenuBarLabel.render(title: long, offset: 0)
        #expect(image.isTemplate)
        #expect(image.size.width <= QTMenuBarLabel.maxTitleWidth + 30)
        let glyphOnly = QTMenuBarLabel.render(title: nil, offset: 0)
        #expect(glyphOnly.size.width < 30)
    }

    @Test func appleIntelligenceUnavailableStatesExplainThemselves() {
        let states: [QTAppleIntelligence.Status] = [.requiresNewerMacOS, .deviceNotEligible, .notEnabled, .modelNotReady,
                                                    .languageUnsupported("vi"), .unavailable]
        for s in states { #expect(s.reason?.isEmpty == false) }
        #expect(QTAppleIntelligence.Status.available.reason == nil)
    }
}
