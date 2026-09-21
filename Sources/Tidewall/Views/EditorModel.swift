import AVFoundation
import Observation

/// Drives the editor's preview: its own muted player, the playhead, the
/// filmstrip and frame-accurate scrubbing while loop points are dragged.
@MainActor
@Observable
final class EditorModel {
    let player: LoopingPlayer
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = true
    private(set) var filmstrip: [CGImage] = []
    /// A rendered frame shown over the preview while a trim handle is dragged.
    private(set) var scrubFrame: CGImage?

    @ObservationIgnored private let url: URL
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private let scrubGenerator: AVAssetImageGenerator
    @ObservationIgnored private var scrubTask: Task<Void, Never>?
    @ObservationIgnored private var pendingScrub: (time: Double, wallpaper: Wallpaper, size: CGSize)?
    @ObservationIgnored private var scrubGeneration = 0

    init(wallpaper: Wallpaper) {
        url = LibraryStore.shared.mediaURL(for: wallpaper)
        player = LoopingPlayer(wallpaper: wallpaper, url: url, forceMuted: true)
        player.setPlaying(true)

        scrubGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        scrubGenerator.appliesPreferredTrackTransform = true
        scrubGenerator.maximumSize = CGSize(width: 1280, height: 1280)
        let tolerance = CMTime(seconds: 0.04, preferredTimescale: 600)
        scrubGenerator.requestedTimeToleranceBefore = tolerance
        scrubGenerator.requestedTimeToleranceAfter = tolerance

        timeObserver = player.player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 24), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.seconds.isFinite else { return }
                self.currentTime = time.seconds
            }
        }
    }

    func tearDown() {
        if let timeObserver { player.player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        scrubTask?.cancel()
        player.invalidate()
    }

    func update(_ wallpaper: Wallpaper) {
        player.update(wallpaper)
    }

    func loadFilmstrip(duration: Double) async {
        guard filmstrip.isEmpty else { return }
        filmstrip = await FrameGrabber.filmstrip(of: url, duration: duration, count: 14, height: 72)
    }

    // MARK: Transport

    func togglePlayback() {
        isPlaying.toggle()
        player.setPlaying(isPlaying)
    }

    func seek(to seconds: Double) {
        player.seek(to: seconds)
        currentTime = seconds
    }

    // MARK: Scrubbing

    /// Shows the frame at `time` exactly as the desktop would. Requests are
    /// coalesced so dragging never queues up more than one decode.
    func scrub(to time: Double, wallpaper: Wallpaper, size: CGSize) {
        pendingScrub = (time, wallpaper, size)
        guard scrubTask == nil else { return }
        let generation = scrubGeneration
        scrubTask = Task { [weak self] in
            while let self, let request = self.pendingScrub, generation == self.scrubGeneration {
                self.pendingScrub = nil
                let cmTime = CMTime(seconds: request.time, preferredTimescale: 600)
                guard let frame = try? await self.scrubGenerator.image(at: cmTime).image else { continue }
                let settings = request.wallpaper.settings
                let rendered = await Task.detached(priority: .userInitiated) {
                    FramePipeline.renderScreen(frame: frame, pixelSize: request.size, settings: settings)
                }.value
                if generation == self.scrubGeneration { self.scrubFrame = rendered }
            }
            self?.scrubTask = nil
        }
    }

    func endScrub(seekTo time: Double?) {
        scrubGeneration += 1
        pendingScrub = nil
        scrubTask?.cancel()
        scrubTask = nil
        scrubFrame = nil
        if let time {
            // The player rebuilds its loop shortly after trim changes; land on
            // the new loop point once it has.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(320))
                self?.seek(to: time)
            }
        }
    }
}
