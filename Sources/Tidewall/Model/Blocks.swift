import Foundation

/// A wallpaper built from blocks: each block draws one element over the ones
/// before it, and any block can react to the music.
struct Composition: Codable, Hashable {
    var blocks: [Block] = []

    static let maxBlocks = 16

    /// Whether anything in it listens to audio (so Tidewall only listens then).
    var usesAudio: Bool {
        blocks.contains { $0.enabled && ($0.kind.isAudio || $0.react != .nothing) }
    }
}

/// What a block can react to.
enum ReactSource: String, Codable, CaseIterable, Identifiable {
    case nothing, bass, mid, treble, level, beat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nothing: "Nothing"
        case .bass: "Bass"
        case .mid: "Vocals & Mids"
        case .treble: "Treble"
        case .level: "Volume"
        case .beat: "The Beat"
        }
    }

    func value(in frame: AudioAnalyzer.Frame) -> Float {
        switch self {
        case .nothing: 0
        case .bass: frame.bass
        case .mid: frame.mid
        case .treble: frame.treble
        case .level: frame.level
        case .beat: frame.beat
        }
    }
}

enum BlockCategory: String, CaseIterable {
    case background = "Backgrounds", light = "Light & Shapes", motion = "Motion", music = "Music", finish = "Finishing"
}

