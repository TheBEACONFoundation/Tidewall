// Renders a battery-reactive wallpaper that belongs with the Lantern desktop
// battery gauge: one seamless loop per charge state, lit from exactly where the
// emblem sits, with motes that move the way Lantern's own do for that corps.
//
//   swiftc -O Scripts/make-lantern.swift -o .build/tools/make-lantern
//   .build/tools/make-lantern --package ~/Movies/Lantern.tidewall
//   .build/tools/make-lantern --still frame.png 0.3 normal
//
// The emblem's position and size are measured from Lantern's window while it
// runs (falling back to its saved settings), laid out exactly as Lantern lays
// it out, and the output matches the main display's pixel size, so the light
// sits behind the emblem 1:1. Override with --center X,Y (the emblem's centre)
// and --emblem DIAMETER, in points, and --screen WxH@SCALE.

import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

let tau = 2 * Double.pi
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let fps = 30
let loopSeconds = 12.0
let frameCount = Int(loopSeconds) * fps

// MARK: - Options and layout

var options: [String: String] = [:]
var positional: [String] = []
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        if arg.hasPrefix("--"), !["--still", "--package"].contains(arg), let value = it.next() {
            options[String(arg.dropFirst(2))] = value
        } else {
            positional.append(arg)
        }
    }
}

func pair(_ s: String?) -> (Double, Double)? {
    guard let parts = s?.split(separator: ","), parts.count == 2,
          let a = Double(parts[0]), let b = Double(parts[1]) else { return nil }
    return (a, b)
}

let lantern = UserDefaults(suiteName: "com.dominic.lantern")
let screen = NSScreen.main
let screenPoints: (Double, Double) = {
    if let s = options["screen"]?.split(separator: "@").first, let wh = pair(s.replacingOccurrences(of: "x", with: ",")) { return wh }
    return (Double(screen?.frame.width ?? 1728), Double(screen?.frame.height ?? 1080))
}()
let scale: Double = options["screen"]?.split(separator: "@").dropFirst().first.flatMap { Double($0) }
    ?? Double(screen?.backingScaleFactor ?? 2)
let W = (screenPoints.0 * scale).rounded()
let H = (screenPoints.1 * scale).rounded()

/// Where Lantern draws its emblem, in screen points (AppKit coordinates),
/// following Lantern's own layout:
/// - its window is a square canvas centred on the saved position, and the
///   emblem fills the middle 60% of it (`glowPadding` 0.40);
/// - the Size setting is 1/0.83 of the emblem's diameter;
/// - with Show Percentage on, the emblem is lifted by half the caption block
///   (5% of the diameter plus the cap height of the semibold digit font at 14%
///   of it), so ring and number together straddle the window's centre.
func lanternEmblem() -> (center: (Double, Double), diameter: Double, source: String) {
    var center: (Double, Double)?
    var diameter: Double?
    var source = "defaults"

    // The live window is the ground truth for where the canvas is.
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let primaryTop = Double(NSScreen.screens.first?.frame.maxY ?? CGFloat(screenPoints.1))
    if let window = windows.first(where: { ($0[kCGWindowOwnerName as String] as? String) == "Lantern" }),
       let bounds = (window[kCGWindowBounds as String]).flatMap({ CGRect(dictionaryRepresentation: $0 as! CFDictionary) }),
       bounds.width > 40, abs(bounds.width - bounds.height) < 1 {
        center = (Double(bounds.midX), primaryTop - Double(bounds.midY))
        diameter = Double(bounds.width) * (1 - 0.40)
        source = "Lantern's window"
    } else if lantern?.bool(forKey: "hasCenter") == true {
        center = (lantern!.double(forKey: "centerX"), lantern!.double(forKey: "centerY"))
        source = "Lantern's saved position"
    }
    let size = lantern?.double(forKey: "emblemSize") ?? 0
    let d = diameter ?? (size > 0 ? size : 190) * 0.83
    var c = center ?? (screenPoints.0 / 2, screenPoints.1 / 2)

    let showPercent = lantern?.object(forKey: "showPercent") as? Bool ?? true
    if showPercent {
        let font = NSFont.monospacedDigitSystemFont(ofSize: d * 0.14, weight: .semibold)
        c.1 += (d * 0.05 + Double(font.capHeight)) / 2
    }
    return (c, d, source)
}

