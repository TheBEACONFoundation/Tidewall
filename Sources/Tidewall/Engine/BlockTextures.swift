import AppKit
import Metal
import MetalKit

/// Where a clock, text or picture block finds its texture in a frame.
struct BlockTextureSlot: Equatable {
    /// Index into the textures bound for the frame.
    var index: Int32
    /// Width over height.
    var aspect: Float
    /// Type only: the texture's height as a fraction of the screen's.
    var height: Float = 0
}

/// Turns clock, text and picture blocks into GPU textures. Type is drawn
/// white, one channel, with mipmaps: the shader reads a blurred level of
/// the same texture for the glow. Textures are cached, so a clock renders
/// its type once a minute.
@MainActor
final class BlockTextures {
    /// The most textures one frame can use.
    static let slotCount = 8

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let loader: MTKTextureLoader
    private let placeholder: MTLTexture
    private var typeCache: [String: (texture: MTLTexture, aspect: Float, height: Float, lastUsed: Int)] = [:]
    private var pictureCache: [String: (texture: MTLTexture, aspect: Float)?] = [:]
    private var generation = 0
    private let timeFormatter = DateFormatter()
    private let dateFormatter = DateFormatter()
    private var formattedMinute = -1
    private var formatted: (time: String, date: String) = ("", "")

    /// Where picture blocks' files live (tests point it elsewhere).
    var mediaDirectory = LibraryStore.shared.mediaDirectory {
        didSet { pictureCache.removeAll() }
    }

