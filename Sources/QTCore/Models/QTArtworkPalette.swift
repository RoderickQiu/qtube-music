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
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
