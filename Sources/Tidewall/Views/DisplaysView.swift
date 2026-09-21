import SwiftUI

/// Shows the display arrangement and lets each screen have its own wallpaper.
struct DisplaysView: View {
    private let engine = WallpaperEngine.shared
    private let store = LibraryStore.shared
    @State private var selectedDisplayID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                arrangement
                    .frame(height: 260)
                    .frame(maxWidth: .infinity)
                    .padding(20)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(spacing: 12) {
                    ForEach(engine.displays) { display in
                        DisplayRow(display: display, isSelected: selectedDisplayID == display.id)
                            .onTapGesture { selectedDisplayID = display.id }
                    }
                }

                if engine.displays.count > 1 {
                    HStack {
                        Text("Use one wallpaper on every display:")
                            .foregroundStyle(.secondary)
                        Menu(store.wallpaper(id: engine.sharedWallpaperID)?.name ?? "Choose…") {
                            ForEach(store.wallpapers) { wallpaper in
                                Button(wallpaper.name) { engine.setWallpaper(wallpaper.id) }
                            }
                            Divider()
                            Button("System Wallpaper") { engine.setWallpaper(nil) }
                        }
                        .fixedSize()
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Displays")
        .navigationSubtitle(engine.displays.count == 1 ? "1 display" : "\(engine.displays.count) displays")
    }

    /// Screens drawn to scale in their real arrangement.
    private var arrangement: some View {
        GeometryReader { geo in
            let displays = engine.displays
            let union = displays.reduce(CGRect.null) { $0.union($1.frame) }
            let scale = union.isNull ? 1 : min(geo.size.width / union.width, geo.size.height / union.height) * 0.92
            let offset = CGPoint(x: (geo.size.width - union.width * scale) / 2,
                                 y: (geo.size.height - union.height * scale) / 2)

            ZStack(alignment: .topLeading) {
                ForEach(displays) { display in
                    let frame = display.frame
                    // AppKit's origin is bottom-left; SwiftUI's is top-left.
                    let x = (frame.minX - union.minX) * scale + offset.x
                    let y = (union.maxY - frame.maxY) * scale + offset.y
                    ScreenTile(display: display, isSelected: selectedDisplayID == display.id)
                        .frame(width: frame.width * scale - 6, height: frame.height * scale - 6)
                        .offset(x: x + 3, y: y + 3)
                        .onTapGesture { selectedDisplayID = display.id }
                }
            }
        }
    }
}

private struct ScreenTile: View {
    let display: Display
    let isSelected: Bool
    private let engine = WallpaperEngine.shared
    private let store = LibraryStore.shared

    var body: some View {
        let wallpaper = store.wallpaper(id: engine.wallpaperID(for: display.id))
        ZStack {
            if let wallpaper {
                WallpaperThumbnail(wallpaper: wallpaper)
            } else {
                LinearGradient(colors: [Color(white: 0.35), Color(white: 0.2)], startPoint: .top, endPoint: .bottom)
                    .overlay {
                        Label("System Wallpaper", systemImage: "photo")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                    }
            }
        }
        .overlay(alignment: .bottomLeading) {
            Text(display.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .shadow(radius: 3)
                .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .black.opacity(0.4), lineWidth: isSelected ? 3 : 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
    }
}

private struct DisplayRow: View {
    let display: Display
    let isSelected: Bool
    private let engine = WallpaperEngine.shared
    private let store = LibraryStore.shared

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: display.isMain ? "display" : "display.2")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(display.name).font(.headline)
                    if display.isMain {
                        Text("Main")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(display.resolutionDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("Wallpaper", selection: Binding(
                get: { engine.wallpaperID(for: display.id) },
                set: { engine.setWallpaper($0, for: display.id) }
            )) {
                Text("System Wallpaper").tag(UUID?.none)
                if !store.wallpapers.isEmpty { Divider() }
                ForEach(store.wallpapers) { wallpaper in
                    Text(wallpaper.name).tag(Optional(wallpaper.id))
                }
            }
            .labelsHidden()
            .frame(width: 220)
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.06),
                              lineWidth: isSelected ? 2 : 1)
        }
        .contentShape(Rectangle())
    }
}
