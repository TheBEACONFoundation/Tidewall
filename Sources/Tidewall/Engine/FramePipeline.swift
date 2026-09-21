import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import AppKit

/// The per-frame look of a wallpaper. Used by the live video composition, the
/// library thumbnails and the static system-wallpaper snapshot, so every surface
/// shows the same result.
enum FramePipeline {
    static let context = CIContext(options: [.cacheIntermediates: false])

    static func apply(_ adjustments: Adjustments, to input: CIImage) -> CIImage {
        guard !adjustments.isIdentity else { return input }
        let extent = input.extent
        var image = input

        if adjustments.brightness != 0 || adjustments.contrast != 1 || adjustments.saturation != 1 {
            let f = CIFilter.colorControls()
            f.inputImage = image
            f.brightness = Float(adjustments.brightness)
            f.contrast = Float(adjustments.contrast)
            f.saturation = Float(adjustments.saturation)
            image = f.outputImage ?? image
        }

        if adjustments.hue != 0 {
            let f = CIFilter.hueAdjust()
            f.inputImage = image
            f.angle = Float(adjustments.hue * .pi / 180)
            image = f.outputImage ?? image
        }

        if adjustments.tintAmount > 0 {
            let c = adjustments.tintColor
            let f = CIFilter.colorMonochrome()
            f.inputImage = image
            f.color = CIColor(red: c.red, green: c.green, blue: c.blue)
            f.intensity = Float(adjustments.tintAmount)
            image = f.outputImage ?? image
        }

        if adjustments.blur > 0 {
            // Blur radius is relative to a 1080p frame so the look is the same
            // for 720p previews and 4K sources.
            let sigma = adjustments.blur * max(extent.height, 1) / 1080
            image = image.clampedToExtent()
                .applyingGaussianBlur(sigma: sigma)
                .cropped(to: extent)
        }

        if adjustments.vignette > 0 {
            let f = CIFilter.vignette()
            f.inputImage = image
            f.intensity = Float(adjustments.vignette)
            f.radius = Float(max(extent.width, extent.height) / 1.6)
            image = f.outputImage ?? image
        }

        return image.cropped(to: extent)
    }

    static func apply(_ adjustments: Adjustments, to cgImage: CGImage) -> CGImage {
        guard !adjustments.isIdentity else { return cgImage }
        let output = apply(adjustments, to: CIImage(cgImage: cgImage))
        return context.createCGImage(output, from: output.extent) ?? cgImage
    }

    /// Where the video sits inside a screen of the given bounds for the
    /// wallpaper's framing settings. The rect may extend past `bounds`.
    static func videoRect(in bounds: CGRect, videoSize: CGSize, settings s: WallpaperSettings) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        var size: CGSize
        switch s.scaling {
        case .fill:
            let k = max(bounds.width / videoSize.width, bounds.height / videoSize.height)
            size = CGSize(width: videoSize.width * k, height: videoSize.height * k)
        case .fit:
            let k = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
            size = CGSize(width: videoSize.width * k, height: videoSize.height * k)
        case .stretch:
            size = bounds.size
        }
        size.width *= s.zoom
        size.height *= s.zoom

        // Signed overhang: positive when the video is larger than the screen.
        let dx = (size.width - bounds.width) / 2
        let dy = (size.height - bounds.height) / 2
        let center = CGPoint(x: bounds.midX - s.focusX * dx, y: bounds.midY - s.focusY * dy)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Renders a single frame exactly as it appears on a screen of `pixelSize`
    /// (used for the static system wallpaper snapshot).
    static func renderScreen(frame: CGImage, pixelSize: CGSize, settings: WallpaperSettings) -> CGImage? {
        let width = Int(pixelSize.width), height = Int(pixelSize.height)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(settings.backgroundColor.cgColor)
        ctx.fill(bounds)

        let filtered = apply(settings.adjustments, to: frame)
        let rect = videoRect(in: bounds, videoSize: CGSize(width: filtered.width, height: filtered.height),
                             settings: settings)
        ctx.interpolationQuality = .high
        if settings.mirrored {
            ctx.translateBy(x: rect.midX, y: 0)
            ctx.scaleBy(x: -1, y: 1)
            ctx.translateBy(x: -rect.midX, y: 0)
        }
        ctx.draw(filtered, in: rect)
        return ctx.makeImage()
    }
}

/// Thread-safe holder for the adjustments the video composition reads on its
/// rendering queue, so sliders update the picture without rebuilding playback.
final class AdjustmentsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Adjustments

    init(_ value: Adjustments) { self.value = value }

    var current: Adjustments {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
