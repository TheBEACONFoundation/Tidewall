import CoreGraphics
import Foundation
import Metal
import simd

/// Mirrors the shader's `Scene`.
struct BlocksScene {
    var resolution: SIMD2<Float> = .zero
    var time: Float = 0
    var count: Int32 = 0
    var audio: SIMD4<Float> = .zero   // bass, mid, treble, level
    var beat: SIMD4<Float> = .zero    // beat, seconds since it
}

/// Mirrors the shader's `BlockData`: one block, with its reaction to the
/// music already applied.
struct BlockUniform {
    var kind: Int32 = 0
    /// Texture blocks: their texture's index, or -1 when they have none.
    var flags: Int32 = 0
    var opacity: Float = 1
    /// Texture blocks: the texture's width over height.
    var pad: Float = 0
    var colorA: SIMD4<Float> = .zero
    var colorB: SIMD4<Float> = .zero
    var params: SIMD4<Float> = .zero   // amount, size, detail, count
    var place: SIMD4<Float> = .zero    // x, y, phase, reaction
}

/// Per-view motion state: each block's travel is integrated over time, so
/// speeding up with the music never makes anything jump.
struct BlocksMotion {
    var phases: [UUID: Double] = [:]

    mutating func advance(_ composition: Composition, frame: AudioAnalyzer.Frame, by dt: Double) {
        for block in composition.blocks where block.enabled {
            let boost = Double(block.react.value(in: frame)) * block.reactStrength
            phases[block.id, default: 0] += dt * block.speed * (1 + 2 * boost)
        }
    }
}

/// Draws block compositions with one precompiled shader.
@MainActor
final class BlocksRenderer {
    static let shared = BlocksRenderer()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let textures: BlockTextures

    private init?() {
        guard let base = VisualizerRenderer.shared,
              let library = try? base.device.makeLibrary(source: Self.source, options: nil),
              let vertex = library.makeFunction(name: "blocks_vertex"),
              let fragment = library.makeFunction(name: "blocks_fragment")
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? base.device.makeRenderPipelineState(descriptor: descriptor),
              let textures = BlockTextures(device: base.device, queue: base.queue)
        else { return nil }
        self.textures = textures
        device = base.device
        queue = base.queue
        self.pipeline = pipeline
    }

    /// - Parameter slots: where each clock, text and picture block's
    ///   texture is; those without one draw nothing.
    nonisolated static func uniforms(_ composition: Composition, frame: AudioAnalyzer.Frame, motion: BlocksMotion,
                                     size: CGSize, time: Float,
                                     slots: [UUID: BlockTextureSlot] = [:]) -> (BlocksScene, [BlockUniform]) {
        func color(_ c: RGBAColor) -> SIMD4<Float> { [Float(c.red), Float(c.green), Float(c.blue), 1] }
        let blocks = composition.blocks.filter(\.enabled).prefix(Composition.maxBlocks).map { b -> BlockUniform in
            let reaction = Float(Double(b.react.value(in: frame)) * b.reactStrength)
            let slot = slots[b.id]
            // Type sizes itself from its texture; everything else from its detail setting.
            let detail = b.kind.isType ? (slot?.height ?? 0) * (1 + 0.35 * reaction) : Float(b.detail)
            return BlockUniform(
                kind: Int32(b.kind.rawValue), flags: b.kind.usesTexture ? slot?.index ?? -1 : 0,
                opacity: Float(b.opacity), pad: slot?.aspect ?? 0,
                colorA: color(b.colorA), colorB: color(b.colorB),
                // Reacting blocks brighten and swell with the music.
                params: [Float(b.amount) * (1 + 1.2 * reaction), Float(b.size) * (1 + 0.35 * reaction),
                         detail, Float(b.count)],
                place: [Float(b.x), Float(b.y), Float(motion.phases[b.id] ?? 0), reaction])
        }
        let scene = BlocksScene(resolution: [Float(size.width), Float(size.height)], time: time,
                                count: Int32(blocks.count),
                                audio: [frame.bass, frame.mid, frame.treble, frame.level],
                                beat: [frame.beat, frame.beatAge, 0, 0])
        return (scene, Array(blocks))
    }

