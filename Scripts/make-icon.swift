// Draws the 1024×1024 app icon master: an aurora-filled rounded square with a
// white loop glyph.   swiftc Scripts/make-icon.swift -o .build/tools/make-icon && .build/tools/make-icon icon.png

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

let size: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 186

func aurora() -> CGImage {
    let extent = CGRect(x: 0, y: 0, width: size, height: size)
    let base = CIFilter.linearGradient()
    base.point0 = CGPoint(x: 0, y: size)
    base.point1 = CGPoint(x: size, y: 0)
    base.color0 = CIColor(red: 0.05, green: 0.06, blue: 0.20)
    base.color1 = CIColor(red: 0.10, green: 0.03, blue: 0.20)
    var image = base.outputImage!.cropped(to: extent)

    let blobs: [(CGFloat, CGFloat, CGFloat, CIColor)] = [
        (0.30, 0.34, 0.50, CIColor(red: 0.10, green: 0.85, blue: 0.78, alpha: 0.95)),
        (0.72, 0.30, 0.46, CIColor(red: 0.22, green: 0.42, blue: 1.00, alpha: 0.95)),
        (0.66, 0.74, 0.46, CIColor(red: 0.92, green: 0.26, blue: 0.62, alpha: 0.90)),
        (0.30, 0.78, 0.40, CIColor(red: 0.56, green: 0.28, blue: 1.00, alpha: 0.90)),
    ]
    for (x, y, r, c) in blobs {
        let g = CIFilter.radialGradient()
        g.center = CGPoint(x: x * size, y: y * size)
        g.radius0 = 0
        g.radius1 = Float(r * size)
        g.color0 = c
        g.color1 = CIColor(red: c.red, green: c.green, blue: c.blue, alpha: 0)
        let screen = CIFilter.screenBlendMode()
        screen.inputImage = g.outputImage!.cropped(to: extent)
        screen.backgroundImage = image
        image = screen.outputImage!.cropped(to: extent)
    }
    let twirl = CIFilter.twirlDistortion()
    twirl.inputImage = image.clampedToExtent()
    twirl.center = CGPoint(x: size * 0.5, y: size * 0.5)
    twirl.radius = Float(size * 0.55)
    twirl.angle = 2.4
    image = twirl.outputImage!.cropped(to: extent)

    let color = CIFilter.colorControls()
    color.inputImage = image
    color.saturation = 1.3
    color.contrast = 1.08
    image = color.outputImage!.cropped(to: extent)
    return CIContext().createCGImage(image, from: extent)!
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(shape)
ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

// Aurora fill
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
ctx.draw(aurora(), in: CGRect(x: 0, y: 0, width: size, height: size))

// Soft top highlight
let highlight = CGGradient(colorsSpace: space, colors: [
    CGColor(gray: 1, alpha: 0.18), CGColor(gray: 1, alpha: 0),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(highlight, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])
ctx.restoreGState()

// Inner rim
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: radius - 1.5, cornerHeight: radius - 1.5, transform: nil))
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.22))
ctx.setLineWidth(3)
ctx.strokePath()

// Loop glyph
let config = NSImage.SymbolConfiguration(pointSize: 330, weight: .semibold)
if let symbol = NSImage(systemSymbolName: "infinity", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let glyphSize = symbol.size
    let rect = CGRect(x: (size - glyphSize.width) / 2, y: (size - glyphSize.height) / 2,
                      width: glyphSize.width, height: glyphSize.height)
    let tinted = NSImage(size: glyphSize, flipped: false) { bounds in
        symbol.draw(in: bounds)
        NSColor.white.setFill()
        bounds.fill(using: .sourceAtop)
        return true
    }
    var proposed = CGRect(origin: .zero, size: glyphSize)
    if let cg = tinted.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: CGColor(gray: 0, alpha: 0.35))
        ctx.setAlpha(0.95)
        ctx.draw(cg, in: rect)
        ctx.restoreGState()
    }
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png")
let dest = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("Wrote \(output.path)")
