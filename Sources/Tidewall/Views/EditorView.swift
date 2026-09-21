import SwiftUI

struct WallpaperEditorView: View {
    let wallpaperID: UUID
    private let store = LibraryStore.shared

    var body: some View {
        if let binding = store.binding(for: wallpaperID) {
            EditorContent(wallpaper: binding)
                .id(wallpaperID)
        } else {
            ContentUnavailableView("Wallpaper Not Found", systemImage: "questionmark.square.dashed",
                                   description: Text("It may have been deleted."))
        }
    }
}

private struct EditorContent: View {
    @Binding var wallpaper: Wallpaper
    @State private var model: EditorModel?
    @State private var previewDisplayID: String?
    @State private var showsDesktopOverlay = true
    @State private var confirmReset = false

    private let engine = WallpaperEngine.shared
    private let store = LibraryStore.shared

    private var previewDisplay: Display? {
        engine.displays.first { $0.id == previewDisplayID } ?? engine.displays.first
    }

    private var aspectRatio: CGFloat { previewDisplay?.aspectRatio ?? 16 / 10 }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 18) {
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(-1)
                transportBar
                trimSection
            }
            .padding(24)
            .frame(minWidth: 460)

            Divider()

            EditorInspector(wallpaper: $wallpaper)
                .frame(width: 340)
        }
        .navigationTitle(wallpaper.name)
        .navigationSubtitle(engine.displays(showing: wallpaper.id).isEmpty ? "" : "On Desktop — edits apply live")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                SetWallpaperButton(wallpaperID: wallpaper.id)
                Menu {
                    Button("Duplicate") {
                        if let copy = store.duplicate(wallpaper.id) {
                            AppDelegate.shared.navigation.edit(copy.id)
                        }
                    }
                    Button("Show Video in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.mediaURL(for: wallpaper)])
                    }
                    Divider()
                    Button("Reset All Settings…") { confirmReset = true }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Reset all settings for “\(wallpaper.name)”?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                withAnimation(.snappy) { wallpaper.settings = WallpaperSettings() }
            }
        } message: {
            Text("Framing, trim, speed, adjustments and audio go back to their defaults.")
        }
        .onDisappear {
            model?.tearDown()
            model = nil
        }
        .onChange(of: wallpaper) { _, new in
            model?.update(new)
        }
        .task(id: wallpaper.id) {
            if model == nil { model = EditorModel(wallpaper: wallpaper) }
            await model?.loadFilmstrip(duration: wallpaper.duration)
        }
    }

    // MARK: Preview

    private var preview: some View {
        ZStack {
            Color.black
            if let model {
                WallpaperPlayerRepresentable(player: model.player.player, wallpaper: wallpaper)
                if let frame = model.scrubFrame {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                }
            }
            if showsDesktopOverlay {
                DesktopOverlay()
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        }
        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
    }

    private var transportBar: some View {
        HStack(spacing: 14) {
            Button {
                model?.togglePlayback()
            } label: {
                Label((model?.isPlaying ?? true) ? "Pause Preview" : "Play Preview",
                      systemImage: (model?.isPlaying ?? true) ? "pause.fill" : "play.fill")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: 22)
            }
            .buttonStyle(.borderless)
            .help("Play or pause the preview")

            if let model {
                PlayheadTimecode(model: model)
            }

            Spacer()

            Toggle(isOn: $showsDesktopOverlay) {
                Label("Show Menu Bar and Dock", systemImage: "menubar.dock.rectangle")
                    .labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            .help("Show the menu bar and Dock in the preview")

            if engine.displays.count > 1 {
                Picker("Preview on", selection: Binding(
                    get: { previewDisplay?.id ?? "" },
                    set: { previewDisplayID = $0 }
                )) {
                    ForEach(engine.displays) { display in
                        Text(display.name).tag(display.id)
                    }
                }
                .fixedSize()
            }
        }
    }

    // MARK: Trim

    private var trimStart: Binding<Double> {
        Binding(get: { wallpaper.loopRange.lowerBound },
                set: { wallpaper.settings.trimStart = $0 })
    }

    private var trimEnd: Binding<Double> {
        Binding(get: { wallpaper.loopRange.upperBound },
                set: { wallpaper.settings.trimEnd = $0 >= wallpaper.duration - 0.01 ? nil : $0 })
    }

    private var scrubSize: CGSize {
        CGSize(width: 1280, height: (1280 / aspectRatio).rounded())
    }

    private var trimSection: some View {
        let range = wallpaper.loopRange
        let isTrimmed = range.lowerBound > 0.001 || range.upperBound < wallpaper.duration - 0.01
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Loop").font(.headline)
                Text("Drag the yellow handles to choose the part that repeats.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(range.lowerBound.timecode) – \(range.upperBound.timecode)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1fs", range.upperBound - range.lowerBound))
                    .monospacedDigit()
                    .fontWeight(.semibold)
            }

            if let model {
                TrimStrip(
                    duration: wallpaper.duration,
                    start: trimStart,
                    end: trimEnd,
                    model: model,
                    onScrub: { time in model.scrub(to: time, wallpaper: wallpaper, size: scrubSize) },
                    onScrubEnded: { model.endScrub(seekTo: wallpaper.loopRange.lowerBound) })
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(height: TrimStrip.height)
            }

            HStack {
                Button("Start at Playhead") {
                    let t = min(model?.currentTime ?? 0, range.upperBound - TrimStrip.minimumLength)
                    trimStart.wrappedValue = max(0, t)
                }
                Button("End at Playhead") {
                    let t = max(model?.currentTime ?? 0, range.lowerBound + TrimStrip.minimumLength)
                    trimEnd.wrappedValue = min(wallpaper.duration, t)
                }
                Spacer()
                Button("Use Full Video") {
                    wallpaper.settings.trimStart = 0
                    wallpaper.settings.trimEnd = nil
                }
                .disabled(!isTrimmed)
            }
            .controlSize(.small)
        }
    }
}

