import AppKit
import AVFoundation

/// Hosts a player layer and positions it according to the wallpaper's framing
/// (scaling, zoom, focus, mirroring). Used on the desktop and in the editor.
final class WallpaperPlayerView: NSView {
    private let playerLayer = AVPlayerLayer()
    private var settings = WallpaperSettings()
    private var videoSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resize
        playerLayer.actions = ["bounds": NSNull(), "position": NSNull(), "transform": NSNull()]
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var player: AVPlayer? {
        get { playerLayer.player }
        set { if playerLayer.player !== newValue { playerLayer.player = newValue } }
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
        playerLayer.bounds = CGRect(origin: .zero, size: rect.size)
        playerLayer.position = CGPoint(x: rect.midX, y: rect.midY)
        playerLayer.setAffineTransform(settings.mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        CATransaction.commit()
    }
}

/// A borderless, click-through window pinned to the desktop layer of one
/// screen: above the system wallpaper, below desktop icons and every app.
final class DesktopWindow: NSWindow {
    let displayID: String
    let playerView = WallpaperPlayerView()
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

    func show(_ wallpaper: Wallpaper, player: LoopingPlayer) {
        wallpaperID = wallpaper.id
        playerView.configure(with: wallpaper)
        playerView.player = player.player
        if !isVisible { orderFrontRegardless() }
    }

    func tearDown() {
        playerView.player = nil
        wallpaperID = nil
        orderOut(nil)
        close()
    }
}
