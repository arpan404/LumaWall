import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ImportInspection: Sendable {
    public let duration: TimeInterval
    public let framesPerSecond: Double
    public let pixelSize: CGSize
    public let fileSize: Int64
    public let contentHash: String
    public let containsAudio: Bool

    public var recommendations: [String] {
        var messages: [String] = []
        if max(pixelSize.width, pixelSize.height) < 1_920 {
            messages.append("The source is below 1080p and may look soft on Retina displays.")
        }
        if duration > 60 { messages.append("Long loops use more storage and take longer to optimize.") }
        if fileSize > 200 * 1_024 * 1_024 { messages.append("This source is larger than 200 MB.") }
        if framesPerSecond > 120 { messages.append("Frame rates above 120 FPS use more GPU.") }
        return messages
    }
}

public struct ImportOutcome: Sendable {
    public let asset: WallpaperAsset
    public let inspection: ImportInspection
    public let removedAudio: Bool
}

/// Metadata read without hashing the file. `importVideo` uses this first so a
/// no-audio import reads the source only once: the copy streams the bytes and
/// hashes them on the way to the destination.
private struct VideoMetadata: Sendable {
    let duration: TimeInterval
    let framesPerSecond: Double
    let pixelSize: CGSize
    let fileSize: Int64
    let containsAudio: Bool
}

