import ImageIO
import SwiftUI
import UniformTypeIdentifiers

extension BlockCategory {
    var color: Color {
        switch self {
        case .background: Color(red: 0.30, green: 0.50, blue: 1.00)
        case .light: Color(red: 1.00, green: 0.62, blue: 0.20)
        case .motion: Color(red: 0.62, green: 0.40, blue: 1.00)
        case .music: Color(red: 0.20, green: 0.80, blue: 0.50)
        case .content: Color(red: 0.95, green: 0.35, blue: 0.45)
        case .finish: Color(red: 0.55, green: 0.58, blue: 0.64)
        }
    }
}

/// The blocks editor: a live preview on the left and the stack of blocks on
/// the right. Blocks run top to bottom; each draws over the ones above it.
struct BlocksEditorContent: View {
    @Binding var wallpaper: Wallpaper
    @State private var expanded: UUID?
    @State private var showingPalette = false
    @State private var confirmTemplate: BlockTemplate?
    private let engine = WallpaperEngine.shared
    private let store = LibraryStore.shared
    private let reactor = AudioReactor.shared

    /// - Parameter expanded: a block to open straight away.
    init(wallpaper: Binding<Wallpaper>, expanded: UUID? = nil) {
        _wallpaper = wallpaper
        _expanded = State(initialValue: expanded)
    }

    private var composition: Binding<Composition> {
        Binding(get: { wallpaper.composition ?? Composition() }, set: { wallpaper.composition = $0 })
    }

