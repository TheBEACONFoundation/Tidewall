import AppKit
import AVFoundation

/// Hosts a player layer and positions it according to the wallpaper's framing
/// (scaling, zoom, focus, mirroring). Used on the desktop and in the editor.
final class WallpaperPlayerView: NSView {
    private var playerLayer = WallpaperPlayerView.makePlayerLayer()
    private var incomingLayer: AVPlayerLayer?
    private var incomingFade: TimeInterval = 0
    private var readyObservation: NSKeyValueObservation?
    private var settings = WallpaperSettings()
    private var videoSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func makePlayerLayer() -> AVPlayerLayer {
        let layer = AVPlayerLayer()
        layer.videoGravity = .resize
        layer.actions = ["bounds": NSNull(), "position": NSNull(), "transform": NSNull()]
        return layer
    }

    var player: AVPlayer? {
        get { incomingLayer?.player ?? playerLayer.player }
        set {
            guard player !== newValue else { return }
            cancelTransition()
            playerLayer.player = newValue
        }
    }

    /// Switches to another player showing the same wallpaper (e.g. its
    /// optimized copy). The current picture stays up until the new one has a
    /// frame ready, so the swap is invisible; with `fade`, the old picture then
    /// dissolves into the new one (used when a battery variant takes over).
    func transition(to newPlayer: AVPlayer, fade: TimeInterval = 0) {
        guard player !== newPlayer else { return }
        guard playerLayer.player != nil else {
            player = newPlayer
            return
        }
        cancelTransition()
        let incoming = Self.makePlayerLayer()
        incoming.player = newPlayer
        layer?.insertSublayer(incoming, below: playerLayer)
        incomingLayer = incoming
        incomingFade = fade
        needsLayout = true
        readyObservation = incoming.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { self?.finishTransition(to: layer) }
        }
    }

    private func finishTransition(to incoming: AVPlayerLayer) {
        guard incoming === incomingLayer else { return }
        readyObservation = nil
        incomingLayer = nil
        let outgoing = playerLayer
        playerLayer = incoming
        guard incomingFade > 0 else {
            outgoing.player = nil
            outgoing.removeFromSuperlayer()
            return
        }
        // The new picture is already underneath: fade the old one away.
        CATransaction.begin()
        CATransaction.setAnimationDuration(incomingFade)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setCompletionBlock {
            outgoing.player = nil
            outgoing.removeFromSuperlayer()
        }
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1
        fadeOut.toValue = 0
        outgoing.add(fadeOut, forKey: "fade")
        outgoing.opacity = 0
        CATransaction.commit()
    }

    private var firstFrameObservation: NSKeyValueObservation?

    /// Calls `action` once the picture has a frame up, or after `timeout`
    /// (so a video that fails to load can't hold anything up).
    func whenReady(timeout: TimeInterval, _ action: @escaping () -> Void) {
        var done = false
        let finish = { [weak self] in
            guard !done else { return }
            done = true
            self?.firstFrameObservation = nil
            action()
        }
        firstFrameObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { finish() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish() }
    }

    private func cancelTransition() {
        readyObservation = nil
        incomingLayer?.player = nil
        incomingLayer?.removeFromSuperlayer()
        incomingLayer = nil
    }

    func configure(with wallpaper: Wallpaper) {
        guard settings != wallpaper.settings || videoSize != wallpaper.videoSize else { return }
        settings = wallpaper.settings
        videoSize = wallpaper.videoSize
        layer?.backgroundColor = settings.backgroundColor.cgColor
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let rect = FramePipeline.videoRect(in: bounds, videoSize: videoSize, settings: settings)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [playerLayer, incomingLayer].compactMap({ $0 }) {
            layer.bounds = CGRect(origin: .zero, size: rect.size)
            layer.position = CGPoint(x: rect.midX, y: rect.midY)
            layer.setAffineTransform(settings.mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        }
        CATransaction.commit()
    }
}

