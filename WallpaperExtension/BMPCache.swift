import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import os

/// Removes reproducible WallpaperAgent snapshots while preserving every source
/// video and user assignment. The Agent regenerates the right poster on demand.
func clearWallpaperSnapshotCache() {
    guard let cacheDir = WallpaperState.shared.cacheDirectoryURL else { return }
    let gained = cacheDir.startAccessingSecurityScopedResource()
    defer { if gained { cacheDir.stopAccessingSecurityScopedResource() } }
    guard gained,
          let contents = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)
    else { return }
    for file in contents where file.pathExtension == "bmp" {
        try? FileManager.default.removeItem(at: file)
    }
    extensionLog("[BMPCache] Cleared generated wallpaper snapshots")
}

/// Recently decoded snapshots, keyed by the file's URL plus its modification
/// date and size. The Agent rewrites snapshots with timestamped filenames, so
/// this saves re-decoding the same poster across acquire/transition calls. A
/// couple of entries cover multi-display transitions that alternate choices.
private struct CachedSnapshotImage: @unchecked Sendable {
    let url: URL
    let modificationDate: Date?
    let fileSize: Int?
    let image: CGImage
}

private let cachedSnapshotImages = OSAllocatedUnfairLock(initialState: [URL: CachedSnapshotImage]())
private let cachedSnapshotImageLimit = 4

/// Load the most recent cached BMP from the Agent's cache directory as a CGImage.
/// Used to set rootLayer.contents as immediate visual content during transitions,
/// matching Apple's "Using existing snapshot as initial wallpaper contents" pattern.
///
/// - Parameter videoID: per-context choice identifier. Each display's acquire
///   passes its own choice so the right cached frame is shown during transitions.
///   Reading the process-wide "current" selection here would race across displays.
func loadCachedSnapshotImage(forChoice videoID: String?) -> CGImage? {
    guard let cacheDir = WallpaperState.shared.cacheDirectoryURL else { return nil }

    let gained = cacheDir.startAccessingSecurityScopedResource()
    defer { if gained { cacheDir.stopAccessingSecurityScopedResource() } }

    guard let contents = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else {
        return nil
    }

    let bmpFiles = contents.filter { $0.pathExtension == "bmp" }

    let bmpURL: URL?
    if let videoID {
        let hash = videoHash(for: videoID)
        bmpURL = bmpFiles.first { $0.lastPathComponent.hasPrefix(hash) } ?? bmpFiles.first
    } else {
        bmpURL = bmpFiles.first
    }

    guard let url = bmpURL else { return nil }

    let fileValues = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    let modificationDate = fileValues?.contentModificationDate
    let fileSize = fileValues?.fileSize

    // Only reuse a decoded image when the exact on-disk file is unchanged.
    if fileValues != nil {
        let cached = cachedSnapshotImages.withLock { cache -> CGImage? in
            guard let entry = cache[url],
                  entry.modificationDate == modificationDate,
                  entry.fileSize == fileSize
            else { return nil }
            return entry.image
        }
        if let cached {
            traceLog("  [InitContent] Loaded cached snapshot (decoded cache): \(url.lastPathComponent) (\(cached.width)x\(cached.height))")
            return cached
        }
    }

    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
        traceLog("  [InitContent] Failed to decode cached BMP: \(url.lastPathComponent)")
        return nil
    }

    if fileValues != nil {
        let entry = CachedSnapshotImage(
            url: url,
            modificationDate: modificationDate,
            fileSize: fileSize,
            image: cgImage,
        )
        cachedSnapshotImages.withLock { cache in
            if cache.count >= cachedSnapshotImageLimit, let oldest = cache.keys.first {
                cache.removeValue(forKey: oldest)
            }
            cache[url] = entry
        }
    }

    traceLog("  [InitContent] Loaded cached snapshot: \(url.lastPathComponent) (\(cgImage.width)x\(cgImage.height))")
    return cgImage
}

/// Write a BMP snapshot of the video's first frame to the Agent's cache directory.
/// Each video gets its own BMP file (keyed by video ID hash) so the Agent shows
/// the correct cached frame during transitions between videos.
func writeBMPSnapshot(videoURL: URL, videoID: String? = nil, displayPixelWidth: Int, displayPixelHeight: Int) async {
    guard let cacheDir = WallpaperState.shared.cacheDirectoryURL else {
        traceLog("  [BMPCache] No cacheDirectoryURL, skipping")
        return
    }

    let gained = cacheDir.startAccessingSecurityScopedResource()
    defer { if gained { cacheDir.stopAccessingSecurityScopedResource() } }

    guard gained else {
        traceLog("  [BMPCache] Failed to acquire security-scoped access")
        return
    }

    let hashHex = videoHash(for: videoID ?? videoURL.lastPathComponent)

    // List once: reused for the existing-dimension check and stale cleanup.
    let existingFiles = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)

    // Check if existing BMP for this video already matches requested dimensions
    if let existingFiles {
        for bmp in existingFiles where bmp.pathExtension == "bmp" && bmp.lastPathComponent.hasPrefix(hashHex) {
            let components = bmp.deletingPathExtension().lastPathComponent.components(separatedBy: "-")
            // Filename format: <64-char-hash>-<width>-<height>-0-<timestamp>
            if components.count == 5,
               let existingW = Int(components[1]),
               let existingH = Int(components[2]),
               existingW == displayPixelWidth,
               existingH == displayPixelHeight {
                traceLog("  [BMPCache] Existing BMP matches \(displayPixelWidth)x\(displayPixelHeight) for \(videoID ?? "?"), skipping")
                return
            }
        }
    }

    let asset = AVURLAsset(url: videoURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true

    let cgImage: CGImage
    do {
        cgImage = try await generator.image(at: .zero).image
    } catch {
        traceLog("  [BMPCache] Failed to get video frame: \(error)")
        return
    }

    guard let bmp = bmpData(from: cgImage) else {
        traceLog("  [BMPCache] BMP encode failed for \(cgImage.width)x\(cgImage.height)")
        return
    }

    let timestamp = Date().timeIntervalSinceReferenceDate
    let timestampHex = String(format: "%016llx", timestamp.bitPattern)
    let filename = "\(hashHex)-\(displayPixelWidth)-\(displayPixelHeight)-0-\(timestampHex).bmp"

    // Remove old BMP files for this video from cache
    if let existingFiles {
        for file in existingFiles where file.pathExtension == "bmp" && file.lastPathComponent.hasPrefix(hashHex) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    let bmpURL = cacheDir.appendingPathComponent(filename)
    do {
        try bmp.write(to: bmpURL, options: .atomic)
        traceLog("  [BMPCache] Wrote \(bmp.count) bytes → \(filename)")
    } catch {
        traceLog("  [BMPCache] Write failed: \(error)")
    }

    // Write cacheVersion.db
    let versionURL = cacheDir.appendingPathComponent("cacheVersion.db")
    do {
        try Data("{\"version\":2}".utf8).write(to: versionURL, options: .atomic)
    } catch {
        traceLog("  [BMPCache] cacheVersion.db failed: \(error)")
    }
}

/// Generate a consistent hash prefix for a video identifier.
private func videoHash(for identifier: String) -> String {
    let hash = SHA256.hash(data: Data(identifier.utf8))
    return hash.map { String(format: "%02x", $0) }.joined()
}
