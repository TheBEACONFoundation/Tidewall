import AVFAudio
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
        // The player clock can briefly run past the loop end while the looper
        // hands off to the next item; on CI VMs without hardware video that
        // overshoot reaches ~0.15s, so allow a quarter second.
        #expect(times.allSatisfy { $0 >= 1.95 && $0 <= 3.25 }, "saw \(times.min() ?? -1)…\(times.max() ?? -1)")
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

@Suite("Player hand-off", .serialized)
@MainActor
struct HandOffTests {
    @Test func preparedPlayerLandsOnRequestedTime() async {
        let player = LoopingPlayer(wallpaper: .sample, url: sampleMovie)
        defer { player.invalidate() }
        await player.prepare(at: { 7.5 })
        #expect(player.player.currentItem?.status == .readyToPlay)
        #expect(abs(player.currentTime - 7.5) < 0.05)
    }
}

@Suite("Muted audio", .serialized)
@MainActor
struct MutedAudioTests {
    /// Aurora's first 4 seconds with a sine-wave soundtrack.
    private func makeClipWithAudio(in dir: URL) async throws -> URL {
        let tone = dir.appendingPathComponent("tone.m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: tone, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
        ])
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100 * 4)!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][i] = 0.2 * sin(2 * .pi * 440 * Float(i) / 44_100)
        }
        try file.write(from: buffer)
        file.close()

        // Tracks only weakly reference their asset, so keep the assets alive.
        let videoAsset = AVURLAsset(url: sampleMovie), audioAsset = AVURLAsset(url: tone)
        let composition = AVMutableComposition()
        let video = try await videoAsset.loadTracks(withMediaType: .video)[0]
        let audio = try await audioAsset.loadTracks(withMediaType: .audio)[0]
        // AAC priming makes the encoded tone a touch shorter than 4 seconds.
        let audioRange = try await audio.load(.timeRange)
        let range = CMTimeRange(start: .zero, duration: min(CMTime(seconds: 3.5, preferredTimescale: 600), audioRange.duration))
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(range, of: video, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(range, of: audio, at: .zero)
        let output = dir.appendingPathComponent("with-audio.mov")
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await session.export(to: output, as: .mov)
        withExtendedLifetime((videoAsset, audioAsset)) {}
        return output
    }

    private func audioStates(_ player: LoopingPlayer) -> [Bool] {
        player.player.items().flatMap { $0.tracks.filter { $0.assetTrack?.mediaType == .audio }.map(\.isEnabled) }
    }

    @Test func mutedPlayersDontRunTheAudioPipeline() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidewall-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try await makeClipWithAudio(in: dir)

        var wallpaper = Wallpaper.sample
        wallpaper.duration = 3.5
        wallpaper.settings.trimEnd = 1.5
        let player = LoopingPlayer(wallpaper: wallpaper, url: url)
        defer { player.invalidate() }
        player.setPlaying(true)
        try? await Task.sleep(for: .seconds(2.5))   // past a loop, so recycled items are covered too

        let muted = audioStates(player)
        #expect(!muted.isEmpty)
        #expect(muted.allSatisfy { !$0 }, "audio tracks should be disabled while muted: \(muted)")

        wallpaper.settings.muted = false
        player.update(wallpaper)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(audioStates(player).allSatisfy { $0 }, "audio should come back when unmuted")
    }
}
