import CoreGraphics
import Foundation
import Testing
@testable import Tidewall

@Suite("Live wallpapers", .serialized)
@MainActor
struct VisualizerTests {
    @Test func visualizerSettingsDecodeWithDefaults() throws {
        let s = try JSONDecoder().decode(VisualizerSettings.self, from: Data(#"{"palette":"ember"}"#.utf8))
        #expect(s.palette == .ember)
        #expect(s.sensitivity == 1)
        #expect(s.quality == 0.5)
    }

    @Test func liveWallpapersSurviveAReload() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidewall-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(rootURL: dir)
        store.load()
        let pulse = try #require(BuiltInWallpaper.all.first { $0.isVisualizer })
        await store.addBuiltIn(pulse)
        let added = try #require(store.wallpapers.first)
        #expect(added.isLive)
        #expect(added.allMediaFiles.isEmpty, "a live wallpaper has no video to delete")

        let reopened = LibraryStore(rootURL: dir)
        reopened.load()
        #expect(reopened.wallpapers.map(\.id) == [added.id], "live wallpapers have no media file and must not be dropped")
        #expect(reopened.wallpapers.first?.visualizer == VisualizerSettings())
    }

    /// Average brightness of an image, 0…255.
    private func brightness(_ image: CGImage) -> Double {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0
        for i in stride(from: 0, to: px.count, by: 4) { sum += Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]) }
        return Double(sum) / Double(w * h * 3)
    }

    @Test func shaderRendersAndFollowsTheMusic() throws {
        guard let renderer = VisualizerRenderer.shared else {
            Issue.record("Metal isn't available here")
            return
        }
        let size = CGSize(width: 320, height: 200)
        let loud = try #require(renderer.snapshot(settings: VisualizerSettings(), size: size))
        let silent = try #require(renderer.snapshot(settings: VisualizerSettings(), size: size, frame: AudioAnalyzer.Frame()))
        #expect(loud.width == 320 && loud.height == 200)
        #expect(brightness(silent) > 1, "an idle visualizer still shows something")
        #expect(brightness(loud) > brightness(silent) * 1.5, "music should light it up: \(brightness(loud)) vs \(brightness(silent))")
    }
}
