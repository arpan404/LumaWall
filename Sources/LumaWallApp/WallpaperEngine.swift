import AVFoundation
import AppKit
import LumaWallCore
import QuartzCore

@MainActor
final class OverlayWallpaperEngine {
    private let displays: DisplayCoordinator
    private let assignments: AssignmentStore
    private var sessions: [DisplayID: DesktopVideoSession] = [:]
    private var tiers: [DisplayID: PlaybackTier] = [:]
    // Observer tokens + pending work are touched on MainActor during life, but
    // nonisolated deinit must also reach them. nonisolated(unsafe) with
    // init-once/deinit-once discipline (mutations otherwise happen on MainActor
    // while the instance is alive; deinit runs exclusively after last release).
    nonisolated(unsafe) private var recoveryWorkItems: [DispatchWorkItem] = []
    nonisolated(unsafe) private var notificationTokens: [NSObjectProtocol] = []
    nonisolated(unsafe) private var workspaceTokens: [NSObjectProtocol] = []
    /// Debounced geometry rebuild (see `scheduleGeometryRebuild`). Same
    /// init-once/deinit-once discipline as the tokens above.
    nonisolated(unsafe) private var geometryWorkItem: DispatchWorkItem?

    init(displays: DisplayCoordinator, assignments: AssignmentStore) {
        self.displays = displays
        self.assignments = assignments
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleSurfaceRecovery() }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // didChangeScreenParameters fires in bursts during a join/cut/mode
            // probe, and a display can flicker out for a single event. Pruning
            // sessions on every fire destroys windows for displays that are
            // still there (and rebuilds them a moment later, the visible
            // glitch loop). Debounce so only the settled topology applies.
            Task { @MainActor in self?.scheduleGeometryRebuild() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleSurfaceRecovery() }
        })
        workspaceTokens.append(workspace.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.finder" || app?.bundleIdentifier == "com.apple.dock" else { return }
            Task { @MainActor in self?.scheduleSurfaceRecovery() }
        })
    }

    deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        for token in workspaceTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        for work in recoveryWorkItems {
            work.cancel()
        }
        geometryWorkItem?.cancel()
    }

    var activeDisplayIDs: Set<DisplayID> { Set(sessions.keys) }

    func wallpaperID(on displayID: DisplayID) -> WallpaperID? {
        sessions[displayID]?.asset.id
    }

    func composition(on displayID: DisplayID) -> DisplayComposition {
        sessions[displayID]?.currentComposition ?? .init()
    }

    func tier(on displayID: DisplayID) -> PlaybackTier {
        tiers[displayID] ?? .full
    }

    func apply(_ asset: WallpaperAsset, to displayID: DisplayID, composition: DisplayComposition = .init()) async throws {
        try activate(asset, on: displayID, composition: composition)
        try await assignments.upsert(
            DisplayAssignment(displayID: displayID, wallpaperID: asset.id, composition: composition, isEnabled: true)
        )
    }

    private func activate(_ asset: WallpaperAsset, on displayID: DisplayID, composition: DisplayComposition) throws {
        // Refresh on cache miss: after a join/cut the cached ConnectedDisplay
        // list is stale, and throwing missingDisplay here (then showing an
        // alert) is the "glitches when display is joined or cut off" path.
        // A live lookup must consult the refreshed topology.
        var screen = displays.screen(for: displayID)
        var connected = displays.display(id: displayID)
        if screen == nil || connected == nil {
            let fresh = displays.refresh()
            screen = screen ?? NSScreen.screens.first { DisplayCoordinator.stableID(for: $0) == displayID }
            connected = connected ?? fresh.first { $0.displayID == displayID }
        }
        guard let screen, let connected else {
            throw EngineError.missingDisplay
        }

        installSystemPoster(asset.posterURL ?? asset.mediaURL, on: screen)
        if let existing = sessions[displayID] {
            existing.replace(asset: asset, composition: composition, screen: screen, connected: connected)
        } else {
            let tier = tiers[displayID] ?? .full
            let session = DesktopVideoSession(asset: asset, composition: composition, screen: screen, connected: connected, tier: tier)
            sessions[displayID] = session
            session.show()
        }
        // Kick off the 720p sibling now (async, cached): by the time the user
        // flips to Battery Saver / unplugs on Automatic, the variant exists and
        // the tier switch moves to it immediately instead of transcoding first.
        Task { await BatteryMediaVariant.ensure(for: asset) }
        apply(tier: tiers[displayID] ?? .full, to: displayID)
        reconcileSharedDecoders()
    }

    func applyToAll(_ asset: WallpaperAsset, composition: DisplayComposition = .init()) async throws {
        let connected = displays.refresh()
        guard !connected.isEmpty else { throw EngineError.missingDisplay }
        for display in connected {
            try activate(asset, on: display.displayID, composition: composition)
        }
        try await assignments.upsert(connected.map {
            DisplayAssignment(displayID: $0.displayID, wallpaperID: asset.id, composition: composition, isEnabled: true)
        })
        synchronize(displayIDs: connected.map(\.displayID))
    }

    func applySpanning(_ asset: WallpaperAsset) async throws {
        let connected = displays.refresh()
        guard !connected.isEmpty else { throw EngineError.missingDisplay }
        guard let canvas = SpanningGeometry.canvas(for: connected.map(\.frame)) else {
            throw EngineError.missingDisplay
        }
        let composition = DisplayComposition(contentMode: .fill, spanningCanvas: canvas)
        for display in connected {
            try activate(asset, on: display.displayID, composition: composition)
        }
        try await assignments.upsert(connected.map {
            DisplayAssignment(displayID: $0.displayID, wallpaperID: asset.id, composition: composition, isEnabled: true)
        })
        synchronize(displayIDs: connected.map(\.displayID))
    }

    private func synchronize(displayIDs: [DisplayID]) {
        let clock = CMClockGetHostTimeClock()
        let now = CMClockGetTime(clock)
        let start = CMTimeAdd(now, CMTime(seconds: 0.25, preferredTimescale: 1_000_000_000))
        for id in displayIDs where tiers[id] == .full || tiers[id] == .reduced || tiers[id] == .minimal {
            sessions[id]?.synchronize(atHostTime: start, tier: tiers[id] ?? .full)
        }
    }

    func clear(_ displayID: DisplayID) async throws {
        dismantleSession(displayID)
        try await assignments.clear(displayID: displayID)
    }

    func clearAll() async throws {
        dismantleSessions()
        try await assignments.clearAll()
    }

    /// Tears down overlay windows without touching the shared assignment
    /// store. Used when the native host takes over rendering the same
    /// assignments, clearing the store here would wipe what native restore
    /// is about to read.
    func dismantleSession(_ displayID: DisplayID) {
        sessions.removeValue(forKey: displayID)?.tearDown()
        tiers.removeValue(forKey: displayID)
        reconcileSharedDecoders()
    }

    func dismantleSessions() {
        // Snapshot the keys: mutating the dictionary while iterating its live
        // keys view corrupts the table (and every session/window it owns).
        for key in Array(sessions.keys) {
            sessions.removeValue(forKey: key)?.tearDown()
        }
        tiers.removeAll()
    }

    func apply(tier: PlaybackTier, to displayID: DisplayID) {
        guard tiers[displayID] != tier else { return }
        tiers[displayID] = tier
        sessions[displayID]?.apply(tier: tier)
    }

    func reconcileSharedDecoders() {
        // Incremental reconcile: the old code detached EVERY session on each
        // apply, destroying and recreating the shared hub per display added.
        // Each detach cleared layer.contents (black flash) and reset playback,
        // so applying to N displays flickered N times. Only touch sessions
        // whose sharing state actually changed.
        //
        // Groups key on the tier-resolved URL (full file vs. 720p battery
        // sibling), not the raw media path: a display on Battery Saver must
        // share the downscaled decode with other saver displays, while a Full
        // Quality display keeps the full-res one. Variants that don't exist
        // yet resolve to the full file, so grouping degrades to the old
        // behavior until the background transcode lands (which then regroups).
        var groups: [String: [(DisplayID, DesktopVideoSession)]] = [:]
        for (id, session) in sessions {
            let tier = tiers[id] ?? .full
            if tier != .full {
                Task { await BatteryMediaVariant.ensure(for: session.asset) }
            }
            let key = BatteryMediaVariant.resolvedURL(for: session.asset, tier: tier)
                .standardizedFileURL.path
            groups[key, default: []].append((id, session))
        }
        var desiredHubKey: [ObjectIdentifier: String?] = [:]
        for (id, session) in sessions {
            let tier = tiers[id] ?? .full
            let key = BatteryMediaVariant.resolvedURL(for: session.asset, tier: tier)
                .standardizedFileURL.path
            let group = groups[key] ?? []
            desiredHubKey[ObjectIdentifier(session)] = group.count >= 2 ? key : nil
        }
        var alreadyCorrect = true
        for session in sessions.values {
            let want = desiredHubKey[ObjectIdentifier(session)] ?? nil
            if session.sharedHubKey != want {
                alreadyCorrect = false
                break
            }
        }
        if alreadyCorrect {
            for (id, session) in sessions {
                session.apply(tier: tiers[id] ?? .full)
            }
            return
        }
        for session in sessions.values {
            session.detachSharedHub()
        }
        for (key, group) in groups {
            if group.count >= 2 {
                let url = URL(fileURLWithPath: key)
                let hub = SharedPlaybackHub.acquire(url: url)
                for _ in 1..<group.count {
                    _ = SharedPlaybackHub.acquire(url: url)
                }
                for (_, session) in group {
                    session.attachSharedHub(hub)
                }
            } else if let (id, session) = group.first {
                // Build the tier's variant up front so the trailing apply pass
                // doesn't immediately throw it away and rebuild (one wasted
                // decoder per regroup on reduced/minimal tiers).
                let tier = tiers[id] ?? .full
                session.usePrivatePlayer(preferBatteryVariant: tier != .full)
            }
        }
        for (id, session) in sessions {
            session.apply(tier: tiers[id] ?? .full)
        }
    }

    var activeDecoderCount: Int {
        let privateCount = sessions.values.filter { !$0.usesSharedDecoder }.count
        return SharedPlaybackHub.activeDecoderCount + privateCount
    }

    func restore(using library: [WallpaperAsset], nativeHostActive: Bool = false) async {
        let connected = displays.refresh()
        let connectedByID = Dictionary(uniqueKeysWithValues: connected.map { ($0.displayID, $0) })
        let connectedIDs = Set(connectedByID.keys)
        // Drop sessions for removed displays now: their borderless windows
        // would otherwise linger over the remaining topology as glitchy
        // "overlay" rects until the next debounced geometry pass.
        for id in Array(sessions.keys) where !connectedIDs.contains(id) {
            sessions.removeValue(forKey: id)?.tearDown()
            tiers.removeValue(forKey: id)
        }
        // A newly attached display has no stored assignment yet. Inherit the
        // main display's wallpaper so it shows something immediately instead
        // of the system default (and so the native half below can claim it).
        // This runs BEFORE the canvas refresh so the new display is included
        // in the recomputed union. Otherwise it inherits a canvas computed
        // over the old display set and renders the wrong crop until the next
        // topology event.
        var snapshot = await assignments.current()
        let inherited = DisplayTopology.inheritedAssignments(
            stored: snapshot.assignments,
            connectedIDs: connectedIDs,
            mainDisplayID: displays.mainDisplay()?.displayID
        )
        if !inherited.isEmpty {
            try? await assignments.upsert(inherited)
        }
        // Canvases go stale the moment the topology changes; refresh before
        // comparing session compositions so spanning sessions relayout to the
        // live union instead of rendering the old canvas half off-screen.
        await refreshSpanningCanvases(connected: connected)
        snapshot = await assignments.current()
        let byID = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
        let restoredAssignments = snapshot.assignments

        var synchronizedGroups: [WallpaperID: [DisplayID]] = [:]
        for assignment in restoredAssignments where assignment.isEnabled {
            guard let wallpaperID = assignment.wallpaperID, let asset = byID[wallpaperID] else { continue }
            guard connectedByID[assignment.displayID] != nil else { continue }
            // In native mode the system host owns default-crop displays. The
            // overlay must neither create sessions for them nor install system
            // posters there: setDesktopImageURL rewrites the agent's Desktop
            // entry to an Apple image choice, wiping the native video
            // assignment (this left desktops showing stills/defaults).
            if nativeHostActive, assignment.composition.usesDefaultCrop,
               assignment.composition.spanningCanvas == nil {
                dismantleSession(assignment.displayID)
                continue
            }
            synchronizedGroups[wallpaperID, default: []].append(assignment.displayID)
            if let session = sessions[assignment.displayID],
               session.asset.id == wallpaperID,
               session.currentComposition == assignment.composition {
                continue
            }
            try? activate(asset, on: assignment.displayID, composition: assignment.composition)
        }
        for ids in synchronizedGroups.values where ids.count > 1 {
            synchronize(displayIDs: ids)
        }
    }

    /// Recompute spanning canvases against live display frames and persist when
    /// they changed. Shared by the restore path and the debounced fast geometry
    /// path so both converge on the same union.
    private func refreshSpanningCanvases(connected: [ConnectedDisplay]) async {
        let snapshot = await assignments.current()
        let framesByID = Dictionary(uniqueKeysWithValues: connected.map { ($0.displayID, $0.frame) })
        var stored = snapshot.assignments
        var topologyChanged = false

        let spanningWallpaperIDs = Set(stored.compactMap { assignment in
            assignment.composition.spanningCanvas == nil ? nil : assignment.wallpaperID
        })
        for wallpaperID in spanningWallpaperIDs {
            let indices = stored.indices.filter { index in
                stored[index].wallpaperID == wallpaperID
                    && stored[index].composition.spanningCanvas != nil
                    && framesByID[stored[index].displayID] != nil
            }
            let frames = indices.compactMap { framesByID[stored[$0].displayID] }
            guard let canvas = SpanningGeometry.canvas(for: frames) else { continue }
            for index in indices where stored[index].composition.spanningCanvas != canvas {
                stored[index].composition.spanningCanvas = canvas
                topologyChanged = true
            }
        }
        if topologyChanged {
            try? await assignments.replaceAll(with: stored)
        }
    }

    func reapplyAssignments() {
        displays.refresh()
        for (id, session) in sessions {
            guard let screen = displays.screen(for: id),
                  let connected = displays.display(id: id) else { continue }
            installSystemPoster(session.asset.posterURL ?? session.asset.mediaURL, on: screen)
            session.relayout(screen: screen, connected: connected)
            session.apply(tier: tiers[id] ?? .full)
            session.reassert()
        }
    }

    func releaseWorkingMemory() {
        for session in sessions.values {
            session.releaseDecoderNow()
        }
        // Tiers must go too. `apply(tier:to:)` early-returns when the tier is
        // unchanged, so keeping them would make the policy pass that follows
        // "Clear RAM" a no-op. Every session would stay decoderless (black)
        // until some unrelated event happened to flip a tier.
        tiers.removeAll()
    }

    private func reassertAll() {
        for session in sessions.values {
            session.reassert()
        }
    }

    private func scheduleSurfaceRecovery() {
        recoveryWorkItems.forEach { $0.cancel() }
        recoveryWorkItems.removeAll(keepingCapacity: true)
        reassertAll()
        for delay in [0.016, 0.08, 0.20] {
            let work = DispatchWorkItem { [weak self] in self?.reassertAll() }
            recoveryWorkItems.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func scheduleGeometryRebuild(delay: TimeInterval = 0.6) {
        geometryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.rebuildGeometry() }
        }
        geometryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func rebuildGeometry() async {
        let connected = displays.refresh()
        let connectedIDs = Set(connected.map(\.displayID))
        // Snapshot the keys: removing while iterating the live view corrupts
        // the dictionary (see dismantleSessions).
        for id in Array(sessions.keys) where !connectedIDs.contains(id) {
            sessions.removeValue(forKey: id)?.tearDown()
            tiers.removeValue(forKey: id)
        }
        // The cached spanning canvas is in the old coordinate space after a
        // join/cut/mode change; relayouting survivors with it renders the
        // video half off-screen. Refresh (and persist) first.
        await refreshSpanningCanvases(connected: connected)
        let snapshot = await assignments.current()
        let compositionByID = Dictionary(
            uniqueKeysWithValues: snapshot.assignments.map { ($0.displayID, $0.composition) }
        )
        for (id, session) in sessions {
            guard let screen = displays.screen(for: id),
                  let connected = displays.display(id: id) else { continue }
            session.relayout(screen: screen, connected: connected)
            if let composition = compositionByID[id],
               composition != session.currentComposition {
                session.updateComposition(composition, screen: screen, connected: connected)
            }
            session.apply(tier: tiers[id] ?? .full)
        }
    }

    private func installSystemPoster(_ url: URL, on screen: NSScreen) {
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSNumber(value: Int(NSImageScaling.scaleProportionallyUpOrDown.rawValue)),
            .allowClipping: true
        ]
        try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
    }

    enum EngineError: LocalizedError {
        case missingDisplay
        var errorDescription: String? { "That display is no longer connected." }
    }
}

