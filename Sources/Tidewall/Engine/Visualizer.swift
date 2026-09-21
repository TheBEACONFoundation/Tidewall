import AppKit
import Metal
import MetalKit
import simd

/// Colour schemes for the audio visualizer.
enum VisualizerPalette: String, Codable, CaseIterable, Identifiable {
    case neon, lantern, ember, ice, mono

    var id: String { rawValue }

    var title: String {
        switch self {
        case .neon: "Neon"
        case .lantern: "Lantern Green"
        case .ember: "Ember"
        case .ice: "Ice"
        case .mono: "Moonlight"
        }
    }

    /// Low → mid → high frequencies, and the background.
    var colors: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
        switch self {
        case .neon: ([0.20, 0.85, 1.00, 1], [0.55, 0.35, 1.00, 1], [1.00, 0.30, 0.70, 1], [0.012, 0.010, 0.030, 1])
        case .lantern: ([0.24, 0.95, 0.40, 1], [0.08, 0.70, 0.45, 1], [0.65, 1.00, 0.70, 1], [0.010, 0.030, 0.015, 1])
        case .ember: ([1.00, 0.30, 0.18, 1], [1.00, 0.55, 0.15, 1], [1.00, 0.88, 0.45, 1], [0.030, 0.010, 0.008, 1])
        case .ice: ([0.30, 0.55, 1.00, 1], [0.50, 0.85, 1.00, 1], [0.88, 0.96, 1.00, 1], [0.010, 0.015, 0.035, 1])
        case .mono: ([0.60, 0.62, 0.72, 1], [0.82, 0.84, 0.92, 1], [1.00, 1.00, 1.00, 1], [0.015, 0.015, 0.022, 1])
        }
    }
}

/// What a live, audio-reactive wallpaper looks like.
struct VisualizerSettings: Codable, Hashable {
    var palette: VisualizerPalette = .neon
    /// How far the bars reach for a given loudness.
    var sensitivity: Double = 1
    /// Nebula and particle activity.
    var motion: Double = 1
    /// Fraction of the display's resolution the scene renders at.
    var quality: Double = 0.5

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VisualizerSettings()
        palette = try c.decode(.palette, default: d.palette)
        sensitivity = try c.decode(.sensitivity, default: d.sensitivity)
        motion = try c.decode(.motion, default: d.motion)
        quality = try c.decode(.quality, default: d.quality)
    }
}

/// Mirrors the shader's `Uniforms` struct byte for byte.
struct VisualizerUniforms {
    var resolution: SIMD2<Float> = .zero
    var center: SIMD2<Float> = [0.5, 0.5]
    var time: Float = 0
    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    var level: Float = 0
    var beat: Float = 0
    var beatAge: Float = 10
    var sensitivity: Float = 1
    var motion: Float = 1
    /// Integrated particle travel and nebula drift: they speed up with the
    /// music without ever jumping.
    var flight: Float = 0
    var drift: Float = 0
    var pad: Float = 0
    var colorA: SIMD4<Float> = .zero
    var colorB: SIMD4<Float> = .zero
    var colorC: SIMD4<Float> = .zero
    var background: SIMD4<Float> = .zero
}

