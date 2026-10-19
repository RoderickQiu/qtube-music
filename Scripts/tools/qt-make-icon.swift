// qt-make-icon — renders the QTube Music app icon with CoreGraphics (no external assets).
// Compiled on demand by Scripts/lib.sh; driven by Scripts/make-app-icon.sh.
//
//   qt-make-icon --iconset <dir.iconset>          → icon_16x16.png … icon_512x512@2x.png
//   qt-make-icon --png <file.png> [--size 1024]   → a single rendering
//   qt-make-icon --layers <dir>                   → background.png + record.png for the Icon Composer icon
//
// Design: macOS squircle (Big Sur grid: 824 pt body on a 1024 canvas, continuous corners, soft drop shadow),
// warm art-driven gradient (amber → coral → raspberry), a vinyl record whose rim plus a short tail reads as a
// subtle "Q". No YouTube marks.
import AppKit
import CoreGraphics
import Foundation

let canvas: CGFloat = 1024
let body: CGFloat = 824
let bodyOrigin = (canvas - body) / 2

/// Apple's continuous-corner squircle approximated with a superellipse (n ≈ 4.6), as on the macOS icon grid.
func squircle(in rect: CGRect, exponent n: CGFloat = 4.6) -> CGPath {
    let path = CGMutablePath()
    let cx = rect.midX, cy = rect.midY, a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
               colors: stops.map { color($0.0, $0.1) } as CFArray,
               locations: stops.map(\.2))!
}

/// Deterministic film grain (so every build produces the same icon).
func drawGrain(_ ctx: CGContext, in rect: CGRect, amount: CGFloat) {
    var seed: UInt64 = 0x51_75_62_65
    func next() -> CGFloat {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((seed >> 33) & 0xffff) / 65535
    }
    let cell: CGFloat = 2
    var y = rect.minY
    while y < rect.maxY {
        var x = rect.minX
        while x < rect.maxX {
            let v = next()
            if v > 0.5 {
                ctx.setFillColor(CGColor(gray: 1, alpha: (v - 0.5) * amount))
            } else {
                ctx.setFillColor(CGColor(gray: 0, alpha: (0.5 - v) * amount))
            }
            ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
            x += cell
        }
        y += cell
    }
}

/// The warm gradient body (amber -> coral -> raspberry), light bloom, deeper bottom edge and grain.
func drawBody(_ ctx: CGContext, in bodyRect: CGRect) {
    // Body: warm diagonal gradient, amber top-left → coral → raspberry bottom-right.
    ctx.drawLinearGradient(gradient([(0xFFB45E, 1, 0), (0xF46A4B, 1, 0.45), (0xC93468, 1, 0.82), (0x8E2463, 1, 1)]),
                           start: CGPoint(x: bodyRect.minX, y: bodyRect.minY),
                           end: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY), options: [])
    // Soft light bloom from the top-left (like light falling on artwork).
    ctx.drawRadialGradient(gradient([(0xFFE2B0, 0.55, 0), (0xFFE2B0, 0, 1)]),
                           startCenter: CGPoint(x: bodyRect.minX + bodyRect.width * 0.22, y: bodyRect.minY + bodyRect.height * 0.12), startRadius: 0,
                           endCenter: CGPoint(x: bodyRect.minX + bodyRect.width * 0.22, y: bodyRect.minY + bodyRect.height * 0.12), endRadius: bodyRect.width * 0.62,
                           options: [])
    // Deepen the bottom edge a touch.
    ctx.drawLinearGradient(gradient([(0x2A0A22, 0, 0.55), (0x2A0A22, 0.28, 1)]),
                           start: CGPoint(x: 0, y: bodyRect.minY), end: CGPoint(x: 0, y: bodyRect.maxY), options: [])
    drawGrain(ctx, in: bodyRect, amount: 0.07)

}

