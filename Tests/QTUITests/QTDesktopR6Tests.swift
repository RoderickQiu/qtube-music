import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QTUI

/// Desktop area, R6 release-candidate fixes: desktop lyrics legible on any wallpaper, the mini player panel sized
/// and placed on screen, launch-argument checks in the screenshot scripts.
@MainActor
@Suite struct QTDesktopR6Tests {
    // MARK: Desktop lyrics legibility

    @Test func onlyTheDesktopOverlayGetsTheGlowAndUnderlay() throws {
        for style in [QTLyricsStyle.panel, .stage(centered: true), .mini] {
            let m = QTLyricsMetrics.make(style)
            #expect(m.glow == nil && m.glyphUnderlay == nil)
        }
        let desktop = QTLyricsMetrics.make(.desktop)
        let glow = try #require(desktop.glow)
        #expect(glow.radius >= desktop.main.size * 0.4)
        #expect(desktop.glyphUnderlay != nil)
        // The text image has room for the whole cloud.
        #expect(desktop.shadowRoom >= glow.radius + glow.spread)
        // Increase Contrast makes the cloud denser.
        let strong = try #require(QTLyricsMetrics.make(.desktop, increaseContrast: true).glow)
        #expect(strong.color.alphaComponent > glow.color.alphaComponent)
    }

    /// The glow darkens the area around the words (a pixel above the line box is no longer transparent) and the
    /// underlay makes the inside of the glyphs dark, so a translucent unsung fill reads as grey on white.
    @Test func glowAndUnderlayDarkenAroundAndInsideTheGlyphs() throws {
        let m = QTLyricsMetrics.make(.desktop)
        let layout = QTLyricTextLayout(string: "Em ngày xưa", style: m.main, maxWidth: 2000, documentLanguage: "vi",
                                       shadowRoom: m.shadowRoom)
        let plain = try #require(layout.render(color: .clear, scale: 1, shadow: m.shadow, outline: m.outline))
        let lit = try #require(layout.render(color: .clear, scale: 1, shadow: m.shadow, outline: m.outline,
                                             glow: m.glow, underlay: m.glyphUnderlay))
        // A point in the padding just above the middle of the text box (clear of the accents).
        let above = CGPoint(x: layout.padding.left + layout.size.width / 2, y: layout.padding.top - 3)
        #expect(alpha(plain, at: above) == 0)
        #expect(alpha(lit, at: above) > 0.05)
    }

    @Test func desktopLyricsPanelLeavesRoomForTheGlow() throws {
        for size in [20.0, 36, 72] {
            let m = QTLyricsMetrics.make(.desktop, desktopFontSize: size)
            let glow = try #require(m.glow)
            #expect(QTDesktopLyricsView.verticalPadding(fontSize: size) >= glow.radius)
        }
    }

    private func alpha(_ image: CGImage, at p: CGPoint) -> CGFloat {
        let rep = NSBitmapImageRep(cgImage: image)
        // Image coordinates are top-left in NSBitmapImageRep.colorAt.
        return rep.colorAt(x: Int(p.x), y: Int(p.y))?.alphaComponent ?? 0
    }

    // MARK: Mini player panel

    /// The compact strip's window is exactly the strip: the hosting view isn't the window's content view, so
    /// SwiftUI doesn't add the hidden title bar's height and grow the panel past the bottom of the screen.
    @Test func compactMiniPlayerPanelStaysStripSized() throws {
        let panel = QTMiniPlayerPanel(content: Color.clear.frame(height: QTMiniPlayerPanel.compactHeight),
                                      mode: .compact)
        let content = try #require(panel.contentView)
        #expect(!String(describing: type(of: content)).contains("Hosting"))
        let screen = try #require(NSScreen.screens.first)
        panel.restoreFrame(on: screen, mode: .compact)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.layoutIfNeeded()
        #expect(panel.frame.height == QTMiniPlayerPanel.compactHeight)
        #expect(screen.visibleFrame.contains(panel.frame))
    }

    // MARK: Scripts

    /// `Scripts/lib.sh` `qt_launch_args`: one-string arguments are split, malformed ones fail at once (exit 2).
    @Test func screenshotScriptsCheckLaunchArguments() throws {
        func run(_ args: [String]) throws -> (status: Int32, out: String) {
            let lib = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Scripts/lib.sh").path
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", "source \"$0\" >/dev/null 2>&1; qt_launch_args \"$@\" 2>/dev/null || exit $?; printf '%s|' \"${QT_ARGS[@]}\"",
                           lib] + args
            let pipe = Pipe()
            p.standardOutput = pipe
            try p.run()
            p.waitUntilExit()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return (p.terminationStatus, out)
        }
        let ok = try run(["-qt.surface", "stage", "-qt.paused", "YES"])
        #expect(ok.status == 0 && ok.out == "-qt.surface|stage|-qt.paused|YES|")
        let split = try run(["-qt.surface stage -qt.paused YES"])
        #expect(split.status == 0 && split.out == "-qt.surface|stage|-qt.paused|YES|")
        let spaced = try run(["-qt.live.open", "album:Some Title"])
        #expect(spaced.status == 0 && spaced.out == "-qt.live.open|album:Some Title|")
        #expect(try run(["-qt.surface"]).status == 2)
        #expect(try run(["-qt.surface", "-qt.time", "40"]).status == 2)
        #expect(try run(["qt.surface", "stage"]).status == 2)
        #expect(try run(["-qt.surface stage -qt.paused"]).status == 2)
    }
}