    private var aspectRatio: CGFloat { engine.displays.first?.aspectRatio ?? 16 / 10 }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                LivePreview(content: .blocks(composition.wrappedValue))
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12))
                    }
                    .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(-1)
                footerHint
            }
            .padding(24)
            .frame(minWidth: 440)

            Divider()

            blockStack
                .frame(width: 380)
        }
        .navigationTitle(wallpaper.name)
        .navigationSubtitle(engine.displays(showing: wallpaper.id).isEmpty ? "Made with blocks" : "On Desktop — edits apply live")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                SetWallpaperButton(wallpaperID: wallpaper.id)
                Menu {
                    Button("Duplicate") {
                        if let copy = store.duplicate(wallpaper.id) { AppDelegate.shared.navigation.edit(copy.id) }
                    }
                    Button("Export…") { store.presentExportPanel(for: wallpaper) }
                    Divider()
                    Menu("Start Over From") {
                        ForEach(BlockTemplate.allCases) { template in
                            Button(template.title) { confirmTemplate = template }
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Replace all blocks with the “\(confirmTemplate?.title ?? "")” template?",
                            isPresented: Binding(get: { confirmTemplate != nil }, set: { if !$0 { confirmTemplate = nil } })) {
            Button("Replace", role: .destructive) {
                if let template = confirmTemplate {
                    withAnimation(.snappy) { composition.wrappedValue = template.composition }
                    expanded = nil
                }
                confirmTemplate = nil
            }
        }
    }

    // MARK: Stack

    private var blockStack: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField("Name", text: $wallpaper.name)
                        .textFieldStyle(.plain)
                        .font(.title3.weight(.semibold))
                    Spacer()
                }
                Text("Blocks run from top to bottom — each one draws over those above it. Drag to reorder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            List {
                ForEach(composition.blocks) { $block in
                    BlockCard(block: $block, isExpanded: expanded == block.id,
                              onToggleExpand: {
                                  withAnimation(.snappy(duration: 0.25)) { expanded = expanded == block.id ? nil : block.id }
                              },
                              onDuplicate: { duplicate(block) },
                              onDelete: { delete(block) })
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                }
                .onMove { from, to in composition.wrappedValue.blocks.move(fromOffsets: from, toOffset: to) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            Divider()
            HStack {
                Button {
                    showingPalette = true
                } label: {
                    Label("Add Block", systemImage: "plus.circle.fill")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(composition.wrappedValue.blocks.count >= Composition.maxBlocks)
                .popover(isPresented: $showingPalette, arrowEdge: .top) {
                    BlockPalette { kind in
                        add(kind)
                        showingPalette = false
                    }
                }
                Spacer()
                Text("\(composition.wrappedValue.blocks.count) of \(Composition.maxBlocks)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(12)
        }
        .background(.background)
    }

    private var footerHint: some View {
        HStack(spacing: 8) {
            if composition.wrappedValue.usesAudio {
                Image(systemName: reactor.isListening ? "waveform" : "music.note")
                Text(reactor.isListening ? "Listening — blocks set to react move with your music."
                                         : "Some blocks react to music. Play something to see them move.")
            } else {
                Image(systemName: "lightbulb")
                Text("Tip: set a block's “React to” to make it move with your music.")
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    // MARK: Editing

    private func add(_ kind: BlockKind) {
        let block = kind.makeBlock()
        var blocks = composition.wrappedValue.blocks
        // A new background (or picture) goes to the bottom of the stack, anything else on top.
        if kind == .gradient || kind == .image {
            blocks.insert(block, at: 0)
        } else if let vignette = blocks.lastIndex(where: { $0.kind == .vignette }), kind != .vignette {
            blocks.insert(block, at: vignette)
        } else {
            blocks.append(block)
        }
        withAnimation(.snappy) {
            composition.wrappedValue.blocks = blocks
            expanded = block.id
        }
    }

    private func duplicate(_ block: Block) {
        guard let index = composition.wrappedValue.blocks.firstIndex(where: { $0.id == block.id }),
              composition.wrappedValue.blocks.count < Composition.maxBlocks else { return }
        var copy = block
        copy.id = UUID()
        withAnimation(.snappy) { composition.wrappedValue.blocks.insert(copy, at: index + 1) }
    }

    private func delete(_ block: Block) {
        withAnimation(.snappy) { composition.wrappedValue.blocks.removeAll { $0.id == block.id } }
    }
}

/// One block: a colour-coded header, and its settings when expanded.
private struct BlockCard: View {
    @Binding var block: Block
    let isExpanded: Bool
    var onToggleExpand: () -> Void
    var onDuplicate: () -> Void
    var onDelete: () -> Void
    @State private var pictureError: String?
    @State private var pictureThumbnail: NSImage?

    private var tint: Color { block.kind.category.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider().padding(.horizontal, 12)
                settings
                    .padding(12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.55)))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, style: .continuous)
                .fill(tint)
                .frame(width: 5)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isExpanded ? tint.opacity(0.7) : Color.primary.opacity(0.06), lineWidth: isExpanded ? 1.5 : 1)
        }
        .opacity(block.enabled ? 1 : 0.55)
        .contextMenu {
            Button("Duplicate", action: onDuplicate)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.gradient)
                Image(systemName: block.kind.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(block.kind.title).font(.body.weight(.semibold))
                if block.react != .nothing || block.kind.isAudio {
                    Label(block.kind.isAudio && block.react == .nothing ? "Music" : "Reacts to \(block.react.title.lowercased())",
                          systemImage: "waveform")
                        .font(.caption2)
                        .foregroundStyle(tint)
                }
            }
            Spacer()
            HStack(spacing: 3) {
                colorDot(block.colorA)
                if block.kind.usesSecondColor { colorDot(block.colorB) }
            }
            .opacity(block.kind == .vignette || block.kind == .image ? 0 : 1)
            Toggle("On", isOn: $block.enabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(block.enabled ? "Turn this block off" : "Turn this block on")
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleExpand)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isExpanded ? "Collapses the block's settings" : "Shows the block's settings")
    }

    @ViewBuilder
    private var pictureSettings: some View {
        HStack(spacing: 10) {
            Group {
                if let preview = pictureThumbnail {
                    Image(nsImage: preview).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary).overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                }
            }
            .frame(width: 64, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .task(id: block.media) { pictureThumbnail = await Self.thumbnail(of: block.media) }
            Button(block.media == nil ? "Choose Picture…" : "Change Picture…", action: choosePicture)
            Spacer()
        }
        if let pictureError {
            Text(pictureError).font(.caption).foregroundStyle(.red)
        }
        Picker("Layout", selection: Binding(get: { Int(block.detail.rounded()) }, set: { block.detail = Double($0) })) {
            ForEach(BlockKind.imageLayouts.indices, id: \.self) { Text(BlockKind.imageLayouts[$0]).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    /// A small copy of the block's picture, made off the main thread.
    private static func thumbnail(of file: String?) async -> NSImage? {
        guard let file else { return nil }
        let url = LibraryStore.shared.mediaDirectory.appendingPathComponent(file)
        return await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 160,
                  ] as CFDictionary)
            else { return nil }
            return NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        }.value
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Picture"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            block.media = try LibraryStore.shared.importPicture(from: url)
            pictureError = nil
        } catch {
            pictureError = error.localizedDescription
        }
    }

    private func colorDot(_ color: RGBAColor) -> some View {
        Circle().fill(color.color).frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.2)))
    }

    @ViewBuilder
    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            if block.kind == .image {
                pictureSettings
            }
            if block.kind == .text {
                TextField("Text", text: $block.text, prompt: Text("Your words"), axis: .vertical)
                    .lineLimit(1...4)
            }
            if block.kind == .clock {
                Picker("Show", selection: Binding(get: { Int(block.detail.rounded()) }, set: { block.detail = Double($0) })) {
                    ForEach(BlockKind.clockFormats.indices, id: \.self) { Text(BlockKind.clockFormats[$0]).tag($0) }
                }
            }
            if block.kind.isType {
                Picker("Font", selection: $block.font) {
                    ForEach(BlockFont.allCases) { Text($0.title).tag($0) }
                }
            }
            if block.kind != .vignette && block.kind != .image {
                HStack(spacing: 16) {
                    ColorPicker(block.kind.usesSecondColor ? "Colors" : "Color",
                                selection: $block.colorA.swiftUIColor, supportsOpacity: false)
                    if block.kind.usesSecondColor {
                        ColorPicker("", selection: $block.colorB.swiftUIColor, supportsOpacity: false)
                            .labelsHidden()
                    }
                    Spacer()
                }
            }

            if block.kind == .particles {
                Picker("Direction", selection: Binding(get: { Int(block.detail.rounded()) }, set: { block.detail = Double($0) })) {
                    ForEach(BlockKind.directions.indices, id: \.self) { Text(BlockKind.directions[$0]).tag($0) }
                }
            }

            ForEach(block.kind.controls(for: block)) { control in
                SliderRow(title: control.title, value: $block[dynamicMember: control.key], range: control.range,
                          defaultValue: block.kind.makeBlock()[keyPath: control.key], format: control.text)
            }

            if block.kind.showsPosition(for: block) {
                SliderRow(title: "Left – Right", value: $block.x, range: 0...1, defaultValue: 0.5,
                          format: { String(format: "%.0f%%", $0 * 100) })
                SliderRow(title: "Down – Up", value: $block.y, range: 0...1, defaultValue: block.kind.makeBlock().y,
                          format: { String(format: "%.0f%%", $0 * 100) })
            }

            if block.kind != .vignette && block.kind != .gradient {
                HStack {
                    Label("React to", systemImage: "waveform")
                    Spacer()
                    Picker("React to", selection: $block.react) {
                        ForEach(ReactSource.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if block.react != .nothing {
                    SliderRow(title: "Reaction", value: $block.reactStrength, range: 0.2...2, defaultValue: 1,
                              format: { String(format: "%.0f%%", $0 * 100) })
                }
            }

            SliderRow(title: "Opacity", value: $block.opacity, range: 0...1, defaultValue: 1,
                      format: { String(format: "%.0f%%", $0 * 100) })

            HStack {
                Button("Duplicate", systemImage: "plus.square.on.square", action: onDuplicate)
                Spacer()
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }
}

/// The blocks you can add, grouped by what they're for.
struct BlockPalette: View {
    var onPick: (BlockKind) -> Void
    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(BlockCategory.allCases, id: \.self) { category in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(category.rawValue.uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(category.color)
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(BlockKind.allCases.filter { $0.category == category }) { kind in
                                Button { onPick(kind) } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        ZStack {
                                            Circle().fill(category.color.gradient)
                                            Image(systemName: kind.symbol)
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(.white)
                                        }
                                        .frame(width: 24, height: 24)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(kind.title).font(.callout.weight(.semibold))
                                            Text(kind.summary).font(.caption2).foregroundStyle(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.6)))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 440, height: 460)
    }
}

/// Picks a starting point for a new blocks wallpaper.
struct NewBlocksSheet: View {
    var onCreate: (BlockTemplate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var previews: [BlockTemplate: NSImage] = [:]
    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Wallpaper from Blocks").font(.title2.weight(.semibold))
                Text("Pick a starting point. You can change every block afterwards.")
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(BlockTemplate.allCases) { template in
                    Button {
                        onCreate(template)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Group {
                                if let image = previews[template] {
                                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Rectangle().fill(.quaternary)
                                }
                            }
                            .aspectRatio(16 / 10, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Text(template.title).font(.headline)
                            Text(template.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 700)
        .task {
            for template in BlockTemplate.allCases {
                if let image = BlocksRenderer.shared?.snapshot(template.composition, size: CGSize(width: 480, height: 300)) {
                    previews[template] = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
                }
            }
        }
    }
}