/// The kinds of block. The raw value is what the shader switches on, so new
/// kinds must be added at the end.
enum BlockKind: Int, Codable, CaseIterable, Identifiable {
    case gradient, aurora, particles, waves, orb, rays, ripples, grid, spectrumRing, equalizer, vignette

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .gradient: "Gradient"
        case .aurora: "Aurora"
        case .particles: "Particles"
        case .waves: "Waves"
        case .orb: "Glowing Orb"
        case .rays: "Light Rays"
        case .ripples: "Ripples"
        case .grid: "Neon Grid"
        case .spectrumRing: "Spectrum Ring"
        case .equalizer: "Equalizer"
        case .vignette: "Vignette"
        }
    }

    var symbol: String {
        switch self {
        case .gradient: "square.fill.on.square.fill"
        case .aurora: "wind"
        case .particles: "sparkles"
        case .waves: "water.waves"
        case .orb: "circle.hexagongrid.fill"
        case .rays: "sun.max.fill"
        case .ripples: "dot.radiowaves.left.and.right"
        case .grid: "squareshape.split.3x3"
        case .spectrumRing: "circle.dashed"
        case .equalizer: "chart.bar.fill"
        case .vignette: "camera.aperture"
        }
    }

    var summary: String {
        switch self {
        case .gradient: "A smooth blend of two colors that can slowly turn."
        case .aurora: "Glowing ribbons of light drifting across the sky."
        case .particles: "Stars, bubbles or embers floating in one direction."
        case .waves: "Rolling lines of light."
        case .orb: "A soft glowing light, like a sun or a moon."
        case .rays: "Beams of light turning around a point."
        case .ripples: "Rings spreading out from a point."
        case .grid: "A retro neon floor rolling towards you."
        case .spectrumRing: "A ring of bars that dance to the music."
        case .equalizer: "Music bars along the bottom of the screen."
        case .vignette: "Darkens the edges to frame everything."
        }
    }

    var category: BlockCategory {
        switch self {
        case .gradient, .aurora: .background
        case .orb, .rays, .ripples, .grid: .light
        case .particles, .waves: .motion
        case .spectrumRing, .equalizer: .music
        case .vignette: .finish
        }
    }

    /// Always driven by the music, whatever it reacts to.
    var isAudio: Bool { self == .spectrumRing || self == .equalizer }

    var usesSecondColor: Bool {
        switch self {
        case .gradient, .aurora, .particles, .waves, .spectrumRing, .equalizer: true
        default: false
        }
    }

    var usesPosition: Bool {
        switch self {
        case .orb, .rays, .ripples, .spectrumRing: true
        default: false
        }
    }

    /// The sliders a block shows, in order, with labels that fit it.
    var controls: [BlockControl] {
        let brightness = BlockControl(\.amount, "Brightness", 0...2)
        switch self {
        case .gradient:
            return [BlockControl(\.detail, "Angle", 0...1, format: .degrees), BlockControl(\.speed, "Turning", 0...1)]
        case .aurora:
            return [brightness, BlockControl(\.size, "Size", 0.3...2), BlockControl(\.y, "Height", 0...1),
                    BlockControl(\.speed, "Speed", 0...2)]
        case .particles:
            return [brightness, BlockControl(\.count, "Amount", 0.1...1), BlockControl(\.size, "Size", 0.3...3),
                    BlockControl(\.speed, "Speed", 0...2)]
        case .waves:
            return [brightness, BlockControl(\.count, "Lines", 1...8, format: .whole), BlockControl(\.size, "Height", 0.1...2),
                    BlockControl(\.y, "Position", 0...1), BlockControl(\.speed, "Speed", 0...2)]
        case .orb:
            return [brightness, BlockControl(\.size, "Size", 0.1...2)]
        case .rays:
            return [brightness, BlockControl(\.count, "Beams", 3...24, format: .whole), BlockControl(\.speed, "Turning", 0...1)]
        case .ripples:
            return [brightness, BlockControl(\.size, "Reach", 0.2...2), BlockControl(\.speed, "Speed", 0...2)]
        case .grid:
            return [brightness, BlockControl(\.y, "Horizon", 0.2...0.7), BlockControl(\.speed, "Speed", 0...2)]
        case .spectrumRing:
            return [brightness, BlockControl(\.size, "Size", 0.3...2)]
        case .equalizer:
            return [brightness, BlockControl(\.count, "Bars", 8...64, format: .whole), BlockControl(\.size, "Height", 0.2...2)]
        case .vignette:
            return [BlockControl(\.amount, "Darkness", 0...1.5), BlockControl(\.size, "Size", 0.3...1.5)]
        }
    }

    /// Particles only: which way they travel.
    static let directions = ["Up", "Down", "Left", "Right", "Outward", "Inward"]

    /// A block of this kind with settings that look good straight away.
    func makeBlock() -> Block {
        var b = Block(kind: self)
        switch self {
        case .gradient:
            b.colorA = RGBAColor(r: 0.05, g: 0.06, b: 0.18); b.colorB = RGBAColor(r: 0.01, g: 0.01, b: 0.04)
            b.detail = 0.5; b.speed = 0
        case .aurora:
            b.colorA = RGBAColor(r: 0.15, g: 0.95, b: 0.65); b.colorB = RGBAColor(r: 0.45, g: 0.30, b: 1.0)
            b.y = 0.62; b.speed = 0.5
        case .particles:
            b.colorA = RGBAColor(r: 1, g: 1, b: 1); b.colorB = RGBAColor(r: 0.6, g: 0.8, b: 1)
            b.count = 0.5; b.size = 1; b.speed = 0.3; b.detail = 0
        case .waves:
            b.colorA = RGBAColor(r: 0.2, g: 0.8, b: 1); b.colorB = RGBAColor(r: 0.5, g: 0.4, b: 1)
            b.count = 4; b.size = 0.8; b.y = 0.3; b.speed = 0.6
        case .orb:
            b.colorA = RGBAColor(r: 1, g: 0.75, b: 0.4); b.size = 0.6; b.x = 0.5; b.y = 0.55
        case .rays:
            b.colorA = RGBAColor(r: 1, g: 0.9, b: 0.7); b.amount = 0.5; b.count = 12; b.speed = 0.15; b.x = 0.5; b.y = 0.55
        case .ripples:
            b.colorA = RGBAColor(r: 0.4, g: 0.9, b: 1); b.amount = 0.8; b.size = 1; b.speed = 0.6; b.x = 0.5; b.y = 0.5
        case .grid:
            b.colorA = RGBAColor(r: 1, g: 0.3, b: 0.8); b.y = 0.4; b.speed = 0.6
        case .spectrumRing:
            b.colorA = RGBAColor(r: 0.2, g: 0.85, b: 1); b.colorB = RGBAColor(r: 1, g: 0.3, b: 0.7); b.size = 1; b.x = 0.5; b.y = 0.5
        case .equalizer:
            b.colorA = RGBAColor(r: 0.3, g: 1, b: 0.6); b.colorB = RGBAColor(r: 0.2, g: 0.6, b: 1); b.count = 32; b.size = 1
        case .vignette:
            b.amount = 0.8; b.size = 1
        }
        return b
    }
}

/// One slider in a block's settings.
struct BlockControl: Identifiable {
    enum Format { case percent, whole, degrees }
    let key: WritableKeyPath<Block, Double>
    let title: String
    let range: ClosedRange<Double>
    var format: Format = .percent
    var id: String { title }

    init(_ key: WritableKeyPath<Block, Double>, _ title: String, _ range: ClosedRange<Double>, format: Format = .percent) {
        self.key = key
        self.title = title
        self.range = range
        self.format = format
    }

    func text(_ value: Double) -> String {
        switch format {
        case .percent: String(format: "%.0f%%", value * 100)
        case .whole: String(format: "%.0f", value)
        case .degrees: String(format: "%.0f°", value * 360)
        }
    }
}

struct Block: Codable, Hashable, Identifiable {
    var id = UUID()
    var kind: BlockKind
    var enabled = true
    var opacity = 1.0
    var colorA = RGBAColor(r: 1, g: 1, b: 1)
    var colorB = RGBAColor(r: 0.5, g: 0.5, b: 1)
    /// Generic settings; each kind gives them its own meaning and label.
    var amount = 1.0
    var size = 1.0
    var speed = 0.5
    var detail = 0.0
    var count = 1.0
    var x = 0.5
    var y = 0.5
    var react: ReactSource = .nothing
    var reactStrength = 1.0

