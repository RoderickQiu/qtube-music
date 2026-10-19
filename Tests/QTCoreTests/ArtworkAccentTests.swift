import Foundation
import Testing
@testable import QTCore

/// Settings › Accent colour › Song: the palette read from real artwork and the control tint made from it.
@Suite struct ArtworkAccentTests {
    /// 16 × 16 RGBA image from a per-pixel colour.
    private func image(_ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
        var out: [UInt8] = []
        for y in 0..<16 {
            for x in 0..<16 {
                let (r, g, b) = pixel(x, y)
                out += [r, g, b, 255]
            }
        }
        return out
    }

    private static let darkWindow = QTRGBColor(hex: "#1e1e1e")!
    private static let lightWindow = QTRGBColor(hex: "#ececec")!
    private static let white = QTRGBColor(hex: "#ffffff")!

    @Test func extractsTheDominantVividHue() throws {
        // Mostly a muted grey-blue background, a quarter vivid red: the cover "is red".
        let px = image { x, y in x < 8 && y < 8 ? (220, 30, 40) : (70, 76, 84) }
        let p = try #require(QTArtworkPalette.extract(rgba: px, width: 16, height: 16))
        let hue = p.accent.oklch.hue
        #expect(hue < 40 || hue > 340, "hue \(hue)")
        #expect(p.accent.oklch.chroma > 0.15)
        #expect(p.deep.oklch.lightness < 0.3)
    }

    @Test func greyscaleAndBlackArtHaveNoColour() {
        let grey = image { x, _ in let v = UInt8(x * 16); return (v, v, v) }
        #expect(QTArtworkPalette.extract(rgba: grey, width: 16, height: 16) == nil)
        let black = image { _, _ in (8, 6, 10) }
        #expect(QTArtworkPalette.extract(rgba: black, width: 16, height: 16) == nil)
        let white = image { _, _ in (250, 248, 252) }
        #expect(QTArtworkPalette.extract(rgba: white, width: 16, height: 16) == nil)
    }

    @Test func aFewColouredPixelsDontColourAGreyCover() {
        // 4 of 256 pixels (1.6%) colourful: below the vivid share, still greyscale.
        let px = image { x, y in x < 2 && y < 2 ? (0, 200, 90) : (128, 128, 128) }
        #expect(QTArtworkPalette.extract(rgba: px, width: 16, height: 16) == nil)
    }

    @Test func transparentPixelsDontVote() {
        var px = image { x, _ in x < 4 ? (40, 90, 230) : (0, 0, 0) }
        for i in stride(from: 0, to: px.count, by: 4) where (i / 4) % 16 >= 4 { px[i + 3] = 0 }
        let p = QTArtworkPalette.extract(rgba: px, width: 16, height: 16)
        let hue = p?.accent.oklch.hue ?? 0
        #expect(hue > 230 && hue < 290, "blue, hue \(hue)")
    }

    @Test func extractRejectsShortBuffers() {
        #expect(QTArtworkPalette.extract(rgba: [1, 2, 3], width: 16, height: 16) == nil)
        #expect(QTArtworkPalette.extract(rgba: [], width: 0, height: 0) == nil)
    }

    /// The control tint reads on the window and under white text, in both appearances, for every hue and for very
    /// dark, very light and very saturated artwork colours.
    @Test(arguments: ["#1f070e", "#ff0000", "#00ff00", "#0000ff", "#ffff00", "#00ffff", "#ff00ff", "#f5f0e6",
                      "#703635", "#5386a4", "#ffb000", "#7a00ff", "#00a86b"])
    func tintMeetsContrastBothWays(hex: String) throws {
        let p = QTArtworkPalette(accent: try #require(QTRGBColor(hex: hex)), deep: .init(red: 0, green: 0, blue: 0))
        #expect(p.tintOnDark.contrast(with: Self.darkWindow) >= 3, "\(hex) dark on window \(p.tintOnDark)")
        #expect(p.tintOnDark.contrast(with: Self.white) >= 3, "\(hex) white text on dark tint \(p.tintOnDark)")
        #expect(p.tintOnLight.contrast(with: Self.lightWindow) >= 3, "\(hex) light on window \(p.tintOnLight)")
        #expect(p.tintOnLight.contrast(with: Self.white) >= 4.5, "\(hex) white text on light tint \(p.tintOnLight)")
    }

    @Test func tintKeepsTheHue() throws {
        let p = QTArtworkPalette(accent: try #require(QTRGBColor(hex: "#5386a4")), deep: .init(red: 0, green: 0, blue: 0))
        let source = p.accent.oklch.hue
        #expect(abs(p.tintOnDark.oklch.hue - source) < 6)
        #expect(abs(p.tintOnLight.oklch.hue - source) < 6)
    }

    @Test func contrastRatio() throws {
        let black = try #require(QTRGBColor(hex: "#000000"))
        #expect(abs(black.contrast(with: Self.white) - 21) < 0.01)
        #expect(abs(Self.white.contrast(with: Self.white) - 1) < 0.0001)
    }

    @Test func accentSourceDefaultsToSongAndRoundTrips() throws {
        #expect(QTSettings().accentSource == .song)
        let old = try JSONDecoder().decode(QTSettings.self, from: Data(#"{"theme":"dark"}"#.utf8))
        #expect(old.accentSource == .song)
        var s = QTSettings()
        s.accentSource = .system
        let back = try JSONDecoder().decode(QTSettings.self, from: JSONEncoder().encode(s))
        #expect(back.accentSource == .system)
        let unknown = try JSONDecoder().decode(QTSettings.self, from: Data(#"{"accentSource":"rainbow"}"#.utf8))
        #expect(unknown.accentSource == .song)
    }
}
