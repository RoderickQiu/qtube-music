import Foundation

/// An sRGB colour, Codable as `"#rrggbb"`. Platform-neutral so QTCore stays free of AppKit.
public struct QTRGBColor: Codable, Sendable, Hashable, CustomStringConvertible {
    /// Components in 0…1, gamma-encoded sRGB.
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red.clamped(to: 0...1)
        self.green = green.clamped(to: 0...1)
        self.blue = blue.clamped(to: 0...1)
    }

    /// Parses `#rgb`, `#rrggbb` or `rrggbb`.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    public var hex: String {
        let c = [red, green, blue].map { Int(($0 * 255).rounded()) }
        return String(format: "#%02x%02x%02x", c[0], c[1], c[2])
    }

    public var description: String { hex }

    public init(from decoder: any Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = QTRGBColor(hex: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad colour \(s)"))
        }
        self = c
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }

    /// WCAG relative luminance (0 black … 1 white).
    public var relativeLuminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(red) + 0.7152 * lin(green) + 0.0722 * lin(blue)
    }

    // MARK: OKLCH

    /// Perceptual lightness/chroma/hue (Björn Ottosson's OKLab in polar form). Hue in degrees.
    public struct OKLCH: Sendable, Hashable {
        public var lightness: Double
        public var chroma: Double
        public var hue: Double
        public init(lightness: Double, chroma: Double, hue: Double) {
            self.lightness = lightness
            self.chroma = chroma
            self.hue = hue
        }
    }

    public var oklch: OKLCH {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let r = lin(red), g = lin(green), b = lin(blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        var h = atan2(B, A) * 180 / .pi
        if h < 0 { h += 360 }
        return OKLCH(lightness: L, chroma: (A * A + B * B).squareRoot(), hue: h)
    }

    public init(oklch c: OKLCH) {
        let a = c.chroma * cos(c.hue * .pi / 180)
        let b = c.chroma * sin(c.hue * .pi / 180)
        let l = pow(c.lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(c.lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(c.lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        func enc(_ x: Double) -> Double {
            let x = x.clamped(to: 0...1)
            return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        self.init(red: enc(r), green: enc(g), blue: enc(bl))
    }

    /// The same hue at a fixed perceptual lightness with chroma clamped — how the prototype
    /// normalises an artwork colour into an always-legible accent.
    public func normalized(lightness: Double, chroma range: ClosedRange<Double>) -> QTRGBColor {
        var c = oklch
        c.lightness = lightness
        c.chroma = c.chroma.clamped(to: range)
        return QTRGBColor(oklch: c)
    }
}

/// Colours sampled from a track's artwork (by `make-mock-catalog.py` for mock data; by the app for real art).
public struct QTArtworkPalette: Codable, Sendable, Hashable {
    /// The dominant vivid colour.
    public var accent: QTRGBColor
    /// A deep background colour (Stage base layer behind blurred art).
    public var deep: QTRGBColor

    public init(accent: QTRGBColor, deep: QTRGBColor) {
        self.accent = accent
        self.deep = deep
    }

    /// Accent tuned for legibility on dark surfaces (prototype: oklch L .74, C .09–.19).
    public var accentOnDark: QTRGBColor { accent.normalized(lightness: 0.74, chroma: 0.09...0.19) }
    /// Accent tuned for legibility on light surfaces (prototype: oklch L .56, C .09–.17).
    public var accentOnLight: QTRGBColor { accent.normalized(lightness: 0.56, chroma: 0.09...0.17) }
    /// Deep ink version of the accent (Liked Songs tile gradient end).
    public var accentInk: QTRGBColor { accent.normalized(lightness: 0.32, chroma: 0.04...0.12) }

    /// The app-wide control tint on dark surfaces (Settings › Accent colour › Song): filled controls carry white text
    /// and the tint marks controls on the window background, so its luminance sits where both read — at least 3:1
    /// against a dark window (#1e1e1e) and at least 3:1 for white text on it.
    public var tintOnDark: QTRGBColor { accent.withLuminance(Self.darkTintLuminance, chroma: 0.09...0.19) }
    /// The app-wide control tint on light surfaces: at least 3:1 against the light window (#ececec) and white,
    /// at least 4.5:1 for white text on it.
    public var tintOnLight: QTRGBColor { accent.withLuminance(Self.lightTintLuminance, chroma: 0.09...0.17) }

    /// Target WCAG luminance for `tintOnDark` (3.6:1 on #1e1e1e, 3.9:1 under white text).
    public static let darkTintLuminance = 0.22
    /// Target WCAG luminance for `tintOnLight` (4.4:1 on #ececec, 5.2:1 under white text).
    public static let lightTintLuminance = 0.15

    // MARK: Extraction

    /// The palette of an artwork image given as 8-bit RGBA pixels (sRGB, alpha last, rows packed), or nil when it has
    /// no usable colour (greyscale, near-black, near-white art): the caller then uses the system accent.
    ///
    /// The accent is the most colourful hue family: pixels vote into 24 OKLCH hue bins with their chroma (pixels
    /// that are nearly grey, black or white don't vote); the winning bin and its neighbours are averaged in OKLab.
    /// The deep colour is the same hue, dark and muted (the Stage's base layer).
    public static func extract(rgba: [UInt8], width: Int, height: Int) -> QTArtworkPalette? {
        let count = width * height
        guard count > 0, rgba.count >= count * 4 else { return nil }
        let bins = 24
        var weight = [Double](repeating: 0, count: bins)
        var sumL = [Double](repeating: 0, count: bins)
        var sumA = [Double](repeating: 0, count: bins)
        var sumB = [Double](repeating: 0, count: bins)
        var opaque = 0
        var vivid = 0
        for i in 0..<count {
            let o = i * 4
            guard rgba[o + 3] >= 128 else { continue }
            opaque += 1
            let c = QTRGBColor(red: Double(rgba[o]) / 255, green: Double(rgba[o + 1]) / 255, blue: Double(rgba[o + 2]) / 255).oklch
            guard c.chroma >= minimumChroma, (0.22...0.94).contains(c.lightness) else { continue }
            vivid += 1
            let bin = Int(c.hue / 360 * Double(bins)) % bins
            // Chroma squared favours the colour that reads as "the colour of the cover" over large muted areas.
            let w = c.chroma * c.chroma
            weight[bin] += w
            let h = c.hue * .pi / 180
            sumL[bin] += w * c.lightness
            sumA[bin] += w * c.chroma * cos(h)
            sumB[bin] += w * c.chroma * sin(h)
        }
        // At least ~4% of the cover must be colourful, or it reads as greyscale.
        guard opaque > 0, Double(vivid) / Double(opaque) >= minimumVividShare else { return nil }
        let best = (0..<bins).max { a, b in
            let wa = weight[a] + 0.5 * (weight[(a + bins - 1) % bins] + weight[(a + 1) % bins])
            let wb = weight[b] + 0.5 * (weight[(b + bins - 1) % bins] + weight[(b + 1) % bins])
            return wa < wb
        }!
        var w = 0.0, l = 0.0, a = 0.0, b = 0.0
        for k in [best, (best + bins - 1) % bins, (best + 1) % bins] {
            w += weight[k]; l += sumL[k]; a += sumA[k]; b += sumB[k]
        }
        guard w > 0 else { return nil }
        var hue = atan2(b / w, a / w) * 180 / .pi
        if hue < 0 { hue += 360 }
        let chroma = (a * a + b * b).squareRoot() / w
        let accent = QTRGBColor(oklch: .init(lightness: l / w, chroma: chroma, hue: hue))
        let deep = QTRGBColor(oklch: .init(lightness: 0.24, chroma: min(chroma, 0.06), hue: hue))
        return QTArtworkPalette(accent: accent, deep: deep)
    }

    /// OKLCH chroma below which a pixel counts as grey.
    static let minimumChroma = 0.045
    /// Share of opaque pixels that must be colourful.
    static let minimumVividShare = 0.04
}

public extension QTRGBColor {
    /// WCAG contrast ratio with another colour (1…21).
    func contrast(with other: QTRGBColor) -> Double {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The same hue with chroma clamped to `range`, at the OKLCH lightness whose WCAG luminance is `luminance`
    /// (bisection; luminance grows with lightness for a fixed hue and chroma).
    func withLuminance(_ luminance: Double, chroma range: ClosedRange<Double>) -> QTRGBColor {
        var c = oklch
        c.chroma = c.chroma.clamped(to: range)
        var lo = 0.0, hi = 1.0
        for _ in 0..<32 {
            let mid = (lo + hi) / 2
            c.lightness = mid
            if QTRGBColor(oklch: c).relativeLuminance < luminance { lo = mid } else { hi = mid }
        }
        c.lightness = (lo + hi) / 2
        return QTRGBColor(oklch: c)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
