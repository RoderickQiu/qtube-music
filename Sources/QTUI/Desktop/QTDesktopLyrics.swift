import AppKit
import QTCore
import QTPlayback
import SwiftUI

// Owner: builder "desktop". Desktop lyrics (draft §4.3): one or two lines in a click-through overlay on all
// Spaces, legible on any wallpaper. Unlock to drag it somewhere else (and nudge the size), lock to make it
// click-through again. Hidden while the Stage is up (QTDesktopCoordinator).

@MainActor
final class QTDesktopLyricsPanel: NSPanel, NSWindowDelegate {
    static let sizeRange: ClosedRange<Double> = 20...72
    /// Moves the user made while unlocked, as fractions of the screen (persisted by the coordinator).
    var onMoved: ((QTDesktopLyricsPrefs) -> Void)?

    private var prefs = QTDesktopLyricsPrefs()
    private var isPlacing = false
    private var avoidedFrame: NSRect?

    init<Content: View>(content: Content) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        identifier = QTWindowID.desktopLyrics.identifier
        title = QTWindowID.desktopLyrics.captureTitle
        isFloatingPanel = true
        // Above ordinary and floating windows (incl. the mini player), below menus and the screen saver.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        delegate = self
        let host = QTFirstMouseHostingView(rootView: content)
        host.sizingOptions = []
        contentView = host
    }

    override var canBecomeMain: Bool { false }

    /// Applies size / position / lock. Idempotent: a frame equal to the current one is left alone.
    /// - Parameter avoiding: the app's own main window frame when it is visible. Until the user moves the overlay,
    ///   its default spot steps out of the window's way (below it, else above it, else the bottom of the screen).
    func apply(prefs new: QTDesktopLyricsPrefs, preferredScreenName: String?, avoiding: NSRect? = nil, force: Bool = false) {
        let changed = new != prefs || avoiding != avoidedFrame
        prefs = new
        avoidedFrame = avoiding
        ignoresMouseEvents = new.isLocked
        guard changed || force || !isVisible else { return }
        let screen = QTWindowPlacement.screen(named: new.screenName) ?? QTWindowPlacement.screen(named: preferredScreenName)
            ?? NSScreen.main
        guard let v = screen?.visibleFrame else { return }
        let size = Self.panelSize(prefs: new, screenWidth: v.width)
        let midX = v.midX + CGFloat(new.horizontalOffset) * v.width
        var minY = v.minY + CGFloat(new.verticalPosition) * v.height
        if Self.isDefaultPosition(new), let window = avoiding, window.intersects(v) {
            let lines = size.height - Self.toolbarHeight(new) // the unlock toolbar grows upwards, out of the way
            let margin: CGFloat = 6
            if window.minY - v.minY >= lines + margin * 2 {
                minY = max(v.minY + margin, min(minY, window.minY - margin - lines))
            } else if v.maxY - window.maxY >= size.height + margin * 2 {
                minY = window.maxY + margin
            } else {
                minY = v.minY + 2
            }
        }
        var f = NSRect(x: midX - size.width / 2, y: minY, width: size.width, height: size.height)
        f.origin.x = min(max(f.origin.x, v.minX), v.maxX - f.width)
        f.origin.y = min(max(f.origin.y, v.minY), v.maxY - f.height)
        f = f.integral
        guard f != frame else { return }
        isPlacing = true
        setFrame(f, display: true)
        isPlacing = false
    }

    static func isDefaultPosition(_ p: QTDesktopLyricsPrefs) -> Bool {
        let d = QTDesktopLyricsPrefs()
        return p.screenName == nil && p.verticalPosition == d.verticalPosition && p.horizontalOffset == d.horizontalOffset
    }

    /// Lines plus a little breathing room for the baked shadow; the toolbar row only while unlocked.
    static func panelSize(prefs: QTDesktopLyricsPrefs, screenWidth: CGFloat) -> NSSize {
        let font = QTLyricsFontOverride(mainSize: prefs.fontSize, design: prefs.fontDesign)
        let lines = QTDesktopLyricsView.linesHeight(font: font, lineCount: prefs.lineCount)
        let chrome = 2 * QTDesktopLyricsView.verticalPadding + toolbarHeight(prefs)
        return NSSize(width: min(max(screenWidth * 0.72, 720), 1500), height: (lines + chrome).rounded())
    }

    static func toolbarHeight(_ prefs: QTDesktopLyricsPrefs) -> CGFloat { prefs.isLocked ? 0 : 40 }

    func windowDidMove(_ notification: Notification) {
        guard !isPlacing, !prefs.isLocked, let screen else { return }
        let v = screen.visibleFrame
        var p = prefs
        p.horizontalOffset = Double((frame.midX - v.midX) / v.width)
        p.verticalPosition = Double(max(0, (frame.minY - v.minY) / v.height))
        p.screenName = screen.localizedName
        prefs = p
        onMoved?(p)
    }
}

