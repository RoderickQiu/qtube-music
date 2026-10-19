import SwiftUI

/// The tonearm (prototype SVG geometry, viewBox 150 × 300): a brushed-steel bearing on a dark base plate, the
/// counterweight behind it, a polished tube shaded like a cylinder, and the headshell with its cartridge and
/// finger lift. Lit from the top left, like the record's sheen. Drawn once per size (Canvas, no animation).
struct QTStageTonearm: View {
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 150
            ctx.scaleBy(x: s, y: s)
            let pivot = CGPoint(x: 112, y: 34)

            // Counterweight: a short steel cylinder behind the pivot, with a knurled groove.
            var weight = ctx
            weight.translateBy(x: 111.4, y: 11)
            weight.rotate(by: .degrees(2))
            let weightRect = CGRect(x: -9.5, y: -9, width: 19, height: 16)
            weight.fill(Path(roundedRect: weightRect, cornerRadius: 3.5),
                        with: .linearGradient(Self.cylinder, startPoint: CGPoint(x: -9.5, y: 0), endPoint: CGPoint(x: 9.5, y: 0)))
            weight.fill(Path(CGRect(x: -9.5, y: -2.2, width: 19, height: 1.1)), with: .color(.black.opacity(0.35)))
            weight.stroke(Path(roundedRect: weightRect, cornerRadius: 3.5), with: .color(.black.opacity(0.3)), lineWidth: 0.6)

            // Base plate: dark anodised disc with a bevelled rim.
            let plate = Path(ellipseIn: CGRect(x: pivot.x - 22, y: pivot.y - 22, width: 44, height: 44))
            ctx.fill(plate, with: .radialGradient(Gradient(colors: [Color(white: 0.3), Color(white: 0.12)]),
                                                  center: CGPoint(x: pivot.x - 6, y: pivot.y - 8), startRadius: 0, endRadius: 30))
            ctx.stroke(plate, with: .linearGradient(Gradient(colors: [.white.opacity(0.38), .white.opacity(0.02)]),
                                                    startPoint: CGPoint(x: pivot.x - 20, y: pivot.y - 20),
                                                    endPoint: CGPoint(x: pivot.x + 20, y: pivot.y + 20)), lineWidth: 1)

            // Bearing housing: brushed steel (conic highlights), with a polished cap.
            let bearing = Path(ellipseIn: CGRect(x: pivot.x - 12, y: pivot.y - 12, width: 24, height: 24))
            ctx.fill(bearing, with: .conicGradient(Gradient(colors: [
                Color(white: 0.93), Color(white: 0.55), Color(white: 0.84), Color(white: 0.48),
                Color(white: 0.9), Color(white: 0.58), Color(white: 0.93),
            ]), center: pivot, angle: .degrees(-30)))
            ctx.stroke(bearing, with: .color(.black.opacity(0.35)), lineWidth: 0.8)
            ctx.fill(Path(ellipseIn: CGRect(x: pivot.x - 4.5, y: pivot.y - 4.5, width: 9, height: 9)),
                     with: .radialGradient(Gradient(colors: [Color(white: 0.99), Color(white: 0.45)]),
                                           center: CGPoint(x: pivot.x - 1.5, y: pivot.y - 1.5), startRadius: 0, endRadius: 6))

            // Arm tube: body, a soft core shadow on the far side and a specular line on the lit side.
            var arm = Path()
            arm.move(to: CGPoint(x: 112, y: 42))
            arm.addLine(to: CGPoint(x: 118, y: 190))
            arm.addQuadCurve(to: CGPoint(x: 92, y: 250), control: CGPoint(x: 120, y: 228))
            ctx.stroke(arm, with: .linearGradient(Gradient(colors: [Color(white: 0.8), Color(white: 0.6)]),
                                                 startPoint: CGPoint(x: 112, y: 34), endPoint: CGPoint(x: 92, y: 252)),
                       style: StrokeStyle(lineWidth: 6.5, lineCap: .round))
            var shade = ctx
            shade.translateBy(x: 1.7, y: 0.4)
            shade.stroke(arm, with: .color(.black.opacity(0.26)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            var spec = ctx
            spec.translateBy(x: -1.4, y: -0.3)
            spec.stroke(arm, with: .color(.white.opacity(0.88)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))

            // Headshell with finger lift, cartridge and stylus guard.
            var head = ctx
            head.translateBy(x: 87, y: 255)
            head.rotate(by: .degrees(-38))
            head.fill(Path(roundedRect: CGRect(x: 12, y: -1.8, width: 14, height: 3), cornerRadius: 1.5),
                      with: .linearGradient(Gradient(colors: [Color(white: 0.85), Color(white: 0.55)]),
                                            startPoint: CGPoint(x: 0, y: -2), endPoint: CGPoint(x: 0, y: 2)))
            let shell = Path(roundedRect: CGRect(x: -16, y: -10, width: 32, height: 20), cornerRadius: 4)
            head.fill(shell, with: .linearGradient(Gradient(colors: [Color(white: 0.94), Color(white: 0.64)]),
                                                   startPoint: CGPoint(x: 0, y: -10), endPoint: CGPoint(x: 0, y: 10)))
            head.stroke(shell, with: .color(.black.opacity(0.25)), lineWidth: 0.6)
            head.fill(Path(roundedRect: CGRect(x: -9, y: 6, width: 18, height: 9), cornerRadius: 1.5),
                      with: .linearGradient(Gradient(colors: [Color(white: 0.22), Color(white: 0.07)]),
                                            startPoint: CGPoint(x: 0, y: 6), endPoint: CGPoint(x: 0, y: 15)))
            head.fill(Path(CGRect(x: -6, y: 7.4, width: 12, height: 0.9)), with: .color(.white.opacity(0.2)))
        }
    }

    /// Cylinder shading across a round steel part: dark edge → highlight → mid → dark edge.
    private static let cylinder = Gradient(stops: [
        .init(color: Color(white: 0.24), location: 0),
        .init(color: Color(white: 0.92), location: 0.3),
        .init(color: Color(white: 0.62), location: 0.62),
        .init(color: Color(white: 0.22), location: 1),
    ])
}
