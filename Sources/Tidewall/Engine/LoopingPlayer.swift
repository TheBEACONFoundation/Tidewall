import AVFoundation
import CoreImage

/// Seamlessly loops (a trimmed range of) a video with the wallpaper's playback
/// and color settings. One instance can drive any number of player layers, so
/// displays showing the same wallpaper share a single decoder.
@MainActor
final class LoopingPlayer {
    let player = AVQueuePlayer()
    let url: URL
    private(set) var wallpaper: Wallpaper
    private(set) var isPlaying = false

    private let asset: AVURLAsset
    private let adjustmentsBox: AdjustmentsBox
    private var looper: AVPlayerLooper?
    private var composition: AVVideoComposition?
    private var compositionTask: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?
    private var queueObservation: NSKeyValueObservation?
    private var trackObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private let forceMuted: Bool

    /// - Parameter forceMuted: used by the editor preview so it never plays
    ///   audio on top of the desktop.
    init(wallpaper: Wallpaper, url: URL, forceMuted: Bool = false) {
        self.wallpaper = wallpaper
        self.url = url
        self.forceMuted = forceMuted
        asset = AVURLAsset(url: url)
        adjustmentsBox = AdjustmentsBox(wallpaper.settings.adjustments)

        // A wallpaper must never keep the display awake or hog AirPlay.
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.allowsExternalPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false
        applyAudio()
        player.defaultRate = Float(wallpaper.settings.speed)

        // The looper fills its queue asynchronously and recycles a few item
        // copies, whose tracks load in the background. Watch each copy as it
        // shows up so it's configured before it starts playing.
        queueObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.watchQueuedItems() }
            }
        }

        buildLooper()
        updateComposition()
    }

    func invalidate() {
        rebuildTask?.cancel()
        compositionTask?.cancel()
        queueObservation = nil
        trackObservations = [:]
        looper?.disableLooping()
        looper = nil
        player.pause()
        player.removeAllItems()
    }

    // MARK: Settings

    func update(_ new: Wallpaper) {
        let old = wallpaper.settings
        wallpaper = new
        let s = new.settings

        if old.trimStart != s.trimStart || old.trimEnd != s.trimEnd {
            scheduleRebuild()
        }
        if old.speed != s.speed {
            player.defaultRate = Float(s.speed)
            if isPlaying { player.rate = Float(s.speed) }
        }
        if old.muted != s.muted || old.volume != s.volume {
            applyAudio()
        }
        if old.adjustments != s.adjustments {
            adjustmentsBox.current = s.adjustments
            updateComposition()
            if !isPlaying { redrawCurrentFrame() }
        }
    }

    // MARK: Transport

    func setPlaying(_ playing: Bool) {
        isPlaying = playing
        if playing {
            if player.rate == 0 { player.play() }
        } else {
            player.pause()
        }
    }

    var currentTime: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? t : 0
    }

    /// Loads the first item and lands on the position `time()` reports once
    /// loaded, so a replacement player can take over mid-loop without a black
    /// frame or a jump.
    func prepare(at time: () -> Double) async {
        let deadline = Date.now.addingTimeInterval(3)
        // Wait for the filters too, so no unfiltered frame reaches the screen.
        while player.currentItem?.status != .readyToPlay
                || (!wallpaper.settings.adjustments.isIdentity && player.currentItem?.videoComposition == nil),
              Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let seconds = time()
        let range = wallpaper.loopRange
        let target = min(max(seconds, range.lowerBound), max(range.lowerBound, range.upperBound - 0.05))
        await player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                          toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(to seconds: Double) {
        let range = wallpaper.loopRange
        let clamped = min(max(seconds, range.lowerBound), max(range.lowerBound, range.upperBound - 0.05))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Looping

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.buildLooper()
        }
    }

    private func buildLooper() {
        looper?.disableLooping()
        player.removeAllItems()
        trackObservations = [:]

        let template = AVPlayerItem(asset: asset)
        configure(template)

        let range = wallpaper.loopRange
        let isFullLength = range.lowerBound <= 0.001 && range.upperBound >= wallpaper.duration - 0.001
        let timeRange: CMTimeRange = isFullLength
            ? .invalid
            : CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                          end: CMTime(seconds: range.upperBound, preferredTimescale: 600))

        let looper = AVPlayerLooper(player: player, templateItem: template, timeRange: timeRange)
        looper.loopingPlayerItems.forEach(configure)
        self.looper = looper
        watchQueuedItems()

        if isPlaying { player.play() }
    }

    private func configure(_ item: AVPlayerItem) {
        let wanted = wallpaper.settings.adjustments.isIdentity ? nil : composition
        if item.videoComposition !== wanted {
            item.videoComposition = wanted
        }
        configureAudioTracks(of: item)
    }

    private func watchQueuedItems() {
        for item in allItems where trackObservations[ObjectIdentifier(item)] == nil {
            trackObservations[ObjectIdentifier(item)] = item.observe(\.tracks, options: [.initial, .new]) { [weak self] item, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.configure(item) }
                }
            }
        }
    }

    private var allItems: [AVPlayerItem] {
        (looper?.loopingPlayerItems ?? []) + player.items()
    }

    // MARK: Color adjustments

    /// Filters only run while an adjustment is active; otherwise frames go
    /// straight from the hardware decoder to the layer.
    private func updateComposition() {
        guard !wallpaper.settings.adjustments.isIdentity else {
            allItems.forEach(configure)
            return
        }
        if composition != nil {
            allItems.forEach(configure)
            return
        }
        guard compositionTask == nil else { return }

        let box = adjustmentsBox
        let asset = self.asset
        compositionTask = Task { [weak self] in
            let composition = try? await AVVideoComposition.videoComposition(
                with: asset,
                applyingCIFiltersWithHandler: { request in
                    let output = FramePipeline.apply(box.current, to: request.sourceImage)
                    request.finish(with: output, context: FramePipeline.context)
                })
            guard let self, !Task.isCancelled else { return }
            self.compositionTask = nil
            self.composition = composition
            self.allItems.forEach(self.configure)
            if !self.isPlaying { self.redrawCurrentFrame() }
        }
    }

    /// A paused player doesn't re-render on its own; an exact seek to the
    /// current time pushes the frame through the filters again.
    private func redrawCurrentFrame() {
        player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private var isSilent: Bool { forceMuted || wallpaper.settings.muted }

    private func applyAudio() {
        player.isMuted = isSilent
        player.volume = Float(wallpaper.settings.volume)
        allItems.forEach(configure)
    }

    /// A muted player still decodes audio and keeps the audio hardware running
    /// at zero volume; disabling the tracks stops both.
    private func configureAudioTracks(of item: AVPlayerItem) {
        for track in item.tracks where track.assetTrack?.mediaType == .audio {
            if track.isEnabled == isSilent { track.isEnabled = !isSilent }
        }
    }
}
