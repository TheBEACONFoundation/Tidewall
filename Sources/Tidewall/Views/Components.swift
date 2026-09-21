import SwiftUI
import AVFoundation

/// A still of the wallpaper with its color adjustments applied.
struct WallpaperThumbnail: View {
    let wallpaper: Wallpaper
    @State private var image: NSImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .scaleEffect(x: wallpaper.settings.mirrored ? -1 : 1)
                        .transition(.opacity)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .clipped()
            .task(id: ThumbnailCache.cacheKey(for: wallpaper)) {
                if let cached = ThumbnailCache.shared.cachedImage(for: wallpaper) {
                    image = cached
                    return
                }
                let loaded = await ThumbnailCache.shared.image(for: wallpaper)
                withAnimation(.easeOut(duration: 0.2)) { image = loaded }
            }
    }
}

/// "Set as Wallpaper" button that becomes a split menu with several displays.
struct SetWallpaperButton: View {
    let wallpaperID: UUID
    var title = "Set as Wallpaper"
    private let engine = WallpaperEngine.shared

    var body: some View {
        if engine.displays.count > 1 {
            Menu {
                Button("All Displays") { engine.setWallpaper(wallpaperID) }
                Divider()
                ForEach(engine.displays) { display in
                    Button(display.name) { engine.setWallpaper(wallpaperID, for: display.id) }
                }
            } label: {
                Label(title, systemImage: "menubar.dock.rectangle")
            } primaryAction: {
                engine.setWallpaper(wallpaperID)
            }
        } else {
            Button {
                engine.setWallpaper(wallpaperID)
            } label: {
                Label(title, systemImage: "menubar.dock.rectangle")
            }
        }
    }
}

/// A labeled slider with its value and a reset button once it's been changed.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                if abs(value - defaultValue) > 0.0001 {
                    Button {
                        withAnimation(.snappy) { value = defaultValue }
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to \(format(defaultValue))")
                }
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 48, alignment: .trailing)
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
        }
    }
}

extension RGBAColor {
    var color: Color { Color(cgColor: cgColor) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent, alpha: ns.alphaComponent)
    }
}

extension Binding where Value == RGBAColor {
    var swiftUIColor: Binding<Color> {
        Binding<Color>(get: { wrappedValue.color }, set: { wrappedValue = RGBAColor($0) })
    }
}

/// Hosts a `WallpaperPlayerView` inside SwiftUI.
struct WallpaperPlayerRepresentable: NSViewRepresentable {
    let player: AVPlayer
    let wallpaper: Wallpaper

    func makeNSView(context: Context) -> WallpaperPlayerView {
        let view = WallpaperPlayerView()
        view.player = player
        view.configure(with: wallpaper)
        return view
    }

    func updateNSView(_ view: WallpaperPlayerView, context: Context) {
        view.player = player
        view.configure(with: wallpaper)
    }
}

/// "Add Built-in Wallpaper" submenu for the File menu.
struct BuiltInWallpaperMenu: View {
    var body: some View {
        Menu("Add Built-in Wallpaper") {
            ForEach(BuiltInWallpaper.all) { builtIn in
                Button(builtIn.name) { Task { await LibraryStore.shared.addBuiltIn(builtIn) } }
            }
        }
    }
}