    init?(device: MTLDevice, queue: MTLCommandQueue) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        guard let placeholder = device.makeTexture(descriptor: descriptor) else { return nil }
        var clear: UInt32 = 0
        placeholder.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &clear, bytesPerRow: 4)
        self.device = device
        self.queue = queue
        self.placeholder = placeholder
        loader = MTKTextureLoader(device: device)
        timeFormatter.setLocalizedDateFormatFromTemplate("jmm")
        // A wallpaper clock reads better as "9:41" than "9:41 AM".
        timeFormatter.amSymbol = ""
        timeFormatter.pmSymbol = ""
        dateFormatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
    }

    /// The textures for one frame of `composition`, drawn `drawableHeight`
    /// pixels tall. With `date` nil, clocks are left out (a still can't
    /// keep time).
    func prepare(_ composition: Composition, drawableHeight: CGFloat, date: Date?) -> (textures: [MTLTexture], slots: [UUID: BlockTextureSlot]) {
        generation += 1
        var textures: [MTLTexture] = []
        var slots: [UUID: BlockTextureSlot] = [:]
        for block in composition.blocks where block.enabled && block.kind.usesTexture {
            guard textures.count < Self.slotCount else { break }
            let entry: (texture: MTLTexture, aspect: Float, height: Float)?
            switch block.kind {
            case .image:
                entry = block.media.flatMap(picture).map { ($0.texture, $0.aspect, 0) }
            case .clock:
                // The date under the time is set smaller.
                entry = date.flatMap { clockText(for: block, at: $0) }
                    .flatMap { type($0, font: block.font, size: block.size, laterLines: 0.32, drawableHeight: drawableHeight) }
            default:
                entry = type(block.text, font: block.font, size: block.size, laterLines: 1, drawableHeight: drawableHeight)
            }
            guard let entry else { continue }
            slots[block.id] = BlockTextureSlot(index: Int32(textures.count), aspect: entry.aspect, height: entry.height)
            textures.append(entry.texture)
        }
        // Forget type nobody has drawn for a while (e.g. last minute's time).
        if typeCache.count > 24 {
            typeCache = typeCache.filter { generation - $0.value.lastUsed < 120 }
        }
        while textures.count < Self.slotCount { textures.append(placeholder) }
        return (textures, slots)
    }

    /// Lets go of a picture's texture, e.g. after the file was replaced.
    func forgetPicture(_ file: String) {
        pictureCache[file] = nil
    }

    // MARK: Clock

    private func clockText(for block: Block, at date: Date) -> String {
        let minute = Int(date.timeIntervalSinceReferenceDate / 60)
        if minute != formattedMinute {
            formattedMinute = minute
            formatted = (timeFormatter.string(from: date).trimmingCharacters(in: .whitespaces),
                         dateFormatter.string(from: date))
        }
        switch Int(block.detail.rounded()) {
        case 0: return formatted.time
        case 2: return formatted.date
        default: return "\(formatted.time)\n\(formatted.date)"
        }
    }

    // MARK: Type

    /// - Parameter laterLines: the size of lines after the first, relative to it.
    private func type(_ string: String, font: BlockFont, size: Double, laterLines: CGFloat, drawableHeight: CGFloat)
        -> (texture: MTLTexture, aspect: Float, height: Float)? {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, drawableHeight > 0 else { return nil }
        // Size 1 sets the first line at a tenth of the screen's height.
        let pointSize = max(6, (drawableHeight * 0.1 * size).rounded())
        let key = "\(text)|\(font.rawValue)|\(pointSize)|\(laterLines)"
        if let cached = typeCache[key] {
            typeCache[key]?.lastUsed = generation
            return (cached.texture, cached.aspect, cached.height)
        }
        guard let rendered = renderType(text, font: font, pointSize: pointSize, laterLines: laterLines) else { return nil }
        let height = Float(CGFloat(rendered.height) / drawableHeight)
        let aspect = Float(rendered.width) / Float(rendered.height)
        typeCache[key] = (rendered, aspect, height, generation)
        return (rendered, aspect, height)
    }

    static func nsFont(_ font: BlockFont, size: CGFloat) -> NSFont {
        let weight: NSFont.Weight = switch font {
        case .light: .ultraLight
        case .bold: .heavy
        case .mono: .regular
        default: .medium
        }
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let design: NSFontDescriptor.SystemDesign? = switch font {
        case .rounded: .rounded
        case .classic: .serif
        case .mono: .monospaced
        default: nil
        }
        guard let design, let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// Draws `text` centred, white on black, with room around it for the glow.
    private func renderType(_ text: String, font: BlockFont, pointSize: CGFloat, laterLines: CGFloat) -> MTLTexture? {
        let lines = text.components(separatedBy: "\n")
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributed = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            let size = i == 0 ? pointSize : (pointSize * laterLines).rounded()
            attributed.append(NSAttributedString(string: line + (i < lines.count - 1 ? "\n" : ""), attributes: [
                .font: Self.nsFont(font, size: size), .foregroundColor: NSColor.white, .paragraphStyle: paragraph,
                .kern: size == pointSize ? -pointSize * 0.01 : size * 0.06,
            ]))
        }
        let bounds = attributed.boundingRect(with: CGSize(width: 100_000, height: 100_000),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading])
        let padding = (pointSize * 0.4).rounded()
        let width = Int(ceil(bounds.width + padding * 2)), height = Int(ceil(bounds.height + padding * 2))
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        attributed.draw(with: CGRect(x: padding, y: padding, width: bounds.width, height: bounds.height),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        guard let data = context.data else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: true)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        // A bitmap context's first row is the top of the picture, as in a texture.
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: data, bytesPerRow: context.bytesPerRow)
        guard let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() else { return texture }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        buffer.commit()
        return texture
    }

    // MARK: Pictures

    private func picture(_ file: String) -> (texture: MTLTexture, aspect: Float)? {
        if let cached = pictureCache[file] { return cached }
        let url = mediaDirectory.appendingPathComponent(file)
        let texture = try? loader.newTexture(URL: url, options: [
            .SRGB: false, .generateMipmaps: true, .allocateMipmaps: true,
            .textureUsage: MTLTextureUsage.shaderRead.rawValue, .origin: MTKTextureLoader.Origin.topLeft,
        ])
        let entry = texture.map { ($0, Float($0.width) / Float(max(1, $0.height))) }
        pictureCache[file] = .some(entry)
        return entry
    }
}
