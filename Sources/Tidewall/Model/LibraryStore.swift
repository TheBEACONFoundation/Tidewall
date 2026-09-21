import AppKit
import AVFoundation
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted when the library changes. `userInfo["id"]` names the wallpaper
    /// whose settings changed; it is absent when wallpapers were added or removed.
    static let libraryDidChange = Notification.Name("TidewallLibraryDidChange")
}

enum ImportError: LocalizedError {
    case notAnimated(String)
    case noVideo(String)
    case unsupported(String)
    case unreadable(String)
    case badPackage(String)

    var errorDescription: String? {
        switch self {
        case .notAnimated(let name): "“\(name)” is a still image. Import a video or an animated GIF, PNG or WebP."
        case .noVideo(let name): "“\(name)” doesn't contain a video track."
        case .unsupported(let name): "macOS can't play “\(name)”. Convert it to MP4 or MOV (H.264 or HEVC) and try again."
        case .unreadable(let name): "“\(name)” couldn't be read."
        case .badPackage(let name): "“\(name)” isn't a valid Tidewall wallpaper package."
        }
    }
}

/// The user's wallpaper library, stored in ~/Library/Application Support/Tidewall.
@MainActor
@Observable
final class LibraryStore {
    static let shared = LibraryStore()

    private(set) var wallpapers: [Wallpaper] = []
    private(set) var importsInProgress = 0
    var importErrors: [String] = []

    /// A folder holding a `wallpaper.json` manifest and its videos, e.g. one
    /// video per battery state.
    static let packageType = UTType(exportedAs: "io.github.thebeaconfoundation.tidewall.wallpaper", conformingTo: .package)
    static let importableTypes: [UTType] = [.movie, .gif, .webP, .png, .heics, packageType]

    @ObservationIgnored let rootURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// - Parameter rootURL: where the library lives; tests pass a temporary folder.
    init(rootURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.rootURL = rootURL ?? support.appendingPathComponent("Tidewall", isDirectory: true)
    }

    var mediaDirectory: URL { rootURL.appendingPathComponent("Media", isDirectory: true) }
    var stillsDirectory: URL { rootURL.appendingPathComponent("Stills", isDirectory: true) }
    private var libraryFile: URL { rootURL.appendingPathComponent("Library.json") }

    /// The video to show for `wallpaper` right now: its variant for the current
    /// battery state if it has one.
    func mediaURL(for wallpaper: Wallpaper) -> URL {
        mediaDirectory.appendingPathComponent(currentMediaFile(for: wallpaper))
    }

    func currentMediaFile(for wallpaper: Wallpaper) -> String {
        wallpaper.mediaFile(for: BatteryStatus.shared.state)
    }

    func wallpaper(id: UUID?) -> Wallpaper? {
        guard let id else { return nil }
        return wallpapers.first { $0.id == id }
    }

    // MARK: Persistence

    func load() {
        let fm = FileManager.default
        for dir in [rootURL, mediaDirectory, stillsDirectory] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        guard let data = try? Data(contentsOf: libraryFile) else { return }
        do {
            let decoded = try Self.decodeLibrary(data)
            // Drop entries whose media went missing (e.g. deleted in Finder).
            wallpapers = decoded.filter { !$0.hasVideo || fm.fileExists(atPath: mediaURL(for: $0).path) }
            // Pictures replaced or removed in the blocks editor last time.
            let used = wallpapers.reduce(into: Set<String>()) { $0.formUnion($1.allMediaFiles) }
            for file in (try? fm.contentsOfDirectory(atPath: mediaDirectory.path)) ?? []
            where file.hasPrefix(Self.picturePrefix) && !used.contains(file) {
                try? fm.removeItem(at: mediaDirectory.appendingPathComponent(file))
            }
        } catch {
            // Set the unreadable file aside rather than letting the next save
            // overwrite it, so the library can still be recovered by hand.
            let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
            let backup = rootURL.appendingPathComponent("Library-unreadable-\(stamp).json")
            try? fm.moveItem(at: libraryFile, to: backup)
            NSLog("Tidewall: could not read library, moved it to \(backup.lastPathComponent): \(error)")
        }
    }

    nonisolated static func encodeLibrary(_ wallpapers: [Wallpaper]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(wallpapers)
    }

