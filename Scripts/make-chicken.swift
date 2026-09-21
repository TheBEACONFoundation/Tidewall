// Renders the bundled "Cool Chicken" wallpaper: a chicken in sunglasses
// strutting through a synthwave sunset. Every motion completes a whole number
// of cycles per loop, so the video repeats seamlessly.
//
//   swiftc -O Scripts/make-chicken.swift -o .build/tools/make-chicken
//   .build/tools/make-chicken Resources/CoolChicken.mov
//   .build/tools/make-chicken --still frame.png 0.25   # one frame at 25% of the loop

import AVFoundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

let W = 3840.0, H = 2160.0
let fps = 60
let loopSeconds = 12.0
let frameCount = Int(loopSeconds) * fps
let tau = 2 * Double.pi
let space = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: - Helpers

struct RGB: Equatable {
    var r, g, b: Double
    var a = 1.0
    func with(alpha: Double) -> RGB { RGB(r: r, g: g, b: b, a: alpha) }
    var cg: CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }
}

func gradient(_ stops: [(Double, RGB)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1.cg) as CFArray, locations: stops.map { CGFloat($0.0) })!
}

func frac(_ x: Double) -> Double { x - floor(x) }
func smooth(_ x: Double) -> Double { let t = min(max(x, 0), 1); return t * t * (3 - 2 * t) }
func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

struct Seeded {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }
}

extension CGContext {
    func fill(_ path: CGPath, _ c: RGB) { addPath(path); setFillColor(c.cg); fillPath() }
    func stroke(_ path: CGPath, _ c: RGB, width: Double) {
        addPath(path); setStrokeColor(c.cg); setLineWidth(width); setLineCap(.round); setLineJoin(.round); strokePath()
    }
    func with(_ body: () -> Void) { saveGState(); body(); restoreGState() }
}

func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> CGPath {
    CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2), transform: nil)
}

// MARK: - Palette

let ink = RGB(r: 0.13, g: 0.04, b: 0.22)
let cream = RGB(r: 1.0, g: 0.96, b: 0.90)
let creamShade = RGB(r: 0.93, g: 0.86, b: 0.86)
let neonPink = RGB(r: 1.0, g: 0.28, b: 0.72)
let neonCyan = RGB(r: 0.25, g: 0.95, b: 1.0)
let comb = RGB(r: 0.98, g: 0.16, b: 0.30)
let beak = RGB(r: 1.0, g: 0.70, b: 0.16)
let legNear = RGB(r: 1.0, g: 0.64, b: 0.14)
let legFar = RGB(r: 0.80, g: 0.44, b: 0.12)

// MARK: - Scene layout

let horizonY = H * 0.40
let sunCenter = CGPoint(x: W * 0.70, y: horizonY + H * 0.16)
let sunRadius = H * 0.25

// Ground plane projection: screen y = horizonY - K / Z, screen x = vpX + K * X / Z.
let vpX = W * 0.5
let K = horizonY

// The chicken: ground contact point, and chicken units (cu) → pixels.
let chickenX = W * 0.34
let chickenGroundY = H * 0.12
let cu = H / 1000 * 0.95
let chickenDepth = K / (horizonY - chickenGroundY)

// Walk cycle: 8 strides per loop; the planted foot slides back at exactly the
// speed the ground moves at the chicken's depth, so feet never skate.
let strideSeconds = loopSeconds / 8
let stanceFraction = 0.6
let strideLength = 110.0 // cu
let footSpeedPx = strideLength / (stanceFraction * strideSeconds) * cu
let groundTravelPerLoop = footSpeedPx * loopSeconds * chickenDepth / K // world units
let gridLines = (groundTravelPerLoop / 0.5).rounded()
let gridSpacing = groundTravelPerLoop / gridLines

// MARK: - Background