@MainActor
final class DesktopVideoSession {
    private(set) var asset: WallpaperAsset
    private var composition: DisplayComposition
    private let window: DesktopSurfaceWindow
    private let root = SessionRootView()
    private var player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var sharedHub: SharedPlaybackHub?
    private var decoderReleaseWorkItem: DispatchWorkItem?
    private var decoderIsLoaded = false
    private var readinessObservation: NSKeyValueObservation?
    private var requestedTier: PlaybackTier = .full
    private var displayPixelSize = CGSize.zero
    var currentComposition: DisplayComposition { composition }
    var usesSharedDecoder: Bool { sharedHub != nil }

    init(asset: WallpaperAsset, composition: DisplayComposition, screen: NSScreen, connected: ConnectedDisplay, tier: PlaybackTier = .full) {
        self.asset = asset
        self.composition = composition
        self.requestedTier = tier
        displayPixelSize = connected.pixelSize
        window = DesktopSurfaceWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.canHide = false
        window.isExcludedFromWindowsMenu = true
        window.sharingType = .none
        window.animationBehavior = .none
        window.contentView = root
        readinessObservation = root.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            let isReady = layer.isReadyForDisplay
            Task { @MainActor [weak self] in
                guard let self, !root.usesSharedFrames else { return }
                root.setVideoVisible(isReady && requestedTier.showsMotion)
            }
        }
        root.apply(composition: composition, poster: asset.posterURL, displayFrame: connected.frame)
        // Configure the tier-resolved URL up front: the trailing apply() then
        // only sets the budget and plays instead of building a full-res
        // decoder just to throw it away for the variant.
        configurePlayer(url: BatteryMediaVariant.resolvedURL(for: asset, tier: tier))
        relayout(screen: screen, connected: connected)
    }

    func show() {
        window.orderFrontRegardless()
        player.play()
    }

    func replace(asset: WallpaperAsset, composition: DisplayComposition, screen: NSScreen, connected: ConnectedDisplay) {
        detachSharedHub()
        self.asset = asset
        self.composition = composition
        relayout(screen: screen, connected: connected)
        // Same single-build reasoning as init: the trailing apply() reuses
        // this decoder when the URL already matches the tier.
        configurePlayer(url: BatteryMediaVariant.resolvedURL(for: asset, tier: requestedTier))
        apply(tier: requestedTier)
        reassert()
    }

    func relayout(screen: NSScreen, connected: ConnectedDisplay) {
        displayPixelSize = connected.pixelSize
        // Use the refreshed ConnectedDisplay frame as the single source of truth
        // for window geometry. screen.frame (live) and connected.frame (cached)
        // can disagree after a mode change / join / cut; mixing them (window from
        // one, media crop from the other) rendered the video half off-screen.
        // The NSScreen is still needed for poster assignment by callers.
        window.setFrame(connected.frame, display: true)
        root.bounds = CGRect(origin: .zero, size: connected.frame.size)
        root.apply(composition: composition, poster: asset.posterURL, displayFrame: connected.frame)
    }

    /// Adopt a new composition (e.g. a refreshed spanning canvas) without
    /// rebuilding the decoder: the crop only affects layer geometry.
    func updateComposition(_ composition: DisplayComposition, screen: NSScreen, connected: ConnectedDisplay) {
        self.composition = composition
        relayout(screen: screen, connected: connected)
    }

    func reassert() {
        window.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        window.orderFrontRegardless()
        window.displayIfNeeded()
    }

    func apply(tier: PlaybackTier) {
        requestedTier = tier
        decoderReleaseWorkItem?.cancel()
        decoderReleaseWorkItem = nil
        switch tier {
        case .full, .reduced, .minimal:
            // Unified tier semantics (see PlaybackTier docs): `.minimal` plays
            // motion at a reduced decode budget, exactly like `.reduced`. Only
            // `.staticFrame` hides video (poster still) and `.paused` holds the
            // last frame. This matches the native extension host, where
            // `.minimal` resumes playback with a lower-res variant. Previously,
            // overlay blanked on batterySaver while native kept playing.
            // `.reduced` and `.minimal` deliberately differ (1080p/2Mbps vs
            // 720p/1Mbps + battery variant) so Battery Saver is visibly and
            // measurably cheaper than Automatic. Identical budgets were why
            // switching profiles "changed nothing".
            let budget = decodeBudget(for: tier)
            if tier != .full {
                // Kick off the 720p sibling generation (async, cached): without
                // it resolvedURL keeps falling back to the full file.
                Task { await BatteryMediaVariant.ensure(for: asset) }
            }
            if let sharedHub {
                // If a previous pause unloaded the hub, re-attach a fresh decoder
                // instead of playing an emptied player (black). The hub is
                // re-acquired by reconcile; here just guard the loaded flag.
                if !sharedHub.isLoaded {
                    // The hub was emptied (stale retain): drop it and play
                    // private on the tier's URL directly, going through
                    // usePrivatePlayer first would build the full URL only for
                    // playPrivate to immediately rebuild the battery variant.
                    detachSharedHub()
                    playPrivate(url: BatteryMediaVariant.resolvedURL(for: asset, tier: tier), budget: budget)
                } else {
                    sharedHub.setDecodeBudget(bitRate: budget.bitRate, maximumResolution: budget.maximumResolution)
                    sharedHub.setLayerPaused(false, for: root.sharedVideoLayer)
                    root.setVideoVisible(true)
                }
            } else {
                playPrivate(url: BatteryMediaVariant.resolvedURL(for: asset, tier: tier), budget: budget)
            }
            reassert()
        case .staticFrame:
            if let sharedHub {
                // Stay attached but paused: detaching would drop the held frame
                // and the hub (shared with playing siblings) must keep running
                // for them. The layer hides so the poster still shows.
                sharedHub.setLayerPaused(true, for: root.sharedVideoLayer)
            } else {
                player.pause()
            }
            root.setVideoVisible(false)
            reassert()
            scheduleDecoderRelease(after: 2)
        case .paused:
            // Hold the last frame AND the decoder for instant resume. The old
            // code freed the decoder 10s after every pause, so resume had to
            // re-decode from disk: black flash + spin-up on every pause/resume
            // cycle.
            if let sharedHub {
                // Per-layer hold: the hub keeps playing while any sibling is
                // unpaused; this layer simply stops receiving new frames and
                // keeps its last one. Pausing the shared player directly (old
                // code) froze every display on the same video.
                sharedHub.setLayerPaused(true, for: root.sharedVideoLayer)
            } else {
                player.pause()
            }
            root.setVideoVisible(root.usesSharedFrames || root.playerLayer.isReadyForDisplay)
            reassert()
        }
    }

    func tearDown() {
        decoderReleaseWorkItem?.cancel()
        decoderReleaseWorkItem = nil
        readinessObservation?.invalidate()
        readinessObservation = nil
        detachSharedHub()
        player.pause()
        looper = nil
        player.replaceCurrentItem(with: nil)
        root.playerLayer.player = nil
        window.orderOut(nil)
        window.close()
        decoderIsLoaded = false
        privateURL = nil
    }

    func synchronize(atHostTime hostTime: CMTime, tier: PlaybackTier) {
        decoderReleaseWorkItem?.cancel()
        requestedTier = tier
        // `.minimal` plays motion (reduced budget), like `.reduced`.
        let budget = decodeBudget(for: tier)
        if let sharedHub {
            sharedHub.setDecodeBudget(
                bitRate: budget.bitRate,
                maximumResolution: budget.maximumResolution
            )
            sharedHub.synchronize(atHostTime: hostTime)
            root.setVideoVisible(true)
            reassert()
            return
        }
        playPrivate(url: BatteryMediaVariant.resolvedURL(for: asset, tier: tier), budget: budget)
        root.setVideoVisible(root.playerLayer.isReadyForDisplay)
        reassert()
        guard player.status == .readyToPlay else { return }
        player.setRate(1, time: .zero, atHostTime: hostTime)
    }

    private struct DecodeBudget {
        var bitRate: Double
        var maximumResolution: CGSize
    }

    private func decodeBudget(for tier: PlaybackTier) -> DecodeBudget {
        switch tier {
        case .full: DecodeBudget(bitRate: 0, maximumResolution: .zero)
        case .reduced: DecodeBudget(bitRate: 2_000_000, maximumResolution: reducedResolution)
        case .minimal: DecodeBudget(bitRate: 1_000_000, maximumResolution: minimalResolution)
        case .staticFrame, .paused: DecodeBudget(bitRate: 0, maximumResolution: .zero)
        }
    }

    private var reducedResolution: CGSize {
        let landscape = displayPixelSize.width >= displayPixelSize.height
        return landscape ? CGSize(width: 1_920, height: 1_080) : CGSize(width: 1_080, height: 1_920)
    }

    private var minimalResolution: CGSize {
        let landscape = displayPixelSize.width >= displayPixelSize.height
        return landscape ? CGSize(width: 1_280, height: 720) : CGSize(width: 720, height: 1_280)
    }

    /// Play motion on the private player, switching to `url` first when it
    /// differs from the loaded one. The old code only picked the battery
    /// variant when no decoder was loaded, so flipping Full → Battery Saver
    /// while playing kept the full-res URL with just a bitrate cap. Visually
    /// (and measurably) nothing changed.
    private func playPrivate(url: URL, budget: DecodeBudget) {
        if !decoderIsLoaded || privateURL != url {
            configurePlayer(url: url)
        }
        configureDecodeBudget(bitRate: budget.bitRate, maximumResolution: budget.maximumResolution)
        root.setVideoVisible(root.playerLayer.isReadyForDisplay)
        player.rate = 1
        player.play()
    }

    /// The media URL the private player was configured with, if any. Used to
    /// detect variant switches (full ↔ battery) without rebuilding the decoder
    /// when the URL is unchanged.
    private var privateURL: URL?

    private func configureDecodeBudget(bitRate: Double, maximumResolution: CGSize) {
        for item in player.items() {
            item.preferredPeakBitRate = bitRate
            item.preferredMaximumResolution = maximumResolution
        }
    }

    private func configurePlayer(url: URL) {
        decoderReleaseWorkItem?.cancel()
        root.setVideoVisible(false)
        player.pause()
        looper = nil
        player = AVQueuePlayer()
        player.isMuted = true
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = false
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 1
        looper = AVPlayerLooper(player: player, templateItem: item)
        root.playerLayer.player = player
        root.playerLayer.videoGravity = gravity(for: composition.contentMode)
        decoderIsLoaded = true
        privateURL = url
    }

    private func ensureDecoder(preferBatteryVariant: Bool = false) {
        if preferBatteryVariant {
            Task { await BatteryMediaVariant.ensure(for: asset) }
        }
        guard !decoderIsLoaded else { return }
        let url = BatteryMediaVariant.resolvedURL(
            for: asset,
            tier: preferBatteryVariant ? .reduced : .full
        )
        configurePlayer(url: url)
    }

    func releaseDecoderNow() {
        decoderReleaseWorkItem?.cancel()
        decoderReleaseWorkItem = nil
        // Keep the readiness observation alive: clearing it permanently (old
        // behaviour) meant the next decoder never flipped the layer visible
        // again → stuck black after "Clear RAM" until re-apply.
        detachSharedHub()
        player.pause()
        looper = nil
        root.playerLayer.player = nil
        decoderIsLoaded = false
        privateURL = nil
    }

    func attachSharedHub(_ hub: SharedPlaybackHub) {
        if sharedHub === hub {
            root.setUsesSharedFrames(true)
            hub.attach(root.sharedVideoLayer)
            decoderIsLoaded = hub.isLoaded
            return
        }
        detachSharedHub()
        sharedHub = hub
        root.setUsesSharedFrames(true)
        hub.attach(root.sharedVideoLayer)
        decoderIsLoaded = hub.isLoaded
        // The private URL is no longer loaded anywhere (player discarded
        // below), so clear it: otherwise a later detach → private replay of
        // the same URL would skip the rebuild it needs.
        privateURL = nil
        player.pause()
        looper = nil
        root.playerLayer.player = nil
    }

    var sharedHubKey: String? {
        sharedHub?.key
    }

    func detachSharedHub() {
        guard let sharedHub else {
            root.setUsesSharedFrames(false)
            return
        }
        sharedHub.detach(root.sharedVideoLayer)
        sharedHub.release()
        self.sharedHub = nil
        root.setUsesSharedFrames(false)
        // Keep the layer's last contents: clearing it here black-flashed every
        // shared session on each reconcile, and wiped the held frame a paused
        // session is supposed to keep. The layer is destroyed with the session
        // on teardown, so nothing leaks.
        // The private decoder was discarded when this session attached to the
        // hub, without resetting the flag, the next private play would
        // early-return thinking a decoder is loaded and resume an empty player
        // (black glitch on pause → resume transitions).
        decoderIsLoaded = false
    }

    func usePrivatePlayer(preferBatteryVariant: Bool = false) {
        detachSharedHub()
        ensureDecoder(preferBatteryVariant: preferBatteryVariant)
    }

    private func scheduleDecoderRelease(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if sharedHub != nil {
                // Shared decoders stay paused with the last frame retained;
                // emptying the shared player here would force every sibling
                // display to re-decode from disk on resume. Memory is reclaimed
                // by teardown / releaseWorkingMemory instead.
                return
            }
            player.pause()
            looper = nil
            root.playerLayer.player = nil
            root.setVideoVisible(false)
            player = AVQueuePlayer()
            player.isMuted = true
            decoderIsLoaded = false
            privateURL = nil
        }
        decoderReleaseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func gravity(for mode: ContentMode) -> AVLayerVideoGravity {
        switch mode {
        case .fill: .resizeAspectFill
        case .fit: .resizeAspect
        case .stretch: .resize
        }
    }
}