public actor MediaImporter {
    public enum ImportError: LocalizedError, Equatable {
        case noVideoTrack
        case invalidDuration
        case unsupportedMedia
        case posterGenerationFailed

        public var errorDescription: String? {
            switch self {
            case .noVideoTrack: "The selected file contains no video track."
            case .invalidDuration: "The video has an invalid duration."
            case .unsupportedMedia: "This video cannot be prepared for wallpaper playback."
            case .posterGenerationFailed: "LumaWall could not create a poster frame."
            }
        }
    }

    private let store: LibraryStore

    public init(store: LibraryStore) { self.store = store }

    /// Full public inspection: metadata plus a content hash of the source.
    /// Unchanged for callers that only inspect before deciding to import.
    public func inspect(_ sourceURL: URL) async throws -> ImportInspection {
        let metadata = try await inspectMetadata(sourceURL)
        let hash = try await Self.sha256(of: sourceURL)
        return ImportInspection(
            duration: metadata.duration,
            framesPerSecond: metadata.framesPerSecond,
            pixelSize: metadata.pixelSize,
            fileSize: metadata.fileSize,
            contentHash: hash,
            containsAudio: metadata.containsAudio
        )
    }

    /// Metadata only, no source read beyond what AVFoundation and the file
    /// system need. Kept private so `importVideo` can defer hashing to the copy.
    private func inspectMetadata(_ sourceURL: URL) async throws -> VideoMetadata {
        let asset = AVURLAsset(url: sourceURL)
        let videoTracks: [AVAssetTrack]
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            // AVFoundation surfaces unreadable media as a raw AVError ("Cannot
            // Open"); prefer the friendly message when the file itself exists.
            if FileManager.default.fileExists(atPath: sourceURL.path) {
                throw ImportError.unsupportedMedia
            }
            throw error
        }
        guard let track = videoTracks.first else {
            throw ImportError.noVideoTrack
        }
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration.isFinite, duration > 0 else { throw ImportError.invalidDuration }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let size = naturalSize.applying(transform)
        let fileSize = Int64(try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let framesPerSecond = try await track.load(.nominalFrameRate)
        return VideoMetadata(
            duration: duration,
            framesPerSecond: Double(framesPerSecond),
            pixelSize: CGSize(width: abs(size.width), height: abs(size.height)),
            fileSize: fileSize,
            containsAudio: !audioTracks.isEmpty
        )
    }

    public func importVideo(_ sourceURL: URL, preferredName: String? = nil) async throws -> ImportOutcome {
        let metadata = try await inspectMetadata(sourceURL)

        let id = WallpaperID()
        let folder = await store.folder(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let mediaURL: URL
            let contentHash: String
            if metadata.containsAudio {
                // Keep the source hash for audio imports: existing library
                // entries were hashed from the original file, and hashing the
                // audio-stripped export would stop recognizing them as
                // duplicates after an upgrade. Check before exporting so a
                // repeat import does not re-encode the whole file.
                contentHash = try await Self.sha256(of: sourceURL)
                if let duplicate = await store.asset(contentHash: contentHash) {
                    throw LibraryStore.StoreError.duplicate(duplicate)
                }
                mediaURL = folder.appendingPathComponent("Wallpaper.mov")
                try await exportVideoOnly(from: sourceURL, to: mediaURL)
            } else {
                let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension.lowercased()
                mediaURL = folder.appendingPathComponent("Wallpaper.\(ext)")
                // One pass: copy to the library and hash the bytes as they
                // stream, instead of hashing the source and then copying it.
                contentHash = try await Self.copyAndHash(from: sourceURL, to: mediaURL)
                // Dedupe after the copy because the hash only exists once the
                // bytes are written. The temporary folder is removed by the
                // catch below.
                if let duplicate = await store.asset(contentHash: contentHash) {
                    throw LibraryStore.StoreError.duplicate(duplicate)
                }
            }

            let posterURL = folder.appendingPathComponent("Poster.jpg")
            try await generatePoster(for: mediaURL, outputURL: posterURL)
            let name = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let asset = WallpaperAsset(
                id: id,
                name: name.flatMap { $0.isEmpty ? nil : $0 }
                    ?? sourceURL.deletingPathExtension().lastPathComponent,
                mediaURL: mediaURL,
                posterURL: posterURL,
                duration: metadata.duration,
                framesPerSecond: metadata.framesPerSecond,
                pixelSize: metadata.pixelSize,
                contentHash: contentHash,
                containsAudio: false
            )
            try await store.install(asset)
            let inspection = ImportInspection(
                duration: metadata.duration,
                framesPerSecond: metadata.framesPerSecond,
                pixelSize: metadata.pixelSize,
                fileSize: metadata.fileSize,
                contentHash: contentHash,
                containsAudio: metadata.containsAudio
            )
            return ImportOutcome(asset: asset, inspection: inspection, removedAudio: metadata.containsAudio)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            await store.invalidateDiskUsageCache()
            throw error
        }
    }

    private func exportVideoOnly(from sourceURL: URL, to outputURL: URL) async throws {
        let sourceAsset = AVURLAsset(url: sourceURL)
        guard let sourceTrack = try await sourceAsset.loadTracks(withMediaType: .video).first else {
            throw ImportError.noVideoTrack
        }
        let duration = try await sourceAsset.load(.duration)
        let composition = AVMutableComposition()
        guard let destination = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw ImportError.unsupportedMedia }
        try destination.insertTimeRange(.init(start: .zero, duration: duration), of: sourceTrack, at: .zero)
        destination.preferredTransform = try await sourceTrack.load(.preferredTransform)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ImportError.unsupportedMedia
        }
        try await exporter.export(to: outputURL, as: .mov)
    }

    private func generatePoster(for mediaURL: URL, outputURL: URL) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: mediaURL))
        generator.appliesPreferredTrackTransform = true
        // A poster is shown scaled down, but 5K/6K desktops still use it as a
        // static wallpaper. 3840 keeps that case sharp while avoiding a full
        // 6K/8K decode for every import.
        generator.maximumSize = CGSize(width: 3_840, height: 3_840)
        let image = try await generator.image(at: .zero).image
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw ImportError.posterGenerationFailed }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImportError.posterGenerationFailed }
    }

    /// Copies `sourceURL` to `destinationURL` while hashing the bytes in the
    /// same pass. `Task.detached` keeps the blocking file I/O off the actor's
    /// executor; cancellation is forwarded explicitly because detached tasks
    /// do not inherit it.
    private nonisolated static func copyAndHash(from sourceURL: URL, to destinationURL: URL) async throws -> String {
        let copyTask = Task.detached(priority: .utility) { () throws -> String in
            let source = try FileHandle(forReadingFrom: sourceURL)
            defer { try? source.close() }
            guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
                throw MediaImporter.ImportError.unsupportedMedia
            }
            let destination = try FileHandle(forWritingTo: destinationURL)
            defer { try? destination.close() }
            var hasher = SHA256()
            while let chunk = try source.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                try destination.write(contentsOf: chunk)
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return try await withTaskCancellationHandler {
            try await copyTask.value
        } onCancel: {
            copyTask.cancel()
        }
    }

    private nonisolated static func sha256(of url: URL) async throws -> String {
        let hashTask = Task.detached(priority: .utility) { () throws -> String in
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return try await withTaskCancellationHandler {
            try await hashTask.value
        } onCancel: {
            hashTask.cancel()
        }
    }
}
