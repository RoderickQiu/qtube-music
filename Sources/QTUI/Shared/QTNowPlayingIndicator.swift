import AppKit
import QTCore
import QuartzCore
import SwiftUI

// Added by builder "player". One answer to "which glyph marks the current track?" so the track tables, the Queue
// and Home agree: level bars that move while audio is actually playing, a still speaker while paused. Never a
// pause glyph — next to a track a pause glyph reads as the button you'd press, i.e. "playing".

public enum QTNowPlayingIndicator {
    /// SF Symbol for the paused marker (the playing marker is `QTNowPlayingBarsView`'s bars).
    public static let pausedSymbolName = "speaker.fill"

    /// VoiceOver label of the marker.
    public static func accessibilityLabel(isPlaying: Bool) -> String {
        isPlaying ? QTLoc.tr("Now Playing") : QTLoc.tr("Paused", table: .player)
    }
}

/// SwiftUI form of the marker (Queue, Home). An AppKit view underneath: the bars move with Core Animation, so a
/// playing marker costs the app no SwiftUI redraws (SwiftUI's own repeating effects re-render every display frame).
public struct QTNowPlayingGlyph: NSViewRepresentable {
    private let isPlaying: Bool
    private let pointSize: CGFloat
    private let weight: NSFont.Weight
    private let tint: NSColor

    public init(isPlaying: Bool, pointSize: CGFloat = 13, weight: NSFont.Weight = .semibold, tint: NSColor = .white) {
        self.isPlaying = isPlaying
        self.pointSize = pointSize
        self.weight = weight
        self.tint = tint
    }

    public func makeNSView(context: Context) -> QTNowPlayingBarsView {
        QTNowPlayingBarsView(pointSize: pointSize, weight: weight)
    }

    public func updateNSView(_ view: QTNowPlayingBarsView, context: Context) {
        view.pointSize = pointSize
        view.weight = weight
        view.tint = tint
        view.show(isPlaying: isPlaying, reduceMotion: context.environment.accessibilityReduceMotion)
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: QTNowPlayingBarsView, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

/// The now-playing marker: four rounded level bars rising and falling at their own pace while playing (a Core
/// Animation loop in the render server, paused when the view leaves its window), a still `speaker.fill` while
/// paused. With Reduce Motion the bars hold still at staggered heights. Takes no clicks.
public final class QTNowPlayingBarsView: NSView {
    public var tint: NSColor = .controlAccentColor { didSet { applyTint() } }
    public var pointSize: CGFloat { didSet { if pointSize != oldValue { configure() } } }
    public var weight: NSFont.Weight { didSet { if weight != oldValue { configure() } } }

    private let speaker = NSImageView()
    private let barsLayer = CALayer()
    private var bars: [CALayer] = []
    private var isPlaying = false
    private var reduceMotion = false
    private var didShow = false

    /// Per bar: keyframe heights (fractions of the full height) and a period, so the four never fall into step.
    private static let patterns: [(heights: [CGFloat], period: CFTimeInterval)] = [
        ([0.35, 0.9, 0.5, 1.0, 0.3, 0.7, 0.35], 1.30),
        ([0.8, 0.35, 1.0, 0.45, 0.85, 0.3, 0.8], 1.05),
        ([0.5, 1.0, 0.3, 0.75, 0.55, 0.95, 0.5], 1.45),
        ([0.9, 0.45, 0.7, 0.3, 1.0, 0.6, 0.9], 1.18),
    ]
    /// Still heights for Reduce Motion: clearly bars, clearly not the speaker.
    private static let stillHeights: [CGFloat] = [0.55, 1.0, 0.7, 0.4]
    private static let spinKey = "qt.nowPlaying.bars"

    public init(pointSize: CGFloat = 13, weight: NSFont.Weight = .semibold) {
        self.pointSize = pointSize
        self.weight = weight
        super.init(frame: .zero)
        wantsLayer = true
        speaker.imageScaling = .scaleNone
        speaker.image = NSImage(systemSymbolName: QTNowPlayingIndicator.pausedSymbolName, accessibilityDescription: nil)
        speaker.setAccessibilityElement(false)
        speaker.translatesAutoresizingMaskIntoConstraints = false
        addSubview(speaker)
        NSLayoutConstraint.activate([
            speaker.centerXAnchor.constraint(equalTo: centerXAnchor),
            speaker.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        barsLayer.actions = ["position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(barsLayer)
        for _ in 0..<4 {
            let bar = CALayer()
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            bar.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull(), "transform": NSNull()]
            barsLayer.addSublayer(bar)
            bars.append(bar)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        configure()
        show(isPlaying: false, reduceMotion: false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Bars as tall as the symbol's cap height at `pointSize`, about as wide as the speaker glyph.
    override public var intrinsicContentSize: NSSize {
        NSSize(width: ceil(pointSize * 1.25), height: ceil(pointSize * 1.15))
    }

    public func show(isPlaying: Bool, reduceMotion: Bool) {
        let changed = !didShow || isPlaying != self.isPlaying || reduceMotion != self.reduceMotion
        didShow = true
        self.isPlaying = isPlaying
        self.reduceMotion = reduceMotion
        setAccessibilityLabel(QTNowPlayingIndicator.accessibilityLabel(isPlaying: isPlaying))
        guard changed else { return }
        speaker.isHidden = isPlaying
        barsLayer.isHidden = !isPlaying
        updateAnimation()
    }

    private func configure() {
        speaker.symbolConfiguration = .init(pointSize: pointSize, weight: weight)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func applyTint() {
        speaker.contentTintColor = tint
        let color = tint.usingColorSpace(.sRGB)?.cgColor ?? tint.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars { bar.backgroundColor = color }
        CATransaction.commit()
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyTint() }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimation()
    }

    override public func layout() {
        super.layout()
        let height = min(bounds.height, ceil(pointSize * 0.95))
        let barWidth = max(2, (pointSize * 0.17).rounded(.toNearestOrAwayFromZero))
        let gap = max(1.5, barWidth * 0.75)
        let total = barWidth * 4 + gap * 3
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barsLayer.frame = CGRect(x: (bounds.width - total) / 2, y: (bounds.height - height) / 2, width: total, height: height)
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: height)
            bar.position = CGPoint(x: CGFloat(i) * (barWidth + gap) + barWidth / 2, y: 0)
            bar.cornerRadius = barWidth / 2
        }
        CATransaction.commit()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyTint() }
        updateAnimation()
    }

    private func updateAnimation() {
        let animates = isPlaying && !reduceMotion && window != nil
        for (i, bar) in bars.enumerated() {
            let pattern = Self.patterns[i]
            if animates {
                guard bar.animation(forKey: Self.spinKey) == nil else { continue }
                let anim = CAKeyframeAnimation(keyPath: "transform.scale.y")
                anim.values = pattern.heights
                anim.calculationMode = .cubic
                anim.duration = pattern.period
                anim.repeatCount = .infinity
                anim.isRemovedOnCompletion = false
                anim.timeOffset = pattern.period * Double(i) * 0.37
                bar.add(anim, forKey: Self.spinKey)
            } else {
                bar.removeAnimation(forKey: Self.spinKey)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                bar.transform = CATransform3DMakeScale(1, Self.stillHeights[i], 1)
                CATransaction.commit()
            }
        }
    }
}
