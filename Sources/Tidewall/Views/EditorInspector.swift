import SwiftUI

/// The settings column of the editor. Every change is saved immediately and,
/// if the wallpaper is on the desktop, applied there live.
struct EditorInspector: View {
    @Binding var wallpaper: Wallpaper

    private var settings: Binding<WallpaperSettings> { $wallpaper.settings }
    private var adjustments: Binding<Adjustments> { $wallpaper.settings.adjustments }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $wallpaper.name)
                LabeledContent("Source", value: wallpaper.originalFileName)
                LabeledContent("Video", value: "\(wallpaper.resolutionDescription) · \(wallpaper.duration.shortDuration)")
            }

            Section("Framing") {
                Picker("Scaling", selection: settings.scaling) {
                    ForEach(Scaling.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                SliderRow(title: "Zoom", value: settings.zoom, range: 1...3, defaultValue: 1,
                          format: { String(format: "%.2f×", $0) })
                SliderRow(title: "Horizontal Position", value: settings.focusX, range: -1...1, defaultValue: 0,
                          format: Self.position(negative: "Left", positive: "Right"))
                SliderRow(title: "Vertical Position", value: settings.focusY, range: -1...1, defaultValue: 0,
                          format: Self.position(negative: "Bottom", positive: "Top"))
                Toggle("Mirror Horizontally", isOn: settings.mirrored)
                ColorPicker("Background", selection: settings.backgroundColor.swiftUIColor, supportsOpacity: false)
                    .help("Fills the space around the video when it doesn't cover the screen")
            }

            Section("Playback") {
                SliderRow(title: "Speed", value: settings.speed, range: 0.25...2, defaultValue: 1,
                          format: { String(format: "%.2f×", $0) })
            }

            Section {
                SliderRow(title: "Brightness", value: adjustments.brightness, range: -0.5...0.5, defaultValue: 0,
                          format: Self.signedPercent(scale: 200))
                SliderRow(title: "Contrast", value: adjustments.contrast, range: 0.5...1.5, defaultValue: 1,
                          format: Self.percent)
                SliderRow(title: "Saturation", value: adjustments.saturation, range: 0...2, defaultValue: 1,
                          format: Self.percent)
                SliderRow(title: "Hue", value: adjustments.hue, range: -180...180, defaultValue: 0,
                          format: { String(format: "%+.0f°", $0) })
                SliderRow(title: "Blur", value: adjustments.blur, range: 0...40, defaultValue: 0,
                          format: { String(format: "%.0f", $0) })
                SliderRow(title: "Vignette", value: adjustments.vignette, range: 0...2, defaultValue: 0,
                          format: { String(format: "%.0f%%", $0 * 50) })
                SliderRow(title: "Tint", value: adjustments.tintAmount, range: 0...1, defaultValue: 0,
                          format: { String(format: "%.0f%%", $0 * 100) })
                if wallpaper.settings.adjustments.tintAmount > 0 {
                    ColorPicker("Tint Color", selection: adjustments.tintColor.swiftUIColor, supportsOpacity: false)
                }
            } header: {
                HStack {
                    Text("Adjustments")
                    Spacer()
                    if !wallpaper.settings.adjustments.isIdentity {
                        Button("Reset") {
                            withAnimation(.snappy) { wallpaper.settings.adjustments = Adjustments() }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            } footer: {
                Text("Dim or blur busy videos to keep desktop icons readable. Unadjusted videos play straight from the hardware decoder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Play Sound", isOn: Binding(get: { !wallpaper.settings.muted },
                                                   set: { wallpaper.settings.muted = !$0 }))
                SliderRow(title: "Volume", value: settings.volume, range: 0...1, defaultValue: 0.5,
                          format: Self.percent)
                    .disabled(wallpaper.settings.muted)
            } header: {
                Text("Audio")
            } footer: {
                Text("Sound plays from the desktop. The preview is always silent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    private static func signedPercent(scale: Double) -> (Double) -> String {
        { value in abs(value) < 0.0005 ? "0%" : String(format: "%+.0f%%", value * scale) }
    }

    private static func position(negative: String, positive: String) -> (Double) -> String {
        { value in
            if abs(value) < 0.01 { return "Center" }
            return String(format: "%.0f%% %@", abs(value) * 100, value < 0 ? negative : positive)
        }
    }
}