let measured = lanternEmblem()
let centerPoints = pair(options["center"]) ?? measured.center
let emblemDiameter = Double(options["emblem"] ?? "") ?? measured.diameter
/// The emblem, in output pixels (y up, like Core Graphics and AppKit).
let C = CGPoint(x: centerPoints.0 * scale, y: centerPoints.1 * scale)
let R = emblemDiameter / 2 * scale

// MARK: - Helpers

struct RGB {
    var r, g, b: Double
    var a = 1.0
    func with(alpha: Double) -> RGB { RGB(r: r, g: g, b: b, a: alpha) }
    func mix(_ o: RGB, _ t: Double) -> RGB { RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t, a: a + (o.a - a) * t) }
    func scaled(_ k: Double) -> RGB { RGB(r: r * k, g: g * k, b: b * k, a: a) }
    var cg: CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }
}

func gradient(_ stops: [(Double, RGB)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1.cg) as CFArray, locations: stops.map { CGFloat($0.0) })!
}

func frac(_ x: Double) -> Double { x - floor(x) }

/// Deterministic per-particle randomness: the same (seed, a, b) always gives
/// the same value, which is what keeps every loop identical.
func hash(_ a: Int, _ b: Int, _ c: Int = 0) -> Double {
    var x = UInt64(bitPattern: Int64(a &* 73856093 ^ b &* 19349663 ^ c &* 83492791))
    x ^= x >> 33; x = x &* 0xff51afd7ed558ccd; x ^= x >> 33; x = x &* 0xc4ceb9fe1a85ec53; x ^= x >> 33
    return Double(x >> 11) / Double(UInt64(1) << 53)
}

func glowDot(_ ctx: CGContext, at p: CGPoint, radius r: Double, color: RGB) {
    ctx.drawRadialGradient(gradient([(0, color), (0.35, color.with(alpha: color.a * 0.45)), (1, color.with(alpha: 0))]),
                           startCenter: p, startRadius: 0, endCenter: p, endRadius: r, options: [])
}

// MARK: - Charge states, in Lantern's palettes

/// Lantern's motes, per corps (units of the emblem's radius and seconds). The
/// wallpaper's are the same behaviour at room scale: they live longer and
/// travel further, so the emblem's light carries on into the scene.
struct Motes {
    var streaked = false
    var lifetime = 2.2
    var speed = 0.18
    var speedRange = 0.14
    var direction = Double.pi / 2
    var spread = 0.6
    var drift = 0.30
    var size = 0.022
    var grow = 0.6
    var fade = 0.38
    var rate = 1.0
    var hotShare = 0.28
    var flicker = 0.0   // fear gutters
}

struct State {
    var id: String          // Tidewall battery state
    var corps: String
    var bright: RGB, deep: RGB, ember: RGB
    var motes: Motes
    var breathePeriod: Double  // seconds; Lantern breathes below 20%
    var breatheDepth: Double
    var ripplePeriod: Double
    /// How much light the emblem gives off in this state, and so how much of
    /// it reaches the room: Lantern's fill (and glow) shrinks with the charge.
    var intensity: Double
    var backdrop: Double = 1   // brightness of the room itself
}

