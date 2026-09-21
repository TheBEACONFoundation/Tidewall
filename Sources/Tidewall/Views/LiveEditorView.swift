import SwiftUI

/// Editor for live wallpapers (the audio visualizer): a live preview driven by
/// whatever the Mac is playing, and the look's settings.
struct LiveEditorContent: View {
    @Binding var wallpaper: Wallpaper
    @State private var confirmReset = false
    private let engine = WallpaperEngine.shared
    private let store = LibraryStore.shared
    private let reactor = AudioReactor.shared

    private var settings: Binding<VisualizerSettings> {
        Binding(get: { wallpaper.visualizer ?? VisualizerSettings() },
                set: { wallpaper.visualizer = $0 })
    }

    private var aspectRatio: CGFloat { engine.displays.first?.aspectRatio ?? 16 / 10 }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 16) {
                VisualizerPreview(settings: settings.wrappedValue)
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12))
                    }
                    .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(-1)
                listeningStatus
            }
            .padding(24)
            .frame(minWidth: 460)

            Divider()

            inspector
                .frame(width: 340)
        }
        .navigationTitle(wallpaper.name)
        .navigationSubtitle(engine.displays(showing: wallpaper.id).isEmpty ? "" : "On Desktop — edits apply live")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                SetWallpaperButton(wallpaperID: wallpaper.id)
                Menu {
                    Button("Duplicate") {
                        if let copy = store.duplicate(wallpaper.id) { AppDelegate.shared.navigation.edit(copy.id) }
                    }
                    Divider()
                    Button("Reset Look…") { confirmReset = true }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Reset the look of “\(wallpaper.name)”?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                withAnimation(.snappy) { wallpaper.visualizer = VisualizerSettings() }
            }
        }
    }

    private var listeningStatus: some View {
        HStack(spacing: 8) {
            if let error = reactor.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if reactor.hearsOnlySilence {
                Label("Something is playing, but Tidewall hears only silence. It may not have permission to listen.",
                      systemImage: "speaker.slash.fill")
                    .foregroundStyle(.orange)
            } else if reactor.isListening {
                Label("Listening — the picture follows whatever your Mac plays.", systemImage: "waveform")
                    .foregroundStyle(.secondary)
            } else {
                Label("Waiting for sound. Play some music to see it move.", systemImage: "music.note")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.callout)
    }

    private var inspector: some View {
        Form {
            Section {
                TextField("Name", text: $wallpaper.name)
                LabeledContent("Type", value: "Live · reacts to audio")
            }

            Section("Look") {
                Picker("Colors", selection: settings.palette) {
                    ForEach(VisualizerPalette.allCases) { Text($0.title).tag($0) }
                }
                SliderRow(title: "Sensitivity", value: settings.sensitivity, range: 0.4...2, defaultValue: 1,
                          format: { String(format: "%.0f%%", $0 * 100) })
                SliderRow(title: "Motion", value: settings.motion, range: 0...1.5, defaultValue: 1,
                          format: { String(format: "%.0f%%", $0 * 100) })
            }

            Section {
                Picker("Quality", selection: settings.quality) {
                    Text("Balanced").tag(0.5)
                    Text("Sharp").tag(0.75)
                    Text("Full").tag(1.0)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Performance")
            } footer: {
                Text("Balanced draws at half your display's resolution: the glow looks the same for a quarter of the GPU work. It slows to 20 frames per second when nothing is playing, and stops whenever the desktop is covered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Open Privacy Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            } header: {
                Text("Audio")
            } footer: {
                Text("Tidewall listens to the sound your Mac plays only while this wallpaper is on screen and something is playing. The audio is analyzed as it plays and never recorded or stored. macOS asks once for permission; if you declined, turn Tidewall on under Privacy & Security → Screen & System Audio Recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// A live visualizer inside SwiftUI; it counts as audio demand while shown.
struct VisualizerPreview: NSViewRepresentable {
    let settings: VisualizerSettings

    func makeNSView(context: Context) -> NSView {
        guard let view = VisualizerView(frame: .zero, settings: settings) else {
            let placeholder = NSView()
            placeholder.wantsLayer = true
            placeholder.layer?.backgroundColor = NSColor.black.cgColor
            return placeholder
        }
        AudioReactor.shared.setDemand(1, from: "editor")
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? VisualizerView)?.settings = settings
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        (view as? VisualizerView)?.isPaused = true
        AudioReactor.shared.setDemand(0, from: "editor")
    }
}