    nonisolated static func decodeLibrary(_ data: Data) throws -> [Wallpaper] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Wallpaper].self, from: data)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        do {
            try Self.encodeLibrary(wallpapers).write(to: libraryFile, options: .atomic)
        } catch {
            NSLog("Tidewall: could not save library: \(error)")
        }
    }

    // MARK: Editing

    func update(_ wallpaper: Wallpaper) {
        guard let index = wallpapers.firstIndex(where: { $0.id == wallpaper.id }),
              wallpapers[index] != wallpaper else { return }
        wallpapers[index] = wallpaper
        scheduleSave()
        NotificationCenter.default.post(name: .libraryDidChange, object: self, userInfo: ["id": wallpaper.id])
    }

    func binding(for id: UUID) -> Binding<Wallpaper>? {
        guard var last = wallpaper(id: id) else { return nil }
        return Binding(
            get: { [weak self] in
                if let current = self?.wallpaper(id: id) { last = current }
                return last
            },
            set: { [weak self] in self?.update($0) })
    }

    @discardableResult
    func duplicate(_ id: UUID) -> Wallpaper? {
        guard let original = wallpaper(id: id), let index = wallpapers.firstIndex(of: original) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.name = "\(original.name) Copy"
        copy.dateAdded = .now
        wallpapers.insert(copy, at: index + 1)
        structureChanged()
        return copy
    }

    func delete(_ ids: Set<UUID>) {
        let removed = wallpapers.filter { ids.contains($0.id) }
        wallpapers.removeAll { ids.contains($0.id) }
        // Playlists forget deleted wallpapers.
        for index in wallpapers.indices where wallpapers[index].playlist != nil {
            wallpapers[index].playlist!.items.removeAll { ids.contains($0.wallpaperID) }
        }
        // Duplicates share media, so only delete files nothing references.
        let stillUsed = wallpapers.reduce(into: Set<String>()) { $0.formUnion($1.allMediaFiles) }
        let unused = removed.reduce(into: Set<String>()) { $0.formUnion($1.allMediaFiles) }.subtracting(stillUsed)
        for file in unused {
            try? FileManager.default.trashItem(at: mediaDirectory.appendingPathComponent(file), resultingItemURL: nil)
        }
        structureChanged()
    }

    private func structureChanged() {
        saveNow()
        NotificationCenter.default.post(name: .libraryDidChange, object: self)
    }

    // MARK: Importing

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Wallpapers"
        panel.message = "Choose videos (MP4, MOV, M4V), animated images (GIF, PNG, WebP) or Tidewall packages."
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.importableTypes
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        Task { await importFiles(panel.urls) }
    }

    @discardableResult
    func importFiles(_ urls: [URL], names: [URL: String] = [:]) async -> [Wallpaper] {
        var imported: [Wallpaper] = []
        for url in urls {
            importsInProgress += 1
            defer { importsInProgress -= 1 }
            do {
                var wallpaper = url.pathExtension.lowercased() == "tidewall"
                    ? try await makeWallpaper(fromPackage: url)
                    : try await makeWallpaper(from: url)
                if let name = names[url] { wallpaper.name = name }
                wallpapers.insert(wallpaper, at: 0)
                imported.append(wallpaper)
                structureChanged()
            } catch {
                importErrors.append(error.localizedDescription)
            }
        }
        return imported
    }

    private func makeWallpaper(from source: URL) async throws -> Wallpaper {
        let media = try await ingest(source)
        return Wallpaper(
            id: UUID(),
            name: source.deletingPathExtension().lastPathComponent,
            mediaFile: media.file,
            originalFileName: source.lastPathComponent,
            dateAdded: .now,
            duration: media.duration,
            pixelWidth: media.size.width,
            pixelHeight: media.size.height,
            settings: WallpaperSettings())
    }

    /// Imports a `.tidewall` package: a folder with `wallpaper.json`
    /// (`{"name": …, "primary": "normal", "battery": {"full": "Full.mov", …}}`)
    /// and the videos it names.
    private func makeWallpaper(fromPackage package: URL) async throws -> Wallpaper {
        let name = package.lastPathComponent
        struct Manifest: Decodable {
            var name: String?
            var primary: String?
            var battery: [String: String]?
            var blocks: Composition?
        }
        guard let data = try? Data(contentsOf: package.appendingPathComponent("wallpaper.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { throw ImportError.badPackage(name) }

        // A wallpaper made with blocks: the recipe, plus any pictures it uses.
        if var blocks = manifest.blocks, manifest.battery == nil {
            for i in blocks.blocks.indices {
                guard let file = blocks.blocks[i].media else { continue }
                let source = package.appendingPathComponent((file as NSString).lastPathComponent)
                blocks.blocks[i].media = try? importPicture(from: source)
            }
            return Wallpaper(
                id: UUID(), name: manifest.name ?? package.deletingPathExtension().lastPathComponent,
                mediaFile: "", originalFileName: name, dateAdded: .now, duration: 0, pixelWidth: 0, pixelHeight: 0,
                settings: WallpaperSettings(), composition: blocks)
        }
        guard let battery = manifest.battery, !battery.isEmpty,
              battery.keys.allSatisfy({ BatteryState(rawValue: $0) != nil })
        else { throw ImportError.badPackage(name) }

        var variants: [String: String] = [:]
        var media: [String: (file: String, duration: Double, size: CGSize)] = [:]
        do {
            for (state, file) in battery {
                let ingested = try await ingest(package.appendingPathComponent(file))
                media[state] = ingested
                variants[state] = ingested.file
            }
        } catch {
            for item in media.values { try? FileManager.default.removeItem(at: mediaDirectory.appendingPathComponent(item.file)) }
            throw error
        }
        let primaryState = manifest.primary.flatMap { media[$0] != nil ? $0 : nil }
            ?? (media[BatteryState.normal.rawValue] != nil ? BatteryState.normal.rawValue : media.keys.sorted()[0])
        let primary = media[primaryState]!
        return Wallpaper(
            id: UUID(),
            name: manifest.name ?? package.deletingPathExtension().lastPathComponent,
            mediaFile: primary.file,
            originalFileName: name,
            dateAdded: .now,
            // Variants share one timeline, so trim and speed apply to all of them.
            duration: media.values.map(\.duration).min() ?? primary.duration,
            pixelWidth: primary.size.width,
            pixelHeight: primary.size.height,
            settings: WallpaperSettings(),
            batteryVariants: variants)
    }

    /// Copies (or converts) a video into the library and reads what Tidewall
    /// needs to know about it.
    private func ingest(_ source: URL) async throws -> (file: String, duration: Double, size: CGSize) {
        let displayName = source.lastPathComponent
        let id = UUID()
        let isImage = UTType(filenameExtension: source.pathExtension)?.conforms(to: .image) ?? false
        let destination: URL

        if isImage {
            guard AnimatedImageConverter.frameCount(at: source) > 1 else {
                throw ImportError.notAnimated(displayName)
            }
            destination = mediaDirectory.appendingPathComponent("\(id.uuidString).mov")
            try await AnimatedImageConverter.convert(source, to: destination)
        } else {
            let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased()
            destination = mediaDirectory.appendingPathComponent("\(id.uuidString).\(ext)")
            do {
                // APFS clones the file, so even large videos import instantly.
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                throw ImportError.unreadable(displayName)
            }
        }

        do {
            let asset = AVURLAsset(url: destination)
            let (duration, playable) = try await asset.load(.duration, .isPlayable)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw ImportError.noVideo(displayName)
            }
            guard playable, duration.seconds.isFinite, duration.seconds > 0.1 else {
                throw ImportError.unsupported(displayName)
            }
            let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
            let size = naturalSize.applying(transform)
            return (destination.lastPathComponent, duration.seconds, CGSize(width: abs(size.width), height: abs(size.height)))
        } catch let error as ImportError {
            try? FileManager.default.removeItem(at: destination)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw ImportError.unsupported(displayName)
        }
    }

    /// Adds each bundled wallpaper once: everything on first launch, and any
    /// built-ins added by an update. Deleted ones stay deleted until the user
    /// adds them back from the + menu.
    func installBuiltInsIfNeeded() async {
        let key = "installedBuiltIns"
        let defaults = UserDefaults.standard
        var installed = Set(defaults.stringArray(forKey: key) ?? [])
        if defaults.bool(forKey: "didInstallSample") { installed.insert("Aurora") } // set by 1.0
        let missing = BuiltInWallpaper.all.filter { !installed.contains($0.id) && $0.isAvailable }
        guard !missing.isEmpty else { return }
        defaults.set(Array(installed.union(missing.map(\.id))).sorted(), forKey: key)
        for builtIn in missing {
            await addBuiltIn(builtIn)
        }
    }

    // MARK: Playlists

    /// Adds a playlist of `wallpaperIDs` and returns it.
    @discardableResult
    func createPlaylist(with wallpaperIDs: [UUID] = []) -> Wallpaper {
        var name = "My Playlist", n = 2
        while wallpapers.contains(where: { $0.name == name }) { name = "My Playlist \(n)"; n += 1 }
        var playlist = Playlist()
        let playable = wallpaperIDs.filter { wallpaper(id: $0)?.isPlaylist == false }
        let starts = Playlist.spreadStarts(count: playable.count)
        playlist.items = zip(playable, starts).map { PlaylistItem(wallpaperID: $0, start: $1) }
        let wallpaper = Wallpaper(
            id: UUID(), name: name, mediaFile: "", originalFileName: "Playlist",
            dateAdded: .now, duration: 0, pixelWidth: 0, pixelHeight: 0,
            settings: WallpaperSettings(), playlist: playlist)
        wallpapers.insert(wallpaper, at: 0)
        structureChanged()
        return wallpaper
    }

    /// The items of `playlist` that can be shown: their wallpaper exists
    /// and isn't a playlist itself.
    func playableItems(of playlist: Playlist) -> [PlaylistItem] {
        playlist.items.filter { wallpaper(id: $0.wallpaperID).map { !$0.isPlaylist } ?? false }
    }

    // MARK: Blocks

    /// Adds a new blocks wallpaper started from `template` and returns it.
    @discardableResult
    func createBlocksWallpaper(from template: BlockTemplate) -> Wallpaper {
        let base = template == .blank ? "My Wallpaper" : "My \(template.title)"
        var name = base, n = 2
        while wallpapers.contains(where: { $0.name == name }) { name = "\(base) \(n)"; n += 1 }
        let wallpaper = Wallpaper(
            id: UUID(), name: name, mediaFile: "", originalFileName: "Made with blocks",
            dateAdded: .now, duration: 0, pixelWidth: 0, pixelHeight: 0,
            settings: WallpaperSettings(), composition: template.composition)
        wallpapers.insert(wallpaper, at: 0)
        structureChanged()
        return wallpaper
    }

    /// Writes a blocks wallpaper as a `.tidewall` package others can import.
    func exportPackage(_ wallpaper: Wallpaper, to url: URL) throws {
        guard let composition = wallpaper.composition else { return }
        struct Manifest: Encodable { var name: String; var blocks: Composition }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try encoder.encode(Manifest(name: wallpaper.name, blocks: composition))
            .write(to: url.appendingPathComponent("wallpaper.json"), options: .atomic)
        for file in Set(composition.blocks.compactMap(\.media)) {
            try fm.copyItem(at: mediaDirectory.appendingPathComponent(file), to: url.appendingPathComponent(file))
        }
    }

    /// Names of pictures copied in for picture blocks.
    static let picturePrefix = "block-"

    /// Copies a picture for a picture block into the library, at most 4K
    /// across and turned the right way up, and returns its file name.
    func importPicture(from source: URL) throws -> String {
        let name = source.lastPathComponent
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 3840,
              ] as CFDictionary)
        else { throw ImportError.unreadable(name) }
        let opaque: [CGImageAlphaInfo] = [.none, .noneSkipFirst, .noneSkipLast]
        let type: UTType = opaque.contains(image.alphaInfo) ? .jpeg : .png
        let file = "\(Self.picturePrefix)\(UUID().uuidString).\(type.preferredFilenameExtension ?? "png")"
        try? FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let destination = mediaDirectory.appendingPathComponent(file)
        guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, type.identifier as CFString, 1, nil)
        else { throw ImportError.unreadable(name) }
        CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw ImportError.unreadable(name) }
        return file
    }

    func presentExportPanel(for wallpaper: Wallpaper) {
        let panel = NSSavePanel()
        panel.title = "Export Wallpaper"
        panel.message = "Share this file: anyone with Tidewall can open it to add your wallpaper."
        panel.nameFieldStringValue = "\(wallpaper.name).tidewall"
        panel.allowedContentTypes = [Self.packageType]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportPackage(wallpaper, to: url)
        } catch {
            importErrors.append("Couldn't export “\(wallpaper.name)”: \(error.localizedDescription)")
        }
    }

    func addBuiltIn(_ builtIn: BuiltInWallpaper) async {
        if builtIn.isVisualizer {
            let wallpaper = Wallpaper(
                id: UUID(), name: builtIn.name, mediaFile: "", originalFileName: "Built in",
                dateAdded: .now, duration: 0, pixelWidth: 0, pixelHeight: 0,
                settings: WallpaperSettings(), visualizer: VisualizerSettings())
            wallpapers.insert(wallpaper, at: 0)
            structureChanged()
            return
        }
        guard let url = builtIn.url else { return }
        await importFiles([url], names: [url: builtIn.name])
    }
}
