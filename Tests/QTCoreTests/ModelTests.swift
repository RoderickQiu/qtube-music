import Foundation
import Testing
@testable import QTCore

@Suite struct ModelTests {
    @Test func trackRoundTripsThroughJSON() throws {
        var t = Fixture.track("abc")
        t.counterpart = QTCounterpart(videoId: "mv", musicVideoType: .omv, artwork: [QTArtworkImage(url: URL(string: "https://x/y.jpg")!)])
        t.palette = QTArtworkPalette(accent: QTRGBColor(hex: "#703635")!, deep: QTRGBColor(hex: "#1f070e")!)
        t.lyricsHint = .word
        let back = try JSONDecoder().decode(QTTrack.self, from: JSONEncoder().encode(t))
        #expect(back == t)
        #expect(back.hasVideo)
        #expect(back.videoArtwork.count == 1)
    }

    @Test func unknownMusicVideoTypeDecodesAsOther() throws {
        let v = try JSONDecoder().decode([QTMusicVideoType].self, from: Data(#"["MUSIC_VIDEO_TYPE_PODCAST_EPISODE","MUSIC_VIDEO_TYPE_OMV"]"#.utf8))
        #expect(v == [.other, .omv])
    }

    @Test func artworkPicksSmallestSufficientImage() {
        let imgs = [300, 60, 1200].map { QTArtworkImage(url: URL(string: "https://x/\($0)")!, width: $0, height: $0) }
        #expect(imgs.best(forPixelWidth: 100)?.width == 300)
        #expect(imgs.best(forPixelWidth: 5000)?.width == 1200)
        #expect(imgs.best(forPixelWidth: 10)?.width == 60)
    }

    @Test func colorHexAndOKLCHRoundTrip() throws {
        let c = try #require(QTRGBColor(hex: "#5386a4"))
        #expect(c.hex == "#5386a4")
        let back = QTRGBColor(oklch: c.oklch)
        #expect(abs(back.red - c.red) < 0.002 && abs(back.green - c.green) < 0.002 && abs(back.blue - c.blue) < 0.002)
        #expect(QTRGBColor(hex: "zz") == nil)
        #expect(QTRGBColor(hex: "#fff")?.hex == "#ffffff")
    }

    @Test func paletteAccentIsNormalisedForLegibility() throws {
        // A very dark artwork colour still yields a light accent on dark surfaces and a mid one on light.
        let p = QTArtworkPalette(accent: QTRGBColor(hex: "#1f070e")!, deep: QTRGBColor(hex: "#000000")!)
        #expect(abs(p.accentOnDark.oklch.lightness - 0.74) < 0.02)
        #expect(abs(p.accentOnLight.oklch.lightness - 0.56) < 0.02)
        #expect(p.accentOnDark.relativeLuminance > p.accentOnLight.relativeLuminance)
    }

    @Test func playlistTotals() {
        let p = QTPlaylist(id: "p", title: .verbatim("P"), tracks: [Fixture.track("a", duration: 100), Fixture.track("b", duration: 50)])
        #expect(p.trackCount == 2)
        #expect(p.totalDuration == 150)
    }

    @Test func displayTextCodableForms() throws {
        let both = try JSONDecoder().decode([QTDisplayText].self, from: Data(#"[{"key":"Home"},{"verbatim":"Sugar"},"plain"]"#.utf8))
        #expect(both == [.localized("Home"), .verbatim("Sugar"), .verbatim("plain")])
        let again = try JSONDecoder().decode([QTDisplayText].self, from: JSONEncoder().encode(both))
        #expect(again == both)
    }
}
