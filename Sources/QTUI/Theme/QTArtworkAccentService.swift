import AppKit
import Observation
import QTCore
import SwiftUI

/// The playing song's artwork palette, for the app-wide accent (Settings › Accent colour › Song).
///
/// Demo tracks carry a palette from `make-mock-catalog.py`; real tracks get one here, from their artwork
/// (`QTArtworkPalette.extract`, on a 32 × 32 thumbnail, off the main thread), cached per song. The palette is sticky:
/// while a new song's colour is still being read the previous one stays, so the app never flashes to the system
/// accent between songs. Art with no usable colour (greyscale, black, white) gives nil — the system accent.
@MainActor
@Observable
public final class QTArtworkAccentService {
    public static let shared = QTArtworkAccentService()

    /// The current song's palette (nil: no song yet, or its art has no usable colour).
    public private(set) var palette: QTArtworkPalette?

    @ObservationIgnored private weak var model: QTAppModel?
    @ObservationIgnored private var cache: [String: Resolved] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var resolvingKey: String?

    private enum Resolved { case palette(QTArtworkPalette), colourless }

    /// DEBUG `-qt.accent.fromArt YES`: demo tracks are read from their artwork like real ones (their bundled palette
    /// is ignored) — screenshots of the extractor and of the colourless-art fallback.
    private static let readsDemoArt: Bool = {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "qt.accent.fromArt")
        #else
        false
        #endif
    }()

    private init() {}

    /// Called once from `QTAppModel.bootstrap`.
    func install(model: QTAppModel) {
        self.model = model
        sync()
        observe()
    }

    private func observe() {
        guard let model else { return }
        withObservationTracking {
            _ = model.player.nowPlaying?.videoId
            _ = model.player.nowPlaying?.artwork
            _ = model.player.nowPlaying?.palette
        } onChange: {
            Task { @MainActor in
                QTArtworkAccentService.shared.sync()
                QTArtworkAccentService.shared.observe()
            }
        }
    }

    private func sync() {
        // Nothing playing (queue cleared, between launches): keep the last colour.
        guard let track = model?.player.nowPlaying else { return }
        if let palette = track.palette, !Self.readsDemoArt { return set(palette) }
        let key = track.videoId
        if let hit = cache[key] {
            task?.cancel()
            resolvingKey = nil
            return set(hit)
        }
        guard resolvingKey != key else { return }
        guard let url = track.artwork.best(forPixelWidth: 64)?.url else { return set(Resolved.colourless) }
        task?.cancel()
        resolvingKey = key
        task = Task { @MainActor [weak self] in
            let resolved = await Self.resolve(url)
            guard !Task.isCancelled, let self else { return }
            if self.resolvingKey == key { self.resolvingKey = nil }
            // The artwork didn't load (offline, slow): keep the current colour, try again on the next change.
            guard let resolved else { return }
            self.store(resolved, for: key)
            guard self.model?.player.nowPlaying?.videoId == key else { return }
            self.set(resolved)
        }
    }

    private func store(_ resolved: Resolved, for key: String) {
        if cache[key] == nil { order.append(key) }
        cache[key] = resolved
        if order.count > 200 { cache[order.removeFirst()] = nil }
    }

    private func set(_ resolved: Resolved) {
        switch resolved {
        case .palette(let p): set(p)
        case .colourless: set(nil as QTArtworkPalette?)
        }
    }

    private func set(_ new: QTArtworkPalette?) {
        guard new != palette else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(QTTheme.Motion.animation(QTTheme.Motion.ui, reduceMotion: reduceMotion)) { palette = new }
    }

    /// Downsamples the artwork to 32 × 32 RGBA and extracts its palette (off the main thread). Nil when the
    /// artwork couldn't be loaded.
    private static func resolve(_ url: URL) async -> Resolved? {
        guard let image = await QTImageLoader.shared.image(at: url, maxPixel: 64) else { return nil }
        let box = QTImageLoader.CGImageBox(image)
        return await Task.detached(priority: .utility) { () -> Resolved in
            let side = 32
            var pixels = [UInt8](repeating: 0, count: side * side * 4)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.interpolationQuality = .medium
                ctx.draw(box.image, in: CGRect(x: 0, y: 0, width: side, height: side))
                return true
            }
            guard drawn, let p = QTArtworkPalette.extract(rgba: pixels, width: side, height: side) else { return .colourless }
            return .palette(p)
        }.value
    }
}
