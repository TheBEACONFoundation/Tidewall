import SwiftUI

struct MenuBarLabel: View {
    private let engine = WallpaperEngine.shared

    var body: some View {
        Image(systemName: engine.isUserPaused ? "pause.rectangle" : "play.rectangle.on.rectangle")
            .accessibilityLabel("Tidewall")
    }
}

/// Quick switcher shown from the menu bar.
struct MenuBarView: View {
    private let engine = WallpaperEngine.shared
    private let store = LibraryStore.shared
    @Environment(\.openSettings) private var openSettings
    /// nil targets every display.
    @State private var targetDisplayID: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    private var currentID: UUID? {
        if let targetDisplayID { return engine.wallpaperID(for: targetDisplayID) }
        return engine.sharedWallpaperID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if engine.displays.count > 1 {
                Picker("Display", selection: $targetDisplayID) {
                    Text("All Displays").tag(String?.none)
                    ForEach(engine.displays) { display in
                        Text(display.name).tag(Optional(display.id))
                    }
                }
                .labelsHidden()
            }

            if store.wallpapers.isEmpty {
                Text("Your library is empty. Open the library to import videos.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        OffTile(isSelected: currentID == nil) {
                            engine.setWallpaper(nil, for: targetDisplayID)
                        }
                        ForEach(store.wallpapers) { wallpaper in
                            MiniTile(wallpaper: wallpaper, isSelected: currentID == wallpaper.id) {
                                engine.setWallpaper(wallpaper.id, for: targetDisplayID)
                            }
                        }
                    }
                    .padding(2)
                }
                .frame(maxHeight: 270)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: 4) {
                Button {
                    AppDelegate.shared.showLibrary()
                } label: {
                    Label("Open Library", systemImage: "square.grid.2x2")
                }
                Spacer()
                Button {
                    NSApp.activate()
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                }
                .help("Settings")
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit Tidewall", systemImage: "power")
                        .labelStyle(.iconOnly)
                }
                .help("Quit Tidewall")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tidewall").font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                engine.isUserPaused.toggle()
            } label: {
                Label(engine.isUserPaused ? "Resume" : "Pause",
                      systemImage: engine.isUserPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var statusText: String {
        let active = engine.displays.filter { engine.wallpaperID(for: $0.id) != nil }.count
        if active == 0 { return "No live wallpaper" }
        if let reason = engine.pauseReason { return reason.title }
        if engine.isPausedWhileHidden { return "Paused while windows cover it" }
        return active == 1 ? "Playing on 1 display" : "Playing on \(active) displays"
    }
}

private struct MiniTile: View {
    let wallpaper: Wallpaper
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            WallpaperThumbnail(wallpaper: wallpaper)
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1),
                                      lineWidth: isSelected ? 2.5 : 1)
                }
        }
        .buttonStyle(.plain)
        .help(wallpaper.name)
        .accessibilityLabel(wallpaper.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct OffTile: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay {
                    VStack(spacing: 2) {
                        Image(systemName: "photo")
                        Text("System").font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1),
                                      lineWidth: isSelected ? 2.5 : 1)
                }
        }
        .buttonStyle(.plain)
        .help("Show the macOS wallpaper")
        .accessibilityLabel("System wallpaper")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