func drawSky(_ ctx: CGContext, t: Double) {
    ctx.drawLinearGradient(gradient([
        (0.0, RGB(r: 0.98, g: 0.42, b: 0.50)),
        (0.12, RGB(r: 0.78, g: 0.20, b: 0.55)),
        (0.45, RGB(r: 0.30, g: 0.07, b: 0.42)),
        (1.0, RGB(r: 0.04, g: 0.02, b: 0.14)),
    ]), start: CGPoint(x: 0, y: horizonY), end: CGPoint(x: 0, y: H), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // Stars twinkle a whole number of times per loop.
    var rng = Seeded(state: 7)
    for _ in 0..<180 {
        let x = rng.next() * W
        let y = horizonY + H * 0.22 + rng.next() * (H - horizonY - H * 0.22)
        let size = (1.5 + rng.next() * 3.5) * H / 1000
        let cycles = Double(1 + Int(rng.next() * 3))
        let phase = rng.next() * tau
        let alpha = 0.25 + 0.75 * (0.5 + 0.5 * sin(tau * cycles * t / loopSeconds + phase))
        ctx.fill(ellipse(x, y, size, size), RGB(r: 1, g: 0.92, b: 1, a: alpha * (y - horizonY) / (H - horizonY)))
    }

    // A shooting star once per loop.
    let shoot = (t - 4.0) / 0.9
    if shoot > 0 && shoot < 1 {
        let head = CGPoint(x: W * (0.95 - 0.55 * shoot), y: H * (0.93 - 0.18 * shoot))
        let tail = CGPoint(x: head.x + W * 0.09, y: head.y + H * 0.03)
        let fade = sin(.pi * shoot)
        ctx.with {
            ctx.setLineCap(.round)
            ctx.setLineWidth(5 * H / 1000)
            ctx.addLines(between: [tail, head])
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            ctx.drawLinearGradient(gradient([(0, RGB(r: 1, g: 1, b: 1, a: 0)), (1, RGB(r: 1, g: 0.95, b: 1, a: fade))]),
                                   start: tail, end: head, options: [])
        }
    }
}

func drawSun(_ ctx: CGContext, t: Double) {
    // Glow
    ctx.drawRadialGradient(gradient([(0, neonPink.with(alpha: 0.55)), (1, neonPink.with(alpha: 0))]),
                           startCenter: sunCenter, startRadius: sunRadius * 0.8,
                           endCenter: sunCenter, endRadius: sunRadius * 2.1, options: [])

    // Disc with scrolling stripe cut-outs in its lower half.
    let disc = CGMutablePath()
    disc.addEllipse(in: CGRect(x: sunCenter.x - sunRadius, y: sunCenter.y - sunRadius, width: sunRadius * 2, height: sunRadius * 2))
    let stripes = 7
    let drift = frac(t / 3) // four cycles per loop
    for i in 0..<stripes {
        let d = (Double(i) + drift) / Double(stripes) // 0 at center, 1 at bottom
        let y = sunCenter.y - sunRadius * d
        let thickness = sunRadius * (0.02 + 0.11 * d)
        disc.addRect(CGRect(x: sunCenter.x - sunRadius, y: y - thickness / 2, width: sunRadius * 2, height: thickness))
    }
    ctx.with {
        ctx.addPath(disc)
        ctx.clip(using: .evenOdd)
        ctx.drawLinearGradient(gradient([
            (0, RGB(r: 1.0, g: 0.20, b: 0.60)),
            (0.55, RGB(r: 1.0, g: 0.55, b: 0.35)),
            (1, RGB(r: 1.0, g: 0.93, b: 0.45)),
        ]), start: CGPoint(x: 0, y: sunCenter.y - sunRadius), end: CGPoint(x: 0, y: sunCenter.y + sunRadius), options: [])
    }
}

func drawMountains(_ ctx: CGContext) {
    func range(seed: UInt64, base: Double, height: Double, fill: RGB, edge: RGB) {
        var rng = Seeded(state: seed)
        let waves = (1...6).map { k in (Double(k), rng.next() * tau, (0.35 + rng.next()) / Double(k)) }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: horizonY - 2))
        var ridge: [CGPoint] = []
        for i in 0...240 {
            let x = W * Double(i) / 240
            var h = 0.0
            for (k, phase, amp) in waves { h += amp * sin(tau * k * x / W * 1.7 + phase) }
            let y = horizonY + base + height * (0.55 + 0.35 * h)
            ridge.append(CGPoint(x: x, y: max(horizonY, y)))
        }
        path.addLines(between: ridge)
        path.addLine(to: CGPoint(x: W, y: horizonY - 2))
        path.closeSubpath()
        ctx.fill(path, fill)
        let edgePath = CGMutablePath()
        edgePath.addLines(between: ridge)
        ctx.stroke(edgePath, edge, width: 4 * H / 1000)
    }
    range(seed: 11, base: 0, height: H * 0.13, fill: RGB(r: 0.20, g: 0.05, b: 0.32), edge: neonPink.with(alpha: 0.8))
    range(seed: 23, base: -H * 0.02, height: H * 0.08, fill: RGB(r: 0.11, g: 0.03, b: 0.20), edge: neonCyan.with(alpha: 0.6))
}