/// A borderless, click-through window pinned to the desktop layer of one
/// screen: above the system wallpaper, below desktop icons and every app.
/// Switching to another wallpaper crossfades: the new picture goes in
/// underneath, and the old one fades away once the new one is ready.
final class DesktopWindow: NSWindow {
    /// The longest a crossfade waits for the new picture's first frame.
    static let readyTimeout: TimeInterval = 2

    let displayID: String
    private let container = NSView()
    /// What's on screen: a video or a live wallpaper.
    private var current: NSView?
    /// The previous wallpaper, while it fades out.
    private var outgoing: NSView?
    private var transitionID = 0
    private(set) var wallpaperID: UUID?

    /// Set while the window shows a video.
    var playerView: WallpaperPlayerView? { current as? WallpaperPlayerView }
    /// Set while the window shows a live wallpaper drawn in real time.
    var visualizer: VisualizerView? { current as? VisualizerView }

    init(screen: NSScreen, displayID: String) {
        self.displayID = displayID
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)

        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        contentView = container
        setAccessibilityElement(false)
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Borderless windows must be allowed to cover the menu bar area.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Shows `wallpaper`. When it's already showing, the current player is
    /// kept: the engine swaps players itself once a replacement is ready.
    func show(_ wallpaper: Wallpaper, player: LoopingPlayer, fade: TimeInterval = 0) {
        if wallpaperID == wallpaper.id, let playerView {
            if playerView.player == nil { playerView.player = player.player }
            playerView.configure(with: wallpaper)
        } else {
            let view = WallpaperPlayerView(frame: container.bounds)
            view.player = player.player
            view.configure(with: wallpaper)
            present(view, fade: fade) { done in view.whenReady(timeout: Self.readyTimeout, done) }
        }
        wallpaperID = wallpaper.id
        if !isVisible { orderFrontRegardless() }
    }

    /// Shows a live wallpaper drawn in real time.
    func showVisualizer(_ wallpaper: Wallpaper, fade: TimeInterval = 0) {
        guard let content = LiveContent(wallpaper) else { return }
        if wallpaperID == wallpaper.id, let visualizer {
            if visualizer.content != content { visualizer.content = content }
        } else if let view = VisualizerView(frame: container.bounds, content: content) {
            view.isPaused = true // the engine starts it once it knows it's visible
            present(view, fade: fade) { done in
                // Draw a first frame so there's something to fade to.
                view.draw()
                done()
            }
        }
        wallpaperID = wallpaper.id
        if !isVisible { orderFrontRegardless() }
    }

    /// Puts `view` on screen, underneath the current picture, and fades the
    /// current one away once `whenReady` says the new one has a frame.
    private func present(_ view: NSView, fade: TimeInterval, whenReady: (@escaping () -> Void) -> Void) {
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        if outgoing != nil {
            // Already crossfading: the half-arrived picture gives way at once,
            // and the one still fading out fades to the new one instead.
            if let current { retire(current) }
        } else {
            outgoing = current
        }
        current = view
        container.addSubview(view, positioned: .below, relativeTo: outgoing)
        transitionID += 1

        guard let leaving = outgoing else { return }
        guard fade > 0, isVisible else {
            retire(leaving)
            outgoing = nil
            return
        }
        let id = transitionID
        whenReady { [weak self] in
            guard let self, id == self.transitionID else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fade
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                leaving.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, id == self.transitionID, self.outgoing === leaving else { return }
                    self.retire(leaving)
                    self.outgoing = nil
                }
            }
        }
    }

    private func retire(_ view: NSView) {
        (view as? VisualizerView)?.isPaused = true
        (view as? WallpaperPlayerView)?.player = nil
        view.removeFromSuperview()
    }

    func tearDown() {
        transitionID += 1
        for view in [current, outgoing].compactMap({ $0 }) { retire(view) }
        current = nil
        outgoing = nil
        wallpaperID = nil
        orderOut(nil)
        close()
    }
}
