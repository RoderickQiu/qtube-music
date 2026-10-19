import AppKit
import QTCore
import SwiftUI

// Owner: builder "desktop". Mini player (draft §4.2): a floating, non-activating panel on all Spaces with two
// modes — a compact strip (art · title · prev/play/next) and a square of artwork with controls on hover.
// Double-click switches mode, edges resize, position is remembered per display and mode.

/// The mini player window. Titled (hidden title bar) so it gets the system's corner radius, shadow and edge
/// resizing; non-activating so clicking it never takes focus from the user's app.
@MainActor
final class QTMiniPlayerPanel: NSPanel, NSWindowDelegate {
    static let compactHeight: CGFloat = QTTheme.Metrics.miniCompact.height
    static let lyricLineHeight: CGFloat = 30
    static let compactWidths: ClosedRange<CGFloat> = 280...560
    static let artSides: ClosedRange<CGFloat> = 220...560

    private(set) var mode: QTMiniPlayerMode
    private var showsLyricLine = false
    private var isApplying = false

    init<Content: View>(content: Content, mode: QTMiniPlayerMode) {
        self.mode = mode
        super.init(contentRect: NSRect(origin: .zero, size: QTTheme.Metrics.miniCompact),
                   styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        identifier = QTWindowID.miniPlayer.identifier
        title = QTWindowID.miniPlayer.captureTitle
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(b)?.isHidden = true }
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
        delegate = self
        setAccessibilityLabel(QTLoc.tr("Mini Player"))
        let host = QTFirstMouseHostingView(rootView: content)
        host.sizingOptions = []
        contentView = host
        applyConstraints()
    }

    override var canBecomeMain: Bool { false }

    // MARK: Mode