func drawPalm(_ ctx: CGContext, baseX: Double, height h: Double, lean: Double, sway: Double) {
    let dark = RGB(r: 0.06, g: 0.015, b: 0.11)
    let top = CGPoint(x: baseX + lean * h, y: horizonY + h)
    let trunk = CGMutablePath()
    let w0 = h * 0.035, w1 = h * 0.018
    let ctrl = CGPoint(x: baseX + lean * h * 0.2, y: horizonY + h * 0.55)
    trunk.move(to: CGPoint(x: baseX - w0, y: horizonY))
    trunk.addQuadCurve(to: CGPoint(x: top.x - w1, y: top.y), control: CGPoint(x: ctrl.x - w0, y: ctrl.y))
    trunk.addLine(to: CGPoint(x: top.x + w1, y: top.y))
    trunk.addQuadCurve(to: CGPoint(x: baseX + w0, y: horizonY), control: CGPoint(x: ctrl.x + w0, y: ctrl.y))
    trunk.closeSubpath()
    ctx.fill(trunk, dark)

    let angles: [Double] = [-170, -140, -110, -60, -25, 10, 35, 150, 120]
    for (i, deg) in angles.enumerated() {
        let a = (deg + sway * (i.isMultiple(of: 2) ? 1 : -0.7)) * .pi / 180
        let length = h * (0.36 + 0.08 * Double(i % 3))
        let dir = CGPoint(x: cos(a), y: sin(a))
        let tip = CGPoint(x: top.x + dir.x * length, y: top.y + dir.y * length * 0.55 - length * 0.35)
        let mid = CGPoint(x: top.x + dir.x * length * 0.55, y: top.y + dir.y * length * 0.5 + length * 0.12)
        let normal = CGPoint(x: -dir.y, y: dir.x)
        let width = h * 0.05
        let leaf = CGMutablePath()
        leaf.move(to: top)
        leaf.addQuadCurve(to: tip, control: CGPoint(x: mid.x + normal.x * width, y: mid.y + normal.y * width))
        leaf.addQuadCurve(to: top, control: CGPoint(x: mid.x - normal.x * width, y: mid.y - normal.y * width))
        ctx.fill(leaf, dark)
    }
}

func drawPalms(_ ctx: CGContext, t: Double) {
    // One tile of palms scrolls past per loop.
    let tile = W * 0.36
    let offset = frac(t / loopSeconds) * tile
    let sway = 3 * sin(tau * 2 * t / loopSeconds)
    var x = -tile - offset
    while x < W + tile {
        drawPalm(ctx, baseX: x + tile * 0.18, height: H * 0.21, lean: 0.10, sway: sway)
        drawPalm(ctx, baseX: x + tile * 0.66, height: H * 0.15, lean: -0.08, sway: -sway)
        x += tile
    }
}

func drawGround(_ ctx: CGContext, t: Double) {
    ctx.drawLinearGradient(gradient([
        (0, RGB(r: 0.02, g: 0.0, b: 0.06)),
        (1, RGB(r: 0.20, g: 0.03, b: 0.26)),
    ]), start: .zero, end: CGPoint(x: 0, y: horizonY), options: [])

    // The sun's reflection
    ctx.with {
        ctx.clip(to: CGRect(x: 0, y: 0, width: W, height: horizonY))
        ctx.translateBy(x: sunCenter.x, y: horizonY)
        ctx.scaleBy(x: 1, y: 0.35)
        ctx.drawRadialGradient(gradient([(0, neonPink.with(alpha: 0.45)), (1, neonPink.with(alpha: 0))]),
                               startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: sunRadius * 1.6, options: [])
    }

    let y: (Double) -> Double = { horizonY - K / $0 }
    let gridColor = RGB(r: 1.0, g: 0.30, b: 0.85)

    // Lines across the view stay put; the camera slides sideways.
    var z = 0.9
    while y(z) < horizonY - 3 {
        let yy = y(z)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: yy))
        path.addLine(to: CGPoint(x: W, y: yy))
        ctx.stroke(path, gridColor, width: max(1.5, 7 / z) * H / 1000)
        z += gridSpacing
    }

    // Lines into the distance converge on the vanishing point and slide past.
    let offset = frac(t / loopSeconds) * gridLines * gridSpacing
    let near = 0.9
    for k in -60...60 {
        let worldX = Double(k) * gridSpacing - offset.truncatingRemainder(dividingBy: gridSpacing)
        let bottom = CGPoint(x: vpX + K * worldX / near, y: y(near))
        guard bottom.x > -W * 3, bottom.x < W * 4 else { continue }
        let path = CGMutablePath()
        path.move(to: bottom)
        path.addLine(to: CGPoint(x: vpX, y: horizonY))
        ctx.stroke(path, gridColor, width: 5 * H / 1000)
    }

    // Fade the grid into haze towards the horizon.
    ctx.drawLinearGradient(gradient([
        (0, RGB(r: 0.20, g: 0.03, b: 0.26, a: 0)),
        (0.55, RGB(r: 0.20, g: 0.03, b: 0.26, a: 0.25)),
        (1, RGB(r: 0.22, g: 0.04, b: 0.28, a: 0.95)),
    ]), start: .zero, end: CGPoint(x: 0, y: horizonY), options: [])

    // Horizon line
    let line = CGMutablePath()
    line.move(to: CGPoint(x: 0, y: horizonY))
    line.addLine(to: CGPoint(x: W, y: horizonY))
    ctx.stroke(line, RGB(r: 1, g: 0.6, b: 0.85), width: 4 * H / 1000)
}