/// The record + rim + Q tail + label, laid out on the 1024 legacy grid (body 824 centred).
func drawRecord(_ ctx: CGContext) {
    // The record (the Q's bowl).
    let center = CGPoint(x: canvas / 2 - 14, y: canvas / 2 - 18)
    let radius: CGFloat = 270
    let disc = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

    // Record body with a soft shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 16), blur: 36, color: color(0x2A0716, 0.45))
    ctx.addEllipse(in: disc)
    ctx.setFillColor(color(0x1A1013))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addEllipse(in: disc)
    ctx.clip()
    // Vinyl sheen: a faint conic-ish highlight approximated by two offset radial gradients.
    ctx.drawRadialGradient(gradient([(0x3B2A2E, 1, 0), (0x1A1013, 1, 1)]),
                           startCenter: center, startRadius: radius * 0.2, endCenter: center, endRadius: radius, options: [])
    // Grooves.
    var r: CGFloat = radius * 0.42
    var i = 0
    while r < radius - 10 {
        ctx.setStrokeColor(CGColor(gray: 1, alpha: i % 3 == 0 ? 0.075 : 0.035))
        ctx.setLineWidth(i % 3 == 0 ? 2.2 : 1.4)
        ctx.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        ctx.strokePath()
        r += 9
        i += 1
    }
    // Light catching the grooves: two opposite soft wedges.
    for (a, alpha) in [(-CGFloat.pi * 0.75, 0.16), (CGFloat.pi * 0.25, 0.08)] {
        ctx.saveGState()
        let wedge = CGMutablePath()
        wedge.move(to: center)
        wedge.addArc(center: center, radius: radius, startAngle: a - 0.32, endAngle: a + 0.32, clockwise: false)
        wedge.closeSubpath()
        ctx.addPath(wedge)
        ctx.clip()
        ctx.drawRadialGradient(gradient([(0xFFFFFF, CGFloat(alpha), 0), (0xFFFFFF, 0, 1)]),
                               startCenter: CGPoint(x: center.x + cos(a) * radius * 0.7, y: center.y + sin(a) * radius * 0.7),
                               startRadius: 0,
                               endCenter: CGPoint(x: center.x + cos(a) * radius * 0.7, y: center.y + sin(a) * radius * 0.7),
                               endRadius: radius * 0.55, options: [])
        ctx.restoreGState()
    }
    ctx.restoreGState()

    // Rim: a bright cream ring, so record + tail read as a "Q".
    ctx.saveGState()
    ctx.setLineWidth(30)
    ctx.setStrokeColor(color(0xFFF6EE))
    ctx.addEllipse(in: disc.insetBy(dx: 15, dy: 15))
    ctx.strokePath()
    ctx.restoreGState()

    // Q tail: a short tapered stroke crossing the rim at the lower right, over the record (not a handle).
    let angle: CGFloat = .pi * 0.27
    let tailStart = CGPoint(x: center.x + cos(angle) * (radius * 0.70), y: center.y + sin(angle) * (radius * 0.70))
    let tailEnd = CGPoint(x: center.x + cos(angle) * (radius + 70), y: center.y + sin(angle) * (radius + 70))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 14, color: color(0x2A0716, 0.4))
    let dx = tailEnd.x - tailStart.x, dy = tailEnd.y - tailStart.y
    let len = (dx * dx + dy * dy).squareRoot()
    let nx = -dy / len, ny = dx / len
    let w0: CGFloat = 26, w1: CGFloat = 40   // half-widths: thin inside, fuller outside
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: tailStart.x + nx * w0, y: tailStart.y + ny * w0))
    tail.addLine(to: CGPoint(x: tailEnd.x + nx * w1, y: tailEnd.y + ny * w1))
    tail.addArc(center: tailEnd, radius: w1, startAngle: atan2(ny, nx), endAngle: atan2(-ny, -nx), clockwise: true)
    tail.addLine(to: CGPoint(x: tailStart.x - nx * w0, y: tailStart.y - ny * w0))
    tail.addArc(center: tailStart, radius: w0, startAngle: atan2(-ny, -nx), endAngle: atan2(ny, nx), clockwise: true)
    tail.closeSubpath()
    ctx.addPath(tail)
    ctx.setFillColor(color(0xFFF6EE))
    ctx.fillPath()
    ctx.restoreGState()

    // Label: warm gradient disc with a tiny spindle hole.
    let labelR: CGFloat = 92
    let label = CGRect(x: center.x - labelR, y: center.y - labelR, width: labelR * 2, height: labelR * 2)
    ctx.saveGState()
    ctx.addEllipse(in: label)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0xFFC069, 1, 0), (0xF2664C, 1, 0.6), (0xD23F66, 1, 1)]),
                           start: CGPoint(x: label.minX, y: label.minY), end: CGPoint(x: label.maxX, y: label.maxY), options: [])
    ctx.restoreGState()
    ctx.setFillColor(color(0x1A1013))
    ctx.fillEllipse(in: CGRect(x: center.x - 13, y: center.y - 13, width: 26, height: 26))

}

