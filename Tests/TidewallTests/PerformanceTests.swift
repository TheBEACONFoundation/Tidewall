import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import Tidewall

@Suite("Required resolution")
struct RequiredScaleTests {
    let video4K = CGSize(width: 3840, height: 2160)

    @Test func smallScreenNeedsLessThanFull() {
        let scale = FramePipeline.requiredScale(videoSize: video4K, screenPixelSizes: [CGSize(width: 1920, height: 1080)],
                                                settings: WallpaperSettings())
        #expect(abs(scale - 0.5) < 0.001)
    }

    @Test func fillUsesTheLargerAxis() {
        // 16:10 screen, 16:9 video: filling needs the height to match.
        let scale = FramePipeline.requiredScale(videoSize: video4K, screenPixelSizes: [CGSize(width: 2880, height: 1800)],
                                                settings: WallpaperSettings())
        #expect(abs(scale - 1800.0 / 2160) < 0.001)
    }

    @Test func zoomAndLargestScreenWin() {
        var s = WallpaperSettings()
        s.zoom = 1.5
        let scale = FramePipeline.requiredScale(videoSize: video4K,
                                                screenPixelSizes: [CGSize(width: 1280, height: 720), CGSize(width: 1920, height: 1080)],
                                                settings: s)
        #expect(abs(scale - 0.75) < 0.001)
    }

    @Test func neverAboveOne() {
        let scale = FramePipeline.requiredScale(videoSize: CGSize(width: 1280, height: 720),
                                                screenPixelSizes: [CGSize(width: 5120, height: 2880)], settings: WallpaperSettings())
        #expect(scale == 1)
    }
}

@Suite("Playback copies")
struct RenditionRecipeTests {
    let hardware = SourceInfo(hardwareDecodable: true, isHDR: false)

    @Test func plainVideoPlaysOriginal() {
        #expect(RenditionRecipe.make(for: .sample, info: hardware, requiredScale: 1) == nil)
    }

    @Test func adjustmentsNeedACopy() {
        var w = Wallpaper.sample
        w.settings.adjustments.blur = 8
        let recipe = RenditionRecipe.make(for: w, info: hardware, requiredScale: 1)
        #expect(recipe?.adjustments.blur == 8)
        #expect(recipe?.scale == 1)
    }

    @Test func oversizedVideoIsDownscaledButNeverBelowTheScreen() {
        let recipe = RenditionRecipe.make(for: .sample, info: hardware, requiredScale: 0.4)
        #expect(recipe?.scale == 0.5)
        #expect(RenditionRecipe.make(for: .sample, info: hardware, requiredScale: 0.8) == nil, "small savings aren't worth a copy")
    }

    @Test func softwareCodecsGetACopy() {
        let software = SourceInfo(hardwareDecodable: false, isHDR: false)
        #expect(RenditionRecipe.make(for: .sample, info: software, requiredScale: 1) != nil)
    }

    @Test func hdrIsLeftAloneUnlessALookIsApplied() {
        let hdr = SourceInfo(hardwareDecodable: true, isHDR: true)
        #expect(RenditionRecipe.make(for: .sample, info: hdr, requiredScale: 0.4) == nil)
        var w = Wallpaper.sample
        w.settings.adjustments.saturation = 0.5
        #expect(RenditionRecipe.make(for: w, info: hdr, requiredScale: 1) != nil)
    }

    @Test func playbackOnlySettingsDontChangeTheCopy() {
        var a = Wallpaper.sample
        a.settings.adjustments.vignette = 1
        var b = a
        b.settings.speed = 1.5
        b.settings.trimStart = 3
        b.settings.zoom = 1.2
        b.settings.mirrored = true
        let ra = RenditionRecipe.make(for: a, info: hardware, requiredScale: 1)
        let rb = RenditionRecipe.make(for: b, info: hardware, requiredScale: 1)
        #expect(ra?.key == rb?.key)
        b.settings.adjustments.vignette = 1.1
        #expect(RenditionRecipe.make(for: b, info: hardware, requiredScale: 1)?.key != ra?.key)
    }

    @Test func bakedCopyHasTheLookAndSize() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidewall-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var adjustments = Adjustments()
        adjustments.saturation = 0
        let recipe = RenditionRecipe(mediaFile: "Aurora.mov", adjustments: adjustments, scale: 0.5)
        let output = dir.appendingPathComponent("copy.mov")
        try await RenditionExporter.export(source: sampleMovie, recipe: recipe, to: output)

        let asset = AVURLAsset(url: output)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 960, height: 540))
        #expect(abs(try await asset.load(.duration).seconds - 20) < 0.1)

        let generator = AVAssetImageGenerator(asset: asset)
        let frame = try await generator.image(at: CMTime(seconds: 5, preferredTimescale: 600)).image
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(frame, in: CGRect(x: -400, y: -200, width: frame.width, height: frame.height))
        #expect(abs(Int(pixel[0]) - Int(pixel[1])) <= 4 && abs(Int(pixel[1]) - Int(pixel[2])) <= 4, "baked copy should be grayscale")
    }
}

@Suite("Desktop coverage")
struct CoverageTests {
    let screen = CGRect(x: 0, y: 25, width: 1600, height: 975)

    @Test func noWindowsNoCoverage() {
        #expect(DesktopCoverage.coveredFraction(of: screen, by: []) == 0)
    }

    @Test func maximizedWindowCoversEverything() {
        #expect(DesktopCoverage.coveredFraction(of: screen, by: [screen]) == 1)
    }

    @Test func halfScreenWindow() {
        let left = CGRect(x: 0, y: 25, width: 800, height: 975)
        #expect(abs(DesktopCoverage.coveredFraction(of: screen, by: [left]) - 0.5) < 0.01)
    }

    @Test func overlappingWindowsArentDoubleCounted() {
        let a = CGRect(x: 0, y: 25, width: 1000, height: 975)
        let b = CGRect(x: 600, y: 25, width: 1000, height: 975)
        #expect(DesktopCoverage.coveredFraction(of: screen, by: [a, b]) == 1)
    }

    @Test func windowsOnOtherDisplaysDontCount() {
        let elsewhere = CGRect(x: 1600, y: 0, width: 1920, height: 1080)
        #expect(DesktopCoverage.coveredFraction(of: screen, by: [elsewhere]) == 0)
    }
}
