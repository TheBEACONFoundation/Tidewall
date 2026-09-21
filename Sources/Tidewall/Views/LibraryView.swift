import SwiftUI
import UniformTypeIdentifiers

struct LibraryRootView: View {
    @Bindable var navigation: LibraryNavigation
    private let store = LibraryStore.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.section) {
                Label("Wallpapers", systemImage: "square.grid.2x2")
                    .tag(LibraryNavigation.Section.wallpapers)
                Label("Displays", systemImage: "display.2")
                    .tag(LibraryNavigation.Section.displays)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
            .safeAreaInset(edge: .bottom) {
                PlaybackStatusView()
                    .padding(12)
            }
        } detail: {
            switch navigation.section ?? .wallpapers {
            case .wallpapers:
                NavigationStack(path: $navigation.path) {
                    LibraryGridView(navigation: navigation)
                        .navigationDestination(for: UUID.self) { id in
                            WallpaperEditorView(wallpaperID: id)
                        }
                }
            case .displays:
                DisplaysView()
            }
        }
        .alert("Couldn't Import", isPresented: Binding(
            get: { !store.importErrors.isEmpty },
            set: { if !$0 { store.importErrors.removeAll() } }
        )) {
            Button("OK") { store.importErrors.removeAll() }
        } message: {
            Text(store.importErrors.joined(separator: "\n\n"))
        }
    }
}

/// Sidebar footer: what's playing, with a pause toggle.
private struct PlaybackStatusView: View {
    private let engine = WallpaperEngine.shared