func drawSparkles(_ ctx: CGContext, t: Double) {
    var rng = Seeded(state: 99)
    for _ in 0..<46 {
        let speed = Double(1 + Int(rng.next() * 2)) // whole screen widths per loop
        let x = frac(rng.next() - speed * t / loopSeconds) * (W + 200) - 100
        let y = H * (0.08 + rng.next() * 0.8) + 18 * H / 1000 * sin(tau * t / loopSeconds * 2 + rng.next() * tau)
        let size = (4 + rng.next() * 8) * H / 1000
        let tint = rng.next() < 0.5 ? neonCyan : RGB(r: 1, g: 0.75, b: 0.95)
        let alpha = 0.35 + 0.65 * (0.5 + 0.5 * sin(tau * 3 * t / loopSeconds + rng.next() * tau))
        let star = CGMutablePath()
        star.move(to: CGPoint(x: x, y: y + size))
        star.addQuadCurve(to: CGPoint(x: x + size, y: y), control: CGPoint(x: x, y: y))
        star.addQuadCurve(to: CGPoint(x: x, y: y - size), control: CGPoint(x: x, y: y))
        star.addQuadCurve(to: CGPoint(x: x - size, y: y), control: CGPoint(x: x, y: y))
        star.addQuadCurve(to: CGPoint(x: x, y: y + size), control: CGPoint(x: x, y: y))
        ctx.fill(star, tint.with(alpha: alpha))
    }
}

// MARK: - The chicken

struct Pose {
    var bodyBob: Double
    var bodyTilt: Double
    var headOffset: CGPoint
    var tailSway: Double
    var wingLift: Double
    var wattleSwing: Double
    var nearFoot: (x: Double, y: Double, curl: Double)
    var farFoot: (x: Double, y: Double, curl: Double)

    init(t: Double) {
        let stride = frac(t / strideSeconds)
        func foot(_ phase: Double, base: Double) -> (Double, Double, Double) {
            if phase < stanceFraction {
                let s = phase / stanceFraction
                return (base + strideLength / 2 - strideLength * s, 0, 0)
            }
            let s = (phase - stanceFraction) / (1 - stanceFraction)
            return (base - strideLength / 2 + strideLength * smooth(s), 46 * sin(.pi * s), sin(.pi * s))
        }
        nearFoot = foot(stride, base: 24)
        farFoot = foot(frac(stride + 0.5), base: -6)

        // Two bobs per stride: lowest as each foot takes the weight.
        let step = frac(t / (strideSeconds / 2))
        bodyBob = 7 * cos(tau * step)
        bodyTilt = 1.5 * sin(tau * stride)

        // The classic chicken head bob: the head holds still against the ground,
        // then snaps forward.
        let hold = 0.72
        let dx = step < hold ? 26 * (0.5 - step / hold) : 26 * (-0.5 + smooth((step - hold) / (1 - hold)))
        headOffset = CGPoint(x: dx, y: 4 * sin(tau * step))
        tailSway = 5 * sin(tau * stride + 0.8)
        wingLift = 3 * sin(tau * step + 0.5)
        wattleSwing = 9 * sin(tau * step - 1.2)
    }
}

