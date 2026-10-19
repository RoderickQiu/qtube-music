// qt-contact-sheet — lay out N screenshots with captions on one PNG (offline, AppKit).
// Compiled on demand by Scripts/lib.sh into .build/qt-tools/.
//
//   qt-contact-sheet --out <file.png> [--title <text>] [--columns <n>] [--width <cell px>] <image> <caption> [<image> <caption> …]
import AppKit

var argv = Array(CommandLine.arguments.dropFirst())
func take(_ flag: String) -> String? {
    guard let i = argv.firstIndex(of: flag), i + 1 < argv.count else { return nil }
    let v = argv[i + 1]
    argv.removeSubrange(i...(i + 1))
    return v
}
guard let out = take("--out") else {
    FileHandle.standardError.write(Data("usage: qt-contact-sheet --out <png> [--title T] [--columns N] [--width PX] <img> <caption> …\n".utf8))
    exit(2)
}
let title = take("--title")
let columns = max(1, Int(take("--columns") ?? "") ?? 3)
let cellWidth = CGFloat(Double(take("--width") ?? "") ?? 720)
guard argv.count >= 2, argv.count % 2 == 0 else {
    FileHandle.standardError.write(Data("qt-contact-sheet: pass image/caption pairs\n".utf8))
    exit(2)
}
let items: [(NSImage, String)] = stride(from: 0, to: argv.count, by: 2).compactMap { i in
    guard let img = NSImage(contentsOfFile: argv[i]) else {
        FileHandle.standardError.write(Data("qt-contact-sheet: can't read \(argv[i])\n".utf8))
        return nil
    }
    return (img, argv[i + 1])
}
guard !items.isEmpty else { exit(1) }

let pad: CGFloat = 40, gap: CGFloat = 32, captionH: CGFloat = 44
let titleH: CGFloat = title == nil ? 0 : 64
func pixelSize(_ img: NSImage) -> CGSize {
    if let rep = img.representations.first, rep.pixelsWide > 0 { return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh) }
    return img.size
}
let rows = (items.count + columns - 1) / columns
var rowHeights = [CGFloat](repeating: 0, count: rows)
for (i, item) in items.enumerated() {
    let s = pixelSize(item.0)
    rowHeights[i / columns] = max(rowHeights[i / columns], cellWidth * s.height / max(s.width, 1))
}
let cols = min(columns, items.count)
let width = pad * 2 + CGFloat(cols) * cellWidth + CGFloat(cols - 1) * gap
let height = pad * 2 + titleH + rowHeights.reduce(0, +) + CGFloat(rows) * captionH + CGFloat(rows - 1) * gap

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()
let flipped = { (y: CGFloat, h: CGFloat) in height - y - h }
if let title {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 26, weight: .bold), .foregroundColor: NSColor.white]
    (title as NSString).draw(at: NSPoint(x: pad, y: flipped(pad, 32)), withAttributes: attrs)
}
var y = pad + titleH
for r in 0..<rows {
    for c in 0..<cols {
        let i = r * columns + c
        guard i < items.count else { break }
        let (img, caption) = items[i]
        let s = pixelSize(img)
        let h = cellWidth * s.height / max(s.width, 1)
        let x = pad + CGFloat(c) * (cellWidth + gap)
        img.draw(in: NSRect(x: x, y: flipped(y, h), width: cellWidth, height: h))
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .medium),
                                                    .foregroundColor: NSColor(calibratedWhite: 0.88, alpha: 1), .paragraphStyle: style]
        (caption as NSString).draw(in: NSRect(x: x, y: flipped(y + rowHeights[r] + 10, 26), width: cellWidth, height: 26), withAttributes: attrs)
    }
    y += rowHeights[r] + captionH + gap
}
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: out))
print(out)
