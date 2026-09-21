import AppKit
import Observation

/// Which wallpaper each display shows.
struct Assignments: Codable, Equatable {
    /// Shown on every display without its own choice.
    var allDisplays: UUID?
    var perDisplay: [String: UUID] = [:]
    /// Displays explicitly set to keep the system wallpaper.
    var disabled: Set<String> = []

    func wallpaperID(for displayID: String) -> UUID? {
        disabled.contains(displayID) ? nil : perDisplay[displayID] ?? allDisplays
    }
}

enum PauseReason: Equatable {
    case user, screenLocked, lowPowerMode, battery

    var title: String {
        switch self {
        case .user: "Paused"
        case .screenLocked: "Paused while the screen is locked"
        case .lowPowerMode: "Paused in Low Power Mode"
        case .battery: "Paused on battery power"
        }
    }
}

/// Owns the desktop windows and players, and keeps them in sync with the
/// library, the connected displays and the power/visibility state.
@MainActor
@Observable
final class WallpaperEngine {
    static let shared = WallpaperEngine()

    private(set) var displays: [Display] = []
    private(set) var assignments = Assignments()
    private(set) var pauseReason: PauseReason?

    var isUserPaused = false {
        didSet {
            UserDefaults.standard.set(isUserPaused, forKey: Self.pausedKey)
            updatePlayback()
        }
    }

    @ObservationIgnored private var windows: [String: DesktopWindow] = [:]
    @ObservationIgnored private var players: [UUID: LoopingPlayer] = [:]
    @ObservationIgnored private var suspensions: Set<String> = []
    @ObservationIgnored private var started = false

    private static let assignmentsKey = "assignments"
    private static let pausedKey = "userPaused"

