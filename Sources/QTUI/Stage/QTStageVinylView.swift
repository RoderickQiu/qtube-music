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

    @Environment(\.displayScale) private var displayScale
    @State private var label: CGImage?

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.6), radius: 35, y: 30)
            QTStageVinylDisc(label: label, spinning: isPlaying && policy.allowsSpin, displayScale: displayScale)
                .frame(width: size, height: size)
            Circle()
                .fill(Color(white: 0.05))
                .frame(width: size * 0.024, height: size * 0.024)
            // `.record::after`: conic sheen that doesn't rotate with the record.
            Circle()
                .fill(AngularGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.07), location: 0.08),
                    .init(color: .clear, location: 0.18),
                    .init(color: .clear, location: 0.5),
                    .init(color: .white.opacity(0.05), location: 0.58),
                    .init(color: .clear, location: 0.68),
                    .init(color: .clear, location: 1),
                ], center: .center, angle: .degrees(30 - 90)))
                .frame(width: size, height: size)
                .allowsHitTesting(false)
            QTStageTonearm()
                .frame(width: size * 150 / 460, height: size * 300 / 460)
                .rotationEffect(.degrees(isPlaying ? 0 : -26), anchor: UnitPoint(x: 112.0 / 150, y: 34.0 / 300))
                .animation(policy.reduceMotion ? nil : .spring(response: 0.9, dampingFraction: 0.72), value: isPlaying)
                .offset(x: size / 2 + size * (64 - 75) / 460, y: -size / 2 + size * (-40 + 150) / 460)
                .shadow(color: .black.opacity(0.35), radius: 8, x: -4, y: 10)
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

/// The tonearm from the prototype's SVG (viewBox 150 × 300): pivot, arm tube, headshell.
struct QTStageTonearm: View {
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 150
            ctx.scaleBy(x: s, y: s)
            var arm = Path()
            arm.move(to: CGPoint(x: 112, y: 34))
            arm.addLine(to: CGPoint(x: 118, y: 190))
            arm.addQuadCurve(to: CGPoint(x: 92, y: 252), control: CGPoint(x: 120, y: 228))
            ctx.stroke(arm, with: .linearGradient(Gradient(colors: [Color(white: 0.93), Color(white: 0.78)]),
                                                 startPoint: CGPoint(x: 112, y: 34), endPoint: CGPoint(x: 92, y: 252)),
                       style: StrokeStyle(lineWidth: 7, lineCap: .round))
            var head = ctx
            head.translateBy(x: 87, y: 255)
            head.rotate(by: .degrees(-38))
            head.fill(Path(roundedRect: CGRect(x: -17, y: -11, width: 34, height: 22), cornerRadius: 4),
                      with: .color(Color(white: 0.81)))
            ctx.fill(Path(ellipseIn: CGRect(x: 90, y: 12, width: 44, height: 44)),
                     with: .radialGradient(Gradient(colors: [Color(white: 0.9), Color(white: 0.72)]),
                                           center: CGPoint(x: 106, y: 28), startRadius: 0, endRadius: 26))
            ctx.fill(Path(ellipseIn: CGRect(x: 103, y: 25, width: 18, height: 18)), with: .color(Color(white: 0.6)))
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