func makeContext() -> CGContext {
    let size = Int(canvas)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // CoreGraphics origin is bottom-left; the design is described top-down, so flip.
    ctx.translateBy(x: 0, y: canvas)
    ctx.scaleBy(x: 1, y: -1)
    return ctx
}

/// Legacy icon (.icns for macOS 15-25): squircle body with shadow, record, sheen.
func renderMaster() -> CGImage {
    let ctx = makeContext()
    let bodyRect = CGRect(x: bodyOrigin, y: bodyOrigin, width: body, height: body)
    let shape = squircle(in: bodyRect)

    // Drop shadow (the macOS grid's soft shadow under the body).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: color(0x000000, 0.32))
    ctx.addPath(shape)
    ctx.setFillColor(color(0xE0574A))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    drawBody(ctx, in: bodyRect)
    ctx.restoreGState()

    drawRecord(ctx)

    // Top sheen across the body (very subtle glass).
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0xFFFFFF, 0.16, 0), (0xFFFFFF, 0, 0.42)]),
                           start: CGPoint(x: 0, y: bodyRect.minY), end: CGPoint(x: 0, y: bodyRect.maxY), options: [])
    ctx.restoreGState()

    // Hairline inner edge so the body holds up on light and dark Docks.
    ctx.saveGState()
    ctx.addPath(squircle(in: bodyRect.insetBy(dx: 1, dy: 1)))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
    ctx.setLineWidth(2)
    ctx.strokePath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

/// Icon Composer layers (macOS 26+ icon): a full-bleed background (the system applies shape, shadow and glass)
/// and the record as its own foreground layer, scaled to the full canvas.
func renderLayers() -> (background: CGImage, foreground: CGImage) {
    let bg = makeContext()
    drawBody(bg, in: CGRect(x: 0, y: 0, width: canvas, height: canvas))
    let fg = makeContext()
    let k = canvas / body * 0.9 // a touch of breathing room inside the system mask
    fg.translateBy(x: canvas / 2, y: canvas / 2)
    fg.scaleBy(x: k, y: k)
    fg.translateBy(x: -canvas / 2, y: -canvas / 2)
    drawRecord(fg)
    return (bg.makeImage()!, fg.makeImage()!)
}

func resized(_ image: CGImage, to px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url)
}

var args = Array(CommandLine.arguments.dropFirst())
func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let master = renderMaster()
if let dir = value("--layers") {
    let url = URL(fileURLWithPath: dir)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let layers = renderLayers()
    try writePNG(layers.background, to: url.appendingPathComponent("background.png"))
    try writePNG(layers.foreground, to: url.appendingPathComponent("record.png"))
} else if let dir = value("--iconset") {
    let url = URL(fileURLWithPath: dir)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        try writePNG(resized(master, to: base), to: url.appendingPathComponent("icon_\(base)x\(base).png"))
        try writePNG(resized(master, to: base * 2), to: url.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
} else if let file = value("--png") {
    let px = Int(value("--size") ?? "1024") ?? 1024
    try writePNG(px == 1024 ? master : resized(master, to: px), to: URL(fileURLWithPath: file))
} else {
    FileHandle.standardError.write(Data("usage: qt-make-icon --iconset <dir> | --png <file> [--size N]\n".utf8))
    exit(2)
}
