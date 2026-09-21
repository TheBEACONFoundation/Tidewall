import SwiftUI

/// Undo and redo for the editors. Every edit to a wallpaper passes through
/// `tracking(_:undoManager:)`, which records the wallpaper as it was. A run of
/// changes to one setting (a slider drag, typing a name) becomes one step, so
/// ⌘Z goes back to where the drag started rather than one pixel of it.
@MainActor
final class EditHistory {
    static let shared = EditHistory()

    /// How long a run of changes to the same setting stays one step.
    static let coalescingWindow: TimeInterval = 1.0

    private let store: LibraryStore
    private var openRun: (wallpaperID: UUID, path: String, lastChange: Date)?

    init(store: LibraryStore? = nil) {
        self.store = store ?? .shared
    }

    /// `base`, with every change it makes recorded for undo.
    func tracking(_ base: Binding<Wallpaper>, undoManager: UndoManager?) -> Binding<Wallpaper> {
        Binding(
            get: { base.wrappedValue },
            set: { [weak self] new in
                self?.record(from: base.wrappedValue, to: new, undoManager: undoManager)
                base.wrappedValue = new
            })
    }

    /// Registers the step from `old` to `new`, unless it continues the run
    /// of changes before it.
    func record(from old: Wallpaper, to new: Wallpaper, undoManager: UndoManager?, now: Date = .now) {
        guard old != new, let undoManager, !undoManager.isUndoing, !undoManager.isRedoing else { return }
        let path = Self.changedPath(old, new) ?? "#structure"
        let continues = !path.hasSuffix("#structure")
        if continues, let run = openRun, run.wallpaperID == new.id, run.path == path,
           now.timeIntervalSince(run.lastChange) < Self.coalescingWindow {
            openRun?.lastChange = now
            return
        }
        openRun = continues ? (new.id, path, now) : nil
        let name = Self.actionName(from: old, to: new, path: path)
        // Managers that don't group by event (as in tests) need a group of their own.
        let needsGroup = !undoManager.groupsByEvent && undoManager.groupingLevel == 0
        if needsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { history in
            history.restore(old, named: name, undoManager: undoManager)
        }
        undoManager.setActionName(name)
        if needsGroup { undoManager.endUndoGrouping() }
    }

    /// Puts `snapshot` back and registers the way back again (redo, or undo
    /// after a redo).
    private func restore(_ snapshot: Wallpaper, named name: String, undoManager: UndoManager) {
        guard let current = store.wallpaper(id: snapshot.id) else { return }
        openRun = nil
        undoManager.registerUndo(withTarget: self) { history in
            history.restore(current, named: name, undoManager: undoManager)
        }
        undoManager.setActionName(name)
        store.update(snapshot)
    }

    // MARK: Describing changes

    /// The first setting that differs, e.g. `settings.adjustments.blur` or
    /// `composition.blocks[2].size`. Adding, removing or reordering things
    /// ends in `#structure`, which never merges with the next change.
    nonisolated static func changedPath(_ old: Any, _ new: Any, at path: String = "") -> String? {
        if let a = old as? AnyHashable, let b = new as? AnyHashable, a == b { return nil }
        let before = Mirror(reflecting: old), after = Mirror(reflecting: new)
        switch before.displayStyle {
        case .optional:
            guard let a = before.children.first?.value, let b = after.children.first?.value else {
                return path + "#structure"
            }
            return changedPath(a, b, at: path)
        case .collection:
            let a = before.children.map(\.value), b = after.children.map(\.value)
            guard a.count == b.count else { return path + "#structure" }
            for i in a.indices {
                if let changed = changedPath(a[i], b[i], at: "\(path)[\(i)]") {
                    // A different element in this place means things moved.
                    return changed.hasSuffix(".id") ? path + "#structure" : changed
                }
            }
            return path
        case .struct:
            for (a, b) in zip(before.children, after.children) {
                let label = a.label ?? "?"
                if let changed = changedPath(a.value, b.value, at: path.isEmpty ? label : "\(path).\(label)") {
                    return changed
                }
            }
            // Differs, but shows no parts (e.g. a UUID): the change is here.
            return path
        default:
            return path
        }
    }

    /// What Edit ▸ Undo calls the step.
    nonisolated static func actionName(from old: Wallpaper, to new: Wallpaper, path: String) -> String {
        if path.hasPrefix("name") { return "Rename" }
        if path.hasPrefix("composition") {
            let before = old.composition?.blocks ?? [], after = new.composition?.blocks ?? []
            if Set(before.map(\.id)).isDisjoint(with: after.map(\.id)), !before.isEmpty, !after.isEmpty {
                return "Start Over"
            }
            if after.count > before.count { return after.count - before.count == 1 ? "Add Block" : "Add Blocks" }
            if after.count < before.count { return before.count - after.count == 1 ? "Delete Block" : "Delete Blocks" }
            if path.hasSuffix("#structure") { return "Move Block" }
            if path.hasSuffix(".enabled") { return "Turn Block On or Off" }
            return "Block Change"
        }
        if path.hasPrefix("playlist") { return "Playlist Change" }
        if path.hasPrefix("visualizer") { return "Look Change" }
        if path.hasPrefix("settings.trim") { return "Trim" }
        if path.hasPrefix("settings.adjustments") { return "Adjustment" }
        return "Change"
    }
}