    var body: some View {
        let activeCount = engine.displays.filter { engine.wallpaperID(for: $0.id) != nil }.count
        HStack(spacing: 10) {
            Button {
                engine.isUserPaused.toggle()
            } label: {
                Label(engine.isUserPaused ? "Resume" : "Pause",
                      systemImage: engine.isUserPaused ? "play.fill" : "pause.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .disabled(activeCount == 0)
            .help(engine.isUserPaused ? "Resume wallpapers" : "Pause wallpapers")

            VStack(alignment: .leading, spacing: 1) {
                Text(activeCount == 0 ? "No live wallpaper" : (engine.pauseReason == nil ? "Playing" : "Paused"))
                    .font(.callout.weight(.medium))
                Text(statusDetail(activeCount: activeCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    private func statusDetail(activeCount: Int) -> String {
        if activeCount == 0 { return "Pick a wallpaper to start" }
        if let reason = engine.pauseReason, reason != .user { return reason.title }
        if engine.isPausedWhileHidden { return "Paused while windows cover it" }
        return activeCount == 1 ? "On 1 display" : "On \(activeCount) displays"
    }
}

struct LibraryGridView: View {
    @Bindable var navigation: LibraryNavigation
    private let store = LibraryStore.shared
    private let engine = WallpaperEngine.shared

    @State private var searchText = ""
    @State private var isDropTargeted = false
    @State private var pendingDeletion: Wallpaper?

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: 22)]

    private var filtered: [Wallpaper] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.wallpapers }
        return store.wallpapers.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Group {
            if store.wallpapers.isEmpty && store.importsInProgress == 0 {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 26) {
                        ForEach(filtered) { wallpaper in
                            WallpaperCard(
                                wallpaper: wallpaper,
                                isSelected: navigation.selection == wallpaper.id,
                                activeDisplays: engine.displays(showing: wallpaper.id),
                                onEdit: { navigation.edit(wallpaper.id) })
                            .onTapGesture(count: 2) { navigation.edit(wallpaper.id) }
                            .onTapGesture { navigation.selection = wallpaper.id }
                            .contextMenu { contextMenu(for: wallpaper) }
                        }
                        if store.importsInProgress > 0 {
                            ImportingCard()
                        }
                    }
                    .padding(24)
                }
                .background {
                    // Clicking empty space clears the selection.
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { navigation.selection = nil }
                }
            }
        }
        .navigationTitle("Wallpapers")
        .navigationSubtitle(subtitle)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Import Videos or GIFs…") { store.presentImportPanel() }
                    Divider()
                    Section("Built-in Wallpapers") {
                        ForEach(BuiltInWallpaper.all) { builtIn in
                            Button(builtIn.name) { Task { await store.addBuiltIn(builtIn) } }
                        }
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                } primaryAction: {
                    store.presentImportPanel()
                }
                .help("Import videos, or add a built-in wallpaper")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            Task { await store.importFiles(files) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        Label("Drop to Import", systemImage: "square.and.arrow.down")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .onDeleteCommand {
            if let selected = store.wallpaper(id: navigation.selection) { pendingDeletion = selected }
        }
        .confirmationDialog(
            "Delete “\(pendingDeletion?.name ?? "")”?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let wallpaper = pendingDeletion { store.delete([wallpaper.id]) }
                pendingDeletion = nil
            }
        } message: {
            Text("The video file is moved to the Trash.")
        }
    }

    private var subtitle: String {
        let count = store.wallpapers.count
        return count == 1 ? "1 wallpaper" : "\(count) wallpapers"
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Wallpapers Yet", systemImage: "film.stack")
        } description: {
            Text("Drop videos, GIFs or animated images here, or import them from your Mac.")
        } actions: {
            Button("Import Wallpapers…") { store.presentImportPanel() }
                .buttonStyle(.borderedProminent)
            Button("Add Built-in Wallpapers") {
                Task {
                    for builtIn in BuiltInWallpaper.all { await store.addBuiltIn(builtIn) }
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for wallpaper: Wallpaper) -> some View {
        Button("Set as Wallpaper on All Displays") { engine.setWallpaper(wallpaper.id) }
        if engine.displays.count > 1 {
            Menu("Set as Wallpaper On") {
                ForEach(engine.displays) { display in
                    Button(display.name) { engine.setWallpaper(wallpaper.id, for: display.id) }
                }
            }
        }
        Divider()
        Button("Edit") { navigation.edit(wallpaper.id) }
        Button("Duplicate") {
            if let copy = store.duplicate(wallpaper.id) { navigation.selection = copy.id }
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([store.mediaURL(for: wallpaper)])
        }
        Divider()
        Button("Delete…", role: .destructive) { pendingDeletion = wallpaper }
    }
}

private struct WallpaperCard: View {
    let wallpaper: Wallpaper
    let isSelected: Bool
    let activeDisplays: [Display]
    let onEdit: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WallpaperThumbnail(wallpaper: wallpaper)
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    if !activeDisplays.isEmpty {
                        Label(activeLabel, systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(8)
                    }
                }
                .overlay(alignment: .bottom) {
                    if isHovering {
                        HStack(spacing: 8) {
                            SetWallpaperButton(wallpaperID: wallpaper.id, title: "Set")
                            Button(action: onEdit) {
                                Label("Edit", systemImage: "slider.horizontal.3")
                            }
                        }
                        .controlSize(.small)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                                   startPoint: .top, endPoint: .bottom))
                        .transition(.opacity)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                                      lineWidth: isSelected ? 3 : 1)
                }
                .shadow(color: .black.opacity(isHovering ? 0.25 : 0.12), radius: isHovering ? 10 : 4, y: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(wallpaper.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
    }

    private var detailText: String {
        let range = wallpaper.loopRange
        let length = range.upperBound - range.lowerBound
        let trimmed = length < wallpaper.duration - 0.05 ? "Trimmed · " : ""
        let battery = wallpaper.isBatteryReactive ? "Follows battery · " : ""
        return "\(battery)\(trimmed)\(length.shortDuration) · \(wallpaper.resolutionDescription)"
    }

    private var activeLabel: String {
        if activeDisplays.count == 1, WallpaperEngine.shared.displays.count > 1 {
            return activeDisplays[0].name
        }
        return "On Desktop"
    }
}

private struct ImportingCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary)
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Importing…").font(.callout).foregroundStyle(.secondary)
                    }
                }
            Text(" ").font(.headline)
        }
    }
}
