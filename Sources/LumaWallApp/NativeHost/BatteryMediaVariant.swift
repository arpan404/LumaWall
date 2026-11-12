import AVFoundation
import Foundation
import LumaWallCore

/// Silent 1280x720 library sibling used on reduced and minimal tiers.
enum BatteryMediaVariant {
    /// Tracks assets with a transcode currently running (see `ensure`).
    /// MainActor-guarded: every caller is MainActor-isolated.
    @MainActor
    private static var inFlight = Set<String>()

    /// Standardized paths of variant files already confirmed on disk. Both
    /// playback and preview resolution hit this before `FileManager`, which
    /// otherwise stats the sibling on every apply/tier change.
    @MainActor
    private static var knownExisting = Set<String>()

    static func url(for asset: WallpaperAsset) -> URL {
        variantURL(for: asset.mediaURL)
    }

    private static func variantURL(for mediaURL: URL) -> URL {
        mediaURL.deletingLastPathComponent().appendingPathComponent("Wallpaper.battery.mov")
    }

    @MainActor
    static func resolvedURL(for asset: WallpaperAsset, tier: PlaybackTier) -> URL {
        switch tier {
        case .reduced, .minimal:
            if let variant = existingVariant(for: url(for: asset)) { return variant }
            return asset.mediaURL
        default:
            return asset.mediaURL
        }
    }

    /// The battery sibling used for poster/preview frames, when it exists.
    @MainActor
    static func resolvedPreviewURL(for mediaURL: URL) -> URL {
        existingVariant(for: variantURL(for: mediaURL)) ?? mediaURL
    }

    /// Cache hit, else a single disk check that records the positive result.
    /// Missing variants are not cached, so a later `ensure` is still seen.
    @MainActor
    private static func existingVariant(for variant: URL) -> URL? {
        let key = variant.standardizedFileURL.path
        if knownExisting.contains(key) { return variant }
        guard FileManager.default.fileExists(atPath: variant.path) else { return nil }
        knownExisting.insert(key)
        return variant
    }

    @MainActor
    static func ensure(for asset: WallpaperAsset) async {
        let dest = url(for: asset)
        let key = dest.standardizedFileURL.path
        if FileManager.default.fileExists(atPath: dest.path) {
            knownExisting.insert(key)
            return
        }
        // Transcode anything above 720p: the sibling is what reduced/minimal
        // tiers actually play, so without it those profiles only move a bitrate
        // hint and look like they "do nothing". 720p and below play as-is.
        guard max(asset.pixelSize.width, asset.pixelSize.height) > 1_280
        else { return }
        // Applies fan out one ensure per display/session; without this two of
        // them transcode the same source at once (all callers are MainActor,
        // so a plain set suffices).
        let sourceKey = asset.mediaURL.standardizedFileURL.path
        guard inFlight.insert(sourceKey).inserted else { return }
        defer { inFlight.remove(sourceKey) }

        let source = AVURLAsset(url: asset.mediaURL)
        guard let export = AVAssetExportSession(asset: source, presetName: AVAssetExportPreset1280x720)
            ?? AVAssetExportSession(asset: source, presetName: AVAssetExportPresetMediumQuality)
        else { return }
        let temp = dest.deletingLastPathComponent()
            .appendingPathComponent("Wallpaper.battery.\(UUID().uuidString).mov")
        do {
            try await export.export(to: temp, as: .mov)
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            knownExisting.remove(key)
            try FileManager.default.moveItem(at: temp, to: dest)
            knownExisting.insert(key)
        } catch {
            knownExisting.remove(key)
            try? FileManager.default.removeItem(at: temp)
        }
    }
}
