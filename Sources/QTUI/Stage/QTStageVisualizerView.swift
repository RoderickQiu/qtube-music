import AppKit
import Metal
import MetalKit
import QTCore
import QTPlayback
import SwiftUI

/// Audio-reactive spectrum drawn in Metal over the blurred art (Premium only).
///
/// A row of rounded, art-tinted bars rises from the bottom edge with a soft bloom above them and a warm floor
/// glow beneath. Paused, the bars rest at a calm, visible spectrum shape (so the background still reads as a
/// visualizer) and the display link stops once they settle. Data: `QTPlaybackEngine.spectrum(bandCount:)` when
/// the engine provides it; otherwise (M1, simulated engine) a synthetic spectrum with the prototype's envelope and
/// beat. Holds a still frame on battery, and runs at 30 fps in Low Power Mode / Reduce Motion.
struct QTStageVisualizerView: NSViewRepresentable {
    let palette: QTArtworkPalette?
    let accent: Color
    let isPlaying: Bool
    let policy: QTStageMotionPolicy
    @Environment(QTPlayerModel.self) private var player

    func makeNSView(context: Context) -> MTKView {
        let view = QTStageVisualizerMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.enableSetNeedsDisplay = false
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        let renderer = context.coordinator
        renderer.setColors(Self.colors(palette: palette, accent: accent))
        renderer.engine = player.engine
        renderer.update(isPlaying: isPlaying, policy: policy)
    }

    func makeCoordinator() -> QTStageVisualizerRenderer { QTStageVisualizerRenderer() }

    static func dismantleNSView(_ view: MTKView, coordinator: QTStageVisualizerRenderer) {
        view.isPaused = true
        view.delegate = nil
    }

    /// Bar base, bar tip and glow colours from the artwork (system accent without artwork).
    static func colors(palette: QTArtworkPalette?, accent: Color) -> QTStageVisualizerColors {
        func simd(_ c: QTRGBColor) -> SIMD4<Float> { SIMD4(Float(c.red), Float(c.green), Float(c.blue), 1) }
        if let palette {
            let base = palette.accent.normalized(lightness: 0.7, chroma: 0.13...0.2)
            let tip = palette.accent.normalized(lightness: 0.92, chroma: 0.04...0.08)
            return QTStageVisualizerColors(base: simd(base), tip: simd(tip), glow: simd(palette.accentOnDark))
        }
        let rgb = NSColor(accent).usingColorSpace(.sRGB) ?? .white
        let c = SIMD4(Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent), 1)
        return QTStageVisualizerColors(base: c, tip: c * 0.4 + SIMD4(0.6, 0.6, 0.6, 0.6), glow: c)
    }
}

struct QTStageVisualizerColors: Equatable {
    var base: SIMD4<Float>
    var tip: SIMD4<Float>
    var glow: SIMD4<Float>
}

final class QTStageVisualizerMTKView: MTKView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class QTStageVisualizerRenderer: NSObject, MTKViewDelegate {
    nonisolated static let bandCount = 96
    /// Tallest bar while playing, as a fraction of the view height.
    nonisolated static let peak: Float = 0.22

    weak var engine: (any QTPlaybackEngine)?

    private var colors = QTStageVisualizerColors(base: .one, tip: .one, glow: .one)
    private var pipeline: MTLRenderPipelineState?
    private var queue: MTLCommandQueue?
    private weak var view: MTKView?
    private var bands = QTStageVisualizerRenderer.resting()
    /// 0 paused … 1 playing, eased; drives bloom and floor glow.
    private var energy: Float = 0
    private var isPlaying = false
    private var animate = true
    private let start = CACurrentMediaTime()

