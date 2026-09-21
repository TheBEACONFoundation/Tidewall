import AVFoundation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Tidewall

/// Resources/Aurora.mov, located relative to this file so tests run from any directory.
let sampleMovie = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/Aurora.mov")

/// Real AVFoundation playback, so these run one at a time.
@Suite("Looping player", .serialized)
@MainActor
struct LoopingPlayerTests {
    private func makePlayer(trim: ClosedRange<Double>? = nil) -> (LoopingPlayer, Wallpaper) {
        var wallpaper = Wallpaper.sample
        if let trim {
            wallpaper.settings.trimStart = trim.lowerBound
            wallpaper.settings.trimEnd = trim.upperBound
        }
        return (LoopingPlayer(wallpaper: wallpaper, url: sampleMovie), wallpaper)
    }

    private func sample(_ player: LoopingPlayer, count: Int, every ms: Int = 100) async -> [Double] {
        var times: [Double] = []
        for _ in 0..<count {
            try? await Task.sleep(for: .milliseconds(ms))
            times.append(player.currentTime)
        }
        return times
    }

    @Test func wallpaperFriendlyDefaults() {
        let (player, _) = makePlayer()
        defer { player.invalidate() }
        #expect(player.player.preventsDisplaySleepDuringVideoPlayback == false)
        #expect(player.player.allowsExternalPlayback == false)
        #expect(player.player.isMuted)
    }

    @Test func loopsInsideTrimmedRange() async {
        let (player, _) = makePlayer(trim: 2...3)
        defer { player.invalidate() }
        player.setPlaying(true)
        let times = await sample(player, count: 30)

        #expect(player.player.currentItem?.status == .readyToPlay)
        #expect(times.allSatisfy { $0 >= 1.95 && $0 <= 3.05 }, "saw \(times.min() ?? -1)…\(times.max() ?? -1)")
        let wrapped = zip(times, times.dropFirst()).contains { $1 < $0 - 0.3 }
        #expect(wrapped, "playback should wrap back to the loop start")
    }

    @Test func liveSpeedAndTrimChanges() async {
        var (player, wallpaper) = makePlayer(trim: 2...3)
        defer { player.invalidate() }
        player.setPlaying(true)
        try? await Task.sleep(for: .milliseconds(300))

        wallpaper.settings.speed = 2
        player.update(wallpaper)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(abs(player.player.rate - 2) < 0.01)

        wallpaper.settings.trimStart = 10
        wallpaper.settings.trimEnd = nil
        player.update(wallpaper)
        try? await Task.sleep(for: .milliseconds(900))
        #expect(player.currentTime >= 9.9, "loop should rebuild at the new start")
        #expect(abs(player.player.rate - 2) < 0.01, "speed should survive a loop rebuild")
    }

    @Test func pauseStopsTime() async {
        let (player, _) = makePlayer()
        defer { player.invalidate() }
        player.setPlaying(true)
        try? await Task.sleep(for: .milliseconds(400))
        player.setPlaying(false)
        let paused = player.currentTime
        try? await Task.sleep(for: .milliseconds(300))
        #expect(abs(player.currentTime - paused) < 0.01)
    }

    @Test func filtersRenderIntoDecodedFrames() async throws {
        var (player, wallpaper) = makePlayer()
        defer { player.invalidate() }
        player.setPlaying(true)

        wallpaper.settings.adjustments.saturation = 0
        player.update(wallpaper)
        try? await Task.sleep(for: .milliseconds(800))
        let item = try #require(player.player.currentItem)
        #expect(item.videoComposition != nil)

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        defer { item.remove(output) }
        try? await Task.sleep(for: .milliseconds(400))
        let buffer = try #require(output.copyPixelBuffer(forItemTime: output.itemTime(forHostTime: CACurrentMediaTime()),
                                                          itemTimeForDisplay: nil))
        #expect(maxChannelSpread(buffer) <= 6, "frames should be grayscale")

        wallpaper.settings.adjustments = Adjustments()
        player.update(wallpaper)
        #expect(player.player.currentItem?.videoComposition == nil, "no composition once filters are reset")
    }

    private func maxChannelSpread(_ buffer: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        var spread = 0
        for y in stride(from: 0, to: CVPixelBufferGetHeight(buffer), by: 97) {
            for x in stride(from: 0, to: CVPixelBufferGetWidth(buffer), by: 131) {
                let p = base + y * row + x * 4
                let c = [Int(p[0]), Int(p[1]), Int(p[2])]
                spread = max(spread, c.max()! - c.min()!)
            }
        }
        return spread
    }
}

@Suite("Animated image import")
struct AnimatedImageTests {
    @Test func gifBecomesMovieWithMatchingTiming() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidewall-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let gif = dir.appendingPathComponent("test.gif")
        let destination = try #require(CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 12, nil))
        for i in 0..<12 {
            let ctx = CGContext(data: nil, width: 101, height: 75, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: Double(i) / 11, green: 0.3, blue: 1 - Double(i) / 11, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 101, height: 75))
            CGImageDestinationAddImage(destination, ctx.makeImage()!,
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        #expect(AnimatedImageConverter.frameCount(at: gif) == 12)

        let movie = dir.appendingPathComponent("test.mov")
        try await AnimatedImageConverter.convert(gif, to: movie)
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(abs(duration - 0.6) < 0.02)
        #expect(size == CGSize(width: 102, height: 76), "odd dimensions are padded to even")
    }

    @Test func stillImageIsRejected() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidewall-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let png = dir.appendingPathComponent("still.png")
        let destination = try #require(CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil))
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))

        await #expect(throws: ImportError.self) {
            try await AnimatedImageConverter.convert(png, to: dir.appendingPathComponent("out.mov"))
        }
    }
}