    func encode(_ encoder: MTLRenderCommandEncoder, scene: BlocksScene, blocks: [BlockUniform], spectrum: [Float],
                textures: [MTLTexture]) {
        var s = scene
        var b = blocks.isEmpty ? [BlockUniform()] : blocks
        var bands = spectrum
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&s, length: MemoryLayout<BlocksScene>.stride, index: 0)
        encoder.setFragmentBytes(&b, length: MemoryLayout<BlockUniform>.stride * b.count, index: 1)
        encoder.setFragmentBytes(&bands, length: MemoryLayout<Float>.stride * bands.count, index: 2)
        encoder.setFragmentTextures(textures, range: 0..<textures.count)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// One frame as an image, with a moment of music (thumbnails, stills,
    /// tests). `date` sets the clocks; nil leaves them out.
    func snapshot(_ composition: Composition, size: CGSize, frame: AudioAnalyzer.Frame = VisualizerRenderer.demoFrame,
                  motion: BlocksMotion? = nil, date: Date? = .now) -> CGImage? {
        var m = motion ?? BlocksMotion()
        if motion == nil { m.advance(composition, frame: frame, by: 6) }
        let (bound, slots) = textures.prepare(composition, drawableHeight: size.height, date: date)
        let (scene, blocks) = Self.uniforms(composition, frame: frame, motion: m, size: size, time: 6, slots: slots)
        return VisualizerRenderer.shared?.render(size: size) { encoder in
            encode(encoder, scene: scene, blocks: blocks, spectrum: frame.spectrum, textures: bound)
        }
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Scene { float2 resolution; float time; int count; float4 audio; float4 beat; };
    struct BlockData { int kind; int flags; float opacity; float pad; float4 colorA; float4 colorB; float4 params; float4 place; };
    struct VOut { float4 position [[position]]; };

    vertex VOut blocks_vertex(uint vid [[vertex_id]]) {
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

    // Each block returns its colour and how much of it to lay over what's below;
    // `add` blocks are light, added on top.
    struct Layer { float3 color; float alpha; bool add; };

    Layer gradient(BlockData b, float2 uv, float aspect) {
        float angle = (b.params.z + b.place.z * 0.05) * 2.0 * M_PI_F;
        float2 dir = float2(sin(angle), cos(angle));
        float t = clamp(dot((uv - 0.5) * float2(aspect, 1.0), dir) / max(0.5, 0.5 * aspect) + 0.5, 0.0, 1.0);
        return { mix(b.colorB.rgb, b.colorA.rgb, smoothstep(0.0, 1.0, t)), 1.0, false };
    }

    Layer aurora(BlockData b, float2 p, float2 uv) {
        // Curtains of light: a bright, wavy lower edge fading upward through
        // fine vertical streaks, first colour at the edge, second above it.
        float s = b.params.y, ph = b.place.z * 0.15;
        float n = fbm(float2(p.x * 1.2 / s + ph, ph * 0.5));
        float edge = b.place.y + (n - 0.5) * 0.3 * s - 0.08 * s;
        float h = uv.y - edge;
        float curtain = h > 0.0 ? exp(-h * 4.5 / s) : exp(h * 70.0 / s);
        float streak = 0.35 + 0.65 * fbm(float2(p.x * 16.0 / s + ph * 2.5, 0.3));
        float3 c = mix(b.colorA.rgb, b.colorB.rgb, clamp(h * 2.5 / s, 0.0, 1.0));
        return { c, curtain * streak * b.params.x * 0.95, true };
    }

    Layer particles(BlockData b, float2 p, float aspect, float2 uv) {
        float3 total = float3(0.0);
        int dirIndex = int(b.params.z + 0.5);
        for (int layer = 0; layer < 3; layer++) {
            float fl = float(layer);
            float depth = 0.55 + 0.25 * fl;
            float cells = mix(40.0, 14.0, fl / 2.0);
            float2 q;
            float travel = b.place.z * (0.15 + 0.1 * fl);
            if (dirIndex >= 4) {
                // Outward / inward: polar cells so particles stream from the centre.
                float r = length(p), a = atan2(p.y, p.x) / (2.0 * M_PI_F) + 0.5;
                float lr = log(max(r, 0.02)) * 3.0 - (dirIndex == 4 ? travel : -travel) * 6.0;
                q = float2(a * cells * 2.0 + fl * 13.1, lr);
            } else {
                // Shifting the pattern against the direction moves particles along it.
                float2 dirs[4] = { float2(0, -1), float2(0, 1), float2(1, 0), float2(-1, 0) };
                q = float2(p.x, p.y) * cells + dirs[dirIndex] * travel * cells + fl * 17.3;
            }
            float2 cell = floor(q), f = fract(q) - 0.5;
            float h = hash21(cell + fl * 3.7);
            if (h > b.params.w) continue;
            float2 offset = float2(hash21(cell + 1.3), hash21(cell + 7.9)) - 0.5;
            float d = length(f - offset * 0.7);
            float size = 0.06 * b.params.y * depth;
            float twinkle = 0.6 + 0.4 * sin(b.place.z * 3.0 + h * 40.0);
            float3 c = mix(b.colorA.rgb, b.colorB.rgb, hash21(cell + 4.4));
            total += c * exp(-d / max(size, 0.004)) * twinkle * depth;
        }
        return { total, clamp(b.params.x, 0.0, 2.0), true };
    }

    Layer waves(BlockData b, float2 p, float2 uv) {
        float3 total = float3(0.0);
        int lines = int(clamp(b.params.w, 1.0, 8.0));
        for (int i = 0; i < lines; i++) {
            float fi = float(i) / max(1.0, float(lines - 1));
            float amp = 0.035 * b.params.y * (1.0 + fi);
            float y = b.place.y - fi * 0.18 + amp * sin(p.x * (3.0 + fi * 2.0) + b.place.z * (1.0 + fi) + fi * 2.0)
                      + amp * 0.5 * sin(p.x * 7.3 - b.place.z * 1.7 + fi * 5.0);
            float d = abs(uv.y - y);
            total += mix(b.colorA.rgb, b.colorB.rgb, fi) * (exp(-d * 400.0) + exp(-d * 45.0) * 0.35);
        }
        return { total, clamp(b.params.x, 0.0, 2.0), true };
    }

    Layer orb(BlockData b, float2 p, float2 center) {
        float r = length(p - center) / max(0.02, 0.18 * b.params.y);
        float glow = exp(-r * 1.6) * 0.8 + smoothstep(1.02, 0.98, r) * 0.6 + exp(-r * 0.6) * 0.15;
        return { b.colorA.rgb, glow * b.params.x, true };
    }

    Layer rays(BlockData b, float2 p, float2 center) {
        float2 d = p - center;
        float a = atan2(d.y, d.x) + b.place.z * 0.4;
        float beams = max(3.0, floor(b.params.w));
        float s = pow(abs(sin(a * beams * 0.5)), 12.0);
        float fade = exp(-length(d) * 1.4);
        return { b.colorA.rgb, s * fade * 0.6 * b.params.x, true };
    }

    Layer ripples(BlockData b, float2 p, float2 center, float beatAge) {
        float r = length(p - center);
        float3 total = float3(0.0);
        for (int k = 0; k < 3; k++) {
            float phase = fract(b.place.z * 0.35 + float(k) / 3.0);
            float radius = phase * 0.8 * b.params.y;
            total += b.colorA.rgb * exp(-abs(r - radius) * 160.0) * pow(1.0 - phase, 1.5);
        }
        // Reacting to the beat adds a fresh ring on every hit.
        float hit = b.place.w > 0.0 ? exp(-abs(r - beatAge * 0.9 * b.params.y) * 120.0) * exp(-beatAge * 2.5) : 0.0;
        return { total + b.colorA.rgb * hit, b.params.x, true };
    }

    Layer grid(BlockData b, float2 uv, float aspect) {
        float horizon = b.place.y;
        if (uv.y >= horizon) return { float3(0.0), 0.0, true };
        float depth = (horizon - uv.y) / horizon;          // 1 at the bottom
        float z = 1.0 / max(depth, 0.001);
        float gx = (uv.x - 0.5) * aspect * z * 3.0;
        float gz = z * 2.0 + b.place.z * 2.0;
        float lx = abs(fract(gx) - 0.5), lz = abs(fract(gz) - 0.5);
        float width = 0.03 * z;
        float line = max(smoothstep(width, 0.0, lx), smoothstep(width, 0.0, lz));
        float fade = smoothstep(0.0, 0.6, depth);
        return { b.colorA.rgb, line * fade * b.params.x + exp(-(horizon - uv.y) * 40.0) * 0.4 * b.params.x, true };
    }

    Layer spectrumRing(BlockData b, float2 p, float2 center, constant float *spectrum) {
        float2 d = p - center;
        float r = length(d);
        float R0 = 0.12 * b.params.y;
        float s = acos(clamp(-d.y / max(r, 1e-4), -1.0, 1.0)) / M_PI_F;
        float idx = min(floor(s * 48.0), 47.0);
        float amp = spectrum[int(idx)];
        float len = 0.006 + 0.14 * b.params.y * amp;
        float arc = (s - (idx + 0.5) / 48.0) * M_PI_F * r;
        float2 box = float2(abs(arc) - 0.3 * M_PI_F * R0 / 48.0, abs(r - (R0 + len * 0.5)) - len * 0.5);
        float dist = length(max(box, 0.0)) + min(max(box.x, box.y), 0.0);
        float3 c = mix(b.colorA.rgb, b.colorB.rgb, s);
        float light = smoothstep(0.003, 0.0, dist) * 0.9 + exp(-max(dist, 0.0) * 40.0) * (0.2 + 0.5 * amp)
                    + exp(-abs(r - R0) * 250.0) * 0.5;
        return { c, light * b.params.x, true };
    }

    Layer equalizer(BlockData b, float2 uv, constant float *spectrum) {
        float bars = clamp(floor(b.params.w), 8.0, 64.0);
        float i = floor(uv.x * bars);
        float band = spectrum[int(i / bars * 48.0)];
        float h = 0.01 + 0.17 * b.params.y * band;
        float fx = fract(uv.x * bars);
        float inBar = step(0.12, fx) * step(fx, 0.88) * step(uv.y, h);
        float glow = exp(-max(uv.y - h, 0.0) * 30.0) * step(0.12, fx) * step(fx, 0.88) * 0.35;
        float3 c = mix(b.colorA.rgb, b.colorB.rgb, uv.y / max(h, 0.01));
        return { c, (inBar * 0.75 + glow) * b.params.x, true };
    }

    fragment float4 blocks_fragment(VOut in [[stage_in]], constant Scene &scene [[buffer(0)]],
                                    constant BlockData *blocks [[buffer(1)]], constant float *spectrum [[buffer(2)]],
                                    array<texture2d<float>, 8> textures [[texture(0)]]) {
        constexpr sampler ts(filter::linear, mip_filter::linear, address::clamp_to_zero);
        float2 frag = float2(in.position.x, scene.resolution.y - in.position.y);
        float2 uv = frag / scene.resolution;
        float aspect = scene.resolution.x / scene.resolution.y;
        float2 p = (uv - 0.5) * float2(aspect, 1.0);       // centred, 1 = screen height
        float3 col = float3(0.0);

        for (int i = 0; i < scene.count; i++) {
            BlockData b = blocks[i];
            float2 center = (b.place.xy - 0.5) * float2(aspect, 1.0);
            Layer l;
            switch (b.kind) {
                case 0: l = gradient(b, uv, aspect); break;
                case 1: l = aurora(b, p, uv); break;
                case 2: l = particles(b, p, aspect, uv); break;
                case 3: l = waves(b, p, uv); break;
                case 4: l = orb(b, p, center); break;
                case 5: l = rays(b, p, center); break;
                case 6: l = ripples(b, p, center, scene.beat.y); break;
                case 7: l = grid(b, uv, aspect); break;
                case 8: l = spectrumRing(b, p, center, spectrum); break;
                case 9: l = equalizer(b, uv, spectrum); break;
                case 10: {
                    float v = smoothstep(0.35 * b.params.y, 1.1 * b.params.y, length(p * float2(0.8, 1.0)));
                    col *= 1.0 - v * clamp(b.params.x, 0.0, 1.5) * 0.66 * b.opacity;
                    continue;
                }
                case 11: case 12: {
                    // Type: white coverage in one channel; a blurred mip level glows around it.
                    if (b.flags < 0) continue;
                    float h = max(b.params.z, 1e-4), w = h * b.pad;
                    float2 q = (p - center) / float2(w, h);
                    float2 t = float2(q.x + 0.5, 0.5 - q.y);
                    float ink = textures[b.flags].sample(ts, t).r;
                    float glow = 0.6 * textures[b.flags].sample(ts, t, level(3.5)).r
                               + 0.4 * textures[b.flags].sample(ts, t, level(5.5)).r;
                    col += b.colorA.rgb * glow * b.params.x * 0.9 * b.opacity;
                    col = mix(col, b.colorA.rgb, clamp(ink * b.opacity, 0.0, 1.0));
                    continue;
                }
                case 13: {
                    // A picture: filling the screen with a slow drift, or placed freely.
                    if (b.flags < 0) continue;
                    float2 t;
                    if (b.params.z < 0.5) {
                        float zoom = (1.08 + 0.05 * sin(b.place.z * 0.23)) * (1.0 + 0.04 * b.place.w);
                        float2 drift = float2(sin(b.place.z * 0.13), cos(b.place.z * 0.17)) * 0.025;
                        float2 fit = aspect > b.pad ? float2(1.0, b.pad / aspect) : float2(aspect / b.pad, 1.0);
                        float2 c = (uv - 0.5) * fit / zoom + 0.5 + drift * fit;
                        t = float2(c.x, 1.0 - c.y);
                    } else {
                        float h = 0.5 * b.params.y, w = h * b.pad;
                        float2 q = (p - center) / float2(w, h);
                        t = float2(q.x + 0.5, 0.5 - q.y);
                    }
                    float4 s = textures[b.flags].sample(ts, t);
                    col = mix(col, s.rgb * b.params.x, clamp(s.a * b.opacity, 0.0, 1.0));
                    continue;
                }
                default: continue;
            }
            float a = l.alpha * b.opacity;
            col = l.add ? col + l.color * a : mix(col, l.color, clamp(a, 0.0, 1.0));
        }
        // Soften only bright light; colours the user picked below it stay exact.
        float3 over = max(col - 0.75, 0.0);
        col = min(col, 0.75) + 0.25 * (1.0 - exp(-over * 4.0));
        col += (hash21(frag + fract(scene.time)) - 0.5) / 255.0;
        return float4(col, 1.0);
    }
    """
}
