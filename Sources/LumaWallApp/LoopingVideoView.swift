import AVFoundation
import Foundation
import SwiftUI

struct LoopingVideoView: NSViewRepresentable {
    let url: URL
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeNSView(context: Context) -> PlayerSurface {
        let view = PlayerSurface()
        let coordinator = context.coordinator
        // UI chrome never needs a 4K decode: play the silent 720p sibling
        // BatteryMediaVariant writes next to the original file.
        coordinator.reconfigure(url: url, resolvedURL: Self.previewURL(for: url))
        view.playerLayer.player = coordinator.player
        view.playerLayer.videoGravity = gravity
        view.onVisibilityChange = { [weak coordinator] visible in
            coordinator?.setPlaying(visible)
        }
        return view
    }

    func updateNSView(_ view: PlayerSurface, context: Context) {
        view.playerLayer.videoGravity = gravity
        // Recreate the decoder when the URL changes (SwiftUI reuses the view).
        // Without this, hero/carousel reuse silently kept playing the old video.
        let resolved = Self.previewURL(for: url)
        if context.coordinator.url != url || context.coordinator.resolvedURL != resolved {
            context.coordinator.reconfigure(url: url, resolvedURL: resolved)
            view.playerLayer.player = context.coordinator.player
        }
    }

    static func dismantleNSView(_ view: PlayerSurface, coordinator: Coordinator) {
        coordinator.setPlaying(false)
        coordinator.tearDown()
        view.playerLayer.player = nil
    }

    /// 720p sibling used for small UI previews, when the background transcode
    /// has produced one. Falls back to the original media until then. Resolved
    /// through BatteryMediaVariant's positive cache, so repeated SwiftUI
    /// updates don't stat the sibling on every pass.
    @MainActor private static func previewURL(for url: URL) -> URL {
        BatteryMediaVariant.resolvedPreviewURL(for: url)
    }

    @MainActor
    final class Coordinator {
        let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private(set) var url: URL
        private(set) var resolvedURL: URL?
        private var desiredPlaying = false
        private var readinessTask: Task<Void, Never>?

        init(url: URL) {
            self.url = url
            player.isMuted = true
            player.actionAtItemEnd = .none
            player.automaticallyWaitsToMinimizeStalling = false
        }

        /// Swap the looping item for a new URL (main thread, SwiftUI update).
        func reconfigure(url: URL, resolvedURL: URL? = nil) {
            self.url = url
            load(url: resolvedURL ?? LoopingVideoView.previewURL(for: url))
        }

        /// Idempotent play/pause. `play()` only runs once the item is ready and
        /// the player is not already playing, so repeated visibility updates
        /// can't restart a running decoder.
        func setPlaying(_ playing: Bool) {
            desiredPlaying = playing
            readinessTask?.cancel()
            readinessTask = nil
            guard playing else {
                player.pause()
                return
            }
            guard player.rate != 1 else { return }
            guard player.currentItem?.status == .readyToPlay else {
                // The item is still loading (fresh view or reconfigure). Poll
                // briefly instead of queueing play() calls on every update.
                readinessTask = Task { @MainActor [weak self] in
                    var attempts = 0
                    while let self, !Task.isCancelled, self.desiredPlaying {
                        let status = self.player.currentItem?.status
                        if status == .readyToPlay {
                            if self.player.rate != 1 { self.player.play() }
                            return
                        }
                        if status == .failed { return }
                        attempts += 1
                        // Stop polling for an item that never becomes ready
                        // (missing/corrupt file) instead of running forever.
                        if attempts >= 100 { return }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
                return
            }
            player.play()
        }

        /// Fully release the decoder for view teardown.
        func tearDown() {
            desiredPlaying = false
            readinessTask?.cancel()
            readinessTask = nil
            player.pause()
            looper = nil
            player.replaceCurrentItem(with: nil)
            resolvedURL = nil
        }

        private func load(url: URL) {
            resolvedURL = url
            player.pause()
            looper = nil
            player.replaceCurrentItem(with: nil)
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            if desiredPlaying { setPlaying(true) }
        }
    }
}

final class PlayerSurface: NSView {
    let playerLayer = AVPlayerLayer()
    /// Called whenever the hosting window's visibility changes. Menu bar
    /// popovers may never become active, so playback follows window occlusion,
    /// not app activation.
    var onVisibilityChange: (@MainActor (Bool) -> Void)?

    private weak var observedWindow: NSWindow?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = playerLayer
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func layout() { super.layout(); playerLayer.frame = bounds }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if observedWindow !== window {
            detachWindowObservers()
            attachWindowObservers()
        }
        notifyVisibility()
    }

    private var isPlaybackVisible: Bool {
        guard let window, window.isVisible, !window.isMiniaturized else { return false }
        return window.occlusionState.contains(.visible)
    }

    private func attachWindowObservers() {
        guard let window else { return }
        observedWindow = window
        let center = NotificationCenter.default
        // Selector-based observers are removed automatically when the view is
        // deallocated; no token storage (and no nonisolated deinit access).
        for name in [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification,
        ] {
            center.addObserver(self, selector: #selector(windowVisibilityChanged), name: name, object: window)
        }
    }

    private func detachWindowObservers() {
        NotificationCenter.default.removeObserver(self)
        observedWindow = nil
    }

    @objc private func windowVisibilityChanged(_ notification: Notification) {
        // A closing window may still report itself visible during willClose;
        // pause immediately instead of trusting the pre-close state.
        if notification.name == NSWindow.willCloseNotification {
            onVisibilityChange?(false)
        } else {
            notifyVisibility()
        }
    }

    private func notifyVisibility() {
        onVisibilityChange?(isPlaybackVisible)
    }
}
