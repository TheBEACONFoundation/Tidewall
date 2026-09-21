import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import VideoToolbox

/// What the desktop plays for a wallpaper.
struct PlaybackSource: Equatable {
    var url: URL
    /// The settings to play with. Adjustments are identity when they're baked in.
    var wallpaper: Wallpaper
}

/// Facts about a source video that decide whether a playback copy helps.
struct SourceInfo: Sendable {
    var hardwareDecodable: Bool
    var isHDR: Bool

    static func load(from url: URL) async -> SourceInfo? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let formats = try? await track.load(.formatDescriptions)
        else { return nil }
        let codec = formats.first.map(CMFormatDescriptionGetMediaSubType) ?? 0
        let isHDR = (try? await track.load(.mediaCharacteristics))?.contains(.containsHDRVideo) ?? false
        return SourceInfo(hardwareDecodable: VTIsHardwareDecodeSupported(codec), isHDR: isHDR)
    }
}

/// Everything baked into a playback copy. Trim, speed, framing and audio are
/// applied at playback, so changing them never needs a new copy.
struct RenditionRecipe: Codable, Hashable {
    static let formatVersion = 1

    var mediaFile: String
    var adjustments: Adjustments
    /// Downscale factor (≤ 1), quantized so small zoom changes don't re-encode.
    var scale: Double
    var version = RenditionRecipe.formatVersion

    /// Returns nil when the original already plays as efficiently as a copy would.
    static func make(for wallpaper: Wallpaper, info: SourceInfo, requiredScale: Double) -> RenditionRecipe? {
        let adjustments = wallpaper.settings.adjustments
        // Keep HDR sources untouched unless a look has to be baked anyway.
        if info.isHDR && adjustments.isIdentity { return nil }
        let scale = quantizedScale(requiredScale)
        guard !adjustments.isIdentity || scale < 1 || !info.hardwareDecodable else { return nil }
        return RenditionRecipe(mediaFile: wallpaper.mediaFile, adjustments: adjustments, scale: scale)
    }

    /// Only downscale when it saves a meaningful amount (≥ 25%), and round up
    /// to eighths so the copy always has at least the pixels the screen needs.
    static func quantizedScale(_ required: Double) -> Double {
        guard required < 0.75 else { return 1 }
        return min(1, max(0.125, (required * 8).rounded(.up) / 8))
    }

    var key: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let digest = SHA256.hash(data: (try? encoder.encode(self)) ?? Data())
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Bakes playback copies.
enum RenditionExporter {
    /// Encodes the source with the recipe's look and size baked in, using the
    /// hardware HEVC encoder at its highest quality preset. Audio is kept.
    static func export(source: URL, recipe: RenditionRecipe, to output: URL) async throws {
        let asset = AVURLAsset(url: source)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

        var preset = AVAssetExportPresetHEVCHighestQuality
        if await !AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: .mov) {
            preset = AVAssetExportPresetHighestQuality
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let adjustments = recipe.adjustments
        let scale = recipe.scale
        let composition = try await AVMutableVideoComposition.videoComposition(
            with: asset,
            applyingCIFiltersWithHandler: { request in
                var image = request.sourceImage
                if scale < 1 {
                    let lanczos = CIFilter.lanczosScaleTransform()
                    lanczos.inputImage = image
                    lanczos.scale = Float(scale)
                    lanczos.aspectRatio = 1
                    image = lanczos.outputImage ?? image
                }
                request.finish(with: FramePipeline.apply(adjustments, to: image), context: FramePipeline.context)
            })
        if scale < 1 {
            let size = composition.renderSize
            composition.renderSize = CGSize(width: (size.width * scale / 2).rounded(.up) * 2,
                                            height: (size.height * scale / 2).rounded(.up) * 2)
        }
        session.videoComposition = composition

        let temporary = output.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).mov")
        defer { try? fileManager.removeItem(at: temporary) }
        try await session.export(to: temporary, as: .mov)
        try? fileManager.removeItem(at: output)
        try fileManager.moveItem(at: temporary, to: output)
    }
}