    init(kind: BlockKind) { self.kind = kind }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Block(kind: try c.decode(BlockKind.self, forKey: .kind))
        self = d
        id = try c.decode(.id, default: d.id)
        enabled = try c.decode(.enabled, default: d.enabled)
        opacity = try c.decode(.opacity, default: d.opacity)
        colorA = try c.decode(.colorA, default: d.colorA)
        colorB = try c.decode(.colorB, default: d.colorB)
        amount = try c.decode(.amount, default: d.amount)
        size = try c.decode(.size, default: d.size)
        speed = try c.decode(.speed, default: d.speed)
        detail = try c.decode(.detail, default: d.detail)
        count = try c.decode(.count, default: d.count)
        x = try c.decode(.x, default: d.x)
        y = try c.decode(.y, default: d.y)
        react = try c.decode(.react, default: d.react)
        reactStrength = try c.decode(.reactStrength, default: d.reactStrength)
    }
}

extension RGBAColor {
    init(r: Double, g: Double, b: Double) { self.init(red: r, green: g, blue: b) }
}

/// Ready-made starting points.
enum BlockTemplate: String, CaseIterable, Identifiable {
    case nightSky, synthwave, ocean, party, blank

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nightSky: "Night Sky"
        case .synthwave: "Synthwave"
        case .ocean: "Ocean"
        case .party: "Music Party"
        case .blank: "Blank"
        }
    }

    var summary: String {
        switch self {
        case .nightSky: "Stars and a drifting aurora"
        case .synthwave: "Retro sun over a neon grid"
        case .ocean: "Waves with rising bubbles"
        case .party: "Everything dances to your music"
        case .blank: "Just a gradient to build on"
        }
    }

    var composition: Composition {
        func block(_ kind: BlockKind, _ edit: (inout Block) -> Void = { _ in }) -> Block {
            var b = kind.makeBlock()
            edit(&b)
            return b
        }
        switch self {
        case .nightSky:
            return Composition(blocks: [
                block(.gradient) { $0.colorA = RGBAColor(r: 0.03, g: 0.05, b: 0.16); $0.colorB = RGBAColor(r: 0.0, g: 0.0, b: 0.02) },
                block(.particles) { $0.count = 0.7; $0.size = 0.6; $0.speed = 0.05; $0.detail = 2 },
                block(.aurora),
                block(.vignette),
            ])
        case .synthwave:
            return Composition(blocks: [
                block(.gradient) { $0.colorA = RGBAColor(r: 0.35, g: 0.05, b: 0.45); $0.colorB = RGBAColor(r: 0.03, g: 0.01, b: 0.08) },
                block(.rays) { $0.colorA = RGBAColor(r: 1, g: 0.5, b: 0.6); $0.amount = 0.35; $0.y = 0.52 },
                block(.orb) { $0.colorA = RGBAColor(r: 1, g: 0.55, b: 0.3); $0.size = 0.9; $0.y = 0.52 },
                block(.grid),
                block(.particles) { $0.colorA = RGBAColor(r: 1, g: 0.7, b: 0.9); $0.count = 0.35; $0.size = 0.7; $0.speed = 0.1 },
                block(.vignette),
            ])
        case .ocean:
            return Composition(blocks: [
                block(.gradient) { $0.colorA = RGBAColor(r: 0.02, g: 0.20, b: 0.35); $0.colorB = RGBAColor(r: 0.0, g: 0.03, b: 0.08) },
                block(.orb) { $0.colorA = RGBAColor(r: 0.6, g: 0.9, b: 1); $0.amount = 0.6; $0.size = 1.2; $0.y = 0.85 },
                block(.waves) { $0.count = 6; $0.y = 0.35 },
                block(.particles) { $0.colorA = RGBAColor(r: 0.7, g: 0.95, b: 1); $0.count = 0.3; $0.size = 1.4; $0.speed = 0.25 },
                block(.vignette),
            ])
        case .party:
            return Composition(blocks: [
                block(.gradient) { $0.colorA = RGBAColor(r: 0.06, g: 0.02, b: 0.12); $0.colorB = RGBAColor(r: 0.0, g: 0.0, b: 0.02) },
                block(.ripples) { $0.react = .beat; $0.colorA = RGBAColor(r: 1, g: 0.35, b: 0.75) },
                block(.particles) { $0.detail = 4; $0.count = 0.3; $0.amount = 0.7; $0.size = 0.7; $0.react = .level },
                block(.spectrumRing),
                block(.orb) { $0.colorA = RGBAColor(r: 0.4, g: 0.8, b: 1); $0.amount = 0.55; $0.size = 0.3; $0.react = .bass },
                block(.equalizer),
                block(.vignette),
            ])
        case .blank:
            return Composition(blocks: [block(.gradient)])
        }
    }
}
