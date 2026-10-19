import QTCore
import SwiftUI

/// Loads a Core Image–processed version of an artwork image (see `QTStageImageProcessor`) and hands it to `content`.
/// Holds launch readiness while loading so screenshots never catch a half-drawn Stage.
struct QTStageProcessedImage<Content: View>: View {
    let images: [QTArtworkImage]
    let look: QTStageImageProcessor.Look
    @ViewBuilder let content: (CGImage?) -> Content

    @State private var image: CGImage?

    private var url: URL? { images.best(forPixelWidth: look.sourcePixels)?.url }

    var body: some View {
        content(image)
            .task(id: url.map { "\(look.rawValue)|\($0.absoluteString)" }) {
                guard let url else { image = nil; return }
                let hold = QTReadiness.shared.hold("stage \(look.rawValue)")
                let loaded = await QTStageImageProcessor.shared.image(for: url, look: look)
                QTReadiness.shared.release(hold)
                guard !Task.isCancelled else { return }
                image = loaded
            }
    }
}

/// Tiled film grain; `opacity` per background (cover .2, blur .05). Overlay blend keeps it neutral.
struct QTStageGrain: View {
    var opacity: Double

    var body: some View {
        if let grain = QTStageImageProcessor.grain {
            Image(decorative: grain, scale: 2)
                .resizable(resizingMode: .tile)
                .blendMode(.overlay)
                .opacity(opacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The five Stage backgrounds. Purely decorative (hidden from VoiceOver, no hit testing).
struct QTStageBackgroundView: View {
    let track: QTTrack?
    let appearance: QTStageResolvedAppearance
    let isPlaying: Bool
    let policy: QTStageMotionPolicy
    let accent: Color

    var body: some View {
        ZStack {
            QTTheme.Colors.stageBase(track?.palette)
            switch appearance.background {
            case .blur, .vinyl, .visualizer:
                blurredArt
                if appearance.background == .visualizer {
                    QTStageVisualizerView(palette: track?.palette, accent: accent, isPlaying: isPlaying, policy: policy)
                        .accessibilityIdentifier("qt.stage.visualizer")
                }
            case .cover:
                fullBleedCover
            case .video:
                QTStageVideoSurface(track: track, isPlaying: isPlaying, policy: policy)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .accessibilityIdentifier("qt.stage.background.\(appearance.background.rawValue)")
    }

    // MARK: Blurred art (default; also under vinyl and the visualizer)

    private var blurredArt: some View {
        // During an ad the background stays the song's own blurred art (the art slot carries the ad card); only
        // the drift stops, so nothing on screen pretends the song is playing.
        QTStageProcessedImage(images: track?.artwork ?? [], look: .blurredArt) { image in
            ZStack {
                QTStageLayerImage(image: image, isRunning: isPlaying, baseScale: 1.15, overscan: 120)
                if policy.allowsAmbientDrift && !appearance.isAd {
                    QTStageLayerImage(image: image, motion: .drift, isRunning: isPlaying, baseScale: 1.15,
                                      overscan: 120, opacity: 0.3)
                }
                Color.black.opacity(0.12)
                QTStageGrain(opacity: 0.05)
            }
        }
    }

    // MARK: Full-bleed cover — frosted toward the lyrics + grain, never a raw upscaled image

    private var fullBleedCover: some View {
        let art = track?.artwork ?? []
        return ZStack {
            QTStageProcessedImage(images: art, look: .coverSoft) { image in
                QTStageLayerImage(image: image, overscan: 24)
            }
            QTStageProcessedImage(images: art, look: .coverFrost) { image in
                QTStageLayerImage(image: image, overscan: 24)
                    .mask {
                        LinearGradient(stops: [
                            .init(color: .black.opacity(0.35), location: 0),
                            .init(color: .black.opacity(0.5), location: 0.28),
                            .init(color: .black, location: 0.52),
                        ], startPoint: .leading, endPoint: .trailing)
                    }
            }
            QTStageGrain(opacity: 0.2)
            LinearGradient(stops: [
                .init(color: .black.opacity(0.35), location: 0),
                .init(color: .clear, location: 0.22),
                .init(color: .clear, location: 0.7),
                .init(color: .black.opacity(0.55), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// The music video surface. M1 shows the MV still with a slow Ken Burns; from M5 the playback layer hands in a
/// live video (an `AVPlayerLayer` for the native engine, or the web engine's video view) through
/// `QTStageVideoSurfaceProvider`, without touching the Stage layout. The scrims stay on top either way.
struct QTStageVideoSurface: View {
    let track: QTTrack?
    let isPlaying: Bool
    let policy: QTStageMotionPolicy

    private var stillImages: [QTArtworkImage] {
        let still = track?.videoArtwork ?? []
        return still.isEmpty ? (track?.artwork ?? []) : still
    }

    var body: some View {
        ZStack {
            if let live = QTStageVideoSurfaceProvider.shared.surface(for: track) {
                QTStageHostedVideo(surface: live)
            } else {
                QTStageProcessedImage(images: stillImages, look: .videoStill) { image in
                    QTStageLayerImage(image: image, motion: policy.allowsAmbientDrift ? .kenBurns : .none,
                                      isRunning: isPlaying, overscan: 16)
                }
            }
            QTStageVideoScrims()
        }
    }
}

/// Top and bottom scrims over the music video so the chrome, scrubber, transport and lyric overlay stay legible on
/// any frame (bright sets, burned-in titles). Smoothstep ramps, so there is no visible band edge; the middle of
/// the frame stays untouched.
struct QTStageVideoScrims: View {
    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            VStack(spacing: 0) {
                LinearGradient(stops: Self.ramp(to: 0.6, steps: 8, reversed: true), startPoint: .top, endPoint: .bottom)
                    .frame(height: h * 0.24)
                Spacer(minLength: 0)
                LinearGradient(stops: Self.ramp(to: 0.92, steps: 10, reversed: false), startPoint: .top, endPoint: .bottom)
                    .frame(height: h * 0.5)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Clear → black at `opacity` along a smoothstep curve (or black → clear when `reversed`).
    static func ramp(to opacity: Double, steps: Int, reversed: Bool) -> [Gradient.Stop] {
        (0...steps).map { i in
            let t = Double(i) / Double(steps)
            let x = reversed ? 1 - t : t
            let e = x * x * (3 - 2 * x)
            return .init(color: .black.opacity(opacity * e), location: t)
        }
    }
}

/// A live music-video surface handed in by the playback layer.
public enum QTStageVideoSurfaceKind {
    /// A layer to host and resize to fill, e.g. `AVPlayerLayer` (native engine, M5).
    case layer(CALayer)
    /// A view to host, e.g. the web engine's video element container. It's moved into the Stage while shown.
    case view(NSView)
}

/// Hook for live video on the Stage (M5). The playback layer sets `source` once at startup; while it returns nil
/// (M1, or a track without video), the Stage shows the music-video still with a slow Ken Burns.
@MainActor
public final class QTStageVideoSurfaceProvider {
    public static let shared = QTStageVideoSurfaceProvider()

    /// Returns the live video for `track`, or nil to fall back to the still.
    public var source: ((QTTrack?) -> QTStageVideoSurfaceKind?)?

    private init() {}

    func surface(for track: QTTrack?) -> QTStageVideoSurfaceKind? { source?(track) }
}

/// Hosts an externally owned video layer or view, resized to fill, never taking clicks.
struct QTStageHostedVideo: NSViewRepresentable {
    let surface: QTStageVideoSurfaceKind

    func makeNSView(context: Context) -> QTStageHostedVideoNSView { QTStageHostedVideoNSView() }

    func updateNSView(_ nsView: QTStageHostedVideoNSView, context: Context) { nsView.host(surface) }
}

final class QTStageHostedVideoNSView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func host(_ surface: QTStageVideoSurfaceKind) {
        switch surface {
        case .layer(let video):
            subviews.forEach { $0.removeFromSuperview() }
            if video.superlayer !== layer {
                layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
                layer?.addSublayer(video)
            }
        case .view(let video):
            if video.superview !== self {
                subviews.forEach { $0.removeFromSuperview() }
                addSubview(video)
            }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        subviews.forEach { $0.frame = bounds }
        if subviews.isEmpty { layer?.sublayers?.forEach { $0.frame = bounds } }
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