/// Reads the 24 Hz playhead in its own view so only this text re-renders.
private struct PlayheadTimecode: View {
    let model: EditorModel

    var body: some View {
        Text(model.currentTime.timecode)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}

/// A hint of the menu bar and Dock so framing can be judged in context.
private struct DesktopOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            VStack(spacing: 0) {
                Rectangle()
                    .fill(.black.opacity(0.22))
                    .frame(height: max(5, h * 0.028))
                    .overlay(alignment: .leading) {
                        HStack(spacing: h * 0.03) {
                            Image(systemName: "apple.logo")
                            ForEach(0..<4, id: \.self) { _ in
                                Capsule().frame(width: h * 0.05, height: h * 0.009)
                            }
                        }
                        .font(.system(size: max(4, h * 0.016)))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.leading, h * 0.03)
                    }
                Spacer()
                RoundedRectangle(cornerRadius: h * 0.02, style: .continuous)
                    .fill(.white.opacity(0.18))
                    .overlay {
                        RoundedRectangle(cornerRadius: h * 0.02, style: .continuous)
                            .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
                    }
                    .frame(width: geo.size.width * 0.42, height: h * 0.075)
                    .padding(.bottom, h * 0.012)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Filmstrip with draggable loop points and a playhead.
struct TrimStrip: View {
    static let minimumLength = 0.5

    static let height: CGFloat = 58

    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    let model: EditorModel
    var onScrub: (Double) -> Void
    var onScrubEnded: () -> Void

    private let height = TrimStrip.height
    private let handleWidth: CGFloat = 13

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let x: (Double) -> CGFloat = { CGFloat($0 / max(duration, 0.001)) * width }
            let time: (CGFloat) -> Double = { Double(min(max($0, 0), width) / max(width, 1)) * duration }

            ZStack(alignment: .topLeading) {
                filmstrip(width: width)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { model.seek(to: time($0.location.x)) })

                Rectangle().fill(.black.opacity(0.6))
                    .frame(width: max(0, x(start)), height: height)
                    .allowsHitTesting(false)
                Rectangle().fill(.black.opacity(0.6))
                    .frame(width: max(0, width - x(end)), height: height)
                    .offset(x: x(end))
                    .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.yellow, lineWidth: 3)
                    .frame(width: max(handleWidth * 2, x(end) - x(start)), height: height)
                    .offset(x: x(start))
                    .allowsHitTesting(false)

                Playhead(model: model, height: height, position: x)

                handle(systemImage: "chevron.compact.left")
                    .accessibilityElement()
                    .accessibilityLabel("Loop start")
                    .accessibilityValue(start.timecode)
                    .accessibilityAdjustableAction { direction in
                        let step = direction == .increment ? 0.1 : -0.1
                        start = min(max(0, start + step), end - Self.minimumLength)
                    }
                    .offset(x: x(start))
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
                        .onChanged { value in
                            start = min(max(0, time(value.location.x)), end - Self.minimumLength)
                            onScrub(start)
                        }
                        .onEnded { _ in onScrubEnded() })

                handle(systemImage: "chevron.compact.right")
                    .accessibilityElement()
                    .accessibilityLabel("Loop end")
                    .accessibilityValue(end.timecode)
                    .accessibilityAdjustableAction { direction in
                        let step = direction == .increment ? 0.1 : -0.1
                        end = max(min(duration, end + step), start + Self.minimumLength)
                    }
                    .offset(x: x(end) - handleWidth)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
                        .onChanged { value in
                            end = max(min(duration, time(value.location.x)), start + Self.minimumLength)
                            onScrub(end)
                        }
                        .onEnded { _ in onScrubEnded() })
            }
            .coordinateSpace(.named("trim"))
        }
        .frame(height: height)
    }

    private func filmstrip(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            let frames = model.filmstrip
            if frames.isEmpty {
                Rectangle().fill(.quaternary)
            } else {
                ForEach(frames.indices, id: \.self) { i in
                    Image(decorative: frames[i], scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width / CGFloat(frames.count), height: height)
                        .clipped()
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func handle(systemImage: String) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.yellow)
            .frame(width: handleWidth, height: height)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(.black.opacity(0.7))
            }
            .contentShape(Rectangle().inset(by: -6))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }
}

private struct Playhead: View {
    let model: EditorModel
    let height: CGFloat
    let position: (Double) -> CGFloat

    var body: some View {
        Rectangle()
            .fill(.white)
            .frame(width: 2, height: height + 8)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .offset(x: position(model.currentTime) - 1, y: -4)
            .allowsHitTesting(false)
    }
}
