import CoreImage
import Foundation
import Testing
@testable import Tidewall

@Suite("Framing")
struct FramingTests {
    let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    let video = CGSize(width: 1920, height: 1080)

    private func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.5 }

    @Test func fillCoversScreenCentered() {
        let r = FramePipeline.videoRect(in: screen, videoSize: video, settings: WallpaperSettings())
        #expect(close(r.height, 1000))
        #expect(close(r.width, 1777.8))
        #expect(close(r.midX, 800))
    }

    @Test func fillWithLeftFocusAlignsLeftEdges() {
        var s = WallpaperSettings()
        s.focusX = -1
        let r = FramePipeline.videoRect(in: screen, videoSize: video, settings: s)
        #expect(close(r.minX, 0))
    }

    @Test func fitWithTopFocusAlignsTopEdges() {
        var s = WallpaperSettings()
        s.scaling = .fit
        s.focusY = 1
        let r = FramePipeline.videoRect(in: screen, videoSize: video, settings: s)
        #expect(close(r.width, 1600))
        #expect(close(r.maxY, 1000))
    }

    @Test func stretchMatchesScreen() {
        var s = WallpaperSettings()
        s.scaling = .stretch
        #expect(FramePipeline.videoRect(in: screen, videoSize: video, settings: s) == screen)
    }

    @Test func zoomScalesSize() {
        var s = WallpaperSettings()
        s.zoom = 2
        let r = FramePipeline.videoRect(in: screen, videoSize: video, settings: s)
        #expect(close(r.height, 2000))
    }

    @Test func degenerateVideoSizeFallsBackToScreen() {
        #expect(FramePipeline.videoRect(in: screen, videoSize: .zero, settings: WallpaperSettings()) == screen)
    }
}

@Suite("Adjustments")
struct AdjustmentTests {
    let input = CIImage(color: CIColor(red: 0.8, green: 0.5, blue: 0.2))
        .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))

    @Test func identityIsNoOp() {
        #expect(Adjustments().isIdentity)
        #expect(FramePipeline.apply(Adjustments(), to: input) === input)
    }

    @Test func adjustedFrameKeepsExtent() {
        var adj = Adjustments()
        adj.brightness = -0.3
        adj.blur = 10
        adj.vignette = 1
        adj.tintAmount = 0.5
        #expect(!adj.isIdentity)
        #expect(FramePipeline.apply(adj, to: input).extent == input.extent)
    }

    @Test func zeroSaturationProducesGray() throws {
        var adj = Adjustments()
        adj.saturation = 0
        let output = FramePipeline.apply(adj, to: input)
        var pixel = [UInt8](repeating: 0, count: 4)
        FramePipeline.context.render(output, toBitmap: &pixel, rowBytes: 4,
                                     bounds: CGRect(x: 10, y: 10, width: 1, height: 1),
                                     format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        #expect(abs(Int(pixel[0]) - Int(pixel[1])) <= 2)
        #expect(abs(Int(pixel[1]) - Int(pixel[2])) <= 2)
    }
}

@Suite("Library format")
struct PersistenceTests {
    @Test func partialSettingsDecodeWithDefaults() throws {
        let json = #"{"scaling":"fit","speed":1.5,"adjustments":{"blur":4}}"#
        let s = try JSONDecoder().decode(WallpaperSettings.self, from: Data(json.utf8))
        #expect(s.scaling == .fit)
        #expect(s.speed == 1.5)
        #expect(s.adjustments.blur == 4)
        #expect(s.muted)
        #expect(s.adjustments.contrast == 1)
        #expect(s.trimEnd == nil)
    }

    @Test func settingsRoundTrip() throws {
        var s = WallpaperSettings()
        s.trimStart = 1.25
        s.trimEnd = 7.5
        s.mirrored = true
        s.adjustments.hue = 42
        let decoded = try JSONDecoder().decode(WallpaperSettings.self, from: JSONEncoder().encode(s))
        #expect(decoded == s)
    }

    /// Regression: the library was saved with ISO-8601 dates but loaded with the
    /// default decoder, so every relaunch came up with an empty library.
    @Test func libraryRoundTripsThroughDisk() throws {
        var wallpaper = Wallpaper.sample
        wallpaper.dateAdded = Date(timeIntervalSince1970: 1_790_000_000)
        wallpaper.settings.speed = 0.75
        let decoded = try LibraryStore.decodeLibrary(LibraryStore.encodeLibrary([wallpaper]))
        #expect(decoded == [wallpaper])
    }

    @Test func libraryFileWithISODatesDecodes() throws {
        let json = """
        [{"dateAdded":"2026-09-21T08:45:14Z","duration":20,"id":"2FC7FD02-52F8-44E9-A301-E6E82CFC3859",
          "mediaFile":"a.mov","name":"Aurora","originalFileName":"Aurora.mov",
          "pixelHeight":1080,"pixelWidth":1920,"settings":{}}]
        """
        let library = try LibraryStore.decodeLibrary(Data(json.utf8))
        #expect(library.count == 1)
        #expect(library.first?.settings == WallpaperSettings())
    }

    @Test func loopRangeIsClampedToDuration() {
        var w = Wallpaper.sample
        w.settings.trimStart = -3
        w.settings.trimEnd = 99
        #expect(w.loopRange == 0...20)
        w.settings.trimStart = 12
        w.settings.trimEnd = 4
        #expect(w.loopRange == 12...12)
    }
}

@Suite("Display assignments")
struct AssignmentTests {
    let wallpaper = UUID()
    let other = UUID()

    @Test func allDisplaysAppliesEverywhere() {
        let a = Assignments(allDisplays: wallpaper)
        #expect(a.wallpaperID(for: "A") == wallpaper)
        #expect(a.wallpaperID(for: "B") == wallpaper)
    }

    @Test func perDisplayOverridesAndDisablesWin() {
        var a = Assignments(allDisplays: wallpaper)
        a.perDisplay["B"] = other
        a.disabled.insert("C")
        #expect(a.wallpaperID(for: "A") == wallpaper)
        #expect(a.wallpaperID(for: "B") == other)
        #expect(a.wallpaperID(for: "C") == nil)
    }
}

extension Wallpaper {
    static var sample: Wallpaper {
        Wallpaper(id: UUID(), name: "Aurora", mediaFile: "Aurora.mov", originalFileName: "Aurora.mov",
                  dateAdded: .now, duration: 20, pixelWidth: 1920, pixelHeight: 1080,
                  settings: WallpaperSettings())
    }
}