let states: [State] = [
    State(id: "full", corps: "White",
          bright: RGB(r: 1.00, g: 0.99, b: 0.96), deep: RGB(r: 0.52, g: 0.55, b: 0.64), ember: RGB(r: 0.33, g: 0.34, b: 0.40),
          motes: Motes(lifetime: 2.8, speed: 0.32, speedRange: 0.18, spread: 0.95, drift: 0.55, size: 0.024, grow: 0.8,
                       fade: 0.30, rate: 1.7, hotShare: 0.45),
          breathePeriod: 6, breatheDepth: 0.04, ripplePeriod: 4, intensity: 1.0),
    State(id: "normal", corps: "Green",
          bright: RGB(r: 0.24, g: 0.95, b: 0.40), deep: RGB(r: 0.02, g: 0.52, b: 0.16), ember: RGB(r: 0.04, g: 0.17, b: 0.08),
          motes: Motes(),
          breathePeriod: 6, breatheDepth: 0.04, ripplePeriod: 4, intensity: 1.0),
    State(id: "low", corps: "Yellow",
          bright: RGB(r: 1.00, g: 0.74, b: 0.16), deep: RGB(r: 0.60, g: 0.36, b: 0.03), ember: RGB(r: 0.15, g: 0.10, b: 0.02),
          motes: Motes(lifetime: 1.4, speed: 0.30, speedRange: 0.28, spread: 2.3, drift: 0.06, size: 0.021, grow: 0.3,
                       fade: 0.78, rate: 1.7, flicker: 1),
          breathePeriod: 3, breatheDepth: 0.10, ripplePeriod: 3, intensity: 0.62, backdrop: 0.9),
    State(id: "critical", corps: "Red",
          bright: RGB(r: 1.00, g: 0.30, b: 0.26), deep: RGB(r: 0.62, g: 0.09, b: 0.08), ember: RGB(r: 0.16, g: 0.04, b: 0.04),
          motes: Motes(streaked: true, lifetime: 1.7, speed: 0.58, speedRange: 0.30, spread: 1.5, drift: -0.62, size: 0.030,
                       grow: 0.1, fade: 0.5, rate: 1.2, hotShare: 0.34),
          breathePeriod: 2, breatheDepth: 0.14, ripplePeriod: 2, intensity: 0.5, backdrop: 0.85),
    State(id: "empty", corps: "Black",
          bright: RGB(r: 0.86, g: 0.88, b: 0.94), deep: RGB(r: 0.45, g: 0.46, b: 0.54), ember: RGB(r: 0.24, g: 0.24, b: 0.29),
          motes: Motes(lifetime: 3.4, speed: 0.10, speedRange: 0.08, direction: -.pi / 2, spread: 0.55, drift: -0.20,
                       size: 0.020, grow: 0.2, fade: 0.20, rate: 0.7, hotShare: 0.12),
          breathePeriod: 12, breatheDepth: 0.03, ripplePeriod: 6, intensity: 0.22, backdrop: 0.45),
]

// MARK: - Scene

