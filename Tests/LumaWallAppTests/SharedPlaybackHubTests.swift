import AVFoundation
import AppKit
import LumaWallCore
import QuartzCore
import XCTest
@testable import LumaWall

final class SharedPlaybackHubTests: XCTestCase {
    @MainActor
    func testSharedVideoRendersChangingFramesOnBothDisplays() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await writeVideo(to: url)
        let hub = SharedPlaybackHub.acquire(url: url)
        let layers = [CALayer(), CALayer()]
        for layer in layers {
            layer.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
            hub.attach(layer)
        }
        defer {
            for layer in layers { hub.detach(layer) }
            hub.release()
        }

        let deadline = Date().addingTimeInterval(5)
        while layers[0].contents == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(layers[0].contents, "The decoder must produce a frame")
        let first = try layers.map(render)
        XCTAssertGreaterThan(first[0][3], 0, "Decoded frames must be visible, not transparent")
        XCTAssertEqual(first[0], first[1], "Both displays must receive the same frame")
        try await Task.sleep(for: .milliseconds(350))
        let next = try layers.map(render)
        XCTAssertNotEqual(first[0], next[0], "The wallpaper must keep moving after it is assigned")
        XCTAssertEqual(next[0], next[1])

        hub.setLayerPaused(true, for: layers[0])
        let held = try render(layers[0])
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(held, try render(layers[0]), "Pausing one display must hold its frame")
        XCTAssertNotEqual(next[1], try render(layers[1]), "The other display must keep playing")
        hub.setLayerPaused(false, for: layers[0])
        try await Task.sleep(for: .seconds(3.2))
        let afterLoop = try layers.map(render)
        try await Task.sleep(for: .milliseconds(350))
        let loopNext = try layers.map(render)
        XCTAssertNotEqual(afterLoop[0], loopNext[0], "Playback must continue on the next loop item")
        XCTAssertEqual(loopNext[0], loopNext[1])
    }

    @MainActor
    func testFullyPausedHubStopsPumpingAndHoldsEveryFrame() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await writeVideo(to: url)
        let hub = SharedPlaybackHub.acquire(url: url)
        let layers = [CALayer(), CALayer()]
        for layer in layers {
            layer.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
            hub.attach(layer)
        }
        defer {
            for layer in layers { hub.detach(layer) }
            hub.release()
        }

        let deadline = Date().addingTimeInterval(5)
        while layers.contains(where: { $0.contents == nil }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(layers.allSatisfy { $0.contents != nil }, "The decoder must produce a frame before pausing")
        let initial = try layers.map(render)
        XCTAssertEqual(initial[0], initial[1], "Both displays receive the same frame")
        XCTAssertTrue(hub.isPumping, "An attached, playing hub must run its pump")

        for layer in layers { hub.setLayerPaused(true, for: layer) }
        XCTAssertFalse(hub.isPumping, "Pausing every display must stop the pump")
        // Let a tick that was already queued on the main actor drain before
        // snapshotting the counter; only the idle period must be tick-free.
        try await Task.sleep(for: .milliseconds(150))
        let tickCount = hub.pumpTickCount
        let held = try layers.map(render)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(hub.isPumping)
        XCTAssertEqual(hub.pumpTickCount, tickCount, "A fully paused hub must not tick")
        let stillHeld = try layers.map(render)
        XCTAssertEqual(stillHeld, held, "Paused displays must hold their last frames")

        hub.setLayerPaused(false, for: layers[0])
        XCTAssertTrue(hub.isPumping, "Unpausing one display must restart the pump")
        let resumeDeadline = Date().addingTimeInterval(3)
        var resumed = false
        while Date() < resumeDeadline {
            try await Task.sleep(for: .milliseconds(50))
            if try render(layers[0]) != held[0] {
                resumed = true
                break
            }
        }
        XCTAssertTrue(resumed, "The unpaused display must receive new frames")
        XCTAssertEqual(try render(layers[1]), held[1], "The still-paused display must keep its held frame")
        XCTAssertGreaterThan(hub.pumpTickCount, tickCount)
    }

    @MainActor
    func testSwitchingFromPrivateToSharedPlaybackKeepsVideoVisible() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await writeVideo(to: url)
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let display = try XCTUnwrap(DisplayCoordinator().displays.first)
        let asset = WallpaperAsset(name: "Motion fixture", mediaURL: url, duration: 3,
                                   framesPerSecond: 30, pixelSize: CGSize(width: 32, height: 32),
                                   contentHash: "fixture", containsAudio: false)
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let session = DesktopVideoSession(asset: asset, composition: .init(), screen: screen, connected: display)
        defer { session.tearDown() }
        let window = try XCTUnwrap(NSApp.windows.first { !existingWindows.contains(ObjectIdentifier($0)) })
        let hub = SharedPlaybackHub.acquire(url: url)
        session.attachSharedHub(hub)
        session.apply(tier: .full)
        try await Task.sleep(for: .milliseconds(500))
        let layer = try XCTUnwrap(window.contentView?.layer)
        let first = try render(layer)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertNotEqual(first, try render(layer), "Private-player readiness callbacks must not hide shared video")
    }

    @MainActor
    func testReplacingASharedWallpaperRendersTheNewVideoOnBothDisplays() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldURL = directory.appendingPathComponent("old.mov")
        let newURL = directory.appendingPathComponent("new.mov")
        try await writeVideo(to: oldURL)
        try await writeVideo(to: newURL, blue: true)
        let oldAsset = fixtureAsset(url: oldURL)
        let newAsset = fixtureAsset(url: newURL)
        let baseline = SharedPlaybackHub.activeDecoderCount
        let first = try makeSession(asset: oldAsset)
        let second = try makeSession(asset: oldAsset)
        defer { first.session.tearDown(); second.session.tearDown() }
        let oldHub = SharedPlaybackHub.acquire(url: oldURL)
        _ = SharedPlaybackHub.acquire(url: oldURL)
        for session in [first.session, second.session] {
            session.attachSharedHub(oldHub)
            session.apply(tier: .full)
        }
        try await assertMoving([first.layer, second.layer])
        let oldPixel = try render(first.layer)
        XCTAssertGreaterThan(oldPixel[0], oldPixel[2], "The old fixture must be red")

        let screen = try XCTUnwrap(NSScreen.screens.first)
        let display = try XCTUnwrap(DisplayCoordinator().displays.first)
        for session in [first.session, second.session] {
            session.replace(asset: newAsset, composition: .init(), screen: screen, connected: display)
        }
        XCTAssertFalse(oldHub.isLoaded, "Replacing the last display must release the old decoder")
        let newHub = SharedPlaybackHub.acquire(url: newURL)
        _ = SharedPlaybackHub.acquire(url: newURL)
        for session in [first.session, second.session] {
            session.attachSharedHub(newHub)
            session.apply(tier: .full)
        }
        try await assertMoving([first.layer, second.layer])
        for layer in [first.layer, second.layer] {
            let pixel = try render(layer)
            XCTAssertGreaterThan(pixel[2], pixel[0], "Replacing a wallpaper must display the new blue video")
        }
        first.session.tearDown()
        second.session.tearDown()
        XCTAssertEqual(SharedPlaybackHub.activeDecoderCount, baseline, "Changing wallpaper must not leak decoders")
    }

    @MainActor
    func testMemoryCleanupThenResumeRestoresMovingVideo() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await writeVideo(to: url)
        let fixture = try makeSession(asset: fixtureAsset(url: url))
        defer { fixture.session.tearDown() }
        let oldHub = SharedPlaybackHub.acquire(url: url)
        fixture.session.attachSharedHub(oldHub)
        fixture.session.apply(tier: .full)
        try await assertMoving([fixture.layer])
        fixture.session.releaseDecoderNow()
        XCTAssertFalse(oldHub.isLoaded)

        let resumedHub = SharedPlaybackHub.acquire(url: url)
        fixture.session.attachSharedHub(resumedHub)
        fixture.session.apply(tier: .full)
        try await assertMoving([fixture.layer])
    }

    private func fixtureAsset(url: URL) -> WallpaperAsset {
        WallpaperAsset(name: url.lastPathComponent, mediaURL: url, duration: 3,
                       framesPerSecond: 30, pixelSize: CGSize(width: 32, height: 32),
                       contentHash: url.lastPathComponent, containsAudio: false)
    }

    @MainActor
    private func makeSession(asset: WallpaperAsset) throws -> (session: DesktopVideoSession, layer: CALayer) {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let display = try XCTUnwrap(DisplayCoordinator().displays.first)
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let session = DesktopVideoSession(asset: asset, composition: .init(), screen: screen, connected: display)
        let window = try XCTUnwrap(NSApp.windows.first { !existingWindows.contains(ObjectIdentifier($0)) })
        return (session, try XCTUnwrap(window.contentView?.layer))
    }

    @MainActor
    private func assertMoving(_ layers: [CALayer], file: StaticString = #filePath, line: UInt = #line) async throws {
        // Allow asynchronous decoder startup; a fixed initial sleep flakes on busy runners.
        let deadline = Date().addingTimeInterval(5)
        var previous = try layers.map(render)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(150))
            let current = try layers.map(render)
            let hadVideo = previous.allSatisfy { $0[3] > 0 && $0.prefix(3).contains(where: { $0 > 0 }) }
            if hadVideo, zip(previous, current).allSatisfy({ $0 != $1 }) { return }
            previous = current
        }
        XCTFail("Every assigned display must render changing video frames", file: file, line: line)
    }

    @MainActor
    private func render(_ layer: CALayer) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                                            bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 32 / layer.bounds.width, y: 32 / layer.bounds.height)
        layer.render(in: context)
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: 4))
    }

    @MainActor
    private func writeVideo(to url: URL, blue: Bool = false) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                                         kCVPixelBufferWidthKey as String: 32,
                                         kCVPixelBufferHeightKey as String: 32])
        writer.add(input)
        guard writer.startWriting() else { throw try XCTUnwrap(writer.error) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<90 {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData {
                if let error = writer.error { throw error }
                guard Date() < deadline else { throw CocoaError(.coderInvalidValue) }
                try await Task.sleep(for: .milliseconds(5))
            }
            var pixelBuffer: CVPixelBuffer?
            let pool = try XCTUnwrap(adaptor.pixelBufferPool)
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixelBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<32 {
                for x in 0..<32 {
                    let offset = y * stride + x * 4
                    bytes[offset] = 255
                    bytes[offset + 1] = UInt8(blue ? frame * 2 : 100 + frame)
                    bytes[offset + 2] = 40
                    bytes[offset + 3] = blue ? 220 : 30
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
