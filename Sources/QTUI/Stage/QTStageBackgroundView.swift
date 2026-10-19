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
                    QTStageVisualizerView(accent: accent, isPlaying: isPlaying, policy: policy)
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
        let look: QTStageImageProcessor.Look = appearance.isDimmedForAd ? .blurredArtDimmed : .blurredArt
        return QTStageProcessedImage(images: track?.artwork ?? [], look: look) { image in
            ZStack {
                QTStageLayerImage(image: image, isRunning: isPlaying, baseScale: 1.15, overscan: 120)
                if policy.allowsAmbientDrift && !appearance.isDimmedForAd {
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

/// The music video surface. M1 shows the MV still with a slow Ken Burns; the playback builder can hand in a
/// live video layer later (AVPlayerLayer / the web engine's video) through `QTStageVideoLayerProvider` without
/// touching the Stage layout.
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
            if let provider = QTStageVideoLayerProvider.current, let layer = provider(track) {
                QTStageHostedLayer(layer: layer)
            } else {
                QTStageProcessedImage(images: stillImages, look: .videoStill) { image in
                    QTStageLayerImage(image: image, motion: policy.allowsAmbientDrift ? .kenBurns : .none,
                                      isRunning: isPlaying, overscan: 16)
                }
            }
            // `.st-bg .shade`: legible chrome on top, lyrics overlay on the bottom.
            LinearGradient(stops: [
                .init(color: .black.opacity(0.55), location: 0),
                .init(color: .clear, location: 0.24),
                .init(color: .clear, location: 0.4),
                .init(color: .black.opacity(0.7), location: 0.7),
                .init(color: .black.opacity(0.9), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// Hook for a live video layer (M5). Set once at startup by the playback layer; nil in M1.
@MainActor
public enum QTStageVideoLayerProvider {
    /// Returns a CALayer (e.g. `AVPlayerLayer`) showing the given track's video, or nil to fall back to the still.
    public static var current: ((QTTrack?) -> CALayer?)?
}

/// Hosts an externally owned CALayer, resized to fill.
struct QTStageHostedLayer: NSViewRepresentable {
    let layer: CALayer

    func makeNSView(context: Context) -> NSView {
        let view = QTStageHostedLayerNSView()
        view.wantsLayer = true
        view.layer?.addSublayer(layer)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if layer.superlayer !== nsView.layer {
            nsView.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
            nsView.layer?.addSublayer(layer)
            nsView.needsLayout = true
        }
    }
}

final class QTStageHostedLayerNSView: NSView {
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.sublayers?.forEach { $0.frame = bounds }
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
