import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .frame(width: 500, height: 560)
                .tabItem { Label("General", systemImage: "gearshape") }
            PerformanceSettings()
                .frame(width: 500, height: 520)
                .tabItem { Label("Performance", systemImage: "gauge.with.dots.needle.33percent") }
        }
    }
}

private struct GeneralSettings: View {
    @AppStorage(Preferences.showDockIcon) private var showDockIcon = true
    @AppStorage(Preferences.matchSystemWallpaper) private var matchSystemWallpaper = false
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            try LoginItem.setEnabled(enabled)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Show icon in Dock", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { _, _ in
                        Preferences.applyDockIconPreference()
                        NSApp.activate()
                    }
            } footer: {
                Text("Tidewall is always available from the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Match the macOS wallpaper", isOn: $matchSystemWallpaper)
                    .onChange(of: matchSystemWallpaper) { _, enabled in
                        if enabled {
                            SystemWallpaperSync.shared.forget()
                            WallpaperEngine.shared.reconcile()
                        }
                    }
            } footer: {
                Text("Sets your macOS desktop picture to the first frame of each live wallpaper, so Mission Control, the lock screen and your desktop after quitting all match. This replaces your current desktop picture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            UpdateSettings()

            Section {
                LabeledContent("Library") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([LibraryStore.shared.rootURL])
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct UpdateSettings: View {
    @Bindable private var updates = Updates.shared

    var body: some View {
        Section {
            if updates.isAvailable {
                Toggle("Check for updates automatically", isOn: $updates.automaticallyChecks)
                Toggle("Download and install updates automatically", isOn: $updates.automaticallyInstalls)
                    .disabled(!updates.automaticallyChecks)
                LabeledContent("Last checked") {
                    HStack {
                        Text(updates.lastCheck.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                            .foregroundStyle(.secondary)
                        Button("Check Now") { updates.checkNow() }
                            .disabled(!updates.canCheck)
                    }
                }
            } else {
                Text("This build can't update itself. Builds from the Releases page on GitHub can.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("New versions come from Tidewall's releases on GitHub. Each download is checked against Tidewall's signature before it's installed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PerformanceSettings: View {
    @AppStorage(Preferences.optimizePlayback) private var optimizePlayback = true
    @AppStorage(Preferences.pauseWhenHidden) private var pauseWhenHidden = true
    @AppStorage(Preferences.pauseInLowPowerMode) private var pauseInLowPowerMode = true
    @AppStorage(Preferences.pauseOnBattery) private var pauseOnBattery = false
    @AppStorage(Preferences.pauseForReduceMotion) private var pauseForReduceMotion = true
    @State private var copiesSize: Int64 = RenditionManager.shared.diskUsage

    var body: some View {
        Form {
            Section {
                Toggle("Optimize playback", isOn: $optimizePlayback)
                LabeledContent("Playback copies") {
                    HStack {
                        Text(ByteCountFormatter.string(fromByteCount: copiesSize, countStyle: .file))
                            .foregroundStyle(.secondary)
                        Button("Delete") {
                            RenditionManager.shared.removeAll()
                            copiesSize = RenditionManager.shared.diskUsage
                            WallpaperEngine.shared.reconcile()
                        }
                        .disabled(copiesSize == 0)
                    }
                }
            } header: {
                Text("Efficiency")
            } footer: {
                Text("Color adjustments are baked into a copy a few seconds after you stop editing, so the desktop plays it without filtering every frame. Videos larger than your displays and ones macOS can't decode in hardware get a copy too. Originals are never changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Pause when windows cover the desktop", isOn: $pauseWhenHidden)
                Toggle("Pause in Low Power Mode", isOn: $pauseInLowPowerMode)
                Toggle("Pause on battery power", isOn: $pauseOnBattery)
                Toggle("Pause when Reduce Motion is on", isOn: $pauseForReduceMotion)
            } header: {
                Text("Automatically pause")
            } footer: {
                Text("A wallpaper pauses when full-screen apps or windows cover nearly all of its display. Playback always stops while the screen is locked, asleep or showing a screen saver. Reduce Motion is in System Settings → Accessibility → Display; while it's on, wallpapers hold still on their current frame.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
