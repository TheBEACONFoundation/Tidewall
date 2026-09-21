import AVFoundation
import Foundation
import Testing
@testable import Tidewall

@Suite("Built-in wallpapers")
struct BuiltInTests {
    let resources = sampleMovie.deletingLastPathComponent()

    @Test(arguments: BuiltInWallpaper.all.filter { !$0.isVisualizer })
    func everyBuiltInShipsAPlayableVideo(_ builtIn: BuiltInWallpaper) async throws {
        let url = resources.appendingPathComponent("\(builtIn.id).mov")
        #expect(FileManager.default.fileExists(atPath: url.path), "Resources/\(builtIn.id).mov is missing")
        let asset = AVURLAsset(url: url)
        #expect(try await asset.load(.isPlayable))
        #expect(try await asset.load(.duration).seconds > 1)
        #expect(try await !asset.loadTracks(withMediaType: .video).isEmpty)
    }

    @Test func builtInIDsAreUnique() {
        #expect(Set(BuiltInWallpaper.all.map(\.id)).count == BuiltInWallpaper.all.count)
    }

    @Test func coolChickenIsCrispAndColorAccurate() async throws {
        let asset = AVURLAsset(url: resources.appendingPathComponent("CoolChicken.mov"))
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 3840, height: 2160))
        #expect(abs(try await asset.load(.duration).seconds - 12) < 0.05)
        // Rendered in sRGB; a BT.709 transfer tag would make players lift the shadows.
        let format = try #require(try await track.load(.formatDescriptions).first)
        let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
        #expect(transfer as? String == kCMFormatDescriptionTransferFunction_sRGB as String)
    }
}
