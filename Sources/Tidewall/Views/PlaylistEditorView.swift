import SwiftUI

/// Editor for playlists: what's up now on the left, and the wallpapers with
/// how they take turns on the right.
struct PlaylistEditorContent: View {
    @Binding var wallpaper: Wallpaper
    @State private var showingPicker = false
    private let engine = WallpaperEngine.shared
    private let store = LibraryStore.shared

    private var playlist: Binding<Playlist> {
        Binding(get: { wallpaper.playlist ?? Playlist() }, set: { wallpaper.playlist = $0 })
    }

    private var aspectRatio: CGFloat { engine.displays.first?.aspectRatio ?? 16 / 10 }

    /// What's showing now: from the desktop when the playlist is on it.
    private var showing: PlaylistSchedule.Showing? {
        engine.nowShowing(in: wallpaper)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(-1)
                if playlist.wrappedValue.mode == .timeOfDay, !playlist.wrappedValue.items.isEmpty {
                    DayTimeline(items: store.playableItems(of: playlist.wrappedValue))
                        .frame(height: 64)
                }
            }
            .padding(24)
            .frame(minWidth: 440)

            Divider()

            itemsColumn
                .frame(width: 380)
        }
        .navigationTitle(wallpaper.name)
        .navigationSubtitle(engine.displays(showing: wallpaper.id).isEmpty ? "Playlist" : "On Desktop")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                SetWallpaperButton(wallpaperID: wallpaper.id)
                Menu {
                    Button("Duplicate") {
                        if let copy = store.duplicate(wallpaper.id) { AppDelegate.shared.navigation.edit(copy.id) }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: Preview

    @ViewBuilder
    private var preview: some View {
        let current = showing.flatMap { store.wallpaper(id: $0.item.wallpaperID) }
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if let current {
                    WallpaperThumbnail(wallpaper: current)
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay {
                            Label("Add wallpapers to start the playlist", systemImage: "rectangle.stack.badge.plus")
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .aspectRatio(aspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12))
            }
            .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let current, let showing {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Now: \(current.name)").font(.headline)
                        Text(nextChangeText(showing)).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if engine.canSkip(wallpaper.id), !engine.displays(showing: wallpaper.id).isEmpty {
                        Button("Next Wallpaper", systemImage: "forward.fill") { engine.skip(wallpaper.id) }
                    }
                }
            }
        }
    }

    private func nextChangeText(_ showing: PlaylistSchedule.Showing) -> String {
        guard let next = showing.nextChange else { return "Stays on until you add another wallpaper" }
        let time = next.formatted(date: Calendar.current.isDateInToday(next) ? .omitted : .abbreviated, time: .shortened)
        return engine.displays(showing: wallpaper.id).isEmpty
            ? "Set the playlist as your wallpaper to start it"
            : "Next change at \(time)"
    }

    // MARK: Items

    private var itemsColumn: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Name", text: $wallpaper.name)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                Picker("Change", selection: playlist.mode) {
                    ForEach(Playlist.Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch playlist.wrappedValue.mode {
                case .interval:
                    HStack {
                        Picker("Every", selection: playlist.interval) {
                            ForEach(Playlist.intervals, id: \.seconds) { Text($0.title).tag($0.seconds) }
                        }
                        .fixedSize()
                        Spacer()
                        Toggle("Shuffle", isOn: playlist.shuffle)
                    }
                case .timeOfDay:
                    Text("Each wallpaper takes over at its time and stays until the next one, every day.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if playlist.wrappedValue.items.isEmpty {
                ContentUnavailableView {
                    Label("No Wallpapers Yet", systemImage: "rectangle.stack")
                } description: {
                    Text("Pick the wallpapers this playlist takes turns showing.")
                } actions: {
                    Button("Add Wallpapers…") { showingPicker = true }
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(playlist.items) { $item in
                        PlaylistRow(item: $item, mode: playlist.wrappedValue.mode,
                                    isShowing: showing?.item.id == item.id,
                                    onRemove: { remove(item) })
                            .listRowSeparator(.hidden)
                    }
                    .onMove { from, to in playlist.wrappedValue.items.move(fromOffsets: from, toOffset: to) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            Divider()
            HStack {
                Button {
                    showingPicker = true
                } label: {
                    Label("Add Wallpapers", systemImage: "plus.circle.fill").font(.body.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .popover(isPresented: $showingPicker, arrowEdge: .top) {
                    PlaylistPicker(playlist: playlist, onAdd: add)
                }
                Spacer()
                let count = playlist.wrappedValue.items.count
                Text(count == 1 ? "1 wallpaper" : "\(count) wallpapers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .background(.background)
    }

    private func add(_ id: UUID) {
        let starts = playlist.wrappedValue.items.map(\.start)
        withAnimation(.snappy) {
            playlist.wrappedValue.items.append(PlaylistItem(wallpaperID: id, start: Self.startInLargestGap(starts)))
        }
    }

    private func remove(_ item: PlaylistItem) {
        withAnimation(.snappy) { playlist.wrappedValue.items.removeAll { $0.id == item.id } }
    }

    /// A new wallpaper's time: the middle of the longest stretch of the day
    /// that one wallpaper has to itself, on the quarter hour.
    static func startInLargestGap(_ starts: [Int]) -> Int {
        let day = 24 * 60
        let sorted = starts.map { (($0 % day) + day) % day }.sorted()
        guard let first = sorted.first else { return 7 * 60 }
        var best = (start: first, length: day - sorted.last! + first)
        for (a, b) in zip(sorted, sorted.dropFirst()) where b - a > best.length { best = (a, b - a) }
        if sorted.count > 1, day - sorted.last! + first > best.length { best = (sorted.last!, day - sorted.last! + first) }
        let middle = best.start + best.length / 2
        return ((middle + 7) / 15 * 15) % day
    }
}

/// One wallpaper in the playlist.
private struct PlaylistRow: View {
    @Binding var item: PlaylistItem
    let mode: Playlist.Mode
    let isShowing: Bool
    var onRemove: () -> Void
    private let store = LibraryStore.shared

    private var startTime: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: item.start / 60, minute: item.start % 60, second: 0, of: .now) ?? .now },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                item.start = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            })
    }

    var body: some View {
        let wallpaper = store.wallpaper(id: item.wallpaperID)
        HStack(spacing: 10) {
            Group {
                if let wallpaper {
                    WallpaperThumbnail(wallpaper: wallpaper)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 64, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(wallpaper?.name ?? "Missing wallpaper").lineLimit(1)
                if isShowing {
                    Label("Showing now", systemImage: "play.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
            }
            Spacer()
            if mode == .timeOfDay {
                DatePicker("Starts at", selection: startTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.field)
            }
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove from the playlist")
        }
        .padding(.vertical, 4)
    }
}

/// The library as a grid of tiles that go in or out of the playlist.
private struct PlaylistPicker: View {
    @Binding var playlist: Playlist
    var onAdd: (UUID) -> Void
    private let store = LibraryStore.shared
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        let candidates = store.wallpapers.filter { !$0.isPlaylist }
        ScrollView {
            if candidates.isEmpty {
                Text("Your library has no wallpapers to add yet.")
                    .foregroundStyle(.secondary)
                    .padding(40)
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(candidates) { wallpaper in
                    let included = playlist.items.contains { $0.wallpaperID == wallpaper.id }
                    Button {
                        if included {
                            withAnimation(.snappy) { playlist.items.removeAll { $0.wallpaperID == wallpaper.id } }
                        } else {
                            onAdd(wallpaper.id)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            WallpaperThumbnail(wallpaper: wallpaper)
                                .aspectRatio(16 / 10, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(included ? Color.accentColor : Color.primary.opacity(0.1),
                                                      lineWidth: included ? 2.5 : 1)
                                }
                                .overlay(alignment: .topTrailing) {
                                    if included {
                                        Image(systemName: "checkmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, Color.accentColor)
                                            .padding(5)
                                    }
                                }
                            Text(wallpaper.name).font(.caption).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(included ? .isSelected : [])
                }
            }
            .padding(14)
        }
        .frame(width: 460, height: 380)
    }
}

/// The day from midnight to midnight, split into who shows when.
private struct DayTimeline: View {
    let items: [PlaylistItem]
    private let store = LibraryStore.shared
    private static let colors: [Color] = [.blue, .orange, .purple, .green, .pink, .teal, .yellow, .red]

    var body: some View {
        let day = 24 * 60
        let sorted = items.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
        TimelineView(.everyMinute) { context in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: context.date)
            let now = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    let width = geo.size.width
                    ZStack(alignment: .topLeading) {
                        // The last wallpaper of the day carries on past midnight.
                        if let last = sorted.last {
                            segment(last.offset, from: 0, to: sorted.first!.element.start, width: width)
                        }
                        ForEach(Array(sorted.enumerated()), id: \.offset) { position, entry in
                            let end = position + 1 < sorted.count ? sorted[position + 1].element.start : day
                            segment(entry.offset, from: entry.element.start, to: end, width: width)
                        }
                        Rectangle()
                            .fill(.primary)
                            .frame(width: 2, height: geo.size.height + 6)
                            .offset(x: width * CGFloat(now) / CGFloat(day) - 1, y: -3)
                    }
                }
                .frame(height: 28)
                HStack(spacing: 0) {
                    let labels = ["12 AM", "6 AM", "12 PM", "6 PM", "12 AM"]
                    ForEach(labels.indices, id: \.self) { i in
                        Text(labels[i]).font(.caption2).foregroundStyle(.secondary)
                        if i < labels.count - 1 { Spacer(minLength: 0) }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Schedule for the day")
    }

    @ViewBuilder
    private func segment(_ index: Int, from start: Int, to end: Int, width: CGFloat) -> some View {
        let day = CGFloat(24 * 60)
        if end > start {
            let color = Self.colors[index % Self.colors.count]
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color.opacity(0.75))
                .overlay(alignment: .leading) {
                    Text(store.wallpaper(id: items[index].wallpaperID)?.name ?? "")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                }
                .clipped()
                .frame(width: max(1, width * CGFloat(end - start) / day - 1), height: 28)
                .offset(x: width * CGFloat(start) / day)
        }
    }
}

/// A playlist's card picture: its first few wallpapers, tiled.
struct PlaylistThumbnail: View {
    let wallpaper: Wallpaper
    private let store = LibraryStore.shared

    var body: some View {
        let members = (wallpaper.playlist.map(store.playableItems) ?? [])
            .compactMap { store.wallpaper(id: $0.wallpaperID) }
            .prefix(4)
        ZStack {
            Rectangle().fill(.quaternary)
            if members.isEmpty {
                Image(systemName: "rectangle.stack")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            } else {
                let tiles = Array(members).map { WallpaperThumbnail(wallpaper: $0) }
                switch tiles.count {
                case 1: tiles[0]
                case 2: HStack(spacing: 2) { tiles[0]; tiles[1] }
                case 3: HStack(spacing: 2) { tiles[0]; VStack(spacing: 2) { tiles[1]; tiles[2] } }
                default:
                    VStack(spacing: 2) {
                        HStack(spacing: 2) { tiles[0]; tiles[1] }
                        HStack(spacing: 2) { tiles[2]; tiles[3] }
                    }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "rectangle.stack.fill")
                .font(.caption.weight(.semibold))
                .padding(5)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .padding(6)
        }
    }
}
