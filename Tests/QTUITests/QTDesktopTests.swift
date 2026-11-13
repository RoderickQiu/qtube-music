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

    /// Issue #4: a lyric dragged towards a screen edge stays there when locked. The overlay may hang over the edge;
    /// the part its lines start from stays on screen.
    @Test func desktopLyricsKeepTheirPlaceNearAScreenEdge() {
        let v = NSRect(x: 0, y: 0, width: 1728, height: 1000)
        let w: CGFloat = 1244
        let keep = QTDesktopLyricsPanel.minimumVisibleWidth
        // Centred lines dragged far left: the old clamp put the overlay back at x = 0.
        #expect(QTDesktopLyricsPanel.clampedX(-400, width: w, alignment: .center, in: v) == -400)
        #expect(QTDesktopLyricsPanel.clampedX(900, width: w, alignment: .center, in: v) == 900)
        // …but never so far that nothing is left to grab.
        #expect(QTDesktopLyricsPanel.clampedX(-5000, width: w, alignment: .center, in: v) == keep / 2 - w / 2)
        #expect(QTDesktopLyricsPanel.clampedX(5000, width: w, alignment: .center, in: v) == v.maxX - keep / 2 - w / 2)
        // Left lines start at the overlay's left edge, which stays on screen; right lines mirror that.
        #expect(QTDesktopLyricsPanel.clampedX(-300, width: w, alignment: .left, in: v) == 0)
        #expect(QTDesktopLyricsPanel.clampedX(5000, width: w, alignment: .left, in: v) == v.maxX - keep)
        #expect(QTDesktopLyricsPanel.clampedX(5000, width: w, alignment: .right, in: v) == v.maxX - w)
        #expect(QTDesktopLyricsPanel.clampedX(-5000, width: w, alignment: .right, in: v) == keep - w)
        // The default spot is untouched.
        #expect(QTDesktopLyricsPanel.clampedX((v.width - w) / 2, width: w, alignment: .center, in: v) == (v.width - w) / 2)
    }

    @Test func desktopLyricsAlignmentMovesTheLines() {
        let doc = QTLyricsDocument(lines: [QTLyricsLine(start: 0, text: "Short line")], syncKind: .line, source: .netease)
        func x(_ a: QTDesktopLyricsAlignment) -> CGFloat {
            let rows = QTLyricsRowBuilder.rows(for: doc, lanes: .init(), metrics: QTLyricsMetrics.make(.desktop).withAlignment(a),
                                               width: 1000, includeGaps: false)
            return rows[0].mainOrigin.x
        }
        #expect(x(.left) == 0)
        #expect(x(.center) > 200 && x(.center) < x(.right))
        #expect(QTLyricsMetrics.make(.desktop).main.centered)   // the default stays centred
        var old = QTDesktopLyricsPrefs()
        old.alignment = .right
        let data = try! JSONEncoder().encode(old)
        #expect(try! JSONDecoder().decode(QTDesktopLyricsPrefs.self, from: data).alignment == .right)
        #expect(try! JSONDecoder().decode(QTDesktopLyricsPrefs.self, from: Data("{}".utf8)).alignment == .center)
    }

    @Test func menuBarTitleIsCappedAndTemplate() {
        let long = String(repeating: "Đối Với Anh Em Không Còn Cảm Giác ", count: 4)
        let image = QTMenuBarLabel.render(title: long, offset: 0)
        #expect(image.isTemplate)
        #expect(image.size.width <= QTMenuBarLabel.maxTitleWidth + 30)
        let glyphOnly = QTMenuBarLabel.render(title: nil, offset: 0)
        #expect(glyphOnly.size.width < 30)
    }

    /// The title sits on the menu bar's own text line (like the clock): its caps centred in the item, not ~3 pt high.
    @Test func menuBarTitleIsVerticallyCentred() throws {
        let image = QTMenuBarLabel.render(title: "HELLO 20", offset: 0)
        let rep = try #require(image.representations.first as? NSBitmapImageRep)
        let scale = CGFloat(rep.pixelsHigh) / image.size.height
        let glyphWidth = QTMenuBarLabel.render(title: nil, offset: 0).size.width
        func inkCentre(columns: Range<Int>) -> CGFloat? {
            var rows: [Int] = []
            for y in 0..<rep.pixelsHigh where columns.contains(where: { (rep.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.5 }) {
                rows.append(y)
            }
            guard let top = rows.first, let bottom = rows.last else { return nil }
            return CGFloat(top + bottom + 1) / 2 / scale   // from the top, in points
        }
        let text = try #require(inkCentre(columns: Int((glyphWidth + 6) * scale)..<rep.pixelsWide))
        let glyph = try #require(inkCentre(columns: 0..<Int(glyphWidth * scale)))
        #expect(abs(text - image.size.height / 2) <= 0.75)
        #expect(abs(glyph - text) <= 1.5)
    }

    @Test func lockedDesktopLyricsDropTheToolbarRow() {
        var p = QTDesktopLyricsPrefs()
        p.isLocked = true
        let locked = QTDesktopLyricsPanel.panelSize(prefs: p, screenWidth: 1920)
        p.isLocked = false
        let unlocked = QTDesktopLyricsPanel.panelSize(prefs: p, screenWidth: 1920)
        #expect(unlocked.height - locked.height == QTDesktopLyricsPanel.toolbarHeight(p))
        #expect(QTDesktopLyricsPanel.isDefaultPosition(QTDesktopLyricsPrefs()))
        p.verticalPosition = 0.5
        #expect(!QTDesktopLyricsPanel.isDefaultPosition(p))
    }

    @Test func popoverLyricLinePreviewsTheNextLineAndCollapsesAtTheEnd() {
        let doc = QTLyricsDocument(lines: [
            QTLyricsLine(start: 10, duration: 3, text: "first"),
            QTLyricsLine(start: 14, duration: nil, text: ""),
            QTLyricsLine(start: 30, duration: 4, text: "second"),
        ], syncKind: .line, source: QTLyricsSource(id: "test", name: "Test"))
        // Before the first line: the first line, dimmed.
        #expect(QTCurrentLyricLine.display(in: doc, at: 2).map { [$0.index] + [$0.isUpcoming ? 1 : 0] } == [0, 1])
        #expect(QTCurrentLyricLine.display(in: doc, at: 11).map { [$0.index] + [$0.isUpcoming ? 1 : 0] } == [0, 0])
        // Empty interlude line: preview the next sung line.
        #expect(QTCurrentLyricLine.display(in: doc, at: 20).map { [$0.index] + [$0.isUpcoming ? 1 : 0] } == [2, 1])
        // After the last line has run out: nothing (the popover section collapses).
        #expect(QTCurrentLyricLine.display(in: doc, at: 60) == nil)
        #expect(QTCurrentLyricLine.display(in: nil, at: 0) == nil)
    }

    @Test func accountMonograms() {
        #expect(QTAccountAvatar.initials("Alex Rivera") == "AR")
        #expect(QTAccountAvatar.initials("周杰伦") == "周")
        #expect(QTAccountAvatar.initials("  ") == nil)
        #expect(QTAccountAvatar.initials(nil) == nil)
    }

    @Test func appleIntelligenceUnavailableStatesExplainThemselves() {
        let states: [QTAppleIntelligence.Status] = [.requiresNewerMacOS, .deviceNotEligible, .notEnabled, .modelNotReady,
                                                    .languageUnsupported("vi"), .unavailable]
        for s in states { #expect(s.reason?.isEmpty == false) }
        #expect(QTAppleIntelligence.Status.available.reason == nil)
    }
}
