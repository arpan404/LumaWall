import AVFoundation
import CoreVideo
import Foundation
import LumaWallCore
import QuartzCore
import AppKit

@MainActor
final class SharedPlaybackHub {
    private static var hubs: [String: SharedPlaybackHub] = [:]

    let key: String
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let output: AVPlayerItemVideoOutput
    private weak var outputItem: AVPlayerItem?
    private var layers: [ObjectIdentifier: WeakLayer] = [:]
    /// Layers whose sessions are paused/static. They keep their last pumped
    /// frame (pump skips them) while the hub keeps playing for the remaining
    /// unpaused layers. Without this, pausing one display paused the shared
    /// player for every display on the same video, and resuming one resumed
    /// the paused ones (the per-display pause fight).
    private var pausedLayers: Set<ObjectIdentifier> = []
    private var pumpTimer: Timer?
    private var retainCount = 0
    private var sourceFrameRate: Double = 60
    private(set) var isLoaded = false
    /// Internal test hooks. The pump only exists while a frame can actually
    /// change: at least one attached layer is unpaused and the player runs.
    var isPumping: Bool { pumpTimer?.isValid == true }
    private(set) var pumpTickCount = 0

    private struct WeakLayer {
        weak var layer: CALayer?
    }

    static func acquire(url: URL) -> SharedPlaybackHub {
        let key = url.standardizedFileURL.path
        if let existing = hubs[key] {
            existing.retainCount += 1
            return existing
        }
        let hub = SharedPlaybackHub(key: key, url: url)
        hubs[key] = hub
        return hub
    }

    private init(key: String, url: URL) {
        self.key = key
        self.retainCount = 1
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        player.isMuted = true
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = false
        configure(url: url)
    }

    func attach(_ layer: CALayer) {
        layers[ObjectIdentifier(layer)] = WeakLayer(layer: layer)
        pausedLayers.remove(ObjectIdentifier(layer))
        updatePlayback()
    }

    func detach(_ layer: CALayer) {
        layers.removeValue(forKey: ObjectIdentifier(layer))
        pausedLayers.remove(ObjectIdentifier(layer))
        updatePlayback()
    }

    /// Mark one attached layer paused (holds its last frame) or playing.
    /// The shared player runs while ANY attached layer is unpaused and pauses
    /// only when all of them are, so per-display pause no longer freezes (or
    /// resumes) sibling displays on the same video.
    func setLayerPaused(_ paused: Bool, for layer: CALayer) {
        let id = ObjectIdentifier(layer)
        guard layers[id] != nil else { return }
        if paused {
            pausedLayers.insert(id)
        } else {
            pausedLayers.remove(id)
        }
        updatePlayback()
    }

    private func updatePlayback() {
        if hasUnpausedLayer {
            if player.rate == 0 {
                player.play()
            }
            startPump()
        } else {
            player.pause()
            stopPump()
        }
    }

    /// True while an attached layer exists that has not been marked paused.
    /// Dead weak entries do not count, so a hub whose layers went away without
    /// detaching (and whose paused ones hold frames) still stops its pump.
    private var hasUnpausedLayer: Bool {
        layers.contains { id, entry in
            entry.layer != nil && !pausedLayers.contains(id)
        }
    }

    private var shouldPump: Bool {
        hasUnpausedLayer && player.timeControlStatus != .paused
    }

    func release() {
        retainCount = max(0, retainCount - 1)
        guard retainCount == 0 else { return }
        stopPump()
        player.pause()
        looper = nil
        player.replaceCurrentItem(with: nil)
        Self.hubs.removeValue(forKey: key)
        isLoaded = false
    }

    func setDecodeBudget(bitRate: Double, maximumResolution: CGSize) {
        for item in player.items() {
            item.preferredPeakBitRate = bitRate
            item.preferredMaximumResolution = maximumResolution
        }
    }

    func synchronize(atHostTime hostTime: CMTime) {
        guard player.status == .readyToPlay, hasUnpausedLayer else { return }
        player.setRate(1, time: .zero, atHostTime: hostTime)
        // The synchronized start can be the first time the player is asked to
        // run (init no longer starts the pump), so make sure it follows.
        if shouldPump {
            startPump()
        }
    }

    static var activeDecoderCount: Int { hubs.count }

    private func configure(url: URL) {
        player.pause()
        looper = nil
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 1
        looper = AVPlayerLooper(player: player, templateItem: item)
        isLoaded = true
        Task { await refreshSourceFrameRate(for: url) }
    }

    private func refreshSourceFrameRate(for url: URL) async {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let fps = try? await track.load(.nominalFrameRate)
        else { return }
        let rate = Double(fps)
        guard rate.isFinite, rate > 0 else { return }
        sourceFrameRate = rate
        restartPump()
    }

    private func displayMaxFrameRate() -> Double {
        Double(NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60)
    }

    private func restartPump() {
        stopPump()
        startPump()
    }

    private func startPump() {
        guard pumpTimer == nil, shouldPump else { return }
        let interval = PlaybackFrameRate.pumpInterval(
            sourceFPS: sourceFrameRate,
            displayMaxFPS: displayMaxFrameRate()
        )
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            // The timer runs on the main run loop, so hop-free dispatch is safe
            // and avoids one Task allocation per frame.
            MainActor.assumeIsolated { self?.pumpFrames() }
        }
        timer.tolerance = min(0.01, interval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        pumpTimer = timer
    }

    private func stopPump() {
        pumpTimer?.invalidate()
        pumpTimer = nil
    }

    private func pumpFrames() {
        pumpTickCount += 1
        guard let item = player.currentItem else { return }
        // The looper copies the template without its outputs. Follow the
        // actual queue item, including when playback crosses a loop boundary.
        if outputItem !== item {
            outputItem?.remove(output)
            item.add(output)
            outputItem = item
        }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        else { return }
        var foundDeadLayer = false
        for (id, entry) in layers {
            // Paused layers hold their last frame; overwriting them here is
            // what made a "paused" display keep animating on a shared video.
            guard let layer = entry.layer else {
                foundDeadLayer = true
                continue
            }
            if pausedLayers.contains(id) { continue }
            layer.contents = buffer
        }
        // Rebuilding both dictionaries every tick was pure idle work; only do
        // it on the tick that actually observed a deallocated layer.
        if foundDeadLayer {
            layers = layers.filter { $0.value.layer != nil }
            pausedLayers = pausedLayers.filter { layers[$0] != nil }
        }
    }
}
