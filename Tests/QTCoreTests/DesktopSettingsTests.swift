import Foundation
import Testing
@testable import QTCore

@Suite struct DesktopSettingsTests {
    @Test func oldSettingsWithoutDesktopFieldsStillDecode() throws {
        // A v1 blob from before the desktop fields existed: desktopLyrics lacks isLocked/fontDesign/horizontalOffset.
        let json = #"{"theme":"dark","desktopLyrics":{"isShown":true,"fontSize":44,"showsTranslation":true,"lineCount":1,"verticalPosition":0.3}}"#
        let s = try JSONDecoder().decode(QTSettings.self, from: Data(json.utf8))
        #expect(s.theme == .dark)
        #expect(s.desktopLyrics.isShown)
        #expect(s.desktopLyrics.fontSize == 44)
        #expect(s.desktopLyrics.lineCount == 1)
        #expect(s.desktopLyrics.isLocked)
        #expect(s.desktopLyrics.fontDesign == .standard)
        #expect(s.miniPlayer.mode == .compact)
        #expect(!s.menuBarScrollsTitle)
        #expect(s.playbackEffects.gapless)
    }

    @Test func desktopFieldsRoundTrip() throws {
        var s = QTSettings()
        s.miniPlayer.mode = .art
        s.miniPlayer.showsLyricLine = true
        s.desktopLyrics.isLocked = false
        s.desktopLyrics.fontDesign = .rounded
        s.desktopLyrics.horizontalOffset = -0.2
        s.menuBarScrollsTitle = true
        s.playbackEffects.crossfadeSeconds = 6
        s.playbackEffects.equalizer = .vocalBooster
        let back = try JSONDecoder().decode(QTSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    @Test func unknownEnumValuesFallBackToDefaults() throws {
        let json = #"{"miniPlayer":{"mode":"hologram"},"playbackEffects":{"equalizer":"wobble","crossfadeSeconds":3}}"#
        let s = try JSONDecoder().decode(QTSettings.self, from: Data(json.utf8))
        #expect(s.miniPlayer.mode == .compact)
        #expect(s.playbackEffects.equalizer == .off)
        #expect(s.playbackEffects.crossfadeSeconds == 3)
    }
}
