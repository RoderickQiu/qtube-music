import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import QTCore

/// Pre-renders Stage background images with Core Image once per artwork, off the main thread, so the Stage never
/// runs a live 90 px blur over a full-window bitmap. Large blurs are done on a small downsample (a blur hides the
/// resolution), then the layer scales them up; a fine grain overlay hides banding.
actor QTStageImageProcessor {
    static let shared = QTStageImageProcessor()

    /// Each look, with prototype styles.css values expressed relative to a 1440 pt-wide Stage.
    enum Look: String, Sendable {
        /// `.st-bg.blur .img` — blur(90px) saturate(1.5) brightness(.62).
        case blurredArt
        /// Ad: art blurred and dimmed further.
        case blurredArtDimmed
        /// `.st-bg.cover .img` — blur(5px) saturate(1.15): never a raw upscaled cover.
        case coverSoft
        /// `.st-bg.cover .frost` — blur(34px) saturate(1.35) brightness(.62).
        case coverFrost
        /// `.st-bg.video .img` — brightness(.72) saturate(1.05).
        case videoStill
        /// `.ad-bg` — blur(24px) brightness(.42) saturate(1.2), for the ad card.
        case adCard

        /// Source size to decode (longest side, px).
        var sourcePixels: Int {
            switch self {
            case .blurredArt, .blurredArtDimmed: 160
            case .adCard: 320
            case .coverFrost: 480
            case .coverSoft: 1400
            case .videoStill: 1920
            }
        }

        /// Blur radius as a fraction of the source width.
        var blurFraction: Double {
            switch self {
            case .blurredArt, .blurredArtDimmed: 90.0 / 1440 * 1.6
            case .coverSoft: 5.0 / 1440
            case .coverFrost: 34.0 / 1440 * 1.3
            case .videoStill: 0
            case .adCard: 24.0 / 440
            }
        }

        var saturation: Double {
            switch self {
            case .blurredArt, .blurredArtDimmed: 1.5
            case .coverSoft: 1.15
            case .coverFrost: 1.35
            case .videoStill: 1.05
            case .adCard: 1.2
            }
        }

        var brightness: Double {
            switch self {
            case .blurredArt: 0.62
            case .blurredArtDimmed: 0.4
            case .coverSoft: 1
            case .coverFrost: 0.62
            case .videoStill: 0.72
            case .adCard: 0.42
            }
        }
    }

    private let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])
    private var cache: [String: CGImage] = [:]
    private var order: [String] = []

    func image(for url: URL, look: Look) async -> CGImage? {
        let key = "\(look.rawValue)|\(url.absoluteString)"
        if let hit = cache[key] { return hit }
        guard let source = await QTImageLoader.shared.image(at: url, maxPixel: look.sourcePixels) else { return nil }
        guard let out = render(source, look: look) else { return nil }
        cache[key] = out
        order.append(key)
        if order.count > 48 { cache[order.removeFirst()] = nil }
        return out
    }

    private func render(_ cg: CGImage, look: Look) -> CGImage? {
        let input = CIImage(cgImage: cg)
        let extent = input.extent
        var image = input
        let radius = look.blurFraction * extent.width
        if radius > 0.3 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = image.clampedToExtent()
            blur.radius = Float(radius)
            image = blur.outputImage?.cropped(to: extent) ?? image
        }
        let color = CIFilter.colorControls()
        color.inputImage = image
        color.saturation = Float(look.saturation)
        image = color.outputImage ?? image
        if look.brightness != 1 {
            // CSS brightness(x) multiplies gamma-encoded sRGB; Core Image works in linear light, so x^2.2.
            let m = CIFilter.colorMatrix()
            m.inputImage = image
            let b = CGFloat(pow(look.brightness, 2.2))
            m.rVector = CIVector(x: b, y: 0, z: 0, w: 0)
            m.gVector = CIVector(x: 0, y: b, z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: b, w: 0)
            image = m.outputImage ?? image
        }
        return context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// Tileable monochrome film grain (160 × 160), generated once.
    static let grain: CGImage? = {
        let size = 160
        var rng = QTStageSeededRandom(seed: 0x51_7A_6E)
        var pixels = [UInt8](repeating: 0, count: size * size)
        for i in pixels.indices { pixels[i] = UInt8(truncatingIfNeeded: 64 + Int(rng.next() % 128)) }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()
}

/// SplitMix64 — deterministic noise so screenshots are stable.
struct QTStageSeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