func legJoint(hip: CGPoint, foot: CGPoint, thigh a: Double, shank b: Double) -> CGPoint {
    let dx = foot.x - hip.x, dy = foot.y - hip.y
    let d = min(hypot(dx, dy), a + b - 0.01)
    let theta = atan2(dy, dx)
    let alpha = acos(max(-1, min(1, (a * a + d * d - b * b) / (2 * a * d))))
    // Chicken legs bend backwards at the visible joint.
    return CGPoint(x: hip.x + a * cos(theta - alpha), y: hip.y + a * sin(theta - alpha))
}

func drawLeg(_ ctx: CGContext, hip: CGPoint, foot f: (x: Double, y: Double, curl: Double), color: RGB) {
    let foot = CGPoint(x: f.x, y: f.y)
    let joint = legJoint(hip: hip, foot: foot, thigh: 72, shank: 88)
    let shank = CGMutablePath()
    shank.move(to: joint)
    shank.addLine(to: foot)
    let curl = f.curl * 0.8
    let toes: [(Double, Double)] = [(0.0, 50), (0.35, 40), (-0.25, 34), (.pi, 24)]
    let toePath = CGMutablePath()
    for (angle, length) in toes {
        let a = angle == .pi ? .pi + curl * 0.5 : angle - curl
        toePath.move(to: foot)
        toePath.addLine(to: CGPoint(x: foot.x + cos(a) * length, y: foot.y + sin(a) * length * 0.45))
    }
    // Feathered drumstick
    let thigh = CGMutablePath()
    thigh.move(to: hip)
    thigh.addLine(to: CGPoint(x: lerp(hip.x, joint.x, 0.55), y: lerp(hip.y, joint.y, 0.55)))

    for (path, width) in [(shank, 17.0), (toePath, 12.0)] {
        ctx.stroke(path, ink, width: width + 12)
    }
    ctx.stroke(thigh, ink, width: 48)
    ctx.stroke(shank, color, width: 17)
    ctx.stroke(toePath, color, width: 12)
    ctx.stroke(thigh, color == legNear ? creamShade : RGB(r: 0.78, g: 0.68, b: 0.80), width: 34)
}

/// Adds a rim of light on one side of `shape` (the part not covered when the
/// shape is shifted by `offset`).
func rim(_ ctx: CGContext, _ shape: CGPath, offset: CGPoint, color: RGB) {
    ctx.with {
        ctx.addPath(shape)
        ctx.clip()
        let both = CGMutablePath()
        both.addPath(shape)
        both.addPath(shape, transform: CGAffineTransform(translationX: offset.x, y: offset.y))
        ctx.addPath(both)
        ctx.setFillColor(color.cg)
        ctx.fillPath(using: .evenOdd)
    }
}