/// The overlay's content: the current line (word fill from `QTLyricsView`'s desktop style) and a second line
/// (translation when there is one, otherwise the next line), with the renderer's baked shadow and outline so it
/// reads on any wallpaper; Increase Contrast / Reduce Transparency add a soft dark backdrop.
public struct QTDesktopLyricsView: View {
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isHovering = false

    public init() {}

    private var prefs: QTDesktopLyricsPrefs { model.settings.settings.desktopLyrics }

    public var body: some View {
        let font = QTLyricsFontOverride(mainSize: prefs.fontSize, design: prefs.fontDesign)
        VStack(spacing: 0) {
            if !prefs.isLocked {
                toolbar
                    .frame(height: QTDesktopLyricsPanel.toolbarHeight(prefs))
                    .transition(.opacity)
            }
            lines(font: font)
                .padding(.horizontal, 28)
                .padding(.vertical, Self.verticalPadding)
                .background {
                    if prefs.isLocked && (contrast == .increased || reduceTransparency) {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(.black.opacity(0.5))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if !prefs.isLocked {
                Color.clear
                    .qtGlass(.overArt, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .opacity(isHovering ? 1 : 0.85)
            }
        }
        .background(QTHoverTracking { isHovering = $0 })
        .environment(\.colorScheme, .dark)
        .animation(QTTheme.Motion.ui, value: prefs.isLocked)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(QTLoc.tr("Desktop Lyrics"))
        .accessibilityIdentifier("qt.desktopLyrics.overlay")
    }

    @ViewBuilder
    private func lines(font: QTLyricsFontOverride) -> some View {
        let doc = player.ad == nil ? player.lyrics : nil
        if let doc, !doc.lines.isEmpty {
            // QTLyricsView(.desktop) draws both lines (translation when there is one, otherwise the next line),
            // the word fill, and its own baked shadow + outline, so it reads on any wallpaper without a box.
            QTLyricsView(document: doc, time: player.timeline, style: .desktop,
                         showsTranslation: model.resolvedTranslationLanguage != nil,
                         desktopLineCount: prefs.lineCount, desktopFontSize: prefs.fontSize) { _ in }
                .frame(height: Self.linesHeight(font: font, lineCount: prefs.lineCount))
                .environment(\.qtLyricsFontOverride, font)
        } else if !prefs.isLocked {
            // While moving, show the song so there is something to place.
            Text(player.nowPlaying?.title ?? QTLoc.tr("Desktop Lyrics"))
                .font(font.main)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
    }

    static let verticalPadding: CGFloat = 10

    /// Main line plus, in two-line mode, the second line (same ratios as `QTDesktopLyricsPanel.panelSize`).
    static func linesHeight(font: QTLyricsFontOverride, lineCount: Int) -> CGFloat {
        let main = font.mainSize * 1.32
        let second = lineCount > 1 ? font.translationSize * 1.4 + 6 : 0
        return (main + second).rounded(.up)
    }

    /// Quiet controls while unlocked: smaller / larger, reset, lock.
    private var toolbar: some View {
        HStack(spacing: 4) {
            Spacer()
            Button { QTDesktopCoordinator.shared.nudgeDesktopLyricsSize(by: -2) } label: {
                Label(QTLoc.tr("Smaller", table: .desktop), systemImage: "textformat.size.smaller")
            }
            .help(QTLoc.tr("Smaller", table: .desktop))
            Button { QTDesktopCoordinator.shared.nudgeDesktopLyricsSize(by: 2) } label: {
                Label(QTLoc.tr("Larger", table: .desktop), systemImage: "textformat.size.larger")
            }
            .help(QTLoc.tr("Larger", table: .desktop))
            Button { QTDesktopCoordinator.shared.resetDesktopLyricsPosition() } label: {
                Label(QTLoc.tr("Reset Position", table: .desktop), systemImage: "arrow.counterclockwise")
            }
            .help(QTLoc.tr("Reset Position", table: .desktop))
            Button { QTDesktopCoordinator.shared.setDesktopLyricsLocked(true) } label: {
                Label(QTLoc.tr("Lock Desktop Lyrics", table: .desktop), systemImage: "lock.open.fill")
            }
            .help(QTLoc.tr("Lock Desktop Lyrics", table: .desktop))
            .accessibilityIdentifier("qt.desktopLyrics.lock")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.system(size: 15, weight: .medium))
        .controlSize(.large)
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 18)
        .padding(.top, 8)
    }
}