private extension PlaybackTier {
    /// Tiers that render motion. `.minimal` plays at a reduced decode budget
    /// (unified with the native host); only `.staticFrame` shows a still.
    var showsMotion: Bool {
        switch self {
        case .full, .reduced, .minimal, .paused: true
        case .staticFrame: false
        }
    }
}

private final class DesktopSurfaceWindow: NSWindow {
    // AppKit queries these on its window list at any time (key recalculation
    // during modal sessions, Spaces switches). They must never touch Swift
    // executors or session state. A plain answer keeps the ObjC entry path
    // thunk-free no matter how the SDK annotates NSWindow members.
    override nonisolated var canBecomeKey: Bool { false }
    override nonisolated var canBecomeMain: Bool { false }
}

private final class SessionRootView: NSView {
    let playerLayer = AVPlayerLayer()
    let sharedVideoLayer = CALayer()
    private let posterLayer = CALayer()
    private var composition = DisplayComposition()
    private var displayFrame = CGRect.zero
    private var posterURL: URL?
    private var posterImage: NSImage?
    private(set) var usesSharedFrames = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        posterLayer.actions = Self.disabledActions
        posterLayer.contentsGravity = .resizeAspectFill
        layer?.addSublayer(posterLayer)
        sharedVideoLayer.actions = Self.disabledActions
        sharedVideoLayer.contentsGravity = .resizeAspectFill
        sharedVideoLayer.isHidden = true
        layer?.addSublayer(sharedVideoLayer)
        playerLayer.actions = Self.disabledActions
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.isHidden = true
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let frame = mediaFrame
        posterLayer.frame = frame
        playerLayer.frame = frame
        sharedVideoLayer.frame = frame
        applyTransform()
    }

    func apply(composition: DisplayComposition, poster: URL?, displayFrame: CGRect) {
        self.composition = composition
        self.displayFrame = displayFrame
        // apply() runs on every relayout; decode the poster once per URL, and
        // downsample it instead of holding a full 4K bitmap per display.
        if let poster {
            if posterURL != poster {
                posterURL = poster
                posterImage = PosterCache.thumbnailImage(for: poster, maxPixel: 2_560)
            }
            posterLayer.contents = posterImage
        } else {
            posterURL = nil
            posterImage = nil
            posterLayer.contents = nil
        }
        switch composition.contentMode {
        case .fill:
            playerLayer.videoGravity = .resizeAspectFill
            sharedVideoLayer.contentsGravity = .resizeAspectFill
        case .fit:
            playerLayer.videoGravity = .resizeAspect
            sharedVideoLayer.contentsGravity = .resizeAspect
        case .stretch:
            playerLayer.videoGravity = .resize
            sharedVideoLayer.contentsGravity = .resize
        }
        applyTransform()
    }

    func setUsesSharedFrames(_ shared: Bool) {
        usesSharedFrames = shared
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if shared {
            playerLayer.player = nil
            playerLayer.isHidden = true
        }
        CATransaction.commit()
    }

    func setVideoVisible(_ visible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if usesSharedFrames {
            sharedVideoLayer.isHidden = !visible
            playerLayer.isHidden = true
        } else {
            playerLayer.isHidden = !visible
            sharedVideoLayer.isHidden = true
        }
        CATransaction.commit()
    }

    private var mediaFrame: CGRect {
        guard let canvas = composition.spanningCanvas else { return bounds }
        return SpanningGeometry.mediaFrame(canvas: canvas, on: displayFrame)
    }

    private func applyTransform() {
        let frame = mediaFrame
        let focal = CGPoint(
            x: min(max(composition.focalPoint.x, 0), 1),
            y: min(max(composition.focalPoint.y, 0), 1)
        )
        let anchor = CGPoint(x: focal.x, y: focal.y)
        let position = CGPoint(
            x: frame.minX + frame.width * focal.x + composition.offset.x,
            y: frame.minY + frame.height * focal.y + composition.offset.y
        )
        let radians = CGFloat(composition.rotationDegrees * .pi / 180)
        let scale = CGFloat(min(max(composition.scale, 0.25), 4))
        var transform = CGAffineTransform(rotationAngle: radians)
        transform = transform.scaledBy(x: scale, y: scale)
        for layer in [posterLayer, playerLayer, sharedVideoLayer] {
            layer.anchorPoint = anchor
            layer.position = position
            layer.setAffineTransform(transform)
        }
    }

    private static let disabledActions: [String: CAAction] = [
        "anchorPoint": NSNull(),
        "bounds": NSNull(),
        "contents": NSNull(),
        "hidden": NSNull(),
        "position": NSNull(),
        "sublayers": NSNull(),
        "transform": NSNull()
    ]
}
