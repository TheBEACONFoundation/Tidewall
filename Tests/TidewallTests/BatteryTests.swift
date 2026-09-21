import AVFoundation
import Foundation
import Testing
@testable import Tidewall

@Suite("Battery states")
struct BatteryStateTests {
    /// Must match Lantern's `LanternGlyph.corps(level:charging:)`, so a
    /// battery-reactive wallpaper turns exactly when the emblem does.
    @Test(arguments: [
        (1.0, false, BatteryState.full), (0.995, false, .full), (1.0, true, .full),
        (0.99, false, .normal), (0.9, false, .normal), (0.21, false, .normal),
        (0.20, false, .low), (0.11, false, .low),
        (0.10, false, .critical), (0.016, false, .critical),
        (0.015, false, .empty), (0.0, false, .empty),
        // Charging keeps the normal light at any level short of full.
        (0.05, true, .normal), (0.0, true, .normal),
    ])
    func matchesLanternThresholds(level: Double, charging: Bool, expected: BatteryState) {
        #expect(BatteryState.of(level: level, charging: charging) == expected)
    }

    @Test func variantsFallBackToThePrimaryVideo() {
        var w = Wallpaper.sample
        #expect(w.mediaFile(for: .low) == "Aurora.mov")
        w.batteryVariants = ["full": "White.mov", "normal": "Green.mov"]
        #expect(w.mediaFile(for: .full) == "White.mov")
        #expect(w.mediaFile(for: .critical) == "Aurora.mov")
        #expect(w.mediaFile(for: nil) == "Aurora.mov")
        #expect(w.allMediaFiles == ["Aurora.mov", "White.mov", "Green.mov"])
        #expect(w.isBatteryReactive)
    }

    @Test func variantsSurviveTheLibraryFile() throws {
        var w = Wallpaper.sample
        w.batteryVariants = ["full": "a.mov", "empty": "b.mov"]
        let decoded = try LibraryStore.decodeLibrary(LibraryStore.encodeLibrary([w]))
        #expect(decoded.first?.batteryVariants == w.batteryVariants)
    }
}

@Suite("Wallpaper packages", .serialized)
@MainActor
struct PackageImportTests {
    private func makeTemporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidewall-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func importsOneVideoPerBatteryState() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let package = dir.appendingPathComponent("Glow.tidewall")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        for name in ["White.mov", "Green.mov", "Red.mov"] {
            try FileManager.default.copyItem(at: sampleMovie, to: package.appendingPathComponent(name))
        }
        let manifest = #"{"name": "Glow", "primary": "normal", "battery": {"full": "White.mov", "normal": "Green.mov", "critical": "Red.mov"}}"#
        try Data(manifest.utf8).write(to: package.appendingPathComponent("wallpaper.json"))

        let store = LibraryStore(rootURL: dir.appendingPathComponent("Library"))
        store.load()
        let imported = await store.importFiles([package])
        #expect(store.importErrors.isEmpty, "\(store.importErrors)")
        let wallpaper = try #require(imported.first)
        #expect(wallpaper.name == "Glow")
        #expect(wallpaper.batteryVariants?.count == 3)
        #expect(wallpaper.mediaFile == wallpaper.batteryVariants?["normal"])
        #expect(abs(wallpaper.duration - 20) < 0.1)
        for file in wallpaper.allMediaFiles {
            #expect(FileManager.default.fileExists(atPath: store.mediaDirectory.appendingPathComponent(file).path))
        }
    }

    @Test func rejectsAPackageWithUnknownStates() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let package = dir.appendingPathComponent("Odd.tidewall")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sampleMovie, to: package.appendingPathComponent("a.mov"))
        try Data(#"{"battery": {"sometimes": "a.mov"}}"#.utf8).write(to: package.appendingPathComponent("wallpaper.json"))

        let store = LibraryStore(rootURL: dir.appendingPathComponent("Library"))
        store.load()
        let imported = await store.importFiles([package])
        #expect(imported.isEmpty)
        #expect(store.importErrors.count == 1)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: store.mediaDirectory.path)) ?? []
        #expect(leftovers.isEmpty, "nothing should be copied from a rejected package")
    }
}