    func attach(to view: MTKView) {
        self.view = view
        guard let device = view.device else { return }
        queue = device.makeCommandQueue()
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "qt_stage_vis_vertex")
            desc.fragmentFunction = library.makeFunction(name: "qt_stage_vis_fragment")
            let attachment = desc.colorAttachments[0]!
            attachment.pixelFormat = view.colorPixelFormat
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            FileHandle.standardError.write(Data("QTStageVisualizer: \(error)\n".utf8))
        }
        view.delegate = self
    }

    func setColors(_ new: QTStageVisualizerColors) {
        guard new != colors else { return }
        colors = new
        if let view, view.isPaused { view.draw() }
    }

    func update(isPlaying: Bool, policy: QTStageMotionPolicy) {
        self.isPlaying = isPlaying
        animate = policy.allowsVisualizerAnimation
        guard let view else { return }
        view.preferredFramesPerSecond = policy.visualizerFPS
        if animate {
            // Runs until the bars settle (a frame or two when nothing changed), then pauses itself.
            view.isPaused = false
        } else {
            // Still frame: a calm, representative spectrum (or the resting shape while paused).
            bands = isPlaying ? Self.synthetic(t: 2.2, playing: true) : Self.resting()
            energy = isPlaying ? 1 : 0
            view.isPaused = true
            view.draw()
        }
    }

    // MARK: MTKViewDelegate

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        QTMainActorHop.onMainThread {
            // A paused view doesn't redraw by itself; keep the still frame sharp after a resize.
            if view.isPaused { DispatchQueue.main.async { view.draw() } }
        }
    }

    nonisolated func draw(in view: MTKView) {
        QTMainActorHop.onMainThread { render(in: view) }
    }

    private func render(in view: MTKView) {
        if animate { step() }
        guard let pipeline, let queue, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let size = view.drawableSize
        let scale = Float(view.window?.backingScaleFactor ?? 2)
        var uniforms = [
            SIMD4<Float>(Float(size.width), Float(size.height), Float(bands.count), scale),
            colors.base, colors.tip, colors.glow,
            SIMD4<Float>(energy, 0, 0, 0),
        ]
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride * uniforms.count, index: 0)
        bands.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()

        // Settled while paused: stop the display link until playback resumes.
        if animate && !isPlaying && energy < 0.002 && zip(bands, Self.restingShape).allSatisfy({ abs($0 - $1) < 0.0015 }) {
            view.isPaused = true
        }
    }

    private func step() {
        let t = CACurrentMediaTime() - start
        let target: [Float]
        if isPlaying, let real = engine?.spectrum(bandCount: bands.count), real.count == bands.count {
            // Engines report low → high; fold onto the mirrored layout (pairs of bands share a value).
            let rest = Self.restingShape
            let half = stride(from: 0, to: real.count, by: 2).map { min(max(real[$0], 0), 1) * Self.peak }
            target = Self.smoothed(Self.mirrored(half)).enumerated().map { rest[$0] * 0.7 + $1 }
        } else {
            target = isPlaying ? Self.synthetic(t: t, playing: true) : Self.restingShape
        }
        for i in bands.indices {
            let k: Float = isPlaying ? (target[i] > bands[i] ? 0.42 : 0.14) : 0.09
            bands[i] += (target[i] - bands[i]) * k
        }
        energy += ((isPlaying ? 1 : 0) - energy) * 0.06
    }

    // MARK: Spectrum shapes

    /// Bands are mirrored around the centre (bass in the middle, treble at both edges), so the row stays balanced
    /// under the centred transport and art. `position(i)` is 0 at the centre … 1 at the edges.
    nonisolated static func position(_ i: Int) -> Double {
        abs(Double(i) + 0.5 - Double(bandCount) / 2) / (Double(bandCount) / 2)
    }

    /// Spectral envelope (bass-heavy with a mid hump) over 0 (bass) … 1 (treble).
    nonisolated static func envelope(_ x: Double) -> Double {
        exp(-pow((x - 0.1) / 0.24, 2)) * 0.85 + exp(-pow((x - 0.5) / 0.26, 2)) * 0.45 + 0.12
    }

    /// The paused spectrum: a still, clearly visible silhouette of the envelope with a little texture.
    nonisolated static let restingShape: [Float] = smoothed((0..<bandCount).map { i in
        let x = position(i)
        let k = Double(min(i, bandCount - 1 - i))   // mirrored texture
        let texture = 0.8 + 0.2 * sin(k * 1.7) * cos(k * 0.6)
        return Float((0.014 + envelope(x) * 0.048) * texture)
    })

    nonisolated static func resting() -> [Float] { restingShape }

    /// Mirrors a low→high spectrum of `bandCount / 2` values onto the centred layout.
    nonisolated static func mirrored(_ half: [Float]) -> [Float] {
        let n = bandCount / 2
        guard half.count >= n else { return restingShape }
        return (0..<bandCount).map { i in half[min(Int(position(i) * Double(n)), n - 1)] }
    }

    /// The prototype's synthetic spectrum (stage.jsx `Visualizer`), as a fraction of the view height: a rolling
    /// noise over the envelope with a beat, softened across neighbouring bands so it moves like a curve, not static.
    nonisolated static func synthetic(t: Double, playing: Bool) -> [Float] {
        guard playing else { return restingShape }
        let half = bandCount / 2
        let beat = pow(max(0, sin(t * .pi * 2 * 1.4)), 6)
        let values: [Float] = (0..<half).map { k in
            let x = Double(k) / Double(half - 1)
            let env = envelope(x)
            let j = Double(k)
            let n = 0.5 + 0.5 * (0.6 * sin(t * (2.1 + j * 0.09) + j * 0.8) * sin(t * 1.3 + j * 0.45) + 0.4 * sin(t * 3.7 + j * 1.9))
            return Float((env * (0.25 + 0.75 * n) + beat * env * 0.5) * Double(peak) * 0.72)
        }
        let rest = restingShape
        return smoothed(mirrored(values)).enumerated().map { rest[$0] * 0.7 + $1 }
    }

    /// 1-2-1 blur across neighbouring bands.
    nonisolated static func smoothed(_ v: [Float]) -> [Float] {
        v.indices.map { i in
            let l = v[max(i - 1, 0)], r = v[min(i + 1, v.count - 1)]
            return (l + 2 * v[i] + r) / 4
        }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct QTVisOut { float4 position [[position]]; float2 uv; };

    vertex QTVisOut qt_stage_vis_vertex(uint vid [[vertex_id]]) {
        const float2 p[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        QTVisOut o;
        o.position = float4(p[vid], 0, 1);
        o.uv = (p[vid] + 1.0) * 0.5;
        return o;
    }

    // Signed distance (px) to a vertical capsule bar of half-width w rising from below the bottom edge to height h.
    static float qt_bar_sd(float2 p, float w, float h) {
        float top = max(h - w, 0.0);
        float y = clamp(p.y, -w * 4.0, top);
        return length(float2(p.x, p.y - y)) - w;
    }

    // u[0] = (width px, height px, band count, backing scale), u[1] = base rgba, u[2] = tip rgba, u[3] = glow rgba,
    // u[4].x = energy (0 paused … 1 playing). bands[i] = bar height as a fraction of the height.
    fragment float4 qt_stage_vis_fragment(QTVisOut in [[stage_in]], constant float4 *u [[buffer(0)]],
                                          constant float *bands [[buffer(1)]]) {
        float W = u[0].x, H = u[0].y, count = u[0].z, scale = u[0].w;
        float energy = u[4].x;
        float2 px = float2(in.uv.x * W, in.uv.y * H);   // y up from the bottom edge
        float slot = W / count;
        float half_w = max(slot * 0.28, 1.0 * scale);
        int n = int(count);
        int i = clamp(int(floor(px.x / slot)), 0, n - 1);

        float cover = 0.0;
        float glow = 0.0;
        float h_here = bands[i] * H;
        for (int k = -2; k <= 2; k++) {
            int j = i + k;
            if (j < 0 || j >= n) { continue; }
            float h = bands[j] * H;
            float2 local = float2(px.x - (float(j) + 0.5) * slot, px.y);
            float d = qt_bar_sd(local, half_w, h);
            if (k == 0) { cover = clamp(0.5 - d / max(scale, 1.0), 0.0, 1.0); }
            glow += exp(-max(d, 0.0) / (slot * 1.6)) * (0.35 + 0.65 * smoothstep(0.0, 0.25 * H, h));
        }

        // Bars: deep accent at the floor rising to a pale tip; brighter near the top of each bar.
        float rise = clamp(px.y / max(h_here, 1.0), 0.0, 1.0);
        float heightT = smoothstep(0.0, 0.3 * H, px.y);
        float3 barRGB = mix(u[1].rgb, u[2].rgb, clamp(heightT * 0.55 + pow(rise, 1.5) * 0.55, 0.0, 1.0));
        float barA = (0.4 + 0.52 * rise) * cover;

        // Bloom around the bars (stronger while playing) and a floor glow that grounds the row.
        float bloom = glow * (0.05 + 0.08 * energy);
        float floorGlow = exp(-px.y / (H * (0.05 + 0.03 * energy))) * (0.12 + 0.14 * energy);
        float3 glowRGB = u[3].rgb;

        float a = barA + (bloom + floorGlow) * (1.0 - barA);
        float3 rgb = barRGB * barA + glowRGB * (bloom + floorGlow) * (1.0 - barA);
        return float4(rgb, clamp(a, 0.0, 1.0));
    }
    """
}