func drawChicken(_ ctx: CGContext, t: Double) {
    let pose = Pose(t: t)

    // Soft shadow on the grid
    ctx.with {
        ctx.translateBy(x: chickenX + 10 * cu, y: chickenGroundY)
        ctx.scaleBy(x: 1, y: 0.16)
        ctx.drawRadialGradient(gradient([(0, RGB(r: 0.02, g: 0, b: 0.06, a: 0.75)), (1, RGB(r: 0.02, g: 0, b: 0.06, a: 0))]),
                               startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 210 * cu, options: [])
    }

    ctx.saveGState()
    ctx.translateBy(x: chickenX, y: chickenGroundY)
    ctx.scaleBy(x: cu, y: cu)

    // Both legs come out from under the body.
    let lift = pose.bodyBob
    drawLeg(ctx, hip: CGPoint(x: -8, y: 150 + lift), foot: pose.farFoot, color: legFar)
    drawLeg(ctx, hip: CGPoint(x: 22, y: 150 + lift), foot: pose.nearFoot, color: legNear)

    ctx.saveGState()
    ctx.translateBy(x: 0, y: 150 + lift)
    ctx.rotate(by: pose.bodyTilt * .pi / 180)
    ctx.translateBy(x: 0, y: -150)

    // Tail feathers fan out behind the body.
    let tailBase = CGPoint(x: -120, y: 250)
    let feathers: [(Double, Double, RGB)] = [
        (150, 170, RGB(r: 0.98, g: 0.90, b: 0.95)),
        (128, 205, cream),
        (106, 190, RGB(r: 1.0, g: 0.93, b: 0.93)),
        (86, 150, creamShade),
    ]
    for (deg, length, fill) in feathers {
        let a = (deg + pose.tailSway) * .pi / 180
        let tip = CGPoint(x: tailBase.x + cos(a) * length, y: tailBase.y + sin(a) * length)
        let normal = CGPoint(x: -sin(a), y: cos(a))
        let mid = CGPoint(x: (tailBase.x + tip.x) / 2, y: (tailBase.y + tip.y) / 2)
        let feather = CGMutablePath()
        feather.move(to: tailBase)
        feather.addQuadCurve(to: tip, control: CGPoint(x: mid.x + normal.x * 42, y: mid.y + normal.y * 42))
        feather.addQuadCurve(to: tailBase, control: CGPoint(x: mid.x - normal.x * 30, y: mid.y - normal.y * 30))
        ctx.stroke(feather, ink, width: 14)
        ctx.fill(feather, fill)
        // Neon tip
        ctx.with {
            ctx.addPath(feather)
            ctx.clip()
            ctx.fill(ellipse(tip.x, tip.y, 46, 46), neonPink.with(alpha: 0.55))
        }
    }

    // Body, neck and head share one outline: stroke them all, then fill.
    let body = CGMutablePath()
    body.move(to: CGPoint(x: 165, y: 255))
    body.addCurve(to: CGPoint(x: 40, y: 118), control1: CGPoint(x: 185, y: 170), control2: CGPoint(x: 120, y: 115))
    body.addCurve(to: CGPoint(x: -150, y: 175), control1: CGPoint(x: -40, y: 118), control2: CGPoint(x: -120, y: 125))
    body.addCurve(to: CGPoint(x: -150, y: 300), control1: CGPoint(x: -190, y: 215), control2: CGPoint(x: -185, y: 280))
    body.addCurve(to: CGPoint(x: 70, y: 335), control1: CGPoint(x: -100, y: 340), control2: CGPoint(x: 0, y: 350))
    body.addCurve(to: CGPoint(x: 165, y: 255), control1: CGPoint(x: 130, y: 322), control2: CGPoint(x: 160, y: 300))
    body.closeSubpath()

    let head = CGPoint(x: 168 + pose.headOffset.x, y: 400 + pose.headOffset.y)
    let headShape = ellipse(head.x, head.y, 64, 62)
    let neck = CGMutablePath()
    neck.move(to: CGPoint(x: 60, y: 300))
    neck.addLine(to: CGPoint(x: 150, y: 280))
    neck.addLine(to: CGPoint(x: head.x + 40, y: head.y - 30))
    neck.addLine(to: CGPoint(x: head.x - 45, y: head.y - 10))
    neck.closeSubpath()

    // Comb sits behind the head.
    let combShape = CGMutablePath()
    for (dx, dy, r) in [(-38.0, 50.0, 22.0), (-8.0, 64.0, 26.0), (24.0, 56.0, 22.0)] {
        combShape.addEllipse(in: CGRect(x: head.x + dx - r, y: head.y + dy - r, width: r * 2, height: r * 2))
    }
    ctx.stroke(combShape, ink, width: 14)
    ctx.fill(combShape, comb)

    for shape in [body, neck, headShape] as [CGPath] { ctx.stroke(shape, ink, width: 16) }
    for shape in [body, neck, headShape] as [CGPath] { ctx.fill(shape, cream) }

    // Dusk shading and neon rim light
    ctx.with {
        ctx.addPath(body)
        ctx.clip()
        ctx.drawLinearGradient(gradient([(0, RGB(r: 0.55, g: 0.30, b: 0.78, a: 0.55)), (1, RGB(r: 0.55, g: 0.30, b: 0.78, a: 0))]),
                               start: CGPoint(x: 0, y: 110), end: CGPoint(x: 0, y: 290), options: [])
    }
    rim(ctx, body, offset: CGPoint(x: -16, y: -8), color: neonPink.with(alpha: 0.85))
    rim(ctx, body, offset: CGPoint(x: 14, y: 4), color: neonCyan.with(alpha: 0.45))
    rim(ctx, headShape, offset: CGPoint(x: -12, y: -6), color: neonPink.with(alpha: 0.8))
    rim(ctx, headShape, offset: CGPoint(x: 10, y: 3), color: neonCyan.with(alpha: 0.4))

    // Wing
    ctx.with {
        ctx.translateBy(x: -20, y: 250)
        ctx.rotate(by: (-12 + pose.wingLift) * .pi / 180)
        let wing = CGMutablePath()
        wing.move(to: CGPoint(x: 95, y: 18))
        wing.addCurve(to: CGPoint(x: -150, y: -40), control1: CGPoint(x: 85, y: 75), control2: CGPoint(x: -70, y: 55))
        wing.addCurve(to: CGPoint(x: 95, y: 18), control1: CGPoint(x: -70, y: -62), control2: CGPoint(x: 70, y: -58))
        wing.closeSubpath()
        ctx.stroke(wing, ink, width: 14)
        ctx.fill(wing, creamShade)
        rim(ctx, wing, offset: CGPoint(x: -6, y: -10), color: neonPink.with(alpha: 0.45))
        // Flight feathers along the back of the wing
        for i in 0..<3 {
            let y = -26.0 + Double(i) * 20
            let feather = CGMutablePath()
            feather.move(to: CGPoint(x: 30 - Double(i) * 10, y: y))
            feather.addQuadCurve(to: CGPoint(x: -110 + Double(i) * 18, y: y - 20 + Double(i) * 4),
                                 control: CGPoint(x: -40, y: y + 4))
            ctx.stroke(feather, ink.with(alpha: 0.45), width: 7)
        }
    }

    // Beak
    let upperBeak = CGMutablePath()
    upperBeak.move(to: CGPoint(x: head.x + 52, y: head.y + 12))
    upperBeak.addQuadCurve(to: CGPoint(x: head.x + 116, y: head.y - 6), control: CGPoint(x: head.x + 90, y: head.y + 16))
    upperBeak.addLine(to: CGPoint(x: head.x + 56, y: head.y - 12))
    upperBeak.closeSubpath()
    let lowerBeak = CGMutablePath()
    lowerBeak.move(to: CGPoint(x: head.x + 56, y: head.y - 12))
    lowerBeak.addLine(to: CGPoint(x: head.x + 100, y: head.y - 14))
    lowerBeak.addQuadCurve(to: CGPoint(x: head.x + 50, y: head.y - 30), control: CGPoint(x: head.x + 80, y: head.y - 30))
    lowerBeak.closeSubpath()
    for shape in [upperBeak, lowerBeak] as [CGPath] { ctx.stroke(shape, ink, width: 12); ctx.fill(shape, beak) }

    // Wattle swings a beat behind the head.
    ctx.with {
        ctx.translateBy(x: head.x + 58, y: head.y - 26)
        ctx.rotate(by: pose.wattleSwing * .pi / 180)
        let wattle = CGMutablePath()
        wattle.move(to: .zero)
        wattle.addCurve(to: CGPoint(x: 4, y: -62), control1: CGPoint(x: 26, y: -12), control2: CGPoint(x: 30, y: -58))
        wattle.addCurve(to: .zero, control1: CGPoint(x: -22, y: -64), control2: CGPoint(x: -18, y: -18))
        ctx.stroke(wattle, ink, width: 12)
        ctx.fill(wattle, comb)
    }

    // Sunglasses
    let lensCenter = CGPoint(x: head.x + 22, y: head.y + 12)
    let lens = CGMutablePath()
    lens.move(to: CGPoint(x: lensCenter.x - 50, y: lensCenter.y + 24))
    lens.addLine(to: CGPoint(x: lensCenter.x + 54, y: lensCenter.y + 26))
    lens.addQuadCurve(to: CGPoint(x: lensCenter.x + 34, y: lensCenter.y - 24), control: CGPoint(x: lensCenter.x + 56, y: lensCenter.y - 20))
    lens.addQuadCurve(to: CGPoint(x: lensCenter.x - 36, y: lensCenter.y - 20), control: CGPoint(x: lensCenter.x, y: lensCenter.y - 34))
    lens.addQuadCurve(to: CGPoint(x: lensCenter.x - 50, y: lensCenter.y + 24), control: CGPoint(x: lensCenter.x - 56, y: lensCenter.y - 10))
    lens.closeSubpath()
    let arm = CGMutablePath()
    arm.move(to: CGPoint(x: lensCenter.x - 48, y: lensCenter.y + 16))
    arm.addLine(to: CGPoint(x: head.x - 58, y: head.y + 22))
    ctx.stroke(arm, ink, width: 12)
    ctx.stroke(lens, ink, width: 14)
    ctx.with {
        ctx.addPath(lens)
        ctx.clip()
        ctx.drawLinearGradient(gradient([
            (0, RGB(r: 0.05, g: 0.02, b: 0.12)),
            (0.45, RGB(r: 0.35, g: 0.06, b: 0.45)),
            (0.7, RGB(r: 1.0, g: 0.30, b: 0.70)),
            (1, neonCyan),
        ]), start: CGPoint(x: lensCenter.x - 40, y: lensCenter.y - 30), end: CGPoint(x: lensCenter.x + 40, y: lensCenter.y + 30), options: [])
        // A glint sweeps across the lens twice per loop.
        let glint = frac(t / (loopSeconds / 2)) / 0.12
        if glint < 1 {
            let x = lensCenter.x - 80 + 180 * glint
            let streak = CGMutablePath()
            streak.move(to: CGPoint(x: x, y: lensCenter.y - 40))
            streak.addLine(to: CGPoint(x: x + 40, y: lensCenter.y + 40))
            ctx.stroke(streak, RGB(r: 1, g: 1, b: 1, a: 0.9), width: 14)
        }
        let shine = CGMutablePath()
        shine.move(to: CGPoint(x: lensCenter.x - 30, y: lensCenter.y + 12))
        shine.addLine(to: CGPoint(x: lensCenter.x - 8, y: lensCenter.y + 14))
        ctx.stroke(shine, RGB(r: 1, g: 1, b: 1, a: 0.7), width: 7)
    }

    ctx.restoreGState() // body transform
    ctx.restoreGState()
}

