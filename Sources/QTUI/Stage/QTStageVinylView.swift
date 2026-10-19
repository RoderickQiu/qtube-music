import AppKit
import QTCore
import QuartzCore
import SwiftUI

/// Vinyl: the cover is the record's label; the record spins while playing (Core Animation, paused in place),
/// the light sheen stays still like a real reflection, and the tonearm swings onto the record with a spring
/// on play and lifts away on pause. Reduce Motion: no spin, the arm moves without the swing.
struct QTStageVinylView: View {
    let track: QTTrack?
    let size: CGFloat
    let isPlaying: Bool
    let policy: QTStageMotionPolicy

    /// How far the turntable reaches past the record's right edge, as a fraction of the record's diameter: the
    /// tonearm at rest (lifted, swung out by 26°) — headshell plus a little shadow. Layouts reserve it so the arm
    /// stays inside the art column (prototype geometry: the headshell ends 125 of 460 units past the record).
    static let armReach: CGFloat = 0.28

    @Environment(\.displayScale) private var displayScale
    @State private var label: CGImage?

    var body: some View {
        let lifted = !isPlaying
        let pivot = UnitPoint(x: 112.0 / 150, y: 34.0 / 300)
        ZStack {
            // Ambient shadow (wide) + contact shadow (tight), like a record lying on a platter.
            Circle()
                .fill(Color.black)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.55), radius: 36, y: 30)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            QTStageVinylDisc(label: label, spinning: isPlaying && policy.allowsSpin, displayScale: displayScale)
                .frame(width: size, height: size)
            // `.record::after`: a sheen that stays still while the record turns, like a real reflection. Only the
            // grooves catch it, not the paper label.
            Circle()
                .fill(AngularGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.1), location: 0.07),
                    .init(color: .white.opacity(0.025), location: 0.14),
                    .init(color: .clear, location: 0.2),
                    .init(color: .clear, location: 0.5),
                    .init(color: .white.opacity(0.075), location: 0.57),
                    .init(color: .white.opacity(0.02), location: 0.64),
                    .init(color: .clear, location: 0.7),
                    .init(color: .clear, location: 1),
                ], center: .center, angle: .degrees(30 - 90)))
                .mask {
                    Circle().fill(RadialGradient(stops: [
                        .init(color: .clear, location: 0.37), .init(color: .black, location: 0.43),
                        .init(color: .black, location: 0.97), .init(color: .clear, location: 1),
                    ], center: .center, startRadius: 0, endRadius: size / 2))
                }
                .frame(width: size, height: size)
                .allowsHitTesting(false)
            // Rim catching the top-left key light.
            Circle()
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.18), .clear, .clear, .white.opacity(0.05)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                .frame(width: size, height: size)
            // Polished steel spindle.
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.96), Color(white: 0.56), Color(white: 0.28)],
                                     center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.018))
                .frame(width: size * 0.028, height: size * 0.028)
                .shadow(color: .black.opacity(0.55), radius: 1.5, y: 1)
            // The arm lifts before it swings away: its shadow grows softer and falls further on pause.
            QTStageTonearm()
                .frame(width: size * 150 / 460, height: size * 300 / 460)
                .shadow(color: .black.opacity(lifted ? 0.26 : 0.45), radius: lifted ? 14 : 5,
                        x: lifted ? -10 : -3, y: lifted ? 18 : 7)
                .scaleEffect(lifted && !policy.reduceMotion ? 1.012 : 1, anchor: pivot)
                .rotationEffect(.degrees(lifted ? -26 : 0), anchor: pivot)
                .animation(policy.reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.9, dampingFraction: 0.72),
                           value: isPlaying)
                .offset(x: size / 2 + size * (64 - 75) / 460, y: -size / 2 + size * (-40 + 150) / 460)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: track?.videoId) {
            guard let url = track?.artwork.best(forPixelWidth: Int(size * 0.4 * displayScale))?.url else { label = nil; return }
            let hold = QTReadiness.shared.hold("stage vinyl label")
            label = await QTImageLoader.shared.image(at: url, maxPixel: Int(size * 0.4 * displayScale))
            QTReadiness.shared.release(hold)
        }
    }
}

