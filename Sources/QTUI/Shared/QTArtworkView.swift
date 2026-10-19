import ImageIO
import QTCore
import SwiftUI

/// Decodes and caches artwork as downsampled CGImages (off the main thread). File and http(s) URLs.
public actor QTImageLoader {
    public static let shared = QTImageLoader()

    /// DEBUG fixture runs (`-qt.live.fixtures YES`) keep artwork offline: remote URLs show the placeholder.
    nonisolated(unsafe) static var allowsNetwork = true

    private let cache = NSCache<NSString, CGImageBox>()
    private var inflight: [String: Task<CGImage?, Never>] = [:]

    final class CGImageBox: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    public init() {
        cache.countLimit = 400
    }

    /// Image no larger than `maxPixel` on its longest side.
    public func image(at url: URL, maxPixel: Int) async -> CGImage? {
        let bucket = max(64, Int(pow(2, ceil(log2(Double(max(maxPixel, 1)))))))
        let key = "\(url.absoluteString)#\(bucket)"
        if let hit = cache.object(forKey: key as NSString) { return hit.image }
        if let running = inflight[key] { return await running.value }
        guard url.isFileURL || Self.allowsNetwork else { return nil }
        let task = Task.detached(priority: .userInitiated) { () -> CGImage? in
            let data: Data?
            if url.isFileURL {
                data = try? Data(contentsOf: url)
            } else {
                data = try? await URLSession.shared.data(from: url).0
            }
            guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: bucket,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }
        inflight[key] = task
        let image = await task.value
        inflight[key] = nil
        if let image { cache.setObject(CGImageBox(image), forKey: key as NSString) }
        return image
    }
}

/// Artwork with a quiet placeholder, downsampled to its on-screen size. No borders — art sits directly on the surface.
public struct QTArtworkView: View {
    private let images: [QTArtworkImage]
    private let cornerRadius: CGFloat
    private let contentMode: ContentMode
    private let placeholder: QTIcon

    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var loadedKey: String?

    public init(_ images: [QTArtworkImage], cornerRadius: CGFloat = QTTheme.Radius.artwork,
                contentMode: ContentMode = .fill, placeholder: QTIcon = .note) {
        self.images = images
        self.cornerRadius = cornerRadius
        self.contentMode = contentMode
        self.placeholder = placeholder
    }

    /// Track artwork, or its video still when `video` is true and one exists.
    public init(track: QTTrack?, video: Bool = false, cornerRadius: CGFloat = QTTheme.Radius.artwork,
                contentMode: ContentMode = .fill) {
        let still = track?.videoArtwork ?? []
        self.init(video && !still.isEmpty ? still : (track?.artwork ?? []), cornerRadius: cornerRadius,
                  contentMode: contentMode, placeholder: video ? .video : .note)
    }

    public var body: some View {
        GeometryReader { geo in
            let pixels = Int(max(geo.size.width, geo.size.height) * displayScale)
            let source = images.best(forPixelWidth: pixels)
            ZStack {
                if let image {
                    Image(decorative: image, scale: displayScale)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .transition(.opacity)
                } else {
                    Rectangle()
                        .fill(QTTheme.Colors.fill)
                        .overlay {
                            placeholder.image
                                .font(.system(size: max(10, min(geo.size.width, geo.size.height) * 0.28)))
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .task(id: source.map { "\($0.url.absoluteString)#\(pixels)" }) {
                guard let source, pixels > 0 else { image = nil; return }
                let key = source.url.absoluteString
                if key != loadedKey { image = nil }
                let hold = QTReadiness.shared.hold("artwork")
                let loaded = await QTImageLoader.shared.image(at: source.url, maxPixel: pixels)
                QTReadiness.shared.release(hold)
                guard !Task.isCancelled else { return }
                image = loaded
                loadedKey = key
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}