// MARK: - Frame

func drawScene(_ ctx: CGContext, progress: Double) {
    let t = progress * loopSeconds
    drawSky(ctx, t: t)
    drawSun(ctx, t: t)
    drawMountains(ctx)
    drawPalms(ctx, t: t)
    drawGround(ctx, t: t)
    drawChicken(ctx, t: t)
    drawSparkles(ctx, t: t)
}

let canvas = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
canvas.interpolationQuality = .high
canvas.setShouldAntialias(true)

func frame(at progress: Double) -> CIImage {
    canvas.clear(CGRect(x: 0, y: 0, width: W, height: H))
    drawScene(canvas, progress: progress)
    let image = CIImage(cgImage: canvas.makeImage()!)
    let bloom = CIFilter.bloom()
    bloom.inputImage = image
    bloom.radius = Float(H / 1000 * 22)
    bloom.intensity = 0.55
    let vignette = CIFilter.vignette()
    vignette.inputImage = bloom.outputImage!.cropped(to: image.extent)
    vignette.intensity = 0.6
    vignette.radius = Float(W * 0.75)
    return vignette.outputImage!.cropped(to: image.extent)
}

let context = CIContext(options: [.workingColorSpace: space])
let args = CommandLine.arguments

if args.count >= 3 && args[1] == "--still" {
    let progress = args.count >= 4 ? Double(args[3]) ?? 0 : 0
    let url = URL(fileURLWithPath: args[2])
    try context.writePNGRepresentation(of: frame(at: progress), to: url, format: .RGBA8, colorSpace: space)
    print("Wrote \(url.path)")
    exit(0)
}

