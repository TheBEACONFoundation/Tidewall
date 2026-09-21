import AVFoundation
import Foundation

extension Notification.Name {
    /// Posted when a playback copy finishes or source info loads; `userInfo["id"]` is the wallpaper.
    static let renditionsDidChange = Notification.Name("TidewallRenditionsDidChange")
}

/// Creates and tracks playback copies in ~/Library/Application Support/Tidewall/Renditions.
@MainActor
final class RenditionManager {
    static let shared = RenditionManager()

    private var sourceInfo: [String: SourceInfo] = [:]
    private var loadingInfo: Set<String> = []
    private var pending: [UUID: (key: String, task: Task<Void, Never>)] = [:]
    private var exportChain: Task<Void, Never>?

    var directory: URL { LibraryStore.shared.rootURL.appendingPathComponent("Renditions", isDirectory: true) }

    func fileURL(for recipe: RenditionRecipe, wallpaperID: UUID) -> URL {
        directory.appendingPathComponent("\(wallpaperID.uuidString)-\(recipe.key).mov")
    }

    /// Cached source info; starts loading it (and posts a change) when missing.
    func info(for wallpaper: Wallpaper) -> SourceInfo? {
        if let info = sourceInfo[wallpaper.mediaFile] { return info }
        let file = wallpaper.mediaFile
        if loadingInfo.insert(file).inserted {
            let url = LibraryStore.shared.mediaURL(for: wallpaper)
            let id = wallpaper.id
            Task {
                let info = await SourceInfo.load(from: url)
                self.loadingInfo.remove(file)
                guard let info else { return }
                self.sourceInfo[file] = info
                NotificationCenter.default.post(name: .renditionsDidChange, object: self, userInfo: ["id": id])
            }
        }
        return nil
    }

    func readyURL(for recipe: RenditionRecipe, wallpaperID: UUID) -> URL? {
        let url = fileURL(for: recipe, wallpaperID: wallpaperID)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Bakes `recipe` once the wallpaper has stopped changing for a moment.
    /// Exports run one at a time at utility priority.
    func schedule(_ recipe: RenditionRecipe, for wallpaper: Wallpaper) {
        let key = recipe.key
        if pending[wallpaper.id]?.key == key { return }
        pending[wallpaper.id]?.task.cancel()

        let id = wallpaper.id
        let source = LibraryStore.shared.mediaURL(for: wallpaper)
        let output = fileURL(for: recipe, wallpaperID: id)
        let previous = exportChain
        let task = Task(priority: .utility) {
            // Let slider drags settle before spending energy on an export.
            try? await Task.sleep(for: .seconds(3))
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try await RenditionExporter.export(source: source, recipe: recipe, to: output)
                self.removeRenditions(of: id, except: output)
                NotificationCenter.default.post(name: .renditionsDidChange, object: self, userInfo: ["id": id])
            } catch is CancellationError {
            } catch {
                NSLog("Tidewall: could not create playback copy: \(error)")
            }
            if self.pending[id]?.key == key { self.pending[id] = nil }
        }
        pending[id] = (key, task)
        exportChain = task
    }

    /// Stops a scheduled or running export, e.g. because the wallpaper went
    /// back to a look that already has a copy.
    func cancelPending(for id: UUID) {
        pending.removeValue(forKey: id)?.task.cancel()
    }

    /// Deletes copies that no longer belong to a wallpaper in the library.
    /// `removeTemporary` also clears half-written exports; only safe at launch.
    func prune(keeping ids: Set<UUID>, removeTemporary: Bool = false) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            let name = file.lastPathComponent
            if name.hasPrefix(".") {
                if removeTemporary { try? FileManager.default.removeItem(at: file) }
                continue
            }
            let id = UUID(uuidString: String(name.prefix(36)))
            if id == nil || !ids.contains(id!) { try? FileManager.default.removeItem(at: file) }
        }
    }

    func isCopy(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
    }

    /// Deletes a playback copy that no player needs anymore.
    func deleteCopy(at url: URL) {
        guard isCopy(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func discardCopies(of id: UUID) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(id.uuidString) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func removeRenditions(of id: UUID, except keep: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(id.uuidString) && file != keep {
            try? FileManager.default.removeItem(at: file)
        }
    }

    var diskUsage: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func removeAll() {
        pending.values.forEach { $0.task.cancel() }
        pending.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }
}
