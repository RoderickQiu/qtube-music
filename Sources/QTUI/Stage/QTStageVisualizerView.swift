import AppKit
import Metal
import MetalKit
import QTPlayback
import SwiftUI

/// Audio-reactive spectrum bars drawn in Metal over the blurred art (Premium only).
/// Data: `QTPlaybackEngine.spectrum(bandCount:)` when the engine provides it; otherwise (M1, simulated engine)
/// a synthetic spectrum with the prototype's envelope and beat. Stops drawing once the bars settle while paused,
/// holds a still frame on battery, and runs at 30 fps in Low Power Mode / Reduce Motion.
struct QTStageVisualizerView: NSViewRepresentable {
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
        let rgb = NSColor(accent).usingColorSpace(.sRGB) ?? .white
        renderer.accent = SIMD4(Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent), 1)
        renderer.engine = player.engine
        renderer.update(isPlaying: isPlaying, policy: policy)
    }

    func makeCoordinator() -> QTStageVisualizerRenderer { QTStageVisualizerRenderer() }

    static func dismantleNSView(_ view: MTKView, coordinator: QTStageVisualizerRenderer) {
        view.isPaused = true
        view.delegate = nil
    }
}

final class QTStageVisualizerMTKView: MTKView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class QTStageVisualizerRenderer: NSObject, MTKViewDelegate {
    nonisolated static let bandCount = 96

    var accent = SIMD4<Float>(1, 1, 1, 1)
    weak var engine: (any QTPlaybackEngine)?

    private var pipeline: MTLRenderPipelineState?
    private var queue: MTLCommandQueue?
    private weak var view: MTKView?
    private var bands = [Float](repeating: 0.012, count: QTStageVisualizerRenderer.bandCount)
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

    func update(isPlaying: Bool, policy: QTStageMotionPolicy) {
        self.isPlaying = isPlaying
        animate = policy.allowsVisualizerAnimation
        guard let view else { return }
        view.preferredFramesPerSecond = policy.visualizerFPS
        if animate {
            view.isPaused = false
        } else {
            // Still frame: a calm, representative spectrum.
            bands = Self.synthetic(t: 2.2, playing: true)
            view.isPaused = true
            view.draw()
        }
    }

    // MARK: MTKViewDelegate

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(in: view) }
    }

    private func render(in view: MTKView) {
        if animate { step() }
        guard let pipeline, let queue, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let size = view.drawableSize
        var uniforms = [SIMD4<Float>(Float(size.width), Float(size.height), Float(bands.count), 0), accent]
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride * 2, index: 0)
        bands.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()

        // Settled while paused: stop the display link until playback resumes.
        if animate && !isPlaying && bands.allSatisfy({ $0 < 0.02 }) { view.isPaused = true }
    }

    private func step() {
        let t = CACurrentMediaTime() - start
        let target: [Float]
        if isPlaying, let real = engine?.spectrum(bandCount: bands.count), real.count == bands.count {
            target = real.map { min(max($0, 0), 1) * 0.5 }
        } else {
            target = Self.synthetic(t: t, playing: isPlaying)
        }
        for i in bands.indices {
            let k: Float = target[i] > bands[i] ? 0.45 : 0.12
            bands[i] += (target[i] - bands[i]) * k
        }
    }

    /// The prototype's synthetic spectrum (stage.jsx `Visualizer`), as a fraction of the view height.
    nonisolated static func synthetic(t: Double, playing: Bool) -> [Float] {
        (0..<bandCount).map { i in
            guard playing else { return 0.012 }
            let x = Double(i) / Double(bandCount)
            let env = exp(-pow((x - 0.18) / 0.22, 2)) * 0.9 + exp(-pow((x - 0.55) / 0.3, 2)) * 0.5 + 0.08
            let n = 0.55 + 0.45 * sin(t * (2.1 + Double(i) * 0.13) + Double(i)) * sin(t * 1.3 + Double(i) * 0.7)
            let beat = pow(max(0, sin(t * .pi * 2 * 1.4)), 6)
            return Float((env * n + beat * env * 0.6) * 0.34)
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

    // u[0] = (width px, height px, band count, -), u[1] = accent rgba. bands[i] = bar height as a fraction of height.
    fragment float4 qt_stage_vis_fragment(QTVisOut in [[stage_in]], constant float4 *u [[buffer(0)]],
                                          constant float *bands [[buffer(1)]]) {
        float count = u[0].z;
        float x = in.uv.x * count;
        uint i = min(uint(x), uint(count) - 1);
        float fx = fract(x);
        float barPx = u[0].x / count;
        float gap = clamp(1.5 / barPx, 0.0, 0.35);
        // Soft-edged bars (anti-aliased sides).
        float edge = 1.0 / barPx;
        float side = smoothstep(gap, gap + edge, fx) * (1.0 - smoothstep(1.0 - gap - edge, 1.0 - gap, fx));
        if (side <= 0.0) { return float4(0); }

        float xn = (float(i) + 0.5) / count;
        float env = exp(-pow((xn - 0.18) / 0.22, 2.0)) * 0.9 + exp(-pow((xn - 0.55) / 0.3, 2.0)) * 0.5 + 0.08;
        float h = bands[i];
        float y = in.uv.y;            // 0 = bottom
        float a = 0.0;
        float cap = 1.5 / u[0].y;
        if (y < h) {
            float lift = y / max(h, 1e-3);
            a = (0.12 + 0.36 * env) * (0.7 + 0.3 * lift);
            a *= 1.0 - smoothstep(h - cap, h, y) * 0.5;
        } else if (1.0 - y < h * 0.35) {
            a = 0.045;                // faint reflection from the top edge
        }
        a *= side;
        return float4(u[1].rgb * a, a);
    }
    """
}
