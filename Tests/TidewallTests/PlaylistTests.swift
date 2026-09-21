import Foundation
import Testing
@testable import Tidewall

@Suite("Playlists")
@MainActor
struct PlaylistTests {
    private let seed = UUID()
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func items(_ count: Int, starts: [Int]? = nil) -> [PlaylistItem] {
        (0..<count).map { PlaylistItem(wallpaperID: UUID(), start: starts?[$0] ?? 0) }
    }

    private func date(_ hour: Int, _ minute: Int = 0, day: Int = 21) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    @Test func timerPlaylistsTakeTurnsInOrder() {
        var playlist = Playlist()
        playlist.interval = 600
        let list = items(3)
        let start = date(9)
        let progress = PlaylistProgress(anchor: start)
        let shown = (0..<7).map { step in
            PlaylistSchedule.showing(playlist, items: list, seed: seed, progress: progress,
                                     at: start.addingTimeInterval(Double(step) * 600 + 30))!.index
        }
        #expect(shown == [0, 1, 2, 0, 1, 2, 0])
        let now = PlaylistSchedule.showing(playlist, items: list, seed: seed, progress: progress, at: start.addingTimeInterval(1250))
        #expect(now?.nextChange == start.addingTimeInterval(1800))
    }

    @Test func aSingleWallpaperNeverChanges() {
        let now = PlaylistSchedule.showing(Playlist(), items: items(1), seed: seed,
                                           progress: PlaylistProgress(anchor: date(9)), at: date(18))
        #expect(now?.index == 0)
        #expect(now?.nextChange == nil)
    }

    @Test func shuffleShowsEveryWallpaperOncePerPassWithoutRepeats() {
        let count = 5
        var sequence: [Int] = []
        for slot in 0..<(count * 40) {
            sequence.append(PlaylistSchedule.index(atSlot: slot, count: count, shuffle: true, seed: seed))
        }
        for pass in 0..<40 {
            #expect(Set(sequence[pass * count..<(pass + 1) * count]) == Set(0..<count))
        }
        #expect(zip(sequence, sequence.dropFirst()).allSatisfy { $0 != $1 }, "never the same one twice in a row")
        #expect(sequence != Array((0..<(count * 40)).map { $0 % count }), "actually shuffled")
        // The same seed gives the same order after a restart.
        #expect(PlaylistSchedule.order(count: count, cycle: 7, seed: seed) == PlaylistSchedule.order(count: count, cycle: 7, seed: seed))
    }

    @Test func skippingKeepsTheChosenWallpaper() {
        for shuffle in [false, true] {
            var playlist = Playlist()
            playlist.shuffle = shuffle
            let list = items(6)
            let progress = PlaylistSchedule.progress(showing: 4, count: 6, shuffle: shuffle, seed: seed, at: date(10))
            let now = PlaylistSchedule.showing(playlist, items: list, seed: seed, progress: progress, at: date(10, 5))
            #expect(now?.index == 4)
        }
    }

    @Test func timeOfDayFollowsTheClock() {
        var playlist = Playlist()
        playlist.mode = .timeOfDay
        // Morning at 7:00, evening at 19:30, listed out of order.
        let list = items(2, starts: [19 * 60 + 30, 7 * 60])
        func at(_ date: Date) -> PlaylistSchedule.Showing {
            PlaylistSchedule.showing(playlist, items: list, seed: seed, progress: PlaylistProgress(anchor: date),
                                     at: date, calendar: calendar)!
        }
        #expect(at(date(12)).index == 1)
        #expect(at(date(12)).nextChange == date(19, 30))
        #expect(at(date(20)).index == 0)
        #expect(at(date(20)).nextChange == date(7, day: 22), "tomorrow morning")
        #expect(at(date(3)).index == 0, "before the first start, last night's carries on")
        #expect(at(date(7)).index == 1, "takes over on the minute")
    }

    @Test func newItemsGoInTheLongestGap() {
        #expect(PlaylistEditorContent.startInLargestGap([]) == 7 * 60)
        #expect(PlaylistEditorContent.startInLargestGap([7 * 60]) == 19 * 60)
        #expect(PlaylistEditorContent.startInLargestGap([7 * 60, 19 * 60]) == 13 * 60)
        #expect(Playlist.spreadStarts(count: 2) == [7 * 60, 19 * 60])
    }

    @Test func deletingAWallpaperTakesItOutOfPlaylists() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TidewallPlaylist-\(UUID().uuidString)")
        let store = LibraryStore(rootURL: root)
        store.load()
        let a = store.createBlocksWallpaper(from: .ocean), b = store.createBlocksWallpaper(from: .synthwave)
        let playlist = store.createPlaylist(with: [a.id, b.id])
        let nested = store.createPlaylist(with: [playlist.id, a.id])
        #expect(nested.playlist?.items.count == 1, "playlists can't contain playlists")
        store.delete([a.id])
        #expect(store.wallpaper(id: playlist.id)?.playlist?.items.map(\.wallpaperID) == [b.id])

        // Saved and loaded again, playlists survive (they have no video file).
        store.saveNow()
        let reloaded = LibraryStore(rootURL: root)
        reloaded.load()
        #expect(reloaded.wallpaper(id: playlist.id)?.playlist?.items.count == 1)
    }
}
