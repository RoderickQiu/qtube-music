import AppKit
import CoreText
import QTCore

// Owner: builder "lyrics-ui". Core Text layout for one block of lyric text (a lyric line, its romanization or its
// translation): balanced line breaking, per-script language tagging so the system font cascade picks the right
// fallback (SF Pro first in every locale; PingFang SC for Han, Hiragino for kana, Apple SD Gothic Neo for Hangul),
// word → x-range mapping for the karaoke fill, and rasterisation into a CGImage with room for stacked diacritics.

/// The writing system a lyric line is (mostly) in. Decides the language tag handed to Core Text.
enum QTLyricScript: String, Sendable, Hashable {
    case latin, vietnamese, han, japanese, hangul, thai, cyrillic, other

    /// Detects the dominant script. Kana anywhere means Japanese (kanji share the Han block); Vietnamese is Latin
    /// with Vietnamese-only letters (ơ ư đ and the stacked tone marks).
    static func detect(_ text: String) -> QTLyricScript {
        var han = 0, kana = 0, hangul = 0, latin = 0, thai = 0, cyrillic = 0, viet = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: kana += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2FA1F: han += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: hangul += 1
            case 0x0E00...0x0E7F: thai += 1
            case 0x0400...0x04FF: cyrillic += 1
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F: latin += 1
            case 0x1EA0...0x1EF9: latin += 1; viet += 1
            default: break
            }
            switch scalar {
            case "ơ", "Ơ", "ư", "Ư", "đ", "Đ", "ă", "Ă": viet += 1
            default: break
            }
        }
        if kana > 0 { return .japanese }
        let counts: [(QTLyricScript, Int)] = [(.han, han), (.hangul, hangul), (.thai, thai), (.cyrillic, cyrillic), (.latin, latin)]
        guard let top = counts.max(by: { $0.1 < $1.1 }), top.1 > 0 else { return .other }
        if top.0 == .latin && viet > 0 { return .vietnamese }
        return top.0
    }

    /// BCP-47 tag for Core Text's cascade. `documentLanguage` refines Han (zh-Hans vs zh-Hant vs ja).
    func languageTag(documentLanguage: String?) -> String? {
        switch self {
        case .vietnamese: "vi"
        case .japanese: "ja"
        case .hangul: "ko"
        case .thai: "th"
        case .cyrillic: documentLanguage ?? "ru"
        case .han:
            if let d = documentLanguage, d.hasPrefix("zh") || d == "ja" { d } else { "zh-Hans" }
        case .latin: documentLanguage.flatMap { $0.hasPrefix("zh") || $0 == "ja" || $0 == "ko" ? nil : $0 } ?? "en"
        case .other: documentLanguage
        }
    }

    /// CJK text never gets negative tracking or forced case.
    var isCJK: Bool { self == .han || self == .japanese || self == .hangul }
}

/// How a text block is set.
struct QTLyricTextStyle: Hashable {
    var size: CGFloat
    var weight: NSFont.Weight
    /// Line height as a multiple of the font size (CSS `line-height`).
    var lineHeight: CGFloat
    var centered: Bool
    /// Balance wrapped lines (CSS `text-wrap: balance`).
    var balanced = true
    /// Tracking in em for Latin text (CSS `letter-spacing`); ignored for CJK.
    var tracking: CGFloat = 0
    /// System font design (desktop lyrics: Rounded / Serif from Settings). Always the system family, so SF Pro
    /// leads in every locale and Han text falls back through the system cascade.
    var design: NSFontDescriptor.SystemDesign = .default
}

/// One wrapped visual line inside a block.
struct QTLyricFragment {
    let line: CTLine
    /// UTF-16 range of the source string.
    let range: NSRange
    /// Left edge of the glyphs within the block (alignment applied).
    let x: CGFloat
    /// Ink advance without trailing whitespace.
    let width: CGFloat
    /// Top of this visual line within the block (flipped coordinates).
    let top: CGFloat
    /// Baseline within the block (flipped coordinates).
    let baseline: CGFloat
}

/// Core Text layout of a text block at a given width. Coordinates are top-left origin (flipped).
final class QTLyricTextLayout {
    let string: String
    let style: QTLyricTextStyle
    let script: QTLyricScript
    let font: CTFont
    let attributed: NSAttributedString
    let fragments: [QTLyricFragment]
    /// Layout box: the widest fragment × (fragments × line height).
    let size: CGSize
    /// Extra room around the box in the rendered image, so stacked diacritics (Vietnamese "Ố"), descenders and
    /// shadows are never clipped.
    let padding: NSEdgeInsets
    let lineHeight: CGFloat
    let maxWidth: CGFloat

