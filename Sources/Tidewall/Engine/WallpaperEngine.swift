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

    /// True while every live wallpaper is paused because windows hide it.
    private(set) var isPausedWhileHidden = false

    @ObservationIgnored private var windows: [String: DesktopWindow] = [:]
    @ObservationIgnored private var players: [UUID: LoopingPlayer] = [:]
    @ObservationIgnored private var sources: [UUID: PlaybackSource] = [:]
    /// The player each wallpaper's windows are showing; differs from
    /// `players` while a replacement is being prepared.
    @ObservationIgnored private var onScreen: [UUID: LoopingPlayer] = [:]
    @ObservationIgnored private var swaps: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var suspensions: Set<String> = []
    @ObservationIgnored private var coveredDisplays: Set<String> = []
    @ObservationIgnored private var coverageTimer: Timer?
    @ObservationIgnored private var batteryTimer: Timer?
    @ObservationIgnored private var started = false

    private static let assignmentsKey = "assignments"
    private static let pausedKey = "userPaused"

    private let store = LibraryStore.shared
    private let renditions = RenditionManager.shared

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        loadState()
        observeSystem()
        PowerMonitor.start()
        renditions.prune(keeping: Set(store.wallpapers.map(\.id)), removeTemporary: true)
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
            sources[id] = nil
            swaps.removeValue(forKey: id)?.cancel()
            if let shown = onScreen.removeValue(forKey: id), shown !== player { shown.invalidate() }
        }

        updateCoverageMonitoring()
        updateBatteryMonitoring()
        updatePlayback()
        syncSystemWallpaper()
    }

    // MARK: Battery variants

    /// A slow safety net next to the power-source notification (which is what
    /// Lantern does too), only while a battery-reactive wallpaper is showing.
    private func updateBatteryMonitoring() {
        let wanted = players.keys.contains { store.wallpaper(id: $0)?.isBatteryReactive == true }
        if wanted, batteryTimer == nil {
            let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.batteryDidChange() }
            }
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .common)
            batteryTimer = timer
        } else if !wanted {
            batteryTimer?.invalidate()
            batteryTimer = nil
        }
    }

    private func batteryDidChange() {
        guard BatteryStatus.shared.refresh() else { return }
        for id in players.keys where store.wallpaper(id: id)?.isBatteryReactive == true {
            refresh(id)
        }
        syncSystemWallpaper()
    }

    // MARK: Players

    private func player(for wallpaper: Wallpaper) -> LoopingPlayer {
        let source = playbackSource(for: wallpaper)
        guard let existing = players[wallpaper.id], let current = sources[wallpaper.id] else {
            let player = makePlayer(for: source)
            players[wallpaper.id] = player
            sources[wallpaper.id] = source
            onScreen[wallpaper.id] = player
            return player
        }
        guard source.url != current.url else {
            sources[wallpaper.id] = source
            existing.update(source.wallpaper)
            return existing
        }
        // A new battery variant dissolves in; other swaps are invisible anyway.
        let fade: TimeInterval = source.mediaFile != current.mediaFile ? 1.5 : 0
        return replacePlayer(existing, for: wallpaper.id, with: source, fade: fade)
    }

    private func makePlayer(for source: PlaybackSource) -> LoopingPlayer {
        LoopingPlayer(wallpaper: source.wallpaper, url: source.url)
    }

    /// Switches to a new source (e.g. a finished playback copy) without a
    /// visible cut: the replacement is loaded and synced to the current
    /// position before the windows cross over to it.
    private func replacePlayer(_ old: LoopingPlayer, for id: UUID, with source: PlaybackSource,
                               fade: TimeInterval = 0) -> LoopingPlayer {
        // If an earlier replacement never made it on screen, drop it and hand
        // over from whatever the windows are actually showing.
        let outgoing = onScreen[id] ?? old
        if old !== outgoing { old.invalidate() }

        let replacement = makePlayer(for: source)
        players[id] = replacement
        sources[id] = source
        swaps[id]?.cancel()
        swaps[id] = Task { [weak self] in
            await replacement.prepare(at: { outgoing.currentTime })
            guard let self, !Task.isCancelled, self.players[id] === replacement else { return }
            self.updatePlayback()
            for window in self.windows.values where window.wallpaperID == id {
                window.playerView.transition(to: replacement.player, fade: fade)
            }
            self.onScreen[id] = replacement
            self.swaps[id] = nil
            // The old picture stays up until the new layer has a frame (and
            // has faded out, for a variant change).
            try? await Task.sleep(for: .seconds(2 + fade))
            outgoing.invalidate()
            // A copy of a look that's no longer used (e.g. adjustments reset).
            if self.sources[id]?.url != outgoing.url { self.renditions.deleteCopy(at: outgoing.url) }
        }
        return replacement
    }

    /// The cheapest way to show `wallpaper` at full quality: its baked playback
    /// copy when one is ready, otherwise the original with live filters (and a
    /// copy scheduled in the background).
    private func playbackSource(for wallpaper: Wallpaper) -> PlaybackSource {
        let screens = displays.filter { assignments.wallpaperID(for: $0.id) == wallpaper.id }.map(\.pixelSize)
        let requiredScale = FramePipeline.requiredScale(videoSize: wallpaper.videoSize, screenPixelSizes: screens,
                                                        settings: wallpaper.settings)
        let mediaFile = store.currentMediaFile(for: wallpaper)
        let live = PlaybackSource(url: store.mediaURL(for: wallpaper), wallpaper: wallpaper, mediaFile: mediaFile)

        guard Preferences.bool(Preferences.optimizePlayback), let info = renditions.info(for: wallpaper) else {
            renditions.cancelPending(for: wallpaper.id)
            return live
        }
        guard let recipe = RenditionRecipe.make(for: wallpaper, info: info, requiredScale: requiredScale,
                                                mediaFile: mediaFile) else {
            renditions.cancelPending(for: wallpaper.id)
            // No copy needed anymore; one still on screen is removed after its swap.
            if let current = sources[wallpaper.id]?.url, renditions.isCopy(current) { return live }
            renditions.discardCopies(of: wallpaper.id)
            return live
        }
        if let url = renditions.readyURL(for: recipe, wallpaperID: wallpaper.id) {
            renditions.cancelPending(for: wallpaper.id)
            var baked = wallpaper
            baked.settings.adjustments = Adjustments()
            return PlaybackSource(url: url, wallpaper: baked, mediaFile: mediaFile)
        }
        renditions.schedule(recipe, for: wallpaper)
        return live
    }

    /// Re-evaluates the source of a wallpaper that's on the desktop.
    private func refresh(_ id: UUID) {
        guard players[id] != nil, let wallpaper = store.wallpaper(id: id) else { return }
        _ = player(for: wallpaper)
        for window in windows.values where window.wallpaperID == id {
            window.playerView.configure(with: wallpaper)
        }
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
        refresh(id)
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

        var hiddenCount = 0
        for (id, player) in players {
            var shouldPlay = reason == nil
            if shouldPlay && pauseWhenHidden {
                // Only play if at least one display showing it can be seen.
                shouldPlay = windows.values.contains {
                    $0.wallpaperID == id && $0.occlusionState.contains(.visible)
                        && !coveredDisplays.contains($0.displayID)
                }
                if !shouldPlay { hiddenCount += 1 }
            }
            player.setPlaying(shouldPlay)
        }
        let hidden = !players.isEmpty && hiddenCount == players.count
        if isPausedWhileHidden != hidden { isPausedWhileHidden = hidden }
    }

    // MARK: Coverage

    /// Checks window coverage on a slow timer (plus app and Space switches)
    /// while a wallpaper is showing. One window-list query costs well under a
    /// millisecond, and it lets playback stop for most of the working day.
    private func updateCoverageMonitoring() {
        let wanted = !windows.isEmpty && Preferences.bool(Preferences.pauseWhenHidden)
        if wanted, coverageTimer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateCoverage() }
            }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            coverageTimer = timer
            updateCoverage()
        } else if !wanted, let timer = coverageTimer {
            timer.invalidate()
            coverageTimer = nil
            if !coveredDisplays.isEmpty {
                coveredDisplays = []
                updatePlayback()
            }
        }
    }

    private func updateCoverage() {
        guard coverageTimer != nil else { return }
        let frames = DesktopCoverage.windowFrames()
        var covered: Set<String> = []
        for display in displays where windows[display.id] != nil {
            let fraction = DesktopCoverage.coveredFraction(of: display.quartzVisibleFrame, by: frames)
            // Hysteresis keeps a window dragged near the threshold from flapping.
            let threshold = coveredDisplays.contains(display.id) ? 0.85 : 0.95
            if fraction >= threshold { covered.insert(display.id) }
        }
        if covered != coveredDisplays {
            coveredDisplays = covered
            updatePlayback()
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
        on(center, .powerSourceDidChange) { engine in
            engine.batteryDidChange()
            engine.updatePlayback()
        }
        on(center, .NSProcessInfoPowerStateDidChange) { $0.updatePlayback() }
        on(center, UserDefaults.didChangeNotification) { engine in
            engine.updateCoverageMonitoring()
            engine.players.keys.forEach(engine.refresh)
            engine.updatePlayback()
            engine.syncSystemWallpaper()
        }
        center.addObserver(forName: .libraryDidChange, object: nil, queue: .main) { [weak self] note in
            let id = note.userInfo?["id"] as? UUID
            MainActor.assumeIsolated {
                guard let self else { return }
                if let id {
                    self.wallpaperDidChange(id)
                } else {
                    self.renditions.prune(keeping: Set(self.store.wallpapers.map(\.id)))
                    self.reconcile()
                }
            }
        }
        center.addObserver(forName: .renditionsDidChange, object: nil, queue: .main) { [weak self] note in
            let id = note.userInfo?["id"] as? UUID
            MainActor.assumeIsolated {
                if let id { self?.refresh(id) }
            }
        }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            on(workspace, name) { $0.updateCoverage() }
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
