import AVFoundation
import CoreVideo
import ImageIO

/// Converts animated GIF / PNG / WebP / HEICS images into H.264 movies so they
/// get hardware-decoded playback and the same looping, trimming and filters
/// as any other video.
enum AnimatedImageConverter {
    static func frameCount(at url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
        return CGImageSourceGetCount(source)
    }

    static func convert(_ url: URL, to output: URL) async throws {
        let name = url.lastPathComponent
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 1,
              let first = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ImportError.notAnimated(name) }

        let count = CGImageSourceGetCount(source)
        // H.264 needs even dimensions.
        let width = (first.width + 1) & ~1
        let height = (first.height + 1) & ~1

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(4_000_000, width * height * 10),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ImportError.unreadable(name) }
        writer.startSession(atSourceTime: .zero)

        var time = CMTime.zero
        for index in 0..<count {
            // ImageIO returns fully composited frames (disposal handled for us).
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard let pool = adaptor.pixelBufferPool,
                  let buffer = makeBuffer(from: image, pool: pool, width: width, height: height)
            else { throw writer.error ?? ImportError.unreadable(name) }
            adaptor.append(buffer, withPresentationTime: time)
            time = time + CMTime(seconds: frameDelay(source, index), preferredTimescale: 6000)
        }

        input.markAsFinished()
        writer.endSession(atSourceTime: time)
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ImportError.unreadable(name) }
    }

    private static func makeBuffer(from image: CGImage, pool: CVPixelBufferPool, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    /// Frame duration in seconds, treating tiny delays the way browsers do.
    private static func frameDelay(_ source: CGImageSource, _ index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let containers: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]
        for (container, unclamped, clamped) in containers {
            guard let dict = properties[container] as? [CFString: Any] else { continue }
            let delay = (dict[unclamped] as? Double) ?? (dict[clamped] as? Double) ?? 0.1
            return delay < 0.011 ? 0.1 : delay
        }
        return 0.1
    }
}