func drawBackdrop(_ ctx: CGContext, _ s: State, t: Double) {
    // Lantern's own backdrop is a near-black grey; tint it with the unlit ember.
    let base = RGB(r: 0.055, g: 0.055, b: 0.065).mix(s.ember, 0.35).scaled(s.backdrop)
    ctx.setFillColor(base.scaled(0.55).cg)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    let far = hypot(max(C.x, W - C.x), max(C.y, H - C.y))
    ctx.drawRadialGradient(gradient([
        (0, base.mix(s.ember, 0.5).scaled(1.25)),
        (0.35, base),
        (1, base.scaled(0.35)),
    ]), startCenter: C, startRadius: 0, endCenter: C, endRadius: far, options: [.drawsAfterEndLocation])

    // Slow nebula: a few soft fields of the corps' deep colour on closed paths.
    for i in 0..<5 {
        let a = tau * (Double(i) / 5 + t / loopSeconds * (i.isMultiple(of: 2) ? 1 : -1))
        let dist = R * (2.2 + 1.3 * hash(i, 1))
        let p = CGPoint(x: C.x + cos(a) * dist * 1.5, y: C.y + sin(a) * dist * 0.8)
        let radius = R * (2.8 + 1.8 * hash(i, 2))
        ctx.drawRadialGradient(gradient([(0, s.deep.with(alpha: 0.10 * s.intensity)), (1, s.deep.with(alpha: 0))]),
                               startCenter: p, startRadius: 0, endCenter: p, endRadius: radius, options: [])
    }

    // Faint, distant dust
    for i in 0..<260 {
        let p = CGPoint(x: hash(i, 11) * W, y: hash(i, 12) * H)
        let cycles = Double(1 + Int(hash(i, 13) * 3))
        let twinkle = 0.5 + 0.5 * sin(tau * cycles * t / loopSeconds + hash(i, 14) * tau)
        let size = (0.7 + hash(i, 15) * 1.6) * scale
        ctx.setFillColor(s.bright.mix(RGB(r: 1, g: 1, b: 1), 0.6).with(alpha: (0.06 + 0.16 * twinkle) * s.intensity).cg)
        ctx.fillEllipse(in: CGRect(x: p.x - size, y: p.y - size, width: size * 2, height: size * 2))
    }
}

func drawLight(_ ctx: CGContext, _ s: State, t: Double) {
    let breathe = 1 + s.breatheDepth * sin(tau * t / s.breathePeriod)

    // Rays of light turning slowly around the emblem: a sixteenth of a turn per
    // loop. Each ray's width and brightness depend on where it is pointing, not
    // on which ray it is, so after one loop every ray has become its
    // neighbour exactly and the loop closes.
    ctx.saveGState()
    ctx.translateBy(x: C.x, y: C.y)
    let rayLength = hypot(W, H)
    for i in 0..<16 {
        let a = tau * (Double(i) + t / loopSeconds) / 16
        let width = 0.045 + 0.03 * (0.5 + 0.5 * sin(3 * a + 1.1))
        let ray = CGMutablePath()
        ray.move(to: CGPoint(x: cos(a) * R * 0.9, y: sin(a) * R * 0.9))
        ray.addLine(to: CGPoint(x: cos(a - width) * rayLength, y: sin(a - width) * rayLength))
        ray.addLine(to: CGPoint(x: cos(a + width) * rayLength, y: sin(a + width) * rayLength))
        ray.closeSubpath()
        ctx.saveGState()
        ctx.addPath(ray)
        ctx.clip()
        let strength = (0.028 + 0.028 * (0.5 + 0.5 * sin(5 * a + 0.4))) * max(0, s.intensity - 0.25) / 0.75 * breathe
        ctx.drawRadialGradient(gradient([(0, s.bright.with(alpha: strength)), (1, s.bright.with(alpha: 0))]),
                               startCenter: .zero, startRadius: R, endCenter: .zero, endRadius: R * 7, options: [])
        ctx.restoreGState()
    }
    ctx.restoreGState()

    // The emblem's light spilling into the room.
    ctx.drawRadialGradient(gradient([
        (0, s.deep.mix(s.bright, 0.35).with(alpha: 0.55 * s.intensity)),
        (0.22, s.deep.with(alpha: 0.32 * s.intensity)),
        (0.55, s.deep.with(alpha: 0.10 * s.intensity)),
        (1, s.deep.with(alpha: 0)),
    ]), startCenter: C, startRadius: R * 0.8, endCenter: C, endRadius: R * 5.5 * breathe, options: [])

    // Ripples, like the rings engraved in the core, rolling outwards.
    for k in 0..<2 {
        let phase = frac(t / s.ripplePeriod + Double(k) / 2)
        let radius = R * (1.08 + 4.2 * phase)
        let alpha = 0.16 * pow(1 - phase, 1.6) * s.intensity
        ctx.setStrokeColor(s.bright.with(alpha: alpha).cg)
        ctx.setLineWidth((1.5 + 3 * (1 - phase)) * scale)
        ctx.strokeEllipse(in: CGRect(x: C.x - radius, y: C.y - radius, width: radius * 2, height: radius * 2))
    }
}

