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
    func apply(prefs new: QTDesktopLyricsPrefs, preferredScreenName: String?, force: Bool = false) {
        let changed = new != prefs
        prefs = new
        ignoresMouseEvents = new.isLocked
        guard changed || force || !isVisible else { return }
        let screen = QTWindowPlacement.screen(named: new.screenName) ?? QTWindowPlacement.screen(named: preferredScreenName)
            ?? NSScreen.main
        guard let v = screen?.visibleFrame else { return }
        let size = Self.panelSize(prefs: new, screenWidth: v.width)
        let midX = v.midX + CGFloat(new.horizontalOffset) * v.width
        let minY = v.minY + CGFloat(new.verticalPosition) * v.height
        var f = NSRect(x: midX - size.width / 2, y: minY, width: size.width, height: size.height)
        f.origin.x = min(max(f.origin.x, v.minX), v.maxX - f.width)
        f.origin.y = min(max(f.origin.y, v.minY), v.maxY - f.height)
        f = f.integral
        guard f != frame else { return }
        isPlacing = true
        setFrame(f, display: true)
        isPlacing = false
    }

    /// Wide enough for long lines, tall enough for two lines at the chosen size plus the unlock toolbar.
    static func panelSize(prefs: QTDesktopLyricsPrefs, screenWidth: CGFloat) -> NSSize {
        let font = QTLyricsFontOverride(mainSize: prefs.fontSize, design: prefs.fontDesign)
        let main = font.mainSize * 1.32
        let second = prefs.lineCount > 1 ? font.translationSize * 1.4 + 6 : 0
        let chrome: CGFloat = 44 + 36 // padding + toolbar row when unlocked
        return NSSize(width: min(max(screenWidth * 0.72, 720), 1500), height: (main + second + chrome).rounded())
    }

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
            toolbar
                .frame(height: 36)
                .opacity(prefs.isLocked ? 0 : 1)
            Spacer(minLength: 0)
            lines(font: font)
                .padding(.horizontal, 28)
                .padding(.vertical, 10)
                .background {
                    if prefs.isLocked && (contrast == .increased || reduceTransparency) {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(.black.opacity(0.5))
                    }
                }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if !prefs.isLocked {
                Color.clear
                    .qtFloatingSurface(RoundedRectangle(cornerRadius: 22, style: .continuous), material: .ultraThinMaterial)
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
        .padding(.top, 6)
        .disabled(prefs.isLocked)
    }
}