    init(string: String, style: QTLyricTextStyle, maxWidth: CGFloat, documentLanguage: String?, shadowRoom: CGFloat = 0) {
        self.string = string
        self.style = style
        self.maxWidth = max(40, maxWidth)
        let script = QTLyricScript.detect(string)
        self.script = script
        var nsFont = NSFont.systemFont(ofSize: style.size, weight: style.weight)
        if style.design != .default, let descriptor = nsFont.fontDescriptor.withDesign(style.design),
           let designed = NSFont(descriptor: descriptor, size: style.size) {
            nsFont = designed
        }
        font = nsFont as CTFont
        var attrs: [NSAttributedString.Key: Any] = [
            .font: nsFont,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        if let tag = script.languageTag(documentLanguage: documentLanguage) {
            attrs[NSAttributedString.Key(kCTLanguageAttributeName as String)] = tag
        }
        if style.tracking != 0, !script.isCJK {
            attrs[.kern] = style.tracking * style.size
        }
        let attributed = NSAttributedString(string: string, attributes: attrs)
        self.attributed = attributed
        let lineHeight = (style.size * style.lineHeight).rounded(.up)
        self.lineHeight = lineHeight

        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = attributed.length
        func breaks(at width: CGFloat) -> [NSRange] {
            var ranges: [NSRange] = []
            var start = 0
            while start < length {
                var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
                if count <= 0 { count = length - start }
                ranges.append(NSRange(location: start, length: count))
                start += count
            }
            return ranges.isEmpty ? [NSRange(location: 0, length: 0)] : ranges
        }
        var ranges = breaks(at: self.maxWidth)
        if style.balanced, ranges.count > 1 {
            // Narrowest width that keeps the same number of lines → evenly balanced lines.
            var lo = self.maxWidth / CGFloat(ranges.count) * 0.8, hi = self.maxWidth
            for _ in 0..<10 {
                let mid = (lo + hi) / 2
                if breaks(at: mid).count <= ranges.count { hi = mid } else { lo = mid }
            }
            ranges = breaks(at: hi)
        }

        var ascent: CGFloat = 0, descent: CGFloat = 0
        ascent = CTFontGetAscent(font)
        descent = CTFontGetDescent(font)
        let baselineInset = ((lineHeight - (ascent + descent)) / 2 + ascent).rounded()

        var raw: [(CTLine, NSRange, CGFloat)] = []
        var widest: CGFloat = 0
        for r in ranges {
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: r.location, length: r.length))
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
            widest = max(widest, w)
            raw.append((line, r, w))
        }
        let boxWidth = ceil(widest)
        fragments = raw.enumerated().map { i, item in
            let top = CGFloat(i) * lineHeight
            let x = style.centered ? ((boxWidth - item.2) / 2).rounded() : 0
            return QTLyricFragment(line: item.0, range: item.1, x: x, width: item.2, top: top, baseline: top + baselineInset)
        }
        size = CGSize(width: boxWidth, height: CGFloat(fragments.count) * lineHeight)
        let em = style.size
        padding = NSEdgeInsets(top: ceil(em * 0.32 + shadowRoom), left: ceil(em * 0.16 + shadowRoom),
                               bottom: ceil(em * 0.28 + shadowRoom), right: ceil(em * 0.16 + shadowRoom))
    }

    /// Size of the rendered image in points (box + padding).
    var imageSize: CGSize {
        CGSize(width: size.width + padding.left + padding.right, height: size.height + padding.top + padding.bottom)
    }

    /// x range (block coordinates) covered by a UTF-16 range, split per fragment it touches.
    func xSpans(for range: NSRange) -> [(fragment: Int, x0: CGFloat, x1: CGFloat)] {
        var spans: [(Int, CGFloat, CGFloat)] = []
        for (i, f) in fragments.enumerated() {
            let lo = max(range.location, f.range.location)
            let hi = min(NSMaxRange(range), NSMaxRange(f.range))
            guard hi > lo else { continue }
            let a = CGFloat(CTLineGetOffsetForStringIndex(f.line, lo, nil))
            var b = CGFloat(CTLineGetOffsetForStringIndex(f.line, hi, nil))
            b = min(b, f.width) // trailing whitespace at a wrap is not ink
            spans.append((i, f.x + a, f.x + max(a, b)))
        }
        return spans
    }

    /// Rasterises the block in one colour. `outline`/`shadow` are for the desktop overlay (any wallpaper).
    func render(color: NSColor, scale: CGFloat, shadow: NSShadow? = nil, outline: (width: CGFloat, color: NSColor)? = nil) -> CGImage? {
        let img = imageSize
        let pw = Int(ceil(img.width * scale)), ph = Int(ceil(img.height * scale))
        guard pw > 0, ph > 0,
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setAllowsFontSmoothing(false)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setShouldSubpixelQuantizeFonts(false)
        ctx.textMatrix = .identity
        if let shadow, let c = shadow.shadowColor {
            ctx.setShadow(offset: CGSize(width: shadow.shadowOffset.width, height: shadow.shadowOffset.height),
                          blur: shadow.shadowBlurRadius, color: c.cgColor)
        }
        func drawLines() {
            for f in fragments {
                // Core Graphics is y-up: baseline from the bottom of the image.
                ctx.textPosition = CGPoint(x: padding.left + f.x, y: img.height - (padding.top + f.baseline))
                CTLineDraw(f.line, ctx)
            }
        }
        if let outline {
            ctx.setLineJoin(.round)
            ctx.setLineWidth(outline.width)
            ctx.setStrokeColor(outline.color.cgColor)
            ctx.setTextDrawingMode(.stroke)
            drawLines()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
        }
        ctx.setFillColor(color.cgColor)
        ctx.setTextDrawingMode(.fill)
        drawLines()
        return ctx.makeImage()
    }
}

