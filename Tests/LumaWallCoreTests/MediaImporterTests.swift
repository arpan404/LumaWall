import AVFoundation
import AVFAudio
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import LumaWallCore

/// End-to-end import tests with synthesized videos, no fixtures, no production
/// data. Videos are encoded in-test with `AVAssetWriter` (software H.264 works
/// headless), so every path runs on any Mac.
///
/// Serialized: the tests share one hardware/software encoder resource, and
/// parallel encodes flaked the runner (VideoToolbox contention under load).
@Suite(.serialized)
struct MediaImporterTests {
    @Test func inspectsSynthesizedSilentVideo() async throws {
        let source = try await makeVideo(withAudio: false)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let importer = try MediaImporter(store: store(at: source.deletingLastPathComponent()))

        let inspection = try await importer.inspect(source)
        #expect(abs(inspection.duration - 1.0) < 0.25)
        #expect(abs(inspection.pixelSize.width - 1280) < 1)
        #expect(abs(inspection.pixelSize.height - 720) < 1)
        #expect(!inspection.containsAudio)
        #expect(inspection.contentHash.count == 64)
        #expect(inspection.fileSize > 0)
        // 1280 wide is below the 1080p bar: softness warning must fire.
        #expect(inspection.recommendations.contains {
            $0.contains("below 1080p")
        })
    }

    @Test func importsSilentVideoByCopyWithPoster() async throws {
        let dir = isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await makeVideo(withAudio: false, in: dir, name: "clip.mov")
        let importer = try MediaImporter(store: store(at: dir))

        let inspection = try await importer.inspect(source)
        let outcome = try await importer.importVideo(source, preferredName: "  Demo  ")
        #expect(outcome.asset.name == "Demo")
        #expect(!outcome.removedAudio)
        #expect(outcome.asset.mediaURL.pathExtension == "mov")
        #expect(FileManager.default.fileExists(atPath: outcome.asset.mediaURL.path))
        #expect(FileManager.default.fileExists(atPath: try #require(outcome.asset.posterURL).path))
        // Copy-and-hash must match inspect's hash of the same source bytes.
        #expect(outcome.asset.contentHash == inspection.contentHash)
    }

    @Test func blankPreferredNameFallsBackToFilename() async throws {
        let dir = isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await makeVideo(withAudio: false, in: dir, name: "myclip.mov")
        let importer = try MediaImporter(store: store(at: dir))

        let outcome = try await importer.importVideo(source, preferredName: "   ")
        #expect(outcome.asset.name == "myclip")
    }

    @Test func importsVideoWithAudioStripped() async throws {
        let dir = isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await makeVideo(withAudio: true, in: dir, name: "talkie.mov")
        let importer = try MediaImporter(store: store(at: dir))

        let sourceAsset = AVURLAsset(url: source)
        let sourceDuration = CMTimeGetSeconds(try await sourceAsset.load(.duration))
        let sourceVideoTracks = try await sourceAsset.loadTracks(withMediaType: .video)
        let sourceTrack = try #require(sourceVideoTracks.first)
        let sourceSize = try await sourceTrack.load(.naturalSize)
        let sourceRate = try await sourceTrack.load(.nominalFrameRate)
        let sourceInspection = try await importer.inspect(source)

        let outcome = try await importer.importVideo(source)
        #expect(outcome.removedAudio)
        #expect(outcome.asset.mediaURL.lastPathComponent == "Wallpaper.mov")
        let output = AVURLAsset(url: outcome.asset.mediaURL)
        #expect(try await output.loadTracks(withMediaType: .audio).isEmpty)
        let outputVideoTracks = try await output.loadTracks(withMediaType: .video)
        let outputTrack = try #require(outputVideoTracks.first)

        // Stripping audio must not change the playback metadata.
        let outputDuration = CMTimeGetSeconds(try await output.load(.duration))
        let outputSize = try await outputTrack.load(.naturalSize)
        let outputRate = try await outputTrack.load(.nominalFrameRate)
        #expect(abs(outputDuration - sourceDuration) < 0.1)
        #expect(abs(outputSize.width - sourceSize.width) < 1)
        #expect(abs(outputSize.height - sourceSize.height) < 1)
        #expect(abs(outputRate - sourceRate) < 0.5)

        // The stored asset keeps the source's inspection values, and records
        // that audio was removed.
        #expect(abs(outcome.asset.duration - sourceDuration) < 0.1)
        #expect(abs(outcome.asset.framesPerSecond - Double(sourceRate)) < 0.5)
        #expect(abs(outcome.asset.pixelSize.width - sourceSize.width) < 1)
        #expect(outcome.inspection.containsAudio)
        #expect(!outcome.asset.containsAudio)
        // Audio imports keep the source hash so existing library entries are
        // still recognized as duplicates after an upgrade.
        #expect(outcome.asset.contentHash == sourceInspection.contentHash)
    }

    @Test func duplicateImportThrowsDuplicate() async throws {
        let dir = isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await makeVideo(withAudio: false, in: dir, name: "once.mov")
        let importer = try MediaImporter(store: store(at: dir))
        _ = try await importer.importVideo(source)
        let libraryRoot = dir.appendingPathComponent("Library", isDirectory: true)
        let before = try FileManager.default.contentsOfDirectory(atPath: libraryRoot.path).sorted()

        await expectDuplicate(importer, source)

        // The failed import's copy must not be left behind as an orphan.
        let after = try FileManager.default.contentsOfDirectory(atPath: libraryRoot.path).sorted()
        #expect(after == before)
    }

    @Test func duplicateAudioImportThrowsAndCleansUp() async throws {
        let dir = isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await makeVideo(withAudio: true, in: dir, name: "talkie-once.mov")
        let importer = try MediaImporter(store: store(at: dir))
        _ = try await importer.importVideo(source)
        let libraryRoot = dir.appendingPathComponent("Library", isDirectory: true)
        let before = try FileManager.default.contentsOfDirectory(atPath: libraryRoot.path).sorted()

        await expectDuplicate(importer, source)

        let after = try FileManager.default.contentsOfDirectory(atPath: libraryRoot.path).sorted()
        #expect(after == before)
    }

    @Test func inspectRejectsNonVideo() async throws {
        let dir = isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = dir.appendingPathComponent("notes.txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)
        let importer = try MediaImporter(store: store(at: dir))

        // Unreadable media maps to the friendly error, not a raw AVError.
        await #expect(throws: MediaImporter.ImportError.self) {
            try await importer.inspect(text)
        }
        do {
            _ = try await importer.inspect(text)
            Issue.record("expected inspect to throw for a text file")
        } catch let error as MediaImporter.ImportError {
            #expect(error == .unsupportedMedia)
        }
    }

    @Test func inspectRejectsAudioOnlyFile() async throws {
        let dir = isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = try await makeAudioOnly(in: dir)
        let importer = try MediaImporter(store: store(at: dir))

        do {
            _ = try await importer.inspect(audio)
            Issue.record("expected inspect to throw for an audio-only file")
        } catch let error as MediaImporter.ImportError {
            #expect(error == .noVideoTrack)
        }
    }

    @Test func importErrorMessagesAreHumanReadable() {
        #expect(MediaImporter.ImportError.noVideoTrack.errorDescription?
            .contains("no video track") == true)
        #expect(!(MediaImporter.ImportError.invalidDuration.errorDescription?.isEmpty ?? true))
        #expect(!(MediaImporter.ImportError.unsupportedMedia.errorDescription?.isEmpty ?? true))
        #expect(!(MediaImporter.ImportError.posterGenerationFailed.errorDescription?.isEmpty ?? true))
    }

    @Test func recommendationsFlagLongHeavyAndFastSources() {
        func inspection(duration: TimeInterval, fps: Double, fileSize: Int64) -> ImportInspection {
            ImportInspection(
                duration: duration, framesPerSecond: fps,
                pixelSize: CGSize(width: 3840, height: 2160),
                fileSize: fileSize, contentHash: String(repeating: "a", count: 64),
                containsAudio: false
            )
        }
        #expect(inspection(duration: 61, fps: 30, fileSize: 10).recommendations.contains {
            $0.contains("Long loops")
        })
        #expect(inspection(duration: 5, fps: 30, fileSize: 201 * 1_024 * 1_024).recommendations.contains {
            $0.contains("200 MB")
        })
        #expect(inspection(duration: 5, fps: 240, fileSize: 10).recommendations.contains {
            $0.contains("120 FPS")
        })
        #expect(inspection(duration: 5, fps: 30, fileSize: 10).recommendations.isEmpty)
    }

    // MARK: - Helpers

    private func isolatedDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func store(at dir: URL) throws -> LibraryStore {
        try LibraryStore(rootURL: dir.appendingPathComponent("Library", isDirectory: true))
    }

    /// Asserts that importing `source` again fails specifically as a duplicate.
    private func expectDuplicate(_ importer: MediaImporter, _ source: URL) async {
        do {
            _ = try await importer.importVideo(source)
            Issue.record("expected duplicate import to throw")
        } catch let error as LibraryStore.StoreError {
            guard case .duplicate = error else {
                Issue.record("expected duplicate, got \(error)")
                return
            }
        } catch {
            Issue.record("expected duplicate, got \(error)")
        }
    }

    /// Encodes a 1-second 1280×720 black H.264 movie, optionally with a silent
    /// mono AAC track, and returns its URL.
    private func makeVideo(withAudio: Bool, in dir: URL? = nil, name: String = "source.mov") async throws -> URL {
        let dir = try dir.map {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
            return $0
        } ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1280,
            AVVideoHeightKey: 720,
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 1280,
                kCVPixelBufferHeightKey as String: 720,
            ]
        )
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if withAudio {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
            )
            var format: CMFormatDescription?
            guard CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0,
                layout: nil, magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &format
            ) == noErr, let format else { throw MediaImporter.ImportError.unsupportedMedia }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
            ], sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let frames = 30
        for frame in 0..<frames {
            while !videoInput.isReadyForMoreMediaData { await Task.yield() }
            let buffer = try makeBlackPixelBuffer()
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        if let audioInput {
            while !audioInput.isReadyForMoreMediaData { await Task.yield() }
            // Feed silence decoded from a WAV via AVAssetReader, so every
            // appended buffer is well-formed by construction (hand-rolled
            // CMSampleBuffers segfaulted the runner).
            let silence = try makeSilenceWAV(in: dir)
            let readerAsset = AVURLAsset(url: silence)
            guard let audioTrack = try await readerAsset.loadTracks(withMediaType: .audio).first else {
                throw MediaImporter.ImportError.unsupportedMedia
            }
            let reader = try AVAssetReader(asset: readerAsset)
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            reader.add(output)
            reader.startReading()
            while let sample = output.copyNextSampleBuffer() {
                while !audioInput.isReadyForMoreMediaData { await Task.yield() }
                audioInput.append(sample)
            }
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        await finishWriting(writer)
        guard writer.status == .completed else {
            throw MediaImporter.ImportError.unsupportedMedia
        }
        return url
    }

    /// Finish an `AVAssetWriter` via its completion-handler API. The async
    /// `finishWriting()` overlay traps in this environment (checked
    /// continuation resumed twice through KVO); the handler form is reliable.
    private func finishWriting(_ writer: AVAssetWriter) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }
    }

    /// Encodes a 1-second silent mono WAV (no video track) and returns its URL.
    /// Written with AVAudioFile (safe high-level API), never hand-rolled buffers.
    private func makeSilenceWAV(in dir: URL, name: String = "tone.wav") throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else {
            throw MediaImporter.ImportError.unsupportedMedia
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else {
            throw MediaImporter.ImportError.unsupportedMedia
        }
        buffer.frameLength = buffer.frameCapacity
        memset(buffer.floatChannelData![0], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    /// Encodes a 1-second silent mono WAV (no video track) and returns its URL.
    private func makeAudioOnly(in dir: URL, name: String = "tone.wav") async throws -> URL {
        try makeSilenceWAV(in: dir, name: name)
    }

    private func makeBlackPixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA, nil, &buffer
        ) == kCVReturnSuccess, let buffer else {
            throw MediaImporter.ImportError.unsupportedMedia
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetDataSize(buffer))
        return buffer
    }

}