/// Motes shed by the emblem. Each has its own period — a whole fraction of the
/// loop — and a fresh (but repeatable) launch every time it respawns.
func drawEmblemMotes(_ ctx: CGContext, _ s: State, t: Double) {
    let m = s.motes
    let hot = s.bright.mix(RGB(r: 1, g: 1, b: 1), 0.5)
    let count = Int(150 * m.rate)
    let lifetime = m.lifetime * 2.4
    for i in 0..<count {
        let cyclesPerLoop = max(1, (loopSeconds / (lifetime * (1.1 + 0.6 * hash(i, 1)))).rounded(.down))
        let period = loopSeconds / cyclesPerLoop
        let clock = t / period + hash(i, 2)
        let cycle = Int(floor(clock)) % Int(cyclesPerLoop)
        let life = lifetime * (0.75 + 0.5 * hash(i, cycle, 3))
        let age = frac(clock) * period
        guard age < life else { continue }

        let launch = tau * hash(i, cycle, 4)
        let from = CGPoint(x: C.x + cos(launch) * R * (0.95 + 0.2 * hash(i, cycle, 5)),
                           y: C.y + sin(launch) * R * (0.95 + 0.2 * hash(i, cycle, 5)))
        let heading = m.direction + (hash(i, cycle, 6) - 0.5) * m.spread
        let speed = (m.speed + m.speedRange * (hash(i, cycle, 7) - 0.5)) * R * 2.2
        var p = CGPoint(x: from.x + cos(heading) * speed * age,
                        y: from.y + sin(heading) * speed * age + 0.5 * m.drift * R * 1.6 * age * age)
        if m.flicker > 0 {
            p.x += sin(age * 17 + Double(i)) * R * 0.03
            p.y += cos(age * 13 + Double(i)) * R * 0.03
        }
        let fadeIn = min(1, age / 0.25)
        var alpha = fadeIn * max(0, 1 - m.fade * age / 2.4) * (1 - age / life)
        if m.flicker > 0 { alpha *= 0.55 + 0.45 * sin(age * 31 + Double(i) * 1.7) }
        guard alpha > 0.01 else { continue }
        let isHot = hash(i, cycle, 8) < m.hotShare
        let color = (isHot ? hot : s.bright).with(alpha: alpha * 0.9 * s.intensity)
        let size = m.size * R * 2.2 * (1 + m.grow * age / 2.4)

        if m.streaked {
            // Rage streaks point along their motion.
            let vx = cos(heading) * speed, vy = sin(heading) * speed + m.drift * R * 1.6 * age
            let angle = atan2(vy, vx)
            ctx.saveGState()
            ctx.translateBy(x: p.x, y: p.y)
            ctx.rotate(by: angle)
            ctx.scaleBy(x: 3.2, y: 0.8)
            glowDot(ctx, at: .zero, radius: size, color: color)
            ctx.restoreGState()
        } else {
            glowDot(ctx, at: p, radius: size, color: color)
        }
    }
}

/// Out-of-focus motes further from the emblem give the scene depth.
func drawBokeh(_ ctx: CGContext, _ s: State, t: Double) {
    let m = s.motes
    let rising = m.direction > 0 ? 1.0 : -1.0
    for i in 0..<34 {
        let cycles = Double(1 + Int(hash(i, 31) * 2))
        let travel = frac(hash(i, 32) + cycles * t / loopSeconds)
        let x = hash(i, 33) * W + sin(tau * (travel + hash(i, 34))) * R * 0.3
        let yStart = rising > 0 ? -R : H + R
        let y = yStart + rising * travel * (H + 2 * R)
        let near = hash(i, 35)
        let radius = R * (0.06 + 0.16 * near)
        let alpha = (0.05 + 0.10 * (1 - near)) * sin(.pi * travel) * s.intensity
        ctx.setFillColor(s.bright.with(alpha: alpha).cg)
        ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
    }
}

