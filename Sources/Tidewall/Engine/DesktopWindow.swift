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
final class DesktopWindow: NSWindow {
    let displayID: String
    let playerView = WallpaperPlayerView()
    /// Set while the window shows a live (audio-reactive) wallpaper instead of video.
    private(set) var visualizer: VisualizerView?
    private(set) var wallpaperID: UUID?

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
        contentView = playerView
        setAccessibilityElement(false)
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Borderless windows must be allowed to cover the menu bar area.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Shows `wallpaper`. When it's already showing, the current player is
    /// kept: the engine swaps players itself once a replacement is ready.
    func show(_ wallpaper: Wallpaper, player: LoopingPlayer) {
        if visualizer != nil {
            removeVisualizer()
            contentView = playerView
        }
        if wallpaperID != wallpaper.id || playerView.player == nil {
            playerView.player = player.player
        }
        wallpaperID = wallpaper.id
        playerView.configure(with: wallpaper)
        if !isVisible { orderFrontRegardless() }
    }

    /// Shows a live wallpaper drawn in real time.
    func showVisualizer(_ wallpaper: Wallpaper) {
        guard let content = LiveContent(wallpaper) else { return }
        wallpaperID = wallpaper.id
        if visualizer == nil, let view = VisualizerView(frame: playerView.frame, content: content) {
            playerView.player = nil
            view.isPaused = true // the engine starts it once it knows it's visible
            visualizer = view
            contentView = view
        }
        if visualizer?.content != content { visualizer?.content = content }
        if !isVisible { orderFrontRegardless() }
    }

    private func removeVisualizer() {
        visualizer?.isPaused = true
        visualizer = nil
    }

    func tearDown() {
        removeVisualizer()
        playerView.player = nil
        wallpaperID = nil
        orderOut(nil)
        close()
    }
}
