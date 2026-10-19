// qt-composite — lays a transparent window capture (desktop lyrics, mini player…) over wallpaper crops, one band
// per wallpaper, stacked vertically. Shows legibility on light / dark / busy desktops without capturing the
// user's real screen. Compiled on demand by Scripts/lib.sh.
//
//   qt-composite --out <file.png> --fg <capture.png> [--pad 120] [--align bottom|center] <wallpaper>…
import AppKit
import CoreGraphics
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
func take(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
guard let out = take("--out"), let fgPath = take("--fg"),
      let fg = NSImage(contentsOfFile: fgPath)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("usage: qt-composite --out F --fg capture.png [--pad N] <wallpaper>…\n".utf8))
    exit(2)
}
let pad = CGFloat(Double(take("--pad") ?? "120") ?? 120)
let align = take("--align") ?? "center"
let walls = args.compactMap { NSImage(contentsOfFile: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
guard !walls.isEmpty else { FileHandle.standardError.write(Data("no wallpapers\n".utf8)); exit(2) }

let bandW = CGFloat(fg.width) + pad * 2
let bandH = CGFloat(fg.height) + pad * 2
let ctx = CGContext(data: nil, width: Int(bandW), height: Int(bandH) * walls.count, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
for (i, wall) in walls.enumerated() {
    let band = CGRect(x: 0, y: CGFloat(walls.count - 1 - i) * bandH, width: bandW, height: bandH)
    ctx.saveGState()
    ctx.clip(to: band)
    // Cover-fit the wallpaper's lower-middle region into the band.
    let ww = CGFloat(wall.width), wh = CGFloat(wall.height)
    let scale = max(bandW / ww, bandH / wh) * 1.0
    let dw = ww * scale, dh = wh * scale
    let dy: CGFloat = align == "bottom" ? band.minY : band.midY - dh / 2
    ctx.draw(wall, in: CGRect(x: band.midX - dw / 2, y: dy, width: dw, height: dh))
    ctx.draw(fg, in: CGRect(x: pad, y: band.minY + pad, width: CGFloat(fg.width), height: CGFloat(fg.height)))
    ctx.restoreGState()
}
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print(out)