/// The record itself: grooves rendered once into a bitmap, the cover as a round label, rotated by Core Animation.
struct QTStageVinylDisc: NSViewRepresentable {
    let label: CGImage?
    let spinning: Bool
    let displayScale: CGFloat

    func makeNSView(context: Context) -> QTStageVinylDiscNSView { QTStageVinylDiscNSView() }

    func updateNSView(_ view: QTStageVinylDiscNSView, context: Context) {
        view.update(label: label, spinning: spinning, scale: displayScale)
    }
}

final class QTStageVinylDiscNSView: NSView {
    private let disc = CALayer()
    private let labelLayer = CALayer()
    private var spinning = false
    private var renderedSize: CGFloat = 0
    private var scale: CGFloat = 2
    /// One revolution (prototype `spin 7s linear infinite`): calm rather than a literal 33⅓ rpm.
    private let period: CFTimeInterval = 7

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        disc.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        labelLayer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        labelLayer.masksToBounds = true
        labelLayer.contentsGravity = .resizeAspectFill
        disc.addSublayer(labelLayer)
        layer?.addSublayer(disc)
        disc.speed = 0
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(label: CGImage?, spinning: Bool, scale: CGFloat) {
        self.scale = scale
        if (labelLayer.contents as AnyObject?) !== label {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.5)
            labelLayer.contents = label
            CATransaction.commit()
        }
        setSpinning(spinning)
    }

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        disc.position = CGPoint(x: bounds.midX, y: bounds.midY)
        disc.cornerRadius = side / 2
        let labelSide = side * 0.38
        labelLayer.frame = CGRect(x: (side - labelSide) / 2, y: (side - labelSide) / 2, width: labelSide, height: labelSide)
        labelLayer.cornerRadius = labelSide / 2
        if abs(side - renderedSize) > 1 {
            renderedSize = side
            disc.contentsScale = scale
            disc.contents = Self.grooves(side: side, scale: scale)
        }
        CATransaction.commit()
        if disc.animation(forKey: "qt.stage.vinyl.spin") == nil {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi   // clockwise on screen
            spin.duration = period
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            disc.add(spin, forKey: "qt.stage.vinyl.spin")
        }
    }

    private func setSpinning(_ on: Bool) {
        guard on != spinning else { return }
        spinning = on
        if on {
            let pausedAt = disc.timeOffset
            disc.speed = 1
            disc.timeOffset = 0
            disc.beginTime = 0
            disc.beginTime = disc.convertTime(CACurrentMediaTime(), from: nil) - pausedAt
        } else {
            let now = disc.convertTime(CACurrentMediaTime(), from: nil)
            disc.speed = 0
            disc.timeOffset = now
        }
    }

    /// `.record`: dark centre, fine concentric grooves, a dark rim — drawn once per size.
    private static func grooves(side: CGFloat, scale: CGFloat) -> CGImage? {
        let px = Int(side * scale)
        guard px > 0, let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let r = CGFloat(px) / 2
        let c = CGPoint(x: r, y: r)
        func circle(_ radius: CGFloat, _ gray: CGFloat) {
            ctx.setFillColor(CGColor(gray: gray, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
        }
        circle(r, 0.04)                                   // rim (inset 8px #0a0a0a)
        let grooveOuter = r - 8 * scale * (side / 460)
        // Grooves: 3 px period (2 px #151515, 1 px #0b0b0b) in prototype units.
        let period = 3 * scale * (side / 460)
        var radius = grooveOuter
        var rng = QTStageSeededRandom(seed: 7)
        while radius > r * 0.36 {
            let jitter = CGFloat(rng.next() % 1000) / 1000 * 0.012
            circle(radius, 0.082 + jitter)
            circle(radius - period * 2 / 3, 0.043)
            radius -= period
        }
        // Lead-in and run-out bands catch a little more light.
        ctx.setStrokeColor(CGColor(gray: 0.13, alpha: 1))
        ctx.setLineWidth(1.2 * scale)
        for band in [grooveOuter - period * 2, r * 0.62, r * 0.4] {
            ctx.strokeEllipse(in: CGRect(x: c.x - band, y: c.y - band, width: band * 2, height: band * 2))
        }
        circle(r * 0.33, 0.067)                           // centre #111
        // Spindle hole.
        ctx.setBlendMode(.clear)
        circle(r * 0.018, 0)
        return ctx.makeImage()
    }
}
