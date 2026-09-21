import CoreGraphics
import ImageIO
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

    @Test(arguments: BlockKind.allCases.filter { $0 != .vignette && $0 != .gradient && $0 != .image })
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

    @Test func editingBlocksChangesTheThumbnail() {
        var wallpaper = Wallpaper(id: UUID(), name: "Mine", mediaFile: "", originalFileName: "", dateAdded: .now,
                                  duration: 0, pixelWidth: 0, pixelHeight: 0, settings: WallpaperSettings(),
                                  composition: BlockTemplate.nightSky.composition)
        let before = ThumbnailCache.cacheKey(for: wallpaper)
        #expect(ThumbnailCache.cacheKey(for: wallpaper) == before, "stable while nothing changes")
        wallpaper.composition?.blocks[0].colorA = RGBAColor(red: 1, green: 0, blue: 0)
        #expect(ThumbnailCache.cacheKey(for: wallpaper) != before)
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

    /// A solid-colour picture file, for picture blocks.
    private func writePicture(to url: URL, red: CGFloat, width: Int = 64, height: Int = 32) throws {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: red, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func clocksShowTheTimeButStayOffDesktopPictures() throws {
        let renderer = try #require(BlocksRenderer.shared, "Metal isn't available here")
        let clock = Composition(blocks: [BlockKind.clock.makeBlock()])
        let live = try #require(renderer.snapshot(clock, size: size))
        let still = try #require(renderer.snapshot(clock, size: size, date: nil))
        #expect(brightness(live) > brightness(still) + 1, "the time is drawn")
        #expect(brightness(still) < 0.5, "a desktop picture can't keep time, so it leaves the clock out")
    }

    @Test func typeGrowsWithItsSizeAndText() throws {
        let renderer = try #require(BlocksRenderer.shared, "Metal isn't available here")
        var block = BlockKind.text.makeBlock()
        func slot(_ edit: (inout Block) -> Void) -> BlockTextureSlot? {
            var b = block
            edit(&b)
            return renderer.textures.prepare(Composition(blocks: [b]), drawableHeight: 1000, date: .now).slots[b.id]
        }
        let small = try #require(slot { $0.size = 0.5 }), large = try #require(slot { $0.size = 1.5 })
        #expect(large.height > small.height * 2.5)
        let long = try #require(slot { $0.text = "Hello there, world" })
        let short = try #require(slot { _ in })
        #expect(long.aspect > short.aspect * 2)
        block.text = "   "
        #expect(slot { _ in } == nil, "blank text draws nothing")
    }

    @Test func picturesFillTheScreenAndTravelWithExports() async throws {
        let renderer = try #require(BlocksRenderer.shared, "Metal isn't available here")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidewall-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mine = LibraryStore(rootURL: dir.appendingPathComponent("Mine"))
        mine.load()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("red.png")
        try writePicture(to: source, red: 0.9)

        var picture = BlockKind.image.makeBlock()
        picture.media = try mine.importPicture(from: source)
        #expect(picture.media?.hasPrefix(LibraryStore.picturePrefix) == true)
        var wallpaper = mine.createBlocksWallpaper(from: .blank)
        wallpaper.composition?.blocks.append(picture)
        mine.update(wallpaper)
        #expect(mine.wallpaper(id: wallpaper.id)?.allMediaFiles.contains(picture.media!) == true)

        // Drawn filling the screen: the red covers the corners too.
        let saved = renderer.textures.mediaDirectory
        renderer.textures.mediaDirectory = mine.mediaDirectory
        defer { renderer.textures.mediaDirectory = saved }
        let image = try #require(renderer.snapshot(Composition(blocks: [picture]), size: size))
        let px = pixels(image)
        #expect(px[0] > 180 && px[1] < 80, "top-left corner is the picture's red")
        #expect(px[px.count - 4] > 180, "so is the bottom-right")

        // Exported and imported elsewhere, the picture comes along.
        let package = dir.appendingPathComponent("Shared.tidewall")
        try mine.exportPackage(mine.wallpaper(id: wallpaper.id)!, to: package)
        let theirs = LibraryStore(rootURL: dir.appendingPathComponent("Theirs"))
        theirs.load()
        let imported = try #require(await theirs.importFiles([package]).first)
        let file = try #require(imported.composition?.blocks.last?.media)
        #expect(FileManager.default.fileExists(atPath: theirs.mediaDirectory.appendingPathComponent(file).path))

        // Pictures no wallpaper uses any more are cleared out at the next launch.
        let orphan = try mine.importPicture(from: source)
        let reloaded = LibraryStore(rootURL: dir.appendingPathComponent("Mine"))
        mine.saveNow()
        reloaded.load()
        #expect(!FileManager.default.fileExists(atPath: mine.mediaDirectory.appendingPathComponent(orphan).path))
        #expect(FileManager.default.fileExists(atPath: mine.mediaDirectory.appendingPathComponent(picture.media!).path))
    }
}
