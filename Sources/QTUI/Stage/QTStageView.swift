import AppKit
import QTCore
import QTPlayback
import SwiftUI

/// The Stage — the immersive now-playing screen (spec §4.1, prototype stage.jsx).
///
/// - Layouts: Standard (art left, lyrics right), Lyrics only (centred lyrics, art as background), Art only
///   (automatic when a track has no lyrics).
/// - Backgrounds: blurred art, full-bleed frosted cover, vinyl, music video, Metal visualizer (Premium).
/// - Chrome: icon-only top bar (close, lyrics options, appearance, Song | Video) centred on the window's traffic
///   lights, which stay put on a transparent title bar (`QTStageTitlebar`); a bottom row (progress, transport with
///   a filled play disc, ♥, queue, AirPlay). Fades out after 3 s without mouse movement while playing.
/// - Queue drawer from the right; art and lyrics reflow beside it. Esc closes the drawer, then the Stage.
/// - Right-click (or VoiceOver action): show the Stage on another display / back in the main window, full screen.
///   Double-click empty space: full screen.
/// - During an ad the lyrics step away entirely; the art slot holds the ad card.
///
/// Launch arguments (session-only): `qt.stage.chrome hidden`, `qt.stage.queue YES`, `qt.stage.popover appearance`,
/// `qt.stage.window YES` (open the Stage in its own window on the launch display), `qt.stage.visualizerOnBattery YES`,
/// `qt.stage.reduceMotion YES` (simulate Reduce Motion), `qt.stage.noAd YES` (free account without the pre-roll).
public struct QTStageView: View {
    private let presentation: QTStagePresentation

    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.qtAccent) private var accent

    @State private var chromeVisible = true
    @State private var isQueueOpen = false
    @State private var isAppearanceOpen = false
    @State private var hideTask: Task<Void, Never>?
    @State private var hovering = false
    @State private var menuTracking = false
    @State private var hostWindow = QTStageWeakWindow()
    @State private var isFullScreen = false
    @State private var hasTrafficLights = false
    @State private var stageEnteredFullScreen = false
    @State private var appeared = false
    @State private var titlebar = QTStageTitlebar()
    /// Centre of the window's traffic lights from the top (nil in full screen / without a title bar).
    @State private var trafficLightsMidY: CGFloat?
    /// The synced line over the music video (Appearance popover; on by default).
    @AppStorage(QTStageVideoLyrics.defaultsKey) private var showsVideoLyrics = true
    private let power = QTStagePowerMonitor.shared
    private let coordinator = QTStageCoordinator.shared

    public init() {
        presentation = .inline
    }

    public init(presentation: QTStagePresentation) {
        self.presentation = presentation
    }

    // MARK: Derived state

    private var reduceMotion: Bool { systemReduceMotion || model.launch.bool("qt.stage.reduceMotion") == true }

    private var policy: QTStageMotionPolicy {
        QTStageMotionPolicy(reduceMotion: reduceMotion, lowPower: power.isLowPowerMode, onBattery: power.isOnBattery,
                            visualizerOnBattery: model.launch.bool("qt.stage.visualizerOnBattery")
                                ?? UserDefaults.standard.bool(forKey: "qt.stage.visualizerOnBattery"))
    }

    private var hasLyrics: Bool? {
        if player.isLoadingLyrics { return nil }
        guard let doc = player.lyrics else { return false }
        return !doc.lines.isEmpty
    }

    private var resolved: QTStageResolvedAppearance {
        QTStageResolvedAppearance(layout: model.stageLayout, background: model.stageBackground,
                                  videoMode: model.isVideoMode, hasVideo: player.nowPlaying?.hasVideo ?? false,
                                  hasLyrics: hasLyrics, isPremium: model.account == .premium, isAd: player.ad != nil)
    }

    private var showsTranslation: Bool { model.resolvedTranslationLanguage != nil }

    private var motion: Animation { QTTheme.Motion.animation(QTTheme.Motion.spring, reduceMotion: reduceMotion) }

    // MARK: Body

    public var body: some View {
        let appearance = resolved
        GeometryReader { geo in
            ZStack {
                QTStageBackgroundView(track: player.nowPlaying, appearance: appearance, isPlaying: player.isPlaying,
                                      policy: policy, accent: QTTheme.Colors.accent(player.nowPlaying?.palette, scheme: .dark))
                    .id(appearance.background)
                    .transition(.opacity)

                // Double-click empty space: full screen, like a video player. Right-click: where the Stage shows.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { toggleFullScreen() }
                    .contextMenu { stageMenu }
                    .accessibilityHidden(true)

                content(appearance, size: geo.size, trailingReserve: drawerReserve)
                    .scaleEffect(appeared || reduceMotion ? 1 : 1.015)
                    .opacity(appeared ? 1 : 0)

                chrome(appearance)
                    .opacity(chromeVisible ? 1 : 0)
                    .allowsHitTesting(chromeVisible)
                    .accessibilityHidden(!chromeVisible && !NSWorkspace.shared.isVoiceOverEnabled)

                if isQueueOpen {
                    QTStageQueueDrawer { closeQueue() }
                        .padding(.top, QTTheme.Metrics.stageTopBarHeight)
                        .padding(.trailing, QTTheme.Spacing.l)
                        .padding(.bottom, 128)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .transition(.opacity.combined(with: .offset(x: reduceMotion ? 0 : 16)))
                        .zIndex(2)
                }

                // Toasts (lyrics timing, likes, queue edits) stay visible on the Stage, in the main window and
                // in the detached Stage window alike.
                QTToastOverlay()
                    .padding(.top, QTTheme.Metrics.stageTopBarHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .zIndex(3)
            }
            .animation(QTTheme.Motion.animation(.easeInOut(duration: 0.6), reduceMotion: reduceMotion), value: appearance.background)
            .animation(motion, value: appearance.layout)
            .animation(motion, value: appearance.artSlot)
            .animation(motion, value: isQueueOpen)
        }
        .qtArtworkTint(player.nowPlaying?.palette)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(QTTheme.Colors.onArt)
        .ignoresSafeArea()
        .onContinuousHover { phase in
            switch phase {
            case .active:
                hovering = true
                poke()
            case .ended:
                hovering = false
            }
        }
        .background(QTStageWindowReader { window in
            hostWindow.window = window
            isFullScreen = window?.styleMask.contains(.fullScreen) ?? false
            installTitlebar()
        })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            guard (note.object as? NSWindow) === hostWindow.window else { return }
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard (note.object as? NSWindow) === hostWindow.window else { return }
            isFullScreen = false
            stageEnteredFullScreen = false
            installTitlebar()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in menuTracking = true }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            menuTracking = false
            scheduleHide()
        }
        .onChange(of: player.isPlaying) { _, _ in poke() }
        .onChange(of: isQueueOpen) { _, _ in poke() }
        .onChange(of: isAppearanceOpen) { _, open in if !open { poke() } }
        .onAppear(perform: didAppear)
        .onDisappear(perform: didDisappear)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(QTLoc.tr("Stage"))
        .accessibilityAction(named: Text(QTLoc.tr(isFullScreen ? "Exit Full Screen" : "Enter Full Screen", table: .stage))) {
            toggleFullScreen()
        }
        .accessibilityIdentifier(presentation == .inline ? "qt.stage" : "qt.stage.detached")
    }

    // MARK: Content (layouts)

    @ViewBuilder
    private func content(_ a: QTStageResolvedAppearance, size: CGSize, trailingReserve: CGFloat) -> some View {
        let inset = QTTheme.Metrics.stageInset
        let area = CGSize(width: max(size.width - inset * 2 - trailingReserve, 0), height: max(size.height - inset - 128, 0))
        Group {
            if a.isVideo {
                videoContent(a, area: area)
            } else {
                switch a.layout {
                case .standard: standardLayout(a, area: area)
                case .lyricsOnly: lyricsOnlyLayout(a, area: area)
                case .artOnly: artOnlyLayout(a, area: area)
                }
            }
        }
        .frame(width: area.width, height: area.height)
        .padding(.top, inset)
        .padding(.bottom, 128)
        .padding(.leading, inset)
        .padding(.trailing, inset + trailingReserve)
    }

    /// Width the open Queue drawer takes from the content, so art and lyrics reflow beside it instead of under it.
    private var drawerReserve: CGFloat {
        isQueueOpen ? QTTheme.Metrics.stageQueueWidth + QTTheme.Spacing.l - QTTheme.Metrics.stageInset + 40 : 0
    }

    private func standardLayout(_ a: QTStageResolvedAppearance, area: CGSize) -> some View {
        let gap: CGFloat = 72
        let artWidth = max((area.width - gap) / 2.08, 0)
        let lyricsWidth = max(area.width - gap - artWidth, 0)
        let metaUnder = a.showsMetaUnderArt
        let artSize = min(QTTheme.Metrics.stageArtwork, artWidth, area.height - (metaUnder ? 96 : 0))
        return HStack(spacing: gap) {
            VStack(spacing: 22) {
                artSlot(a, size: artSize)
                if metaUnder { meta(alignment: .center) }
            }
            .frame(width: artWidth, height: area.height)

            ZStack(alignment: .topLeading) {
                if !metaUnder {
                    meta(alignment: .leading)
                        .padding(.top, -4)
                }
                // Lyrics pause for an ad: they step away entirely rather than sitting there, ghosted and still.
                if !a.isAd {
                    lyrics(centered: false)
                        .padding(.top, metaUnder ? 0 : 84)
                        .transition(.opacity)
                }
            }
            .frame(width: lyricsWidth, height: area.height, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func lyricsOnlyLayout(_ a: QTStageResolvedAppearance, area: CGSize) -> some View {
        if a.artSlot == .ad {
            QTStageAdCard(track: player.nowPlaying, size: min(400, area.height - 40))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack(alignment: .top) {
                meta(alignment: .center, compact: true)
                    .padding(.top, -6)
                lyrics(centered: true)
                    .padding(.top, 56)
            }
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func artOnlyLayout(_ a: QTStageResolvedAppearance, area: CGSize) -> some View {
        let wanted: CGFloat = a.artSlot == .vinyl ? 500 : QTTheme.Metrics.stageArtworkArtOnly
        let size = max(min(wanted, area.width, area.height - 150), 120)
        return VStack(spacing: 22) {
            artSlot(a, size: size)
            meta(alignment: .center)
            if a.artSlot != .ad {
                QTStageCurrentLyric(document: player.lyrics, time: player.timeline, style: .artOnly,
                                    showsTranslation: showsTranslation)
                    .frame(minHeight: 56, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func videoContent(_ a: QTStageResolvedAppearance, area: CGSize) -> some View {
        if a.artSlot == .ad {
            QTStageAdCard(track: player.nowPlaying, size: min(440, area.height - 40))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if showsVideoLyrics {
            // `VideoLyricsOverlay`: left 64, right 64, bottom 150 (the content area already ends 128 above the bottom).
            QTStageCurrentLyric(document: player.lyrics, time: player.timeline, style: .videoOverlay,
                                showsTranslation: showsTranslation)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.bottom, 22)
                .transition(.opacity)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func artSlot(_ a: QTStageResolvedAppearance, size: CGFloat) -> some View {
        switch a.artSlot {
        case .artwork:
            QTArtworkView(track: player.nowPlaying, cornerRadius: QTTheme.Radius.artworkLarge)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.5), radius: 40, y: 30)
                .onTapGesture(count: 2) { toggleFullScreen() }
                .accessibilityIdentifier("qt.stage.artwork")
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        case .vinyl:
            QTStageVinylView(track: player.nowPlaying, size: size, isPlaying: player.isPlaying, policy: policy)
                .accessibilityIdentifier("qt.stage.vinyl")
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        case .ad:
            QTStageAdCard(track: player.nowPlaying, size: size)
                .transition(.opacity)
        case .none:
            Color.clear.frame(width: size, height: size)
        }
    }

    private func lyrics(centered: Bool) -> some View {
        QTLyricsView(document: player.lyrics, time: player.timeline, style: .stage(centered: centered),
                     showsTranslation: showsTranslation) { player.seek(to: $0) }
            .mask {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.06),
                    .init(color: .black, location: 0.9),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
            .accessibilityIdentifier("qt.stage.lyrics")
    }

    private func meta(alignment: HorizontalAlignment, compact: Bool = false) -> some View {
        let track = player.nowPlaying
        let subtitle: String = {
            guard let track else { return "" }
            if compact { return track.artistLine }
            if let album = track.album?.title, !album.isEmpty { return "\(track.artistLine) — \(album)" }
            return track.artistLine
        }()
        return VStack(alignment: alignment, spacing: 6) {
            Text(track?.title ?? "")
                .font(compact ? .system(size: 20, weight: .bold) : QTTheme.Typography.stageTitle)
                .lineLimit(2)
            Text(subtitle)
                .font(compact ? .system(size: 13) : QTTheme.Typography.stageSubtitle)
                .foregroundStyle(QTTheme.Colors.onArtSecondary)
                .lineLimit(1)
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("qt.stage.meta")
    }

    // MARK: Chrome

    private func chrome(_ a: QTStageResolvedAppearance) -> some View {
        VStack(spacing: 0) {
            topBar(a)
            Spacer(minLength: 0)
            bottomBar
        }
    }

    /// Leading inset that keeps the close button clear of the traffic lights in a window (not in full screen).
    private var topBarLeading: CGFloat { hasTrafficLights && !isFullScreen ? 84 : QTTheme.Spacing.l }

    private func topBar(_ a: QTStageResolvedAppearance) -> some View {
        @Bindable var model = model
        // Liquid Glass on macOS 26 (QTGlass): the close button is its own glass circle, the trailing controls
        // share one capsule; one container so the shapes blend.
        return QTGlassGroup {
            HStack(spacing: 6) {
                Button(action: closeOrDismissDrawer) {
                    Label(QTLoc.tr("Close"), systemImage: QTIcon.chevD.systemName)
                }
                .buttonStyle(QTStageChromeButtonStyle(glyph: 16, circular: true))
                .qtGlass(.overArt, in: Circle(), interactive: true)
                .keyboardShortcut(.cancelAction)
                .help("\(QTLoc.tr("Close"))  Esc")
                .accessibilityIdentifier("qt.stage.close")

                Spacer(minLength: 0)

                HStack(spacing: 2) {
                    QTLyricsOptionsButton(overArt: true)
                        .frame(width: 34, height: 34)
                    QTStageAppearanceButton(isPresented: $isAppearanceOpen, appearance: a)
                    QTSongVideoToggle(isVideo: songVideoBinding, hasVideo: player.nowPlaying?.hasVideo ?? false)
                        .controlSize(.regular)
                        .padding(.leading, 6)
                        .padding(.trailing, 2)
                }
                .padding(.horizontal, 4)
                .frame(height: 40)
                .qtGlass(.overArt, in: Capsule())
            }
        }
        .frame(height: 40)
        .padding(.leading, topBarLeading)
        .padding(.trailing, QTTheme.Spacing.l + 4)
        .padding(.top, topBarRowTop)
        .frame(height: QTTheme.Metrics.stageTopBarHeight, alignment: .top)
        .background(alignment: .top) {
            // Faint top scrim so glyphs stay legible on bright art.
            LinearGradient(colors: [.black.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 110)
                .allowsHitTesting(false)
        }
    }

    /// The row's top edge: centred on the traffic lights in a window, otherwise centred in the top bar.
    private var topBarRowTop: CGFloat {
        if hasTrafficLights, !isFullScreen, let mid = trafficLightsMidY { return max(mid - 20, 4) }
        return QTTheme.Metrics.stageTopBarHeight / 2 - 20
    }

    /// Right-click menu on the Stage: move it to another display, back into the main window, or full screen.
    @ViewBuilder
    private var stageMenu: some View {
        let screens = coordinator.otherScreens(than: hostWindow.window)
        ForEach(screens, id: \.self) { screen in
            Button(QTLoc.tr("Show Stage on %@", table: .stage, screen.localizedName)) {
                showStage(on: screen)
            }
        }
        if presentation == .detached {
            Button(QTLoc.tr("Show Stage in Main Window", table: .stage)) {
                coordinator.returnToMainWindow(model: model)
            }
        }
        if !screens.isEmpty || presentation == .detached { Divider() }
        Button(QTLoc.tr(isFullScreen ? "Exit Full Screen" : "Enter Full Screen", table: .stage)) {
            toggleFullScreen()
        }
    }

    /// Scrubber + transport + like / queue / AirPlay on one floating glass panel, faintly tinted with the artwork
    /// accent (a dark material on macOS 15, solid with Reduce Transparency).
    private var bottomBar: some View {
        VStack(spacing: 6) {
            QTScrubber(overArt: true, identifier: "qt.stage.scrubber")
            ZStack {
                QTTransportControls(style: .stage)
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    sideControls
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: 860)
        .qtGlass(.overArt, in: RoundedRectangle(cornerRadius: QTTheme.Radius.playerBar + 6, style: .continuous),
                 tint: accent.opacity(0.16))
        .padding(.horizontal, QTTheme.Metrics.stageInset)
        .padding(.bottom, 18)
    }

    private var sideControls: some View {
        HStack(spacing: 8) {
            if let track = player.nowPlaying {
                let liked = player.isLiked(track)
                // Same words as the player bar, menus and Dock: the action it will take.
                let title = QTLoc.tr(liked ? "Remove from Liked Songs" : "Like")
                Button { player.toggleLike(track) } label: {
                    Label(title, systemImage: liked ? QTIcon.heartFill.systemName : QTIcon.heart.systemName)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(QTStageChromeButtonStyle(isOn: false, glyph: 17))
                .help("\(title)  ⌘L")
                .accessibilityAddTraits(liked ? .isSelected : [])
                .accessibilityIdentifier("qt.stage.like")
            }
            Button { isQueueOpen.toggle() } label: {
                Label(QTLoc.tr("Queue"), systemImage: QTIcon.list.systemName)
            }
            .buttonStyle(QTStageChromeButtonStyle(isOn: isQueueOpen, glyph: 17))
            .help(QTLoc.tr("Queue"))
            .accessibilityAddTraits(isQueueOpen ? .isSelected : [])
            .accessibilityIdentifier("qt.stage.queue")
            QTStageAirPlayButton()
                .frame(width: 32, height: 32)
        }
    }

    private var songVideoBinding: Binding<Bool> {
        Binding(get: { resolved.isVideo }, set: { video in
            withAnimation(motion) {
                model.isVideoMode = video
                if !video && model.stageBackground == .video { model.stageBackground = .blur }
            }
        })
    }

    // MARK: Actions

    private func closeQueue() {
        isQueueOpen = false
    }

    /// Esc: drawer first, then the Stage.
    private func closeOrDismissDrawer() {
        if isQueueOpen {
            closeQueue()
            return
        }
        closeStage()
    }

    private func closeStage() {
        switch presentation {
        case .inline:
            if stageEnteredFullScreen, isFullScreen { hostWindow.window?.toggleFullScreen(nil) }
            withAnimation(QTTheme.Motion.animation(QTTheme.Motion.ui, reduceMotion: reduceMotion)) { model.surface = .window }
        case .detached:
            coordinator.closeDetached()
        }
    }

    private func toggleFullScreen() {
        guard let window = hostWindow.window else { return }
        if !isFullScreen { stageEnteredFullScreen = true }
        window.toggleFullScreen(nil)
    }

    private func showStage(on screen: NSScreen) {
        if stageEnteredFullScreen, isFullScreen, presentation == .inline { hostWindow.window?.toggleFullScreen(nil) }
        coordinator.showDetached(on: screen, model: model, activate: true)
    }

    /// Whether the window draws its close/minimise/zoom buttons over the Stage's top-left corner.
    private static func showsTrafficLights(_ window: NSWindow) -> Bool {
        guard window.styleMask.contains(.titled), !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton) else { return false }
        return !close.isHiddenOrHasHiddenAncestor && close.alphaValue > 0
    }

    // MARK: Chrome auto-hide

    private func poke() {
        if !chromeVisible {
            withAnimation(QTTheme.Motion.chromeFade) { chromeVisible = true }
            applyTitlebarVisibility(animated: true)
        }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard player.isPlaying else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(QTTheme.Motion.chromeIdleDelay))
            guard !Task.isCancelled else { return }
            hideChromeIfIdle()
        }
    }

    private func hideChromeIfIdle() {
        guard player.isPlaying, chromeVisible else { return }
        // Keep the chrome while something it owns is open, or for VoiceOver users.
        let popoverOpen = NSApp.windows.contains { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
        if isQueueOpen || isAppearanceOpen || popoverOpen || menuTracking || NSWorkspace.shared.isVoiceOverEnabled {
            scheduleHide()
            return
        }
        withAnimation(QTTheme.Motion.chromeFade) { chromeVisible = false }
        applyTitlebarVisibility(animated: true)
        if hovering { NSCursor.setHiddenUntilMouseMoves(true) }
    }

    /// Fades the window's traffic lights with the chrome (never in full screen, where there are none).
    private func applyTitlebarVisibility(animated: Bool) {
        guard let window = hostWindow.window,
              let titlebar = window.standardWindowButton(.closeButton)?.superview else { return }
        let alpha: CGFloat = chromeVisible ? 1 : 0
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = QTTheme.Motion.chromeFadeDuration
                ctx.timingFunction = QTTheme.Motion.caTimingFunction
                titlebar.animator().alphaValue = alpha
            }
        } else {
            titlebar.alphaValue = alpha
        }
    }

    // MARK: Lifecycle

    private func didAppear() {
        if presentation == .inline, coordinator.isDetached {
            // ⇧⌘F / Open Stage while the Stage is on another display: bring it back into this window.
            coordinator.closeDetached()
        }
        withAnimation(QTTheme.Motion.animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.42), reduceMotion: reduceMotion)) {
            appeared = true
        }
        applyLaunchOptions()
        if chromeVisible { scheduleHide() }
    }

    private func didDisappear() {
        hideTask?.cancel()
        chromeVisible = true
        applyTitlebarVisibility(animated: false)
        if presentation == .inline { titlebar.uninstall() }
    }

    /// Inline: keep the window's traffic lights over the Stage (see `QTStageTitlebar`). Runs after SwiftUI has
    /// applied the main window's toolbar visibility for this update.
    private func installTitlebar() {
        DispatchQueue.main.async {
            guard let window = hostWindow.window else { hasTrafficLights = false; return }
            if presentation == .inline, model.surface == .stage { titlebar.install(in: window) }
            hasTrafficLights = Self.showsTrafficLights(window)
            trafficLightsMidY = QTStageTitlebar.trafficLightsMidY(in: window)
            applyTitlebarVisibility(animated: false)
        }
    }

    /// Applies the `qt.stage.*` launch arguments once per process (to whichever Stage shows first).
    private func applyLaunchOptions() {
        guard !QTStageLaunchState.applied else { return }
        let launch = model.launch
        if presentation == .inline, launch.bool("qt.stage.window") == true {
            // Move to its own window on the launch display; that Stage applies the remaining options.
            let hold = QTReadiness.shared.hold("stage window")
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                let screen = hostWindow.window?.screen ?? QTWindowPlacement.screen(named: launch.effectiveScreenName) ?? NSScreen.main
                if let screen { coordinator.showDetached(on: screen, model: model, activate: false) }
                try? await Task.sleep(for: .milliseconds(600))
                QTReadiness.shared.release(hold)
            }
            return
        }
        QTStageLaunchState.applied = true
        if launch.string("qt.stage.chrome") == "hidden" {
            chromeVisible = false
            DispatchQueue.main.async { applyTitlebarVisibility(animated: false) }
        }
        if launch.bool("qt.stage.queue") == true { isQueueOpen = true }
        if launch.bool("qt.stage.noAd") == true { dismissLaunchAd() }
        if let seconds = launch.double("qt.stage.closeAfter") {
            // Debug: verifies the window underneath comes back in its own appearance after the Stage closes.
            let hold = QTReadiness.shared.hold("stage closeAfter")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                closeStage()
                try? await Task.sleep(for: .milliseconds(700))
                QTReadiness.shared.release(hold)
            }
        }
        if launch.string("qt.stage.popover") == "appearance" {
            let hold = QTReadiness.shared.hold("stage popover")
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                isAppearanceOpen = true
                try? await Task.sleep(for: .milliseconds(400))
                QTReadiness.shared.release(hold)
            }
        }
    }
}

extension QTStageView {
    /// `qt.stage.noAd YES`: a free account without the pre-roll (the simulated engine plays one on every load), so
    /// free-account states such as the visualizer fallback can be seen on their own.
    fileprivate func dismissLaunchAd() {
        let hold = QTReadiness.shared.hold("stage noAd")
        Task { @MainActor in
            for _ in 0..<40 where player.ad == nil { try? await Task.sleep(for: .milliseconds(50)) }
            if let sim = player.engine as? QTSimulatedPlaybackEngine, sim.state.ad != nil {
                let account = sim.account
                sim.account = .premium   // ends the ad
                sim.account = account
                player.seek(to: model.launch.time ?? 31.5)
            }
            try? await Task.sleep(for: .milliseconds(200))
            QTReadiness.shared.release(hold)
        }
    }
}

@MainActor
enum QTStageLaunchState {
    static var applied = false
}

/// Weak holder so `@State` doesn't retain the window.
final class QTStageWeakWindow {
    weak var window: NSWindow?
}