    func apply(mode newMode: QTMiniPlayerMode, showsLyricLine lyric: Bool) {
        guard newMode != mode || lyric != showsLyricLine else { return }
        let modeChanged = newMode != mode
        if modeChanged { saveFrame() }
        mode = newMode
        showsLyricLine = lyric
        applyConstraints()
        isApplying = true
        defer { isApplying = false }
        let target: NSRect
        if modeChanged, let screen, let saved = Self.savedFrame(screen: screen, mode: newMode) {
            target = saved
        } else {
            target = anchoredFrame(for: defaultSize(for: newMode, keepingWidth: !modeChanged))
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        setFrame(clamped(target), display: true, animate: isVisible && !reduceMotion)
    }

    private func applyConstraints() {
        switch mode {
        case .compact:
            let h = Self.compactHeight + (showsLyricLine ? Self.lyricLineHeight : 0)
            contentAspectRatio = .zero
            resizeIncrements = NSSize(width: 1, height: 1)
            contentMinSize = NSSize(width: Self.compactWidths.lowerBound, height: h)
            contentMaxSize = NSSize(width: Self.compactWidths.upperBound, height: h)
        case .art:
            contentMinSize = NSSize(width: Self.artSides.lowerBound, height: Self.artSides.lowerBound)
            contentMaxSize = NSSize(width: Self.artSides.upperBound, height: Self.artSides.upperBound)
            contentAspectRatio = NSSize(width: 1, height: 1)
        }
    }

    private func defaultSize(for mode: QTMiniPlayerMode, keepingWidth: Bool) -> NSSize {
        switch mode {
        case .compact:
            let w = keepingWidth ? frame.width : QTTheme.Metrics.miniCompact.width
            return NSSize(width: w, height: Self.compactHeight + (showsLyricLine ? Self.lyricLineHeight : 0))
        case .art:
            return QTTheme.Metrics.miniArt
        }
    }

    /// Grows/shrinks toward the screen's centre, keeping the corner nearest the screen edge in place.
    private func anchoredFrame(for size: NSSize) -> NSRect {
        let current = frame
        guard let visible = screen?.visibleFrame else { return NSRect(origin: current.origin, size: size) }
        let x = current.midX > visible.midX ? current.maxX - size.width : current.minX
        let y = current.midY > visible.midY ? current.maxY - size.height : current.minY
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: Frames per display

    func restoreFrame(on screen: NSScreen?, mode: QTMiniPlayerMode) {
        guard let screen else { return }
        let size = defaultSize(for: mode, keepingWidth: false)
        if let saved = Self.savedFrame(screen: screen, mode: mode) {
            var f = saved
            if mode == .compact { f.size.height = size.height }
            setFrame(clamped(f, on: screen), display: false)
        } else {
            let v = screen.visibleFrame
            setFrame(NSRect(x: v.maxX - size.width - 28, y: v.minY + 28, width: size.width, height: size.height), display: false)
        }
    }

    func clampToScreen() {
        setFrame(clamped(frame), display: true)
    }

    private func clamped(_ rect: NSRect, on screen: NSScreen? = nil) -> NSRect {
        guard let v = (screen ?? self.screen ?? NSScreen.main)?.visibleFrame else { return rect }
        var r = rect
        r.origin.x = min(max(r.origin.x, v.minX), v.maxX - r.width)
        r.origin.y = min(max(r.origin.y, v.minY), v.maxY - r.height)
        return r.integral
    }

    private static let framesKey = "qt.desktop.miniPlayerFrames"

    private static func key(screen: NSScreen, mode: QTMiniPlayerMode) -> String {
        let s = screen.frame.size
        return "\(screen.localizedName)|\(Int(s.width))x\(Int(s.height))|\(mode.rawValue)"
    }

    static func savedFrame(screen: NSScreen, mode: QTMiniPlayerMode) -> NSRect? {
        guard let s = (UserDefaults.standard.dictionary(forKey: framesKey) as? [String: String])?[key(screen: screen, mode: mode)] else { return nil }
        let r = NSRectFromString(s)
        return r.isEmpty ? nil : r
    }

    private func saveFrame() {
        guard let screen, !isApplying else { return }
        var all = UserDefaults.standard.dictionary(forKey: Self.framesKey) as? [String: String] ?? [:]
        all[Self.key(screen: screen, mode: mode)] = NSStringFromRect(frame)
        UserDefaults.standard.set(all, forKey: Self.framesKey)
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }
}

// MARK: - SwiftUI content

/// Mini player content. Compact follows the system appearance on a floating material (Liquid Glass on
/// macOS 26+); art mode is full-bleed artwork with a dark scrim and controls on hover.
public struct QTMiniPlayerView: View {
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    public init() {}

    private var prefs: QTMiniPlayerPrefs { model.settings.settings.miniPlayer }
    private var hovering: Bool { isHovering || QTDesktopCoordinator.shared.forcesMiniHover }

    public var body: some View {
        Group {
            switch prefs.mode {
            case .compact: compact
            case .art: art
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { progressLine }
        .background(QTHoverTracking { inside in
            withAnimation(QTTheme.Motion.animation(.easeOut(duration: 0.2), reduceMotion: reduceMotion)) { isHovering = inside }
        })
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .onTapGesture(count: 2) { QTDesktopCoordinator.shared.toggleMiniMode() }
        .contextMenu { QTMiniPlayerMenu() }
        .help(QTLoc.tr("Double-click to switch size"))
        .qtArtworkTint(model.palette)
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("qt.miniPlayer.\(prefs.mode.rawValue)")
    }

    // MARK: Compact

    private var compact: some View {
        let height = QTMiniPlayerPanel.compactHeight + (prefs.showsLyricLine ? QTMiniPlayerPanel.lyricLineHeight : 0)
        return HStack(spacing: QTTheme.Spacing.s) {
            QTArtworkView(track: player.nowPlaying, cornerRadius: 0)
                .frame(width: height, height: height)
                .saturation(player.ad != nil ? 0.6 : 1)
                .brightness(player.ad != nil ? -0.15 : 0)
                .overlay { if hovering { expandButton.transition(.opacity) } }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: QTTheme.Spacing.s) {
                    titles
                        .frame(maxWidth: .infinity, alignment: .leading)
                    QTTransportControls(style: .compact)
                        .padding(.trailing, 14)
                }
                .frame(height: QTMiniPlayerPanel.compactHeight - (prefs.showsLyricLine ? 8 : 0))
                if prefs.showsLyricLine {
                    // The shared karaoke renderer's single-line style (word fill in the render server, no timers).
                    QTLyricsView(document: player.ad == nil ? player.lyrics : nil, time: player.timeline, style: .mini,
                                 showsTranslation: false) { _ in }
                        .padding(.trailing, 14)
                        .frame(height: QTMiniPlayerPanel.lyricLineHeight + 8, alignment: .topLeading)
                }
            }
        }
        .frame(height: height)
        .background(QTPanelGlassBackground())
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            if player.ad != nil {
                Text(QTLoc.tr("Advertisement")).font(QTTheme.Typography.rowTitle.weight(.semibold)).lineLimit(1)
                Text(QTLoc.tr("Then: %@", player.nowPlaying?.title ?? "")).font(QTTheme.Typography.secondary)
                    .foregroundStyle(.secondary).lineLimit(1)
            } else if let track = player.nowPlaying {
                Text(track.title).font(QTTheme.Typography.rowTitle.weight(.semibold)).lineLimit(1)
                Text(track.artistLine).font(QTTheme.Typography.secondary).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(QTLoc.tr("Not Playing", table: .desktop)).font(QTTheme.Typography.rowTitle).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Art

    private var art: some View {
        ZStack(alignment: .bottom) {
            QTArtworkView(track: player.nowPlaying, cornerRadius: 0, contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .saturation(player.ad != nil ? 0.6 : 1)
                .brightness(player.ad != nil ? -0.15 : 0)

            // Scrim: stronger with controls, gentle under the lyric line, none otherwise.
            LinearGradient(stops: [.init(color: .clear, location: hovering ? 0.35 : 0.6),
                                   .init(color: .black.opacity(hovering ? 0.78 : (prefs.showsLyricLine ? 0.55 : 0)), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)

            if hovering {
                VStack(spacing: 10) {
                    VStack(spacing: 2) {
                        Text(player.ad != nil ? QTLoc.tr("Advertisement") : player.nowPlaying?.title ?? "")
                            .font(QTTheme.Typography.rowTitle.weight(.semibold))
                        Text(player.nowPlaying?.artistLine ?? "")
                            .font(QTTheme.Typography.secondary)
                            .foregroundStyle(QTTheme.Colors.onArtSecondary)
                    }
                    .lineLimit(1)
                    .padding(.horizontal, QTTheme.Spacing.m)
                    QTTransportControls(style: .compact)
                }
                .padding(.bottom, QTTheme.Spacing.m)
                .transition(.opacity)
            } else if prefs.showsLyricLine {
                QTCurrentLyricLine(style: .miniArt)
                    .padding(.horizontal, QTTheme.Spacing.m)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topLeading) {
            if hovering {
                HStack(spacing: 6) {
                    QTMiniCornerButton(title: QTLoc.tr("Close Mini Player", table: .desktop), systemImage: QTIcon.close.systemName) {
                        QTDesktopCoordinator.shared.closeMiniPlayer()
                    }
                    QTMiniCornerButton(title: QTLoc.tr("Show Main Window"), systemImage: QTIcon.expand.systemName) {
                        QTDesktopCoordinator.shared.showMainWindow()
                    }
                }
                .padding(10)
                .transition(.opacity)
            }
        }
        .foregroundStyle(QTTheme.Colors.onArt)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Pieces

    private var expandButton: some View {
        Button {
            QTDesktopCoordinator.shared.showMainWindow()
        } label: {
            Label(QTLoc.tr("Show Main Window"), systemImage: QTIcon.expand.systemName)
                .labelStyle(.iconOnly)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.38))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(QTLoc.tr("Show Main Window"))
        .accessibilityIdentifier("qt.miniPlayer.showMainWindow")
    }

    /// 2 pt progress line along the bottom edge, tinted with the artwork accent.
    private var progressLine: some View {
        TimelineView(.periodic(from: .now, by: player.timeline.rate > 0 ? 0.5 : 3600)) { _ in
            let fraction = player.ad?.progress ?? (player.duration > 0 ? player.timeline.currentTime / player.duration : 0)
            GeometryReader { g in
                Rectangle()
                    .fill(prefs.mode == .art ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.tint))
                    .frame(width: g.size.width * min(max(fraction, 0), 1), height: 2)
                    .frame(maxHeight: .infinity, alignment: .bottomLeading)
            }
            .frame(height: 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Small round glass button for the art mode's top corner.
struct QTMiniCornerButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .qtFloatingSurface(Circle(), material: .ultraThinMaterial)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

/// Right-click menu of the mini player (native NSMenu via SwiftUI).
struct QTMiniPlayerMenu: View {
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player

    var body: some View {
        let prefs = model.settings.settings.miniPlayer
        Button(QTLoc.tr(player.isPlaying ? "Pause" : "Play")) { player.togglePlayPause() }
        if let track = player.nowPlaying {
            Button(QTLoc.tr(player.isLiked(track) ? "Remove from Liked Songs" : "Like")) { player.toggleLike(track) }
        }
        Divider()
        Picker(QTLoc.tr("Size", table: .desktop), selection: Binding(get: { prefs.mode }, set: { v in model.settings.update { $0.miniPlayer.mode = v } })) {
            Text(QTLoc.tr("Compact", table: .desktop)).tag(QTMiniPlayerMode.compact)
            Text(QTLoc.tr("Artwork", table: .desktop)).tag(QTMiniPlayerMode.art)
        }
        .pickerStyle(.inline)
        Toggle(QTLoc.tr("Show Lyric Line", table: .desktop), isOn: Binding(get: { prefs.showsLyricLine },
                                                                       set: { v in model.settings.update { $0.miniPlayer.showsLyricLine = v } }))
        Divider()
        Button(QTLoc.tr("Show Main Window")) { QTDesktopCoordinator.shared.showMainWindow() }
        Button(QTLoc.tr("Close Mini Player", table: .desktop)) { QTDesktopCoordinator.shared.closeMiniPlayer() }
    }
}
