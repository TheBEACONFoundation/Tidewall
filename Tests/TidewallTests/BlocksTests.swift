import CoreGraphics
import Foundation
import Testing
@testable import Tidewall

@Suite("Blocks", .serialized)
@MainActor
struct BlocksTests {
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

    private let size = CGSize(width: 256, height: 160)

    @Test func uniformsMatchTheShaderLayout() {
        // Must mirror `struct Scene` and `struct BlockData` in BlocksRenderer.source.
        #expect(MemoryLayout<BlocksScene>.stride == 48)
        #expect(MemoryLayout<BlockUniform>.stride == 80)
        #expect(MemoryLayout<BlockUniform>.offset(of: \.colorA) == 16)
        #expect(MemoryLayout<BlockUniform>.offset(of: \.place) == 64)
    }

    @Test func oldAndPartialBlocksDecode() throws {
        let json = #"{"blocks":[{"kind":4,"amount":0.5},{"kind":2}]}"#
        let composition = try JSONDecoder().decode(Composition.self, from: Data(json.utf8))
        #expect(composition.blocks.map(\.kind) == [.orb, .particles])
        #expect(composition.blocks[0].amount == 0.5)
        #expect(composition.blocks[0].enabled && composition.blocks[0].react == .nothing)
    }

    @Test func onlyListensWhenABlockNeedsTheMusic() {
        var c = BlockTemplate.nightSky.composition
        #expect(!c.usesAudio)
        c.blocks[1].react = .beat
        #expect(c.usesAudio)
        c.blocks[1].enabled = false
        #expect(!c.usesAudio, "a switched-off block doesn't count")
        #expect(BlockTemplate.party.composition.usesAudio)
    }

    @Test(arguments: BlockKind.allCases.filter { $0 != .vignette && $0 != .gradient })
    func everyKindDrawsSomething(_ kind: BlockKind) throws {
        let renderer = try #require(BlocksRenderer.shared, "Metal isn't available here")
        let image = try #require(renderer.snapshot(Composition(blocks: [kind.makeBlock()]), size: size))
        #expect(brightness(image) > 0.5, "\(kind.title) drew nothing visible (\(brightness(image)))")
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &px, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return px
    }

    @Test func templatesRenderAndDiffer() throws {
        let renderer = try #require(BlocksRenderer.shared, "Metal isn't available here")
        let images = try BlockTemplate.allCases.map { try #require(renderer.snapshot($0.composition, size: size)) }
        #expect(images.map(brightness).allSatisfy { $0 > 2 })
        // Every pair of templates differs by a clear margin, pixel for pixel.
        let all = images.map(pixels)
        for i in all.indices {
            for j in all.indices where j > i {
                let difference = zip(all[i], all[j]).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) } / all[i].count
                #expect(difference > 8, "\(BlockTemplate.allCases[i].title) and \(BlockTemplate.allCases[j].title) look alike")
            }
        }
    }

    @Test func reactingBlocksMoveWithTheMusic() throws {
        let renderer = try #require(BlocksRenderer.shared, "Metal isn't available here")
        var orb = BlockKind.orb.makeBlock()
        orb.react = .bass
        let composition = Composition(blocks: [orb])
        let loud = try #require(renderer.snapshot(composition, size: size))
        let quiet = try #require(renderer.snapshot(composition, size: size, frame: AudioAnalyzer.Frame()))
        #expect(brightness(loud) > brightness(quiet) * 1.3, "\(brightness(loud)) vs \(brightness(quiet))")
    }

    @Test func motionIsIntegratedAndSpeedsUpWithTheMusic() {
        var block = BlockKind.particles.makeBlock()
        block.speed = 1
        block.react = .level
        let composition = Composition(blocks: [block])
        var calm = BlocksMotion(), loud = BlocksMotion()
        var frame = AudioAnalyzer.Frame()
        for _ in 0..<60 { calm.advance(composition, frame: frame, by: 1.0 / 60) }
        frame.level = 1
        for _ in 0..<60 { loud.advance(composition, frame: frame, by: 1.0 / 60) }
        #expect(abs((calm.phases[block.id] ?? 0) - 1) < 0.001, "one second at speed 1")
        #expect((loud.phases[block.id] ?? 0) > 2.5, "music speeds it up")
    }

    @Test func exportedWallpapersImportElsewhere() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidewall-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mine = LibraryStore(rootURL: dir.appendingPathComponent("Mine"))
        mine.load()
        var original = mine.createBlocksWallpaper(from: .synthwave)
        #expect(original.name == "My Synthwave")
        #expect(mine.createBlocksWallpaper(from: .synthwave).name == "My Synthwave 2", "names stay unique")
        original.composition?.blocks[0].colorA = RGBAColor(r: 0.9, g: 0.1, b: 0.2)
        mine.update(original)

        let package = dir.appendingPathComponent("Shared.tidewall")
        try mine.exportPackage(mine.wallpaper(id: original.id)!, to: package)

        let theirs = LibraryStore(rootURL: dir.appendingPathComponent("Theirs"))
        theirs.load()
        let imported = try #require(await theirs.importFiles([package]).first)
        #expect(theirs.importErrors.isEmpty)
        #expect(imported.name == "My Synthwave")
        #expect(imported.composition == mine.wallpaper(id: original.id)?.composition)
        #expect(imported.id != original.id)
    }
}
