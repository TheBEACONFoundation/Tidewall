import Foundation
import Testing
@testable import Tidewall

@Suite("Undo")
@MainActor
struct EditHistoryTests {
    private func makeStore() -> LibraryStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TidewallUndo-\(UUID().uuidString)")
        let store = LibraryStore(rootURL: root)
        store.load()
        return store
    }

    private func makeUndoManager() -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }

    /// One edit, as the editor's binding makes it.
    private func edit(_ store: LibraryStore, _ history: EditHistory, _ undo: UndoManager, at time: Date,
                      _ change: (inout Wallpaper) -> Void) {
        let id = store.wallpapers[0].id
        var new = store.wallpaper(id: id)!
        change(&new)
        history.record(from: store.wallpaper(id: id)!, to: new, undoManager: undo, now: time)
        store.update(new)
    }

    @Test func aSliderDragIsOneStep() {
        let store = makeStore(), history = EditHistory(store: store), undo = makeUndoManager()
        let wallpaper = store.createBlocksWallpaper(from: .nightSky)
        let start = Date.now
        for i in 1...20 {
            edit(store, history, undo, at: start.addingTimeInterval(Double(i) * 0.03)) {
                $0.composition!.blocks[1].size = 1 + Double(i) / 10
            }
        }
        #expect(store.wallpaper(id: wallpaper.id)?.composition?.blocks[1].size == 3)
        #expect(undo.undoActionName == "Block Change")
        undo.undo()
        #expect(store.wallpaper(id: wallpaper.id) == wallpaper, "one undo returns to before the drag")
        #expect(!undo.canUndo)
        undo.redo()
        #expect(store.wallpaper(id: wallpaper.id)?.composition?.blocks[1].size == 3)
    }

    @Test func separateSettingsAndPausesAreSeparateSteps() {
        let store = makeStore(), history = EditHistory(store: store), undo = makeUndoManager()
        let wallpaper = store.createBlocksWallpaper(from: .nightSky)
        let start = Date.now
        edit(store, history, undo, at: start) { $0.composition!.blocks[1].size = 2 }
        edit(store, history, undo, at: start.addingTimeInterval(0.1)) { $0.composition!.blocks[1].speed = 1 }
        // The same slider again, but after a pause: a new step.
        edit(store, history, undo, at: start.addingTimeInterval(5)) { $0.composition!.blocks[1].speed = 2 }
        undo.undo()
        #expect(store.wallpaper(id: wallpaper.id)?.composition?.blocks[1].speed == 1)
        undo.undo()
        #expect(store.wallpaper(id: wallpaper.id)?.composition?.blocks[1].speed == wallpaper.composition!.blocks[1].speed)
        #expect(store.wallpaper(id: wallpaper.id)?.composition?.blocks[1].size == 2)
        undo.undo()
        #expect(store.wallpaper(id: wallpaper.id) == wallpaper)
    }

    @Test func addingAndDeletingBlocksNeverMerge() {
        let store = makeStore(), history = EditHistory(store: store), undo = makeUndoManager()
        let wallpaper = store.createBlocksWallpaper(from: .blank)
        let start = Date.now
        edit(store, history, undo, at: start) { $0.composition!.blocks.append(BlockKind.orb.makeBlock()) }
        #expect(undo.undoActionName == "Add Block")
        edit(store, history, undo, at: start.addingTimeInterval(0.1)) { $0.composition!.blocks.append(BlockKind.rays.makeBlock()) }
        edit(store, history, undo, at: start.addingTimeInterval(0.2)) { $0.composition!.blocks.removeLast() }
        #expect(undo.undoActionName == "Delete Block")
        undo.undo()
        #expect(store.wallpaper(id: wallpaper.id)?.composition?.blocks.count == 3)
        undo.undo()
        undo.undo()
        #expect(store.wallpaper(id: wallpaper.id) == wallpaper)
    }

    @Test func describesWhatChanged() {
        var a = Wallpaper(id: UUID(), name: "A", mediaFile: "a.mov", originalFileName: "a.mov", dateAdded: .now,
                          duration: 10, pixelWidth: 1920, pixelHeight: 1080, settings: WallpaperSettings())
        var b = a
        b.settings.adjustments.blur = 4
        #expect(EditHistory.changedPath(a, b) == "settings.adjustments.blur")
        b = a
        b.name = "B"
        #expect(EditHistory.changedPath(a, b) == "name")
        a.composition = BlockTemplate.ocean.composition
        b = a
        b.composition!.blocks.swapAt(0, 1)
        #expect(EditHistory.changedPath(a, b) == "composition.blocks#structure")
        #expect(EditHistory.actionName(from: a, to: b, path: "composition.blocks#structure") == "Move Block")
        #expect(EditHistory.changedPath(a, a) == nil)
    }
}