func drawScene(_ ctx: CGContext, _ s: State, progress: Double) {
    let t = progress * loopSeconds
    drawBackdrop(ctx, s, t: t)
    drawLight(ctx, s, t: t)
    drawBokeh(ctx, s, t: t)
    drawEmblemMotes(ctx, s, t: t)
}

// MARK: - Rendering

let canvas = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
let context = CIContext(options: [.workingColorSpace: space])

func frame(_ s: State, progress: Double) -> CIImage {
    canvas.clear(CGRect(x: 0, y: 0, width: W, height: H))
    drawScene(canvas, s, progress: progress)
    let image = CIImage(cgImage: canvas.makeImage()!)
    let bloom = CIFilter.bloom()
    bloom.inputImage = image
    bloom.radius = Float(R * 0.12)
    bloom.intensity = 0.45
    // A whisper of grain keeps the dark gradients from banding.
    let dither = CIFilter.dither()
    dither.inputImage = bloom.outputImage!.cropped(to: image.extent)
    dither.intensity = 0.025
    return dither.outputImage!.cropped(to: image.extent)
}

func render(_ s: State, to output: URL) throws {
    try? FileManager.default.removeItem(at: output)
    let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.hevc,
        AVVideoWidthKey: Int(W),
        AVVideoHeightKey: Int(H),
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: Int(options["bitrate"] ?? "") ?? 8_000_000,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 2,
        ],
        // The frames are sRGB; tagging them BT.709 would lift the shadows.
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: kCVImageBufferTransferFunction_sRGB as String,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(W),
        kCVPixelBufferHeightKey as String: Int(H),
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error! }
    writer.startSession(atSourceTime: .zero)
    for index in 0..<frameCount {
        while !input.isReadyForMoreMediaData { usleep(1000) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        context.render(frame(s, progress: Double(index) / Double(frameCount)), to: buffer!,
                       bounds: CGRect(x: 0, y: 0, width: W, height: H), colorSpace: space)
        adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)))
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(fps)))
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    if writer.status != .completed { throw writer.error! }
}

// MARK: - Main

print(String(format: "Output %.0f×%.0f px; emblem (from %@) at (%.1f, %.1f) pt, %.1f pt across",
             W, H, measured.source, centerPoints.0, centerPoints.1, emblemDiameter))

if positional.first == "--still", positional.count >= 2 {
    let progress = positional.count >= 3 ? Double(positional[2]) ?? 0 : 0
    let id = positional.count >= 4 ? positional[3] : "normal"
    guard let s = states.first(where: { $0.id == id || $0.corps.lowercased() == id.lowercased() }) else {
        print("unknown state \(id); use one of \(states.map(\.id))"); exit(1)
    }
    let url = URL(fileURLWithPath: positional[1])
    try context.writePNGRepresentation(of: frame(s, progress: progress), to: url, format: .RGBA8, colorSpace: space)
    print("Wrote \(url.path)")
    exit(0)
}

guard positional.first == "--package", positional.count >= 2 else {
    print("usage: make-lantern --package <out.tidewall> | --still <out.png> [progress] [state]")
    exit(1)
}

let package = URL(fileURLWithPath: positional[1])
try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
var files: [String: String] = [:]
for s in states {
    let name = "\(s.corps).mov"
    let start = Date.now
    try render(s, to: package.appendingPathComponent(name))
    files[s.id] = name
    print(String(format: "  %@ (%@) in %.0fs", name, s.id, Date.now.timeIntervalSince(start)))
}
let manifest: [String: Any] = ["name": "Lantern", "primary": "normal", "battery": files]
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    .write(to: package.appendingPathComponent("wallpaper.json"))
print("Wrote \(package.path)")
