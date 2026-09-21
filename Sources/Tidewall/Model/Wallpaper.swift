import Foundation
import CoreGraphics

/// A wallpaper in the user's library: one source video plus the settings that
/// turn it into a custom looping wallpaper.
struct Wallpaper: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    /// File name inside the library's Media folder.
    var mediaFile: String
    var originalFileName: String
    var dateAdded: Date
    /// Full duration of the source media, in seconds.
    var duration: Double
    /// Display size of the video (preferred transform already applied).
    var pixelWidth: Double
    var pixelHeight: Double
    var settings: WallpaperSettings
    /// Optional per-battery-state videos (``BatteryState`` raw value → media
    /// file). `mediaFile` is the fallback, e.g. on Macs without a battery.
    var batteryVariants: [String: String]? = nil
    /// Set for live wallpapers drawn in real time (the audio visualizer);
    /// those have no video file.
    var visualizer: VisualizerSettings? = nil
    /// Set for wallpapers made in the blocks editor.
    var composition: Composition? = nil

    var videoSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }

    var isLive: Bool { visualizer != nil || composition != nil }

    var isBatteryReactive: Bool { !(batteryVariants?.isEmpty ?? true) }

    /// The video to show for a battery state.
    func mediaFile(for state: BatteryState?) -> String {
        state.flatMap { batteryVariants?[$0.rawValue] } ?? mediaFile
    }

    /// Every media file this wallpaper uses.
    var allMediaFiles: Set<String> {
        Set(([mediaFile] + (batteryVariants.map { Array($0.values) } ?? [])).filter { !$0.isEmpty })
    }

    /// The portion of the source that loops, in seconds.
    var loopRange: ClosedRange<Double> {
        let start = min(max(0, settings.trimStart), duration)
        let end = min(settings.trimEnd ?? duration, duration)
        return start...max(start, end)
    }

    var resolutionDescription: String {
        "\(Int(pixelWidth))×\(Int(pixelHeight))"
    }
}

/// The battery's condition, using the same thresholds as the Lantern battery
/// gauge, so a battery-reactive wallpaper changes exactly when its emblem does.
enum BatteryState: String, Codable, CaseIterable, Identifiable {
    case full, normal, low, critical, empty

    var id: String { rawValue }

    static func of(level: Double, charging: Bool) -> BatteryState {
        if level >= 0.995 { return .full }
        if !charging && level <= 0.015 { return .empty }
        if !charging && level <= 0.10 { return .critical }
        if !charging && level <= 0.20 { return .low }
        return .normal
    }

    var title: String {
        switch self {
        case .full: "Full"
        case .normal: "Normal"
        case .low: "Low (under 20%)"
        case .critical: "Critical (under 10%)"
        case .empty: "Empty (1%)"
        }
    }
}

/// Wallpapers that ship inside the app: videos (Resources/<id>.mov) and
/// live ones drawn in real time.
struct BuiltInWallpaper: Identifiable, Hashable {
    let id: String
    let name: String
    var isVisualizer = false

    static let all = [
        BuiltInWallpaper(id: "Pulse", name: "Pulse", isVisualizer: true),
        BuiltInWallpaper(id: "CoolChicken", name: "Cool Chicken"),
        BuiltInWallpaper(id: "Aurora", name: "Aurora"),
    ]

    var url: URL? { isVisualizer ? nil : Bundle.main.url(forResource: id, withExtension: "mov") }
    var isAvailable: Bool { isVisualizer || url != nil }
}

enum Scaling: String, Codable, CaseIterable, Identifiable {
    case fill, fit, stretch
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fill: "Fill"
        case .fit: "Fit"
        case .stretch: "Stretch"
        }
    }
}

struct RGBAColor: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    static let black = RGBAColor(red: 0, green: 0, blue: 0)
    static let warmTint = RGBAColor(red: 1.0, green: 0.62, blue: 0.32)

    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

struct WallpaperSettings: Codable, Hashable {
    // Framing
    var scaling: Scaling = .fill
    var zoom: Double = 1
    /// -1 aligns the video's left edge with the screen's, +1 its right edge.
    var focusX: Double = 0
    /// -1 aligns the video's bottom edge with the screen's, +1 its top edge.
    var focusY: Double = 0
    var mirrored = false
    var backgroundColor: RGBAColor = .black

    // Playback
    var speed: Double = 1
    var trimStart: Double = 0
    var trimEnd: Double? = nil

    // Audio
    var muted = true
    var volume: Double = 0.5

    var adjustments = Adjustments()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WallpaperSettings()
        scaling = try c.decode(.scaling, default: d.scaling)
        zoom = try c.decode(.zoom, default: d.zoom)
        focusX = try c.decode(.focusX, default: d.focusX)
        focusY = try c.decode(.focusY, default: d.focusY)
        mirrored = try c.decode(.mirrored, default: d.mirrored)
        backgroundColor = try c.decode(.backgroundColor, default: d.backgroundColor)
        speed = try c.decode(.speed, default: d.speed)
        trimStart = try c.decode(.trimStart, default: d.trimStart)
        trimEnd = try c.decodeIfPresent(Double.self, forKey: .trimEnd)
        muted = try c.decode(.muted, default: d.muted)
        volume = try c.decode(.volume, default: d.volume)
        adjustments = try c.decode(.adjustments, default: d.adjustments)
    }
}

/// Core Image color and effect adjustments applied to every frame.
struct Adjustments: Codable, Hashable {
    var brightness: Double = 0      // -0.5 … 0.5
    var contrast: Double = 1        // 0.5 … 1.5
    var saturation: Double = 1      // 0 … 2
    var hue: Double = 0             // degrees, -180 … 180
    var blur: Double = 0            // 0 … 40
    var vignette: Double = 0        // 0 … 2
    var tintAmount: Double = 0      // 0 … 1
    var tintColor: RGBAColor = .warmTint

    var isIdentity: Bool {
        brightness == 0 && contrast == 1 && saturation == 1 && hue == 0
            && blur == 0 && vignette == 0 && tintAmount == 0
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Adjustments()
        brightness = try c.decode(.brightness, default: d.brightness)
        contrast = try c.decode(.contrast, default: d.contrast)
        saturation = try c.decode(.saturation, default: d.saturation)
        hue = try c.decode(.hue, default: d.hue)
        blur = try c.decode(.blur, default: d.blur)
        vignette = try c.decode(.vignette, default: d.vignette)
        tintAmount = try c.decode(.tintAmount, default: d.tintAmount)
        tintColor = try c.decode(.tintColor, default: d.tintColor)
    }
}

extension KeyedDecodingContainer {
    /// Decodes a value, falling back to a default when the key is absent, so
    /// libraries saved by older versions keep loading as settings are added.
    func decode<T: Decodable>(_ key: Key, default value: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? value
    }
}