// MARK: - Karaoke keyframes

/// The moving "front" of the karaoke fill on one visual line: fully lit left of `x`, a soft edge of `edge` points
/// to its right, unlit beyond. Times are on the lyric timeline (seconds).
struct QTKaraokeTrack: Equatable {
    var fragment: Int
    var times: [Double]
    var fronts: [CGFloat]

    /// Front position at a lyric time (linear between keyframes, clamped outside).
    func front(at t: Double) -> CGFloat {
        guard let first = times.first, let last = times.last else { return 0 }
        if t <= first { return fronts[0] }
        if t >= last { return fronts[fronts.count - 1] }
        var i = 1
        while i < times.count, times[i] < t { i += 1 }
        let t0 = times[i - 1], t1 = times[i]
        let p = t1 > t0 ? (t - t0) / (t1 - t0) : 1
        return fronts[i - 1] + (fronts[i] - fronts[i - 1]) * CGFloat(p)
    }
}

enum QTKaraoke {
    /// Builds one front track per visual line from word timings.
    /// - Parameters:
    ///   - spans: per word (in order), its time range and x-spans from `QTLyricTextLayout.xSpans`.
    ///   - fragments: (x, width) of each visual line.
    ///   - edge: soft-edge width in points.
    static func tracks(words: [(start: Double, end: Double, spans: [(fragment: Int, x0: CGFloat, x1: CGFloat)])],
                       fragments: [(x: CGFloat, width: CGFloat)], edge: CGFloat) -> [QTKaraokeTrack] {
        var perFragment: [Int: [(Double, CGFloat)]] = [:]
        for w in words {
            let total = w.spans.reduce(0) { $0 + max(0, $1.x1 - $1.x0) }
            var t = w.start
            let duration = max(0, w.end - w.start)
            for s in w.spans {
                // Split the word's time across the visual lines it wraps over, by width.
                let share = total > 0 ? Double(max(0, s.x1 - s.x0) / total) : 1 / Double(max(1, w.spans.count))
                let t1 = t + duration * share
                var pts = perFragment[s.fragment] ?? []
                let lastFront = pts.last?.1 ?? -CGFloat.infinity
                let startFront = max(lastFront, s.x0 - edge)
                let lastTime = pts.last?.0 ?? -Double.infinity
                pts.append((max(t, lastTime), startFront))
                pts.append((max(t1, max(t, lastTime) + 0.001), max(startFront, s.x1)))
                perFragment[s.fragment] = pts
                t = t1
            }
        }
        var out: [QTKaraokeTrack] = []
        for (i, f) in fragments.enumerated() {
            guard var pts = perFragment[i], !pts.isEmpty else { continue }
            // Before the first word nothing is lit; after the last word the whole visual line is.
            if pts[0].1 > f.x - edge { pts[0].1 = min(pts[0].1, f.x - edge) }
            if let last = pts.last, last.1 < f.x + f.width {
                pts[pts.count - 1].1 = f.x + f.width
            }
            out.append(QTKaraokeTrack(fragment: i, times: pts.map(\.0), fronts: pts.map(\.1)))
        }
        return out
    }
}
