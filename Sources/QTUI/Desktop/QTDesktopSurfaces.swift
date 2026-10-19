import AppKit
import Observation
import QTCore
import SwiftUI

// Owner: builder "desktop". Stubs for the window-less surfaces: mini player (floating NSPanel, all Spaces),
// desktop lyrics (click-through NSPanel), menu bar popover content. None of them ever activates the app.

/// Keeps the AppKit panels in sync with `QTAppModel` (surface, desktop lyrics, `-qt.show`).
@MainActor
public final class QTDesktopCoordinator {
    public static let shared = QTDesktopCoordinator()

    private var model: QTAppModel?
    private var mini: NSPanel?
    private var lyrics: NSPanel?
    private var menuBarPopover: NSPanel?

    public func start(model: QTAppModel) {
        guard self.model == nil else { return }
        self.model = model
        observe()
    }

    private func observe() {
        withObservationTracking {
            sync()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func sync() {
        guard let model else { return }
        let extra = model.launch.extraWindows
        let showMini = model.surface == .mini || extra.contains(.mini)
        let showLyrics = model.isDesktopLyricsShown && model.surface != .stage
        mini = toggle(mini, show: showMini, id: .miniPlayer) {
            Self.makePanel(id: .miniPlayer, size: QTTheme.Metrics.miniCompact, clickThrough: false,
                           content: QTMiniPlayerView().environment(model).environment(model.player))
        } place: { QTWindowPlacement.placePanel($0, screenName: model.launch.effectiveScreenName, corner: .bottomRight) }
        lyrics = toggle(lyrics, show: showLyrics, id: .desktopLyrics) {
            Self.makePanel(id: .desktopLyrics, size: CGSize(width: 1100, height: 120), clickThrough: true,
                           content: QTDesktopLyricsView().environment(model).environment(model.player))
        } place: { QTWindowPlacement.placePanel($0, screenName: model.launch.effectiveScreenName, corner: .bottomCenter, inset: 120) }
        // Debug hook: the MenuBarExtra popover can't be opened without a click, so screenshots host its content here.
        menuBarPopover = toggle(menuBarPopover, show: extra.contains(.menuBarPopover), id: .menuBarPopover) {
            Self.makePanel(id: .menuBarPopover, size: CGSize(width: 300, height: 170), clickThrough: false,
                           backdrop: .popover, content: QTMenuBarContent().environment(model).environment(model.player))
        } place: { QTWindowPlacement.placePanel($0, screenName: model.launch.effectiveScreenName, corner: .topRight) }
    }

    private func toggle(_ panel: NSPanel?, show: Bool, id: QTWindowID, make: () -> NSPanel, place: (NSPanel) -> Void) -> NSPanel? {
        if show {
            let p = panel ?? { let p = make(); place(p); return p }()
            if !p.isVisible { p.orderFrontRegardless() }
            return p
        }
        panel?.orderOut(nil)
        return panel
    }

    /// Non-activating floating panel on all Spaces. Never becomes key unless clicked.
    /// - Parameter backdrop: system material behind the content (vibrancy), for content that doesn't draw its own surface.
    static func makePanel<Content: View>(id: QTWindowID, size: CGSize, clickThrough: Bool,
                                         backdrop: NSVisualEffectView.Material? = nil, content: Content) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: clickThrough ? [.borderless, .nonactivatingPanel] : [.borderless, .nonactivatingPanel, .resizable],
                            backing: .buffered, defer: false)
        panel.identifier = id.identifier
        panel.title = id.captureTitle
        panel.isFloatingPanel = true
        panel.level = clickThrough ? .statusBar : .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = !clickThrough
        panel.ignoresMouseEvents = clickThrough
        panel.isMovableByWindowBackground = !clickThrough
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: size)
        if let backdrop {
            let effect = NSVisualEffectView(frame: host.frame)
            effect.material = backdrop
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 12
            effect.layer?.masksToBounds = true
            host.autoresizingMask = [.width, .height]
            effect.addSubview(host)
            panel.contentView = effect
        } else {
            panel.contentView = host
        }
        return panel
    }
}

/// Compact mini player (320×64-ish strip): art · title/artist · prev/play/next.
public struct QTMiniPlayerView: View {
    @Environment(QTPlayerModel.self) private var player

    public init() {}

    public var body: some View {
        HStack(spacing: QTTheme.Spacing.s) {
            QTArtworkView(track: player.nowPlaying, cornerRadius: 0)
                .frame(width: QTTheme.Metrics.miniCompact.height, height: QTTheme.Metrics.miniCompact.height)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.ad != nil ? QTLoc.tr("Advertisement") : player.nowPlaying?.title ?? "")
                    .font(QTTheme.Typography.rowTitle).lineLimit(1)
                Text(player.nowPlaying?.artistLine ?? "").font(QTTheme.Typography.secondary)
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            QTTransportControls(style: .compact)
                .padding(.trailing, 14)
        }
        .frame(width: QTTheme.Metrics.miniCompact.width, height: QTTheme.Metrics.miniCompact.height)
        .qtFloatingSurface(RoundedRectangle(cornerRadius: 12, style: .continuous), material: .ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .environment(\.colorScheme, .dark)
        .help(QTLoc.tr("Double-click to switch size"))
        .accessibilityIdentifier("qt.miniPlayer")
    }
}

/// Click-through desktop lyrics (current line + translation).
public struct QTDesktopLyricsView: View {
    @Environment(QTPlayerModel.self) private var player

    public init() {}

    public var body: some View {
        QTLyricsView(document: player.ad == nil ? player.lyrics : nil, time: player.timeline, style: .desktop) { _ in }
            .shadow(color: .black.opacity(0.6), radius: 6, y: 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("qt.desktopLyrics")
    }
}

/// Menu bar popover: art, title, like, scrubber, prev/play/next, current lyric line.
public struct QTMenuBarContent: View {
    @Environment(QTPlayerModel.self) private var player

    public init() {}

    public var body: some View {
        VStack(spacing: QTTheme.Spacing.m) {
            HStack(spacing: QTTheme.Spacing.s) {
                QTArtworkView(track: player.nowPlaying, cornerRadius: 7)
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.nowPlaying?.title ?? "").font(QTTheme.Typography.rowTitle.weight(.semibold)).lineLimit(1)
                    Text(player.nowPlaying?.artistLine ?? "").font(QTTheme.Typography.secondary).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            QTScrubber()
            QTTransportControls(style: .compact)
        }
        .padding(QTTheme.Spacing.m)
        .frame(width: 300)
        .accessibilityIdentifier("qt.menuBarPopover")
    }
}

/// Menu bar item label: note glyph + title.
public struct QTMenuBarLabel: View {
    @Environment(QTPlayerModel.self) private var player

    public init() {}

    public var body: some View {
        Label(player.nowPlaying?.title ?? "QTube Music", systemImage: QTIcon.note.systemName)
    }
}