    private let store = LibraryStore.shared

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        loadState()
        observeSystem()
        PowerMonitor.start()
        reconcile()
    }

    private func loadState() {
        let defaults = UserDefaults.standard
        if let json = defaults.string(forKey: Self.assignmentsKey),
           let decoded = try? JSONDecoder().decode(Assignments.self, from: Data(json.utf8)) {
            assignments = decoded
        }
        isUserPaused = defaults.bool(forKey: Self.pausedKey)
    }

    private func saveAssignments() {
        guard let data = try? JSONEncoder().encode(assignments) else { return }
        UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: Self.assignmentsKey)
    }

    // MARK: Assignments

    func wallpaperID(for displayID: String) -> UUID? {
        assignments.wallpaperID(for: displayID)
    }

    /// The wallpaper shown everywhere, or nil when displays differ.
    var sharedWallpaperID: UUID? {
        let ids = Set(displays.map { assignments.wallpaperID(for: $0.id) })
        return ids.count == 1 ? ids.first ?? nil : nil
    }

    func displays(showing id: UUID) -> [Display] {
        displays.filter { assignments.wallpaperID(for: $0.id) == id }
    }

    /// Sets the wallpaper for one display, or for all displays when
    /// `displayID` is nil. A nil `wallpaperID` restores the system wallpaper.
    func setWallpaper(_ wallpaperID: UUID?, for displayID: String? = nil) {
        if let displayID {
            if let wallpaperID {
                assignments.perDisplay[displayID] = wallpaperID
                assignments.disabled.remove(displayID)
            } else {
                assignments.perDisplay[displayID] = nil
                assignments.disabled.insert(displayID)
            }
        } else {
            assignments = Assignments(allDisplays: wallpaperID)
        }
        saveAssignments()
        reconcile()
    }

    // MARK: Reconciliation

    /// Brings windows and players in line with the displays and assignments.
    func reconcile() {
        displays = Display.all
        pruneMissingWallpapers()

        var liveWindows: [String: DesktopWindow] = [:]
        var neededPlayers: Set<UUID> = []

        for display in displays {
            guard let screen = display.screen,
                  let wallpaper = store.wallpaper(id: assignments.wallpaperID(for: display.id))
            else { continue }

            let player = player(for: wallpaper)
            neededPlayers.insert(wallpaper.id)

            let window = windows[display.id] ?? makeWindow(for: screen, displayID: display.id)
            if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
            window.show(wallpaper, player: player)
            liveWindows[display.id] = window
        }

        for (id, window) in windows where liveWindows[id] == nil {
            window.tearDown()
        }
        windows = liveWindows

        for (id, player) in players where !neededPlayers.contains(id) {
            player.invalidate()
            players[id] = nil
        }

        updatePlayback()
        syncSystemWallpaper()
    }

    private func player(for wallpaper: Wallpaper) -> LoopingPlayer {
        if let existing = players[wallpaper.id] {
            existing.update(wallpaper)
            return existing
        }
        let player = LoopingPlayer(wallpaper: wallpaper, url: store.mediaURL(for: wallpaper))
        players[wallpaper.id] = player
        return player
    }

    private func makeWindow(for screen: NSScreen, displayID: String) -> DesktopWindow {
        let window = DesktopWindow(screen: screen, displayID: displayID)
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePlayback() }
        }
        return window
    }

    private func pruneMissingWallpapers() {
        let known = Set(store.wallpapers.map(\.id))
        var pruned = assignments
        if let all = pruned.allDisplays, !known.contains(all) { pruned.allDisplays = nil }
        pruned.perDisplay = pruned.perDisplay.filter { known.contains($0.value) }
        if pruned != assignments {
            assignments = pruned
            saveAssignments()
        }
    }

    private func wallpaperDidChange(_ id: UUID) {
        guard let wallpaper = store.wallpaper(id: id) else { return }
        players[id]?.update(wallpaper)
        for window in windows.values where window.wallpaperID == id {
            window.playerView.configure(with: wallpaper)
        }
        syncSystemWallpaper()
    }

    // MARK: Playback state

    private func currentPauseReason() -> PauseReason? {
        if isUserPaused { return .user }
        if !suspensions.isEmpty { return .screenLocked }
        if Preferences.bool(Preferences.pauseInLowPowerMode) && PowerMonitor.isLowPowerModeEnabled { return .lowPowerMode }
        if Preferences.bool(Preferences.pauseOnBattery) && PowerMonitor.isOnBattery { return .battery }
        return nil
    }

    func updatePlayback() {
        let reason = currentPauseReason()
        if pauseReason != reason { pauseReason = reason }
        let pauseWhenHidden = Preferences.bool(Preferences.pauseWhenHidden)

        for (id, player) in players {
            var shouldPlay = reason == nil
            if shouldPlay && pauseWhenHidden {
                // Covered by full-screen apps or windows on every display it's on.
                shouldPlay = windows.values.contains {
                    $0.wallpaperID == id && $0.occlusionState.contains(.visible)
                }
            }
            player.setPlaying(shouldPlay)
        }
    }

    var isAnythingPlaying: Bool { !windows.isEmpty && pauseReason == nil }

    private func syncSystemWallpaper() {
        guard Preferences.bool(Preferences.matchSystemWallpaper) else { return }
        for display in displays {
            if let wallpaper = store.wallpaper(id: assignments.wallpaperID(for: display.id)) {
                SystemWallpaperSync.shared.sync(wallpaper, on: display)
            }
        }
    }

    // MARK: System events

    private func observeSystem() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        func on(_ nc: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (WallpaperEngine) -> Void) {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self { action(self) }
                }
            }
        }

        on(center, NSApplication.didChangeScreenParametersNotification) { $0.reconcile() }
        on(center, .powerSourceDidChange) { $0.updatePlayback() }
        on(center, .NSProcessInfoPowerStateDidChange) { $0.updatePlayback() }
        on(center, UserDefaults.didChangeNotification) { engine in
            engine.updatePlayback()
            engine.syncSystemWallpaper()
        }
        center.addObserver(forName: .libraryDidChange, object: nil, queue: .main) { [weak self] note in
            let id = note.userInfo?["id"] as? UUID
            MainActor.assumeIsolated {
                guard let self else { return }
                if let id { self.wallpaperDidChange(id) } else { self.reconcile() }
            }
        }

        // Stop decoding whenever nobody can see the desktop.
        let suspend: [(NotificationCenter, Notification.Name, String, Bool)] = [
            (workspace, NSWorkspace.screensDidSleepNotification, "sleep", true),
            (workspace, NSWorkspace.screensDidWakeNotification, "sleep", false),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, "session", true),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification, "session", false),
            (distributed, Notification.Name("com.apple.screenIsLocked"), "lock", true),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), "lock", false),
            (distributed, Notification.Name("com.apple.screensaver.didstart"), "screensaver", true),
            (distributed, Notification.Name("com.apple.screensaver.didstop"), "screensaver", false),
        ]
        for (nc, name, cause, active) in suspend {
            on(nc, name) { engine in
                if active {
                    engine.suspensions.insert(cause)
                } else {
                    engine.suspensions.remove(cause)
                }
                engine.updatePlayback()
            }
        }
    }
}
