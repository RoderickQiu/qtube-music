import AppKit
import QTCore
import QTPlayback
import SwiftUI

// Owner: builder "stage-video" (M5). Where the real music video shows: the docked panel's hero (the video
// replaces the artwork) and the Stage's Video background. One player page means one video; the slots share it.

/// A place that can show the music video. When several are on screen the higher one gets it (the Stage covers
/// the panel; a detached Stage outranks the main window's panel).
public enum QTVideoSlotKind: Int, Comparable, Sendable {
    case panel = 0
    case stage = 1

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// The live music video in a slot, with `placeholder` (artwork or the MV still) on top until the video's first
/// frame is really there; then the placeholder crossfades away. Switching back to the song fades the placeholder
/// in before the video leaves. During ads, in Picture in Picture and with the simulated engine it simply shows
/// the placeholder (with a quiet PiP glyph while the video floats).
struct QTLiveVideoView<Placeholder: View>: View {
    let kind: QTVideoSlotKind
    var cornerRadius: CGFloat = 0
    @ViewBuilder var placeholder: () -> Placeholder

    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let output = QTVideoModeService.shared.videoOutput
        let inPiP = output?.isPictureInPictureActive ?? false
        let wants = output != nil && model.isVideoMode && player.mode == .video && player.ad == nil && !inPiP
        let showsVideo = wants && (output?.hasFrame ?? false)
        ZStack {
            Color.black
            if output != nil {
                QTVideoSlotHost(kind: kind, wantsVideo: wants, cornerRadius: cornerRadius)
            }
            placeholder()
                .opacity(showsVideo ? 0 : 1)
                .allowsHitTesting(false)
            if inPiP {
                Image(systemName: "pip")
                    .font(.system(size: kind == .stage ? 44 : 18, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.4), radius: 6)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .animation(QTTheme.Motion.animation(.easeInOut(duration: QTVideoSlotHost.crossfade), reduceMotion: reduceMotion), value: showsVideo)
        .animation(QTTheme.Motion.animation(QTTheme.Motion.ui, reduceMotion: reduceMotion), value: inPiP)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(QTLoc.tr("Music video"))
        .accessibilityIdentifier("qt.video.\(kind == .stage ? "stage" : "panel")")
    }
}

/// Hosts the engine's web view while this slot is the one showing the video.
struct QTVideoSlotHost: NSViewRepresentable {
    /// Placeholder ⇄ video crossfade, seconds.
    static let crossfade: Double = 0.32

    let kind: QTVideoSlotKind
    let wantsVideo: Bool
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> QTVideoSlotNSView { QTVideoSlotNSView(kind: kind) }

    func updateNSView(_ view: QTVideoSlotNSView, context: Context) {
        view.cornerRadius = cornerRadius
        view.setWantsVideo(wantsVideo)
    }

    static func dismantleNSView(_ view: QTVideoSlotNSView, coordinator: ()) {
        view.setWantsVideo(false, immediately: true)
        QTVideoSlotCoordinator.shared.unregister(view)
    }
}

/// The AppKit container the web view moves into. Black, clipped, never takes clicks or VoiceOver.
final class QTVideoSlotNSView: NSView {
    let kind: QTVideoSlotKind
    private(set) var wantsVideo = false
    private var releaseWork: DispatchWorkItem?
    private var windowObservers: [NSObjectProtocol] = []
    var cornerRadius: CGFloat = 0 {
        didSet { if cornerRadius != oldValue { layer?.cornerRadius = cornerRadius } }
    }

    init(kind: QTVideoSlotKind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Whether this slot is in a visible window and wants the video right now.
    var isEligible: Bool {
        guard wantsVideo, let window, window.isVisible, !window.isMiniaturized, !isHiddenOrHasHiddenAncestor,
              bounds.width >= 8, bounds.height >= 8 else { return false }
        return true
    }

    func setWantsVideo(_ wants: Bool, immediately: Bool = false) {
        releaseWork?.cancel()
        releaseWork = nil
        if wants || immediately {
            guard wants != wantsVideo || immediately else { return QTVideoSlotCoordinator.shared.reassign() }
            wantsVideo = wants
            QTVideoSlotCoordinator.shared.reassign()
            return
        }
        guard wantsVideo else { return }
        // Let the placeholder fade in over the last frames before the video leaves.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.wantsVideo = false
            QTVideoSlotCoordinator.shared.reassign()
        }
        releaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + QTVideoSlotHost.crossfade + 0.05, execute: work)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        if let window {
            QTVideoSlotCoordinator.shared.register(self)
            let names: [Notification.Name] = [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                                              NSWindow.willCloseNotification, NSWindow.didChangeOcclusionStateNotification,
                                              NSWindow.didChangeBackingPropertiesNotification]
            windowObservers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { QTVideoSlotCoordinator.shared.reassign() }
                }
            }
        } else {
            QTVideoSlotCoordinator.shared.unregister(self)
        }
        QTVideoSlotCoordinator.shared.reassign()
    }

    override func layout() {
        super.layout()
        if let output = QTVideoModeService.shared.videoOutput, output.container === self {
            // Size changes pick the rendition that fits.
            output.present(in: self)
        } else if isEligible {
            QTVideoSlotCoordinator.shared.reassign()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }
}

/// Decides which slot shows the one video (or none: the hidden host, 144p).
@MainActor
final class QTVideoSlotCoordinator {
    static let shared = QTVideoSlotCoordinator()

    private final class Entry {
        weak var view: QTVideoSlotNSView?
        let order: Int
        init(_ view: QTVideoSlotNSView, order: Int) {
            self.view = view
            self.order = order
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var counter = 0

    func register(_ view: QTVideoSlotNSView) {
        let id = ObjectIdentifier(view)
        guard entries[id] == nil else { return }
        counter += 1
        entries[id] = Entry(view, order: counter)
    }

    func unregister(_ view: QTVideoSlotNSView) {
        entries[ObjectIdentifier(view)] = nil
        if let output = QTVideoModeService.shared.videoOutput, output.container === view { output.withdraw(from: view) }
        reassign()
    }

    /// Highest slot kind wins, then the most recently shown one.
    func reassign() {
        entries = entries.filter { $0.value.view != nil }
        guard let output = QTVideoModeService.shared.videoOutput else { return }
        var best: (view: QTVideoSlotNSView, order: Int)?
        for entry in entries.values {
            guard let view = entry.view, view.isEligible else { continue }
            if let b = best, b.view.kind > view.kind || (b.view.kind == view.kind && b.order > entry.order) { continue }
            best = (view, entry.order)
        }
        if let best {
            if output.container !== best.view { output.present(in: best.view) }
        } else if let current = output.container {
            output.withdraw(from: current)
        }
    }
}