guard args.count >= 2 else {
    print("usage: make-chicken <output.mov> | --still <out.png> [progress]")
    exit(1)
}

let output = URL(fileURLWithPath: args[1])
try? FileManager.default.removeItem(at: output)
let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.hevc,
    AVVideoWidthKey: Int(W),
    AVVideoHeightKey: Int(H),
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: Int(ProcessInfo.processInfo.environment["BITRATE"] ?? "") ?? 10_000_000,
        AVVideoExpectedSourceFrameRateKey: fps,
        AVVideoMaxKeyFrameIntervalKey: fps * 2,
    ],
    // The frames are sRGB, so say so: tagging them BT.709 makes players lift
    // the shadows. (sRGB shares BT.709 primaries; only the transfer differs.)
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
guard writer.startWriting() else { fatalError("\(writer.error!)") }
writer.startSession(atSourceTime: .zero)

for index in 0..<frameCount {
    while !input.isReadyForMoreMediaData { usleep(1000) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    guard let buffer else { fatalError("no pixel buffer") }
    context.render(frame(at: Double(index) / Double(frameCount)), to: buffer,
                   bounds: CGRect(x: 0, y: 0, width: W, height: H), colorSpace: space)
    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)))
    if index % 120 == 0 { print("frame \(index)/\(frameCount)") }
}
input.markAsFinished()
writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(fps)))
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else { fatalError("\(writer.error!)") }
print("Wrote \(output.path)")
