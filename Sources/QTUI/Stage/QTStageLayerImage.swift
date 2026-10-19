import AppKit
import QuartzCore
import SwiftUI

/// Slow ambient motion for Stage layers. All of it runs in the render server (Core Animation), so the app's main
/// thread does no per-frame work, and it pauses in place (not reset) when playback pauses.
enum QTStageLayerMotion: Equatable {
    case none
    /// Blurred-art drift: scale 1.15 → 1.35, rotate 14°, 38 s, alternating (`@keyframes drift`).
    case drift
    /// Music-video still: scale 1 → 1.08 with a small pan, 30 s, ease in-out, alternating (`@keyframes kenburns`).
    case kenBurns
}

/// A CALayer-backed image with optional ambient motion. Used for the Stage backgrounds.
struct QTStageLayerImage: NSViewRepresentable {
    var image: CGImage?
    var motion: QTStageLayerMotion = .none
    /// Animation clock runs only while true (playing).
    var isRunning: Bool = true
    /// Static scale applied when there's no motion (the blurred layer overscans like `inset: -120px; scale(1.15)`).
    var baseScale: CGFloat = 1
    var overscan: CGFloat = 0
    var opacity: Float = 1
    var crossfade: TimeInterval = 0.9

    func makeNSView(context: Context) -> QTStageLayerImageNSView { QTStageLayerImageNSView() }

    func updateNSView(_ view: QTStageLayerImageNSView, context: Context) {
        view.configure(image: image, motion: motion, isRunning: isRunning, baseScale: baseScale,
                       overscan: overscan, opacity: opacity, crossfade: crossfade)
    }
}

final class QTStageLayerImageNSView: NSView {
    private let content = CALayer()
    private var motion: QTStageLayerMotion = .none
    private var baseScale: CGFloat = 1
    private var overscan: CGFloat = 0
    private var running = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        content.contentsGravity = .resizeAspectFill
        content.minificationFilter = .linear
        content.magnificationFilter = .linear
        content.actions = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull()]
        layer?.addSublayer(content)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // Purely decorative: let clicks and hover fall through to SwiftUI.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(image: CGImage?, motion: QTStageLayerMotion, isRunning: Bool, baseScale: CGFloat,
                   overscan: CGFloat, opacity: Float, crossfade: TimeInterval) {
        CATransaction.begin()
        if running && isRunning && content.contents != nil && crossfade > 0 {
            CATransaction.setAnimationDuration(crossfade)
            CATransaction.setAnimationTimingFunction(QTTheme.Motion.caTimingFunction)
        } else {
            CATransaction.setDisableActions(true)
        }
        if (content.contents as AnyObject?) !== image { content.contents = image }
        content.opacity = opacity
        CATransaction.commit()

        let geometryChanged = baseScale != self.baseScale || overscan != self.overscan
        self.baseScale = baseScale
        self.overscan = overscan
        if motion != self.motion || content.animation(forKey: "qt.stage.motion") == nil && motion != .none {
            self.motion = motion
            installMotion()
        }
        if geometryChanged { needsLayout = true }
        setRunning(isRunning)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds.insetBy(dx: -overscan, dy: -overscan)
        content.bounds = CGRect(origin: .zero, size: b.size)
        content.position = CGPoint(x: bounds.midX, y: bounds.midY)
        content.transform = CATransform3DMakeScale(baseScale, baseScale, 1)
        CATransaction.commit()
        if motion == .kenBurns { installMotion() }  // pan distance depends on size
    }

    private func installMotion() {
        content.removeAnimation(forKey: "qt.stage.motion")
        let group = CAAnimationGroup()
        switch motion {
        case .none:
            return
        case .drift:
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = baseScale
            scale.toValue = baseScale * 1.35 / 1.15
            let rotate = CABasicAnimation(keyPath: "transform.rotation.z")
            rotate.fromValue = 0
            rotate.toValue = 14 * Double.pi / 180
            group.animations = [scale, rotate]
            group.duration = 38
            group.timingFunction = CAMediaTimingFunction(name: .linear)
        case .kenBurns:
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = baseScale
            scale.toValue = baseScale * 1.08
            let pan = CABasicAnimation(keyPath: "transform.translation")
            pan.fromValue = NSValue(size: .zero)
            pan.toValue = NSValue(size: CGSize(width: -0.015 * bounds.width, height: 0.01 * bounds.height))
            group.animations = [scale, pan]
            group.duration = 30
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        }
        group.autoreverses = true
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        content.add(group, forKey: "qt.stage.motion")
    }

    /// Pauses/resumes the layer clock in place (classic CA pause: speed 0 + timeOffset).
    private func setRunning(_ run: Bool) {
        guard run != running else { return }
        running = run
        if run {
            let pausedAt = content.timeOffset
            content.speed = 1
            content.timeOffset = 0
            content.beginTime = 0
            content.beginTime = content.convertTime(CACurrentMediaTime(), from: nil) - pausedAt
        } else {
            let now = content.convertTime(CACurrentMediaTime(), from: nil)
            content.speed = 0
            content.timeOffset = now
        }
    }
}
