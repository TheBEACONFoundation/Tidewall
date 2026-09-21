import Foundation

/// A wallpaper that shows other wallpapers in turn: one after another on a
/// timer, or each at its own time of day (say, a day look and a night look).
struct Playlist: Codable, Hashable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case interval, timeOfDay

        var id: String { rawValue }

        var title: String {
            switch self {
            case .interval: "On a Timer"
            case .timeOfDay: "By Time of Day"
            }
        }
    }

    var mode: Mode = .interval
    var items: [PlaylistItem] = []
    /// How long each wallpaper shows, in seconds (`.interval` mode).
    var interval: TimeInterval = 30 * 60
    var shuffle = false

    static let intervals: [(seconds: TimeInterval, title: String)] = [
        (60, "1 minute"), (5 * 60, "5 minutes"), (15 * 60, "15 minutes"), (30 * 60, "30 minutes"),
        (60 * 60, "1 hour"), (3 * 60 * 60, "3 hours"), (6 * 60 * 60, "6 hours"), (24 * 60 * 60, "1 day"),
    ]

    var intervalTitle: String {
        Self.intervals.first { $0.seconds == interval }?.title ?? "\(Int(interval / 60)) minutes"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Playlist()
        mode = try c.decode(.mode, default: d.mode)
        items = try c.decode(.items, default: d.items)
        interval = try c.decode(.interval, default: d.interval)
        shuffle = try c.decode(.shuffle, default: d.shuffle)
    }

    /// Start times for `count` wallpapers spread over the day from 7 AM:
    /// two make a day and a night look.
    static func spreadStarts(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let step = 24 * 60 / count
        return (0..<count).map { (7 * 60 + $0 * step) % (24 * 60) }
    }
}

struct PlaylistItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var wallpaperID: UUID
    /// Minutes after midnight when this wallpaper takes over (`.timeOfDay` mode).
    var start = 7 * 60

    init(wallpaperID: UUID, start: Int = 7 * 60) {
        self.wallpaperID = wallpaperID
        self.start = start
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(.id, default: UUID())
        wallpaperID = try c.decode(UUID.self, forKey: .wallpaperID)
        start = try c.decode(.start, default: 7 * 60)
    }
}

/// How far a timer playlist has got: `position` steps, counted from `anchor`.
/// Kept apart from the library, so moving on never counts as an edit.
struct PlaylistProgress: Codable, Equatable {
    var anchor: Date
    var position = 0
}

/// Works out which wallpaper a playlist shows at a given moment. Timer
/// playlists are a pure function of their progress and the clock, so they
/// carry on where they were after a restart, and shuffles repeat nothing
/// until every wallpaper has had its turn.
enum PlaylistSchedule {
    struct Showing: Equatable {
        /// Index into the items passed in.
        var index: Int
        var item: PlaylistItem
        /// When the next wallpaper takes over; nil if nothing ever changes.
        var nextChange: Date?
    }

    /// - Parameter items: the playlist's playable items, in order.
    static func showing(_ playlist: Playlist, items: [PlaylistItem], seed: UUID, progress: PlaylistProgress,
                        at date: Date, calendar: Calendar = .current) -> Showing? {
        guard !items.isEmpty else { return nil }
        switch playlist.mode {
        case .interval:
            let interval = max(60, playlist.interval)
            let steps = max(0, Int(date.timeIntervalSince(progress.anchor) / interval))
            let index = self.index(atSlot: max(0, progress.position + steps), count: items.count,
                                   shuffle: playlist.shuffle, seed: seed)
            let next = items.count > 1 ? progress.anchor.addingTimeInterval(Double(steps + 1) * interval) : nil
            return Showing(index: index, item: items[index], nextChange: next)
        case .timeOfDay:
            let order = items.indices.sorted { (items[$0].start, $0) < (items[$1].start, $1) }
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            // The last one to start today, or else the last one yesterday.
            let index = order.last { items[$0].start <= minute } ?? order.last!
            let starts = Set(items.map(\.start))
            guard starts.count > 1 else { return Showing(index: index, item: items[index], nextChange: nil) }
            let nextStart = starts.sorted().first { $0 > minute }
            let day = calendar.startOfDay(for: date)
            let nextDay = nextStart == nil ? calendar.date(byAdding: .day, value: 1, to: day) ?? day : day
            let start = nextStart ?? starts.min()!
            let next = calendar.date(bySettingHour: start / 60, minute: start % 60, second: 0, of: nextDay)
            return Showing(index: index, item: items[index], nextChange: next)
        }
    }

    /// The item shown at step `slot` of a timer playlist.
    static func index(atSlot slot: Int, count: Int, shuffle: Bool, seed: UUID) -> Int {
        guard shuffle, count > 2 else { return slot % count }
        return order(count: count, cycle: slot / count, seed: seed)[slot % count]
    }

    /// Progress that shows item `index` from `date` on, for a full turn.
    static func progress(showing index: Int, count: Int, shuffle: Bool, seed: UUID, at date: Date) -> PlaylistProgress {
        let position = shuffle && count > 2 ? order(count: count, cycle: 0, seed: seed).firstIndex(of: index) ?? 0 : index
        return PlaylistProgress(anchor: date, position: position)
    }

    /// One shuffled pass through `count` items. The same seed and cycle
    /// always give the same order, and a pass never starts with the
    /// wallpaper the previous one ended on.
    static func order(count: Int, cycle: Int, seed: UUID) -> [Int] {
        var order = rawOrder(count: count, cycle: cycle, seed: seed)
        if cycle > 0, count > 2, order[0] == rawOrder(count: count, cycle: cycle - 1, seed: seed)[count - 1] {
            order.swapAt(0, 1)
        }
        return order
    }

    private static func rawOrder(count: Int, cycle: Int, seed: UUID) -> [Int] {
        var generator = SplitMix64(seed: seed, cycle: cycle)
        var order = Array(0..<count)
        for i in stride(from: count - 1, to: 0, by: -1) {
            order.swapAt(i, Int(generator.next() % UInt64(i + 1)))
        }
        return order
    }
}

/// A tiny seeded random generator: `Hasher` is seeded per launch, so it
/// can't give the same shuffle twice.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UUID, cycle: Int) {
        let b = seed.uuid
        let high = [b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let low = [b.8, b.9, b.10, b.11, b.12, b.13, b.14, b.15].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        state = high ^ (low &* 0x9E37_79B9_7F4A_7C15) ^ UInt64(truncatingIfNeeded: cycle) &* 0xBF58_476D_1CE4_E5B9
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