/// Compiles the "Pulse" shader once and draws it into views or images.
@MainActor
final class VisualizerRenderer {
    static let shared = VisualizerRenderer()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.source, options: nil),
              let vertex = library.makeFunction(name: "pulse_vertex"),
              let fragment = library.makeFunction(name: "pulse_fragment")
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
    }

    func encode(_ encoder: MTLRenderCommandEncoder, uniforms: VisualizerUniforms, spectrum: [Float]) {
        var u = uniforms
        var bands = spectrum
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<VisualizerUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&bands, length: MemoryLayout<Float>.stride * bands.count, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    nonisolated static func uniforms(settings: VisualizerSettings, frame: AudioAnalyzer.Frame, size: CGSize,
                         time: Float, flight: Float, drift: Float) -> VisualizerUniforms {
        let (a, b, c, bg) = settings.palette.colors
        return VisualizerUniforms(
            resolution: [Float(size.width), Float(size.height)],
            time: time, bass: frame.bass, mid: frame.mid, treble: frame.treble, level: frame.level,
            beat: frame.beat, beatAge: frame.beatAge, sensitivity: Float(settings.sensitivity),
            motion: Float(settings.motion), flight: flight, drift: drift,
            colorA: a, colorB: b, colorC: c, background: bg)
    }

    /// A representative moment of music, for thumbnails and stills.
    nonisolated static var demoFrame: AudioAnalyzer.Frame {
        var f = AudioAnalyzer.Frame()
        f.spectrum = (0..<AudioAnalyzer.bandCount).map { i in
            let x = Float(i) / Float(AudioAnalyzer.bandCount)
            return max(0.08, 0.85 - 0.6 * x + 0.18 * sin(x * 23) + 0.1 * sin(x * 61 + 1))
        }
        f.bass = 0.75; f.mid = 0.5; f.treble = 0.35; f.level = 0.6
        f.beat = 0.4; f.beatAge = 0.35; f.isSilent = false
        return f
    }

    /// Renders one frame to an image (thumbnails, the matching macOS still).
    func snapshot(settings: VisualizerSettings, size: CGSize, frame: AudioAnalyzer.Frame = demoFrame) -> CGImage? {
        render(size: size) { encoder in
            encode(encoder, uniforms: Self.uniforms(settings: settings, frame: frame, size: size, time: 12, flight: 7.3, drift: 21),
                   spectrum: frame.spectrum)
        }
    }

    /// Draws one frame offscreen with `draw` and reads it back as an image.
    func render(size: CGSize, _ draw: (MTLRenderCommandEncoder) -> Void) -> CGImage? {
        let width = Int(size.width), height = Int(size.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let buffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        draw(encoder)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 resolution; float2 center;
        float time, bass, mid, treble, level, beat, beatAge, sensitivity, motion, flight, drift, pad;
        float4 colorA, colorB, colorC, background;
    };
    struct VOut { float4 position [[position]]; };

    vertex VOut pulse_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut o; o.position = float4(p * 2.0 - 1.0, 0.0, 1.0); return o;
    }

    float hash21(float2 p) { p = fract(p * float2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
    float noise(float2 p) {
        float2 i = floor(p), f = fract(p), u = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash21(i), hash21(i + float2(1, 0)), u.x), mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), u.x), u.y);
    }
    float fbm(float2 p) {
        float v = 0.0, a = 0.5;
        for (int i = 0; i < 4; i++) { v += a * noise(p); p = p * 2.03 + 17.1; a *= 0.5; }
        return v;
    }
    float3 paint(float t, constant Uniforms &u) {
        t = clamp(t, 0.0, 1.0);
        return t < 0.5 ? mix(u.colorA.rgb, u.colorB.rgb, t * 2.0) : mix(u.colorB.rgb, u.colorC.rgb, t * 2.0 - 1.0);
    }

    fragment float4 pulse_fragment(VOut in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                                   constant float *spectrum [[buffer(1)]]) {
        float2 frag = float2(in.position.x, u.resolution.y - in.position.y);
        float2 p = (frag - u.center * u.resolution) / u.resolution.y;   // centred, 1 = screen height
        float r = length(p);
        float energy = u.level;
        float3 col = u.background.rgb;

        // Nebula: warped noise drifting on its own; the bass pushes it outward.
        float2 q = p * 1.7;
        float2 warp = float2(fbm(q + u.drift * 0.03), fbm(q + 5.2 - u.drift * 0.025));
        float n = fbm(q + warp * 1.5 - p / max(r, 0.05) * u.bass * 0.3 * u.motion);
        col += paint(n, u) * smoothstep(0.32, 0.95, n) * (0.11 + 0.36 * energy) * u.motion;

        // The spectrum: bars around a ring, lows at the bottom, highs at the top, mirrored.
        float R0 = 0.15 + 0.03 * u.bass;
        float s = acos(clamp(-p.y / max(r, 1e-4), -1.0, 1.0)) / M_PI_F;
        const float bars = 48.0;
        float idx = min(floor(s * bars), bars - 1.0);
        float amp = min(1.2, spectrum[int(idx)] * u.sensitivity);
        float len = 0.008 + 0.17 * amp;
        float arc = (s - (idx + 0.5) / bars) * M_PI_F * r;
        float halfW = 0.30 * M_PI_F * R0 / bars;
        float2 d2 = float2(abs(arc) - halfW, abs(r - (R0 + 0.012 + len * 0.5)) - len * 0.5);
        float dist = length(max(d2, 0.0)) + min(max(d2.x, d2.y), 0.0);
        float3 barColor = paint(s, u) + u.treble * 0.2;
        col += barColor * (smoothstep(0.003, 0.0, dist) * 0.85 + exp(-max(dist, 0.0) * 42.0) * (0.18 + 0.55 * amp));

        // Ring and core
        col += paint(0.15, u) * exp(-abs(r - R0) * 220.0) * (0.35 + 0.9 * u.bass);
        col += paint(0.0, u) * exp(-r * 8.0) * (0.10 + 0.45 * u.bass + 0.45 * u.beat);
        float rings = 0.5 + 0.5 * sin(r * 120.0 - u.drift * 1.5 - u.bass * 5.0);
        col += paint(0.1, u) * rings * smoothstep(R0 * 0.85, R0 * 0.15, r) * 0.07 * (0.3 + energy);

        // A shockwave on every beat
        float wave = R0 + u.beatAge * 0.85;
        col += paint(0.85, u) * exp(-abs(r - wave) * 110.0) * exp(-u.beatAge * 2.4) * 0.8;

        // Motes streaming outward, faster when it's loud.
        float angle = atan2(p.y, p.x) / (2.0 * M_PI_F) + 0.5;
        for (int layer = 0; layer < 3; layer++) {
            float fl = float(layer);
            float count = 70.0 + fl * 50.0;
            float a = fract(angle + fl * 0.137);
            float cell = floor(a * count);
            float h = hash21(float2(cell, fl * 7.1 + 1.0));
            if (h < 0.3) continue;
            float life = fract(u.flight * (0.35 + 0.6 * hash21(float2(cell, fl + 3.3))) + h * 13.0);
            float pr = R0 + 0.03 + life * (0.85 + fl * 0.35);
            float da = (a - (cell + 0.5) / count) * 2.0 * M_PI_F * r;
            float d = length(float2(da, (r - pr) * 0.5));
            float size = 0.0012 + 0.0035 * life;
            float fade = smoothstep(0.0, 0.08, life) * (1.0 - life);
            col += paint(h, u) * exp(-d / size) * fade * (0.2 + 0.9 * energy + 0.3 * u.treble) * u.motion;
        }

        col *= 1.0 - 0.4 * smoothstep(0.45, 1.3, length(p * float2(0.75, 1.0)));
        col = 1.0 - exp(-col * 1.3);
        col += (hash21(frag + fract(u.time)) - 0.5) / 255.0;   // dither away banding
        return float4(col, 1.0);
    }
    """
}

/// What a live wallpaper draws.
enum LiveContent: Hashable {
    case pulse(VisualizerSettings)
    case blocks(Composition)

    init?(_ wallpaper: Wallpaper) {
        if let settings = wallpaper.visualizer {
            self = .pulse(settings)
        } else if let composition = wallpaper.composition {
            self = .blocks(composition)
        } else {
            return nil
        }
    }

    /// Only listen to the Mac's audio when the picture uses it.
    var needsAudio: Bool {
        switch self {
        case .pulse: true
        case .blocks(let composition): composition.usesAudio
        }
    }

    var quality: Double {
        switch self {
        case .pulse(let settings): settings.quality
        case .blocks: 0.5
        }
    }

    /// A representative frame, for thumbnails and stills.
    @MainActor
    func snapshot(size: CGSize) -> CGImage? {
        switch self {
        case .pulse(let settings): VisualizerRenderer.shared?.snapshot(settings: settings, size: size)
        case .blocks(let composition): BlocksRenderer.shared?.snapshot(composition, size: size)
        }
    }
}

/// A Metal view that draws a live wallpaper from the shared audio analysis.
final class VisualizerView: MTKView, MTKViewDelegate {
    var content: LiveContent {
        didSet { if content.quality != oldValue.quality { updateDrawableSize() } }
    }
    var needsAudio: Bool { content.needsAudio }
    private var flight: Float = 0
    private var drift: Float = 0
    private var motion = BlocksMotion()
    private var lastTime = CACurrentMediaTime()
    private var quietSince: CFTimeInterval?

    override var isPaused: Bool {
        didSet {
            // Hidden is the time to rewind the travel counters; drawing once
            // leaves a picture that already matches for when it's seen again.
            if isPaused, !oldValue, window != nil, rewindMotion(beyond: 1024) { draw() }
        }
    }

    /// The travel counters only ever grow, and past a few thousand a Float
    /// can't resolve one frame's step, so motion would start to stutter.
    /// Rewinding jumps the picture, so it waits for the view to be hidden
    /// unless it has run visibly for many hours.
    private func rewindMotion(beyond limit: Double) -> Bool {
        guard Double(max(flight, drift)) > limit || motion.phases.values.contains(where: { abs($0) > limit })
        else { return false }
        flight = 0
        drift = 0
        motion = BlocksMotion()
        return true
    }

    init?(frame: CGRect, content: LiveContent) {
        guard let renderer = VisualizerRenderer.shared else { return nil }
        self.content = content
        super.init(frame: frame, device: renderer.device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        autoResizeDrawable = false
        preferredFramesPerSecond = 60
        layer?.isOpaque = true
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = (window?.backingScaleFactor ?? 2) * min(1, max(0.25, content.quality))
        drawableSize = CGSize(width: max(16, bounds.width * scale), height: max(16, bounds.height * scale))
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let renderer = VisualizerRenderer.shared,
              let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let buffer = renderer.queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let now = CACurrentMediaTime()
        let dt = Float(min(0.1, now - lastTime))
        lastTime = now
        let frame = needsAudio ? MainActor.assumeIsolated { AudioReactor.shared.frame(at: now) } : AudioAnalyzer.Frame()
        let time = Float(now.truncatingRemainder(dividingBy: 1000))

        // Full frame rate while music moves the picture, less when it doesn't.
        let idleRate = needsAudio ? 20 : 30
        if frame.level < 0.02 {
            quietSince = quietSince ?? now
            if now - quietSince! > 2, preferredFramesPerSecond != idleRate { preferredFramesPerSecond = idleRate }
        } else {
            quietSince = nil
            if preferredFramesPerSecond != 60 { preferredFramesPerSecond = 60 }
        }

        _ = rewindMotion(beyond: 8192)
        switch content {
        case .pulse(let settings):
            // Travel speeds follow the music; integrating them keeps motion smooth.
            flight += dt * (0.04 + 0.55 * frame.level) * Float(settings.motion)
            drift += dt * (0.25 + 2.0 * frame.level)
            let uniforms = VisualizerRenderer.uniforms(settings: settings, frame: frame, size: drawableSize,
                                                       time: time, flight: flight, drift: drift)
            MainActor.assumeIsolated { renderer.encode(encoder, uniforms: uniforms, spectrum: frame.spectrum) }
        case .blocks(let composition):
            motion.advance(composition, frame: frame, by: Double(dt))
            let (scene, blocks) = BlocksRenderer.uniforms(composition, frame: frame, motion: motion,
                                                          size: drawableSize, time: time)
            MainActor.assumeIsolated {
                BlocksRenderer.shared?.encode(encoder, scene: scene, blocks: blocks, spectrum: frame.spectrum)
            }
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}
