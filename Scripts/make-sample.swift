// Renders the bundled "Aurora" sample: drifting color fields that loop
// seamlessly (every motion is periodic in the loop length).
//
//   swiftc -O Scripts/make-sample.swift -o .build/tools/make-sample && .build/tools/make-sample Resources/Aurora.mov
//   .build/tools/make-sample --still frame.png 0.25   # preview one frame at 25% of the loop

import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

let width = 1920, height = 1080
let fps = 30
let loopSeconds = 20.0
let frameCount = Int(loopSeconds) * fps

struct Blob {
    var color: (Double, Double, Double)
    var alpha: Double
    var center: (Double, Double)    // normalized
    var amplitude: (Double, Double) // normalized
    var cycles: (Double, Double)    // whole cycles per loop keeps it seamless
    var phase: (Double, Double)
    var radius: Double              // relative to height
}

let blobs: [Blob] = [
    Blob(color: (0.10, 0.82, 0.76), alpha: 0.80, center: (0.28, 0.40), amplitude: (0.16, 0.14), cycles: (1, 2), phase: (0.0, 1.2), radius: 0.62),
    Blob(color: (0.23, 0.40, 0.96), alpha: 0.85, center: (0.70, 0.30), amplitude: (0.18, 0.16), cycles: (1, 1), phase: (2.1, 0.4), radius: 0.70),
    Blob(color: (0.88, 0.25, 0.60), alpha: 0.70, center: (0.62, 0.72), amplitude: (0.20, 0.12), cycles: (2, 1), phase: (4.0, 2.6), radius: 0.58),
    Blob(color: (0.54, 0.25, 0.99), alpha: 0.75, center: (0.36, 0.78), amplitude: (0.15, 0.10), cycles: (1, 2), phase: (1.3, 5.0), radius: 0.66),
    Blob(color: (1.00, 0.60, 0.24), alpha: 0.45, center: (0.86, 0.80), amplitude: (0.10, 0.10), cycles: (1, 1), phase: (3.4, 3.9), radius: 0.36),
    Blob(color: (0.12, 0.90, 0.55), alpha: 0.40, center: (0.12, 0.12), amplitude: (0.08, 0.10), cycles: (2, 1), phase: (5.1, 0.7), radius: 0.42),
]

func frame(at progress: Double) -> CIImage {
    let extent = CGRect(x: 0, y: 0, width: width, height: height)
    let tau = 2 * Double.pi
    let w = Double(width), h = Double(height)

    let base = CIFilter.linearGradient()
    base.point0 = CGPoint(x: 0, y: h)
    base.point1 = CGPoint(x: w * 0.3, y: 0)
    base.color0 = CIColor(red: 0.02, green: 0.03, blue: 0.10)
    base.color1 = CIColor(red: 0.06, green: 0.02, blue: 0.12)
    var image = base.outputImage!.cropped(to: extent)

    for blob in blobs {
        let x = blob.center.0 + blob.amplitude.0 * sin(tau * blob.cycles.0 * progress + blob.phase.0)
        let y = blob.center.1 + blob.amplitude.1 * cos(tau * blob.cycles.1 * progress + blob.phase.1)
        let breathe = 1 + 0.12 * sin(tau * progress + blob.phase.0 * 2)
        let g = CIFilter.radialGradient()
        g.center = CGPoint(x: x * w, y: y * h)
        g.radius0 = 0
        g.radius1 = Float(blob.radius * 0.85 * h * breathe)
        g.color0 = CIColor(red: blob.color.0, green: blob.color.1, blue: blob.color.2, alpha: blob.alpha)
        g.color1 = CIColor(red: blob.color.0, green: blob.color.1, blue: blob.color.2, alpha: 0)
        let screen = CIFilter.screenBlendMode()
        screen.inputImage = g.outputImage!.cropped(to: extent)
        screen.backgroundImage = image
        image = screen.outputImage!.cropped(to: extent)
    }

    // Two slow counter-rotating swirls turn the soft fields into flowing ribbons.
    let swirls: [(cx: Double, cy: Double, radius: Double, angle: Double, phase: Double)] = [
        (0.38, 0.55, 0.42, 2.6, 0.8),
        (0.70, 0.42, 0.34, -2.2, 2.9),
    ]
    for swirl in swirls {
        let twirl = CIFilter.twirlDistortion()
        twirl.inputImage = image.clampedToExtent()
        twirl.center = CGPoint(x: w * (swirl.cx + 0.07 * sin(tau * progress + swirl.phase)),
                               y: h * (swirl.cy + 0.06 * cos(tau * progress + swirl.phase)))
        twirl.radius = Float(w * swirl.radius)
        twirl.angle = Float(swirl.angle * sin(tau * progress + swirl.phase))
        image = twirl.outputImage!.cropped(to: extent)
    }

    let color = CIFilter.colorControls()
    color.inputImage = image
    color.saturation = 1.35
    color.contrast = 1.12
    color.brightness = -0.02
    image = color.outputImage!.cropped(to: extent)

    let vignette = CIFilter.vignette()
    vignette.inputImage = image
    vignette.intensity = 0.55
    vignette.radius = Float(w * 0.7)
    image = vignette.outputImage!.cropped(to: extent)

    // Dither to avoid banding in the dark gradients.
    let dither = CIFilter.dither()
    dither.inputImage = image
    dither.intensity = 0.02
    return dither.outputImage!.cropped(to: extent)
}

let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
let args = CommandLine.arguments

if args.count >= 3 && args[1] == "--still" {
    let progress = args.count >= 4 ? Double(args[3]) ?? 0 : 0
    let url = URL(fileURLWithPath: args[2])
    try context.writePNGRepresentation(of: frame(at: progress), to: url, format: .RGBA8,
                                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    print("Wrote \(url.path)")
    exit(0)
}

guard args.count >= 2 else {
    print("usage: make-sample <output.mov> | --still <out.png> [progress]")
    exit(1)
}

let output = URL(fileURLWithPath: args[1])
try? FileManager.default.removeItem(at: output)
let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.hevc,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 9_000_000,
        AVVideoExpectedSourceFrameRateKey: fps,
        AVVideoMaxKeyFrameIntervalKey: fps * 2,
    ],
    AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
    kCVPixelBufferMetalCompatibilityKey as String: true,
])
writer.add(input)
guard writer.startWriting() else { fatalError("\(writer.error!)") }
writer.startSession(atSourceTime: .zero)

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
for index in 0..<frameCount {
    while !input.isReadyForMoreMediaData { usleep(1000) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    guard let buffer else { fatalError("no pixel buffer") }
    context.render(frame(at: Double(index) / Double(frameCount)), to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: colorSpace)
    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)))
    if index % 60 == 0 { print("frame \(index)/\(frameCount)") }
}
input.markAsFinished()
writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(fps)))
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else { fatalError("\(writer.error!)") }
print("Wrote \(output.path)")
