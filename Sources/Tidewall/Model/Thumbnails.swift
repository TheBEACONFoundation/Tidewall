import AppKit
import AVFoundation

/// Frame grabs for library cards, the filmstrip and trim scrubbing.
enum FrameGrabber {
    static func frame(of url: URL, at seconds: Double, maxSize: CGSize, tolerance: Double = 0.2) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxSize
        let tol = CMTime(seconds: tolerance, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tol
        generator.requestedTimeToleranceAfter = tol
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    /// Evenly spaced frames across the whole video, for the trim filmstrip.
    static func filmstrip(of url: URL, duration: Double, count: Int, height: CGFloat) async -> [CGImage] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: height * 3, height: height)
        let tol = CMTime(seconds: duration / Double(count * 2), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tol
        generator.requestedTimeToleranceAfter = tol
        let times = (0..<count).map { i in
            CMTime(seconds: duration * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
        }
        var frames: [CGImage] = []
        for await result in generator.images(for: times) {
            if let image = try? result.image { frames.append(image) }
        }
        return frames
    }
}

/// Caches library thumbnails with the wallpaper's color adjustments baked in.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let rendered = NSCache<NSString, NSImage>()
    private var rawFrames: [String: CGImage] = [:]

    static func cacheKey(for wallpaper: Wallpaper) -> String {
        if let content = LiveContent(wallpaper) { return "live|\(content.hashValue)" }
        let file = LibraryStore.shared.currentMediaFile(for: wallpaper)
        return "\(file)|\(thumbnailTime(for: wallpaper))|\(wallpaper.settings.adjustments.hashValue)"
    }

    /// Shortly into the loop, since many clips open on a black frame.
    static func thumbnailTime(for wallpaper: Wallpaper) -> Double {
        let range = wallpaper.loopRange
        let offset = min(1.5, (range.upperBound - range.lowerBound) * 0.25)
        return ((range.lowerBound + offset) * 10).rounded() / 10
    }

    func cachedImage(for wallpaper: Wallpaper) -> NSImage? {
        rendered.object(forKey: Self.cacheKey(for: wallpaper) as NSString)
    }

    func image(for wallpaper: Wallpaper) async -> NSImage? {
        let key = Self.cacheKey(for: wallpaper)
        if let cached = rendered.object(forKey: key as NSString) { return cached }

        if let content = LiveContent(wallpaper) {
            guard let frame = content.snapshot(size: CGSize(width: 640, height: 400)) else { return nil }
            let image = NSImage(cgImage: frame, size: CGSize(width: frame.width, height: frame.height))
            rendered.setObject(image, forKey: key as NSString)
            return image
        }

        let time = Self.thumbnailTime(for: wallpaper)
        let rawKey = "\(LibraryStore.shared.currentMediaFile(for: wallpaper))|\(time)"
        let raw: CGImage
        if let cached = rawFrames[rawKey] {
            raw = cached
        } else {
            let url = LibraryStore.shared.mediaURL(for: wallpaper)
            guard let frame = await FrameGrabber.frame(of: url, at: time, maxSize: CGSize(width: 640, height: 640))
            else { return nil }
            rawFrames[rawKey] = frame
            raw = frame
        }

        let adjustments = wallpaper.settings.adjustments
        let filtered = await Task.detached(priority: .userInitiated) {
            FramePipeline.apply(adjustments, to: raw)
        }.value
        let image = NSImage(cgImage: filtered, size: CGSize(width: filtered.width, height: filtered.height))
        rendered.setObject(image, forKey: key as NSString)
        return image
    }
}

/// Optionally mirrors the live wallpaper into the macOS desktop picture, so
/// Mission Control, the lock screen and a quit app all show a matching still.
@MainActor
final class SystemWallpaperSync {
    static let shared = SystemWallpaperSync()

    private var applied: [String: Int] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    func sync(_ wallpaper: Wallpaper, on display: Display) {
        var hasher = Hasher()
        hasher.combine(wallpaper.id)
        hasher.combine(LibraryStore.shared.currentMediaFile(for: wallpaper))
        hasher.combine(wallpaper.settings)
        hasher.combine(wallpaper.visualizer)
        hasher.combine(wallpaper.composition)
        hasher.combine(display.pixelSize.width)
        hasher.combine(display.pixelSize.height)
        let signature = hasher.finalize()
        guard applied[display.id] != signature else { return }

        tasks[display.id]?.cancel()
        tasks[display.id] = Task { [weak self] in
            // Settle first: sliders in the editor change settings many times a second.
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            await self.render(wallpaper, on: display)
            self.applied[display.id] = signature
        }
    }

    func forget() {
        applied.removeAll()
    }

    private func render(_ wallpaper: Wallpaper, on display: Display) async {
        let store = LibraryStore.shared
        let pixelSize = display.pixelSize
        let data: Data?
        if let content = LiveContent(wallpaper) {
            // A live wallpaper's still is a representative moment of it.
            data = content.snapshot(size: pixelSize)
                .flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .jpeg, properties: [.compressionFactor: 0.92]) }
        } else {
            let url = store.mediaURL(for: wallpaper)
            guard let frame = await FrameGrabber.frame(of: url, at: wallpaper.loopRange.lowerBound,
                                                       maxSize: .zero, tolerance: 0) else { return }
            let settings = wallpaper.settings
            data = await Task.detached(priority: .utility) {
                guard let image = FramePipeline.renderScreen(frame: frame, pixelSize: pixelSize, settings: settings)
                else { return nil }
                return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.92])
            }.value
        }
        guard let data, let screen = display.screen else { return }

        // macOS caches desktop pictures by URL, so every still needs a new name.
        let fm = FileManager.default
        let prefix = "\(display.id)-"
        let file = store.stillsDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString.prefix(8)).jpg")
        do {
            try data.write(to: file, options: .atomic)
            try NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: true,
            ])
        } catch {
            NSLog("Tidewall: could not set desktop picture: \(error)")
            return
        }
        let old = (try? fm.contentsOfDirectory(at: store.stillsDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in old where url.lastPathComponent.hasPrefix(prefix) && url != file {
            try? fm.removeItem(at: url)
        }
    }
}
