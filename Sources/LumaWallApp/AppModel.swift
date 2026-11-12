import AppKit
import CoreGraphics
import Darwin
import IOKit.ps
import LumaWallCore
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    enum Section: String, CaseIterable, Identifiable {
        case home, library, displays, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .home: L10n.home
            case .library: L10n.library
            case .displays: L10n.displays
            case .settings: L10n.settings
            }
        }

        var symbol: String {
            switch self {
            case .home: "house.fill"
            case .library: "square.grid.2x2.fill"
            case .displays: "display.2"
            case .settings: "gearshape.fill"
            }
        }
    }

    var section: Section = .home
    var assets: [WallpaperAsset] = []
    var playlists: [WallpaperPlaylist] = []
    var displays: [ConnectedDisplay] = []
    var recentIDs: [WallpaperID] = []
    var previewAsset: WallpaperAsset?
    var assignTarget: ConnectedDisplay?
    var searchText = ""
    var librarySort: LibrarySort = .newest
    var resolutionFilter: ResolutionFilter = .all
    var categoryFilter: WallpaperCategory? = nil
    var favoritesOnly = false
    var powerProfile: PowerProfile = .automatic
    var pauseWhenObscured = true
    var pauseOnLock = true
    var hideDesktopVideo = false
    var userPaused = false
    var playbackStopped = false
    var pausedDisplayIDs: Set<DisplayID> = []
    var launchAtLogin = false
    /// Hot diagnostics: excluded from observation so the 15s stats tick doesn't
    /// re-evaluate every `@Bindable` library view. Read directly where needed.
    @ObservationIgnored var processCPUPercent: Double = 0
    @ObservationIgnored var systemCPUPercent: Double = 0
    var batteryPercent = 100
    var isOnBattery = false
    var playlistEditor: PlaylistEditorState?
    var isImporting = false
    var isApplying = false
    /// Queued alerts. The old three-var (`alertTitle/alertMessage/showsAlert`)
    /// form tore: a second `present` overwrote the first before dismissal.
    /// `activeAlert` drives a single `.alert(item:)`; the rest wait in `alertQueue`.
    struct AppAlert: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }
    var activeAlert: AppAlert?
    private var alertQueue: [AppAlert] = []
    var activePlaylistID: PlaylistID?
    @ObservationIgnored var processMemoryMB: Double = 0
    @ObservationIgnored var libraryDiskMB: Double = 0
    @ObservationIgnored var activeDecoderCount = 0
    var reduceMotionActive = false
    var energySoakReport: EnergySoakReport?
    var automations = WallpaperAutomations()
    var automationPickSlot: AutomationSlot?
    var dayNightExpanded = true
    var appearanceExpanded = true
    var automationRulesExpanded = true
    var lockAutomationExpanded = true
    private(set) var favoriteIDs: Set<WallpaperID> = []
    private(set) var activeByDisplay: [DisplayID: WallpaperID] = [:]

    private let store: LibraryStore
    private let importer: MediaImporter
    private let assignmentStore: AssignmentStore
    private let playlistStore: PlaylistStore
    private let playlistPlaybackStore: PlaylistPlaybackStore
    private let recentsStore: RecentsStore
    private let automationStore: AutomationStore
    private let energyLogStore: EnergyLogStore
    private let crashReportStore: CrashReportStore
    var crashReports: [CrashReport] = []
    var lastSessionEndedUncleanly = false
    let displayCoordinator: DisplayCoordinator
    private let engine: WallpaperEngine
    var wallpaperHostMode: WallpaperHostMode { engine.mode }
    private var playlistTimer: Timer?
    private var playlistCursor = 0
    private var playlistNextAdvanceAt: Date?
    private var statsTimer: Timer?
    private var dayNightTimer: Timer?
    private var lastAutomationWallpaperID: WallpaperID?
    private var appearanceObserver: NSObjectProtocol?
    private var automationObservers: [NSObjectProtocol] = []
    private var reduceMotionObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var coverageObservers: [NSObjectProtocol] = []
    private var coverageTimer: Timer?
    private var lockObservers: [NSObjectProtocol] = []
    private var powerObservers: [NSObjectProtocol] = []
    /// Owns the IOKit power-source runloop source. A lock-guarded box rather
    /// than a bare property so both MainActor teardown and nonisolated
    /// deinit can release it: the notify context holds an unretained self
    /// pointer, so a source outliving the model would crash on the next
    /// power event. Removal runs on whatever thread deinit lands on;
    /// CFRunLoopRemoveSource is thread-safe.
    private final class PowerSourceRegistration: @unchecked Sendable {
        private let lock = NSLock()
        private var source: CFRunLoopSource?

        func set(_ source: CFRunLoopSource?) {
            lock.lock()
            defer { lock.unlock() }
            self.source = source
        }

        /// Removes the source from the main runloop and forgets it. Idempotent.
        /// The lock is released before touching the runloop: never call out
        /// while holding it.
        func invalidate() {
            lock.lock()
            let current = source
            source = nil
            lock.unlock()
            if let current {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), current, .defaultMode)
            }
        }

        deinit { invalidate() }
    }
    private let powerSourceRegistration = PowerSourceRegistration()
    private var sessionLocked = false
    private var displaysAsleep = false
    private var cpuSampler = CPUSampler()
    private var playlistIDs: [WallpaperID] = []
    private var statsTick = 0
    private let gameModeMonitor = GameModeMonitor()
    private var didAdvancePlaylistOnLogin = false
    private var lastPlaylistWakeAdvance: Date?
    private var willTerminateObserver: NSObjectProtocol?

    struct PlaylistEditorState: Identifiable {
        var id: PlaylistID
        var existingID: PlaylistID?
        var name: String
        var orderedIDs: [WallpaperID]
        var shuffled: Bool
        var intervalMinutes: Int
    }

    /// Single-sheet router. Four `.sheet(item:)` modifiers on one view mean
    /// only the first non-nil presents and the rest are silently dropped.
    /// `topSheet` exposes priority order; `setTopSheet(nil)` clears the
    /// currently presented sheet's source (replacing double `nil + dismiss()`).
    enum SheetRoute: Identifiable {
        case preview(WallpaperAsset)
        case assign(ConnectedDisplay)
        case automation(AutomationSlot)
        case playlistEditor
        var id: String {
            switch self {
            case .preview(let asset): "preview-\(asset.id.rawValue)"
            case .assign(let display): "assign-\(display.displayID.rawValue)"
            case .automation(let slot): "automation-\(slot.rawValue)"
            case .playlistEditor: "playlist-editor"
            }
        }
    }

    /// Highest-priority presented sheet. Order: preview > assign > automation > editor.
    var topSheet: SheetRoute? {
        if let previewAsset { return .preview(previewAsset) }
        if let assignTarget { return .assign(assignTarget) }
        if let automationPickSlot { return .automation(automationPickSlot) }
        if playlistEditor != nil { return .playlistEditor }
        return nil
    }

    /// Clear (or switch) sheets through the router so sources stay consistent.
    func setTopSheet(_ route: SheetRoute?) {
        switch route {
        case .preview(let asset): previewAsset = asset
        case .assign(let display): assignTarget = display
        case .automation(let slot): automationPickSlot = slot
        case .playlistEditor: break
        case nil:
            previewAsset = nil
            assignTarget = nil
            automationPickSlot = nil
            playlistEditor = nil
        }
    }

    enum AutomationSlot: String, Identifiable {
        case day, night, light, dark, lock
        var id: String { rawValue }

        var title: String {
            switch self {
            case .day: "Day"
            case .night: "Night"
            case .light: "Light"
            case .dark: "Dark"
            case .lock: "Lock Screen"
            }
        }
    }

    init() {
        favoriteIDs = Set(
            UserDefaults.standard.stringArray(forKey: "lumawall.favoriteIDs")?
                .compactMap(UUID.init(uuidString:)).map { WallpaperID(rawValue: $0) } ?? []
        )
        if let raw = UserDefaults.standard.string(forKey: "lumawall.powerProfile"),
           let profile = PowerProfile(rawValue: raw) {
            powerProfile = profile
        }
        if let raw = UserDefaults.standard.string(forKey: "lumawall.librarySort"),
           let sort = LibrarySort(rawValue: raw) {
            librarySort = sort
        }
        pauseWhenObscured = UserDefaults.standard.object(forKey: "lumawall.pauseWhenObscured") as? Bool ?? true
        pauseOnLock = UserDefaults.standard.object(forKey: "lumawall.pauseOnLock") as? Bool ?? true
        hideDesktopVideo = UserDefaults.standard.bool(forKey: "lumawall.hideDesktopVideo")
        userPaused = UserDefaults.standard.bool(forKey: "lumawall.userPaused")
        if let paused = UserDefaults.standard.stringArray(forKey: "lumawall.pausedDisplayIDs") {
            pausedDisplayIDs = Set(paused.map(DisplayID.init(rawValue:)))
        }

        do {
            let store = try LibraryStore()
            let assignments = try AssignmentStore()
            let playlists = try PlaylistStore()
            let playlistPlayback = try PlaylistPlaybackStore()
            let recents = try RecentsStore()
            let automations = try AutomationStore()
            let energyLog = try EnergyLogStore()
            let crashes = try CrashReportStore()
            let displays = DisplayCoordinator()
            self.store = store
            self.importer = MediaImporter(store: store)
            self.assignmentStore = assignments
            self.playlistStore = playlists
            self.playlistPlaybackStore = playlistPlayback
            self.recentsStore = recents
            self.automationStore = automations
            self.energyLogStore = energyLog
            self.crashReportStore = crashes
            self.displayCoordinator = displays
            self.engine = WallpaperEngine(displays: displays, assignments: assignments)
            self.displays = displays.displays
            self.launchAtLogin = LaunchAtLogin.isEnabled
            startCrashReporting()
            Task { await bootstrap() }
            startStatsPolling()
            observeAppearanceChanges()
            observeAutomationClockChanges()
            observeFirstLocationFix()
            observeReduceMotion()
            observeScreenChanges()
            observeDesktopCoverage()
            observeLockAndSleep()
            observePowerChanges()
            observeGameMode()
        } catch {
            fatalError("Unable to initialize LumaWall: \(error)")
        }
    }

    var featured: WallpaperAsset? {
        if let main = displayCoordinator.mainDisplay(), let id = activeByDisplay[main.displayID],
           let asset = assets.first(where: { $0.id == id }) {
            return asset
        }
        return assets.first
    }

    var recentAssets: [WallpaperAsset] {
        recentIDs.compactMap { id in assets.first { $0.id == id } }
    }

    var likedAssets: [WallpaperAsset] {
        assets.filter { favoriteIDs.contains($0.id) }
    }

    var popularAssets: [WallpaperAsset] {
        assets.sorted {
            if $0.applyCount == $1.applyCount {
                return ($0.lastAppliedAt ?? .distantPast) > ($1.lastAppliedAt ?? .distantPast)
            }
            return $0.applyCount > $1.applyCount
        }
    }

    var filteredAssets: [WallpaperAsset] {
        assets.filter { asset in
            let matchesSearch = searchText.isEmpty || asset.name.localizedCaseInsensitiveContains(searchText)
                || asset.category.title.localizedCaseInsensitiveContains(searchText)
            let matchesResolution = resolutionFilter.matches(asset.pixelSize)
            let matchesCategory = categoryFilter.map { asset.category == $0 } ?? true
            let matchesFavorite = !favoritesOnly || favoriteIDs.contains(asset.id)
            return matchesSearch && matchesResolution && matchesCategory && matchesFavorite
        }
    }

    func assets(in category: WallpaperCategory) -> [WallpaperAsset] {
        assets.filter { $0.category == category }
    }

    var isPaused: Bool { userPaused }

    var playbackScope: PlaybackScope {
        if userPaused { return .paused }
        if hideDesktopVideo { return .lockScreen }
        return .everywhere
    }

    func setPlaybackScope(_ scope: PlaybackScope) {
        switch scope {
        case .everywhere:
            userPaused = false
            setHideDesktopVideo(false)
        case .lockScreen:
            userPaused = false
            setHideDesktopVideo(true)
        case .paused:
            userPaused = true
            setHideDesktopVideo(false)
        }
        UserDefaults.standard.set(userPaused, forKey: "lumawall.userPaused")
    }

    func isFavorite(_ asset: WallpaperAsset) -> Bool { favoriteIDs.contains(asset.id) }
    func isActive(_ asset: WallpaperAsset) -> Bool { activeByDisplay.values.contains(asset.id) }
    func activeName(on display: ConnectedDisplay) -> String? {
        guard let id = activeByDisplay[display.displayID] else { return nil }
        return assets.first { $0.id == id }?.name
    }

    func toggleFavorite(_ asset: WallpaperAsset) {
        if favoriteIDs.contains(asset.id) { favoriteIDs.remove(asset.id) } else { favoriteIDs.insert(asset.id) }
        UserDefaults.standard.set(favoriteIDs.map(\.rawValue.uuidString), forKey: "lumawall.favoriteIDs")
    }

    func setSort(_ sort: LibrarySort) {
        librarySort = sort
        UserDefaults.standard.set(sort.rawValue, forKey: "lumawall.librarySort")
        Task { await reload() }
    }

    func setCategory(_ category: WallpaperCategory, for asset: WallpaperAsset) {
        Task {
            try? await store.setCategory(id: asset.id, category: category)
            await reload()
        }
    }

    func rename(_ asset: WallpaperAsset, to name: String) {
        Task {
            try? await store.rename(id: asset.id, to: name)
            await reload()
        }
    }

    func chooseVideos() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose videos for your LumaWall library (1080p+, under 60s preferred)."
        panel.prompt = "Import"
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            self?.importVideos(panel.urls)
        }
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    func importVideos(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        Task {
            var notes: [String] = []
            for url in urls {
                // NOTE: `defer` inside a loop defers to the enclosing scope, not
                // the iteration, the old code held all security-scoped refs until
                // every import finished. Per-URL helper scopes each access.
                notes += await importOneVideo(url)
            }
            await reload()
            isImporting = false
            if !notes.isEmpty {
                present("Import details", notes.joined(separator: "\n"))
            }
        }
    }

    /// Import a single URL, balancing its security-scoped access within the call.
    private func importOneVideo(_ url: URL) async -> [String] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let result = try await importer.importVideo(url)
            var notes = result.inspection.recommendations.map { "\(result.asset.name): \($0)" }
            if result.removedAudio {
                notes.append("\(result.asset.name): Audio removed for silent desktop playback.")
            }
            return notes
        } catch {
            return ["\(url.lastPathComponent): \(error.localizedDescription)"]
        }
    }

    func remove(_ asset: WallpaperAsset) {
        Task {
            for (displayID, wallpaperID) in activeByDisplay where wallpaperID == asset.id {
                try? await engine.clear(displayID)
            }
            do {
                try await store.remove(id: asset.id)
                try? await recentsStore.remove(asset.id)
                favoriteIDs.remove(asset.id)
                UserDefaults.standard.set(favoriteIDs.map(\.rawValue.uuidString), forKey: "lumawall.favoriteIDs")
                if let posterURL = asset.posterURL {
                    await PosterCache.shared.remove(posterURL)
                }
                await reload()
            } catch {
                present("LumaWall", error.localizedDescription)
            }
        }
    }

    func apply(
        _ asset: WallpaperAsset,
        to displayID: DisplayID? = nil,
        composition: DisplayComposition = .init(),
        continuingPlaylist: Bool = false
    ) {
        isApplying = true
        if !continuingPlaylist { stopPlaylistRotation() }
        Task {
            do {
                if let displayID {
                    try await engine.apply(asset, to: displayID, composition: composition)
                } else if let main = displayCoordinator.mainDisplay() {
                    try await engine.apply(asset, to: main.displayID, composition: composition)
                }
                try? await store.recordApply(id: asset.id)
                try? await recentsStore.push(asset.id)
                await reload()
                applyPlaybackPolicy()
            } catch {
                present("Couldn't apply wallpaper", error.localizedDescription)
            }
            isApplying = false
        }
    }

    func composition(on display: ConnectedDisplay) -> DisplayComposition {
        engine.composition(on: display.displayID)
    }

    func applyToAll(_ asset: WallpaperAsset, continuingPlaylist: Bool = false) {
        isApplying = true
        if !continuingPlaylist { stopPlaylistRotation() }
        Task {
            do {
                try await engine.applyToAll(asset)
                try? await store.recordApply(id: asset.id)
                try? await recentsStore.push(asset.id)
                await reload()
                applyPlaybackPolicy()
            } catch {
                present("Couldn't apply wallpaper", error.localizedDescription)
            }
            isApplying = false
        }
    }

    func spanAcrossAllDisplays(_ asset: WallpaperAsset) {
        isApplying = true
        stopPlaylistRotation()
        Task {
            do {
                try await engine.applySpanning(asset)
                try? await store.recordApply(id: asset.id)
                try? await recentsStore.push(asset.id)
                await reload()
                applyPlaybackPolicy()
            } catch {
                present("Couldn't span wallpaper", error.localizedDescription)
            }
            isApplying = false
        }
    }

    func reapplyActive() {
        engine.reapplyAssignments()
        applyPlaybackPolicy()
    }

    func clearDisplay(_ display: ConnectedDisplay) {
        Task {
            try? await engine.clear(display.displayID)
            refreshActive()
            applyPlaybackPolicy()
        }
    }

    func togglePause() {
        userPaused.toggle()
        UserDefaults.standard.set(userPaused, forKey: "lumawall.userPaused")
        applyPlaybackPolicy()
    }

    func togglePause(on display: ConnectedDisplay) {
        if pausedDisplayIDs.contains(display.displayID) {
            pausedDisplayIDs.remove(display.displayID)
        } else {
            pausedDisplayIDs.insert(display.displayID)
        }
        UserDefaults.standard.set(pausedDisplayIDs.map(\.rawValue), forKey: "lumawall.pausedDisplayIDs")
        applyPlaybackPolicy()
    }

    func isDisplayPaused(_ display: ConnectedDisplay) -> Bool {
        userPaused || pausedDisplayIDs.contains(display.displayID) || engine.tier(on: display.displayID) == .paused
    }

    func setPauseWhenObscured(_ enabled: Bool) {
        pauseWhenObscured = enabled
        UserDefaults.standard.set(enabled, forKey: "lumawall.pauseWhenObscured")
        applyPlaybackPolicy()
    }

    func setPauseOnLock(_ enabled: Bool) {
        pauseOnLock = enabled
        UserDefaults.standard.set(enabled, forKey: "lumawall.pauseOnLock")
        applyPlaybackPolicy()
    }

    func setHideDesktopVideo(_ enabled: Bool) {
        hideDesktopVideo = enabled
        UserDefaults.standard.set(enabled, forKey: "lumawall.hideDesktopVideo")
        applyPlaybackPolicy()
    }

    func setPowerProfile(_ profile: PowerProfile) {
        powerProfile = profile
        UserDefaults.standard.set(profile.rawValue, forKey: "lumawall.powerProfile")
        applyPlaybackPolicy()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            launchAtLogin = try LaunchAtLogin.setEnabled(enabled)
        } catch {
            launchAtLogin = LaunchAtLogin.isEnabled
            present("Launch at Login", error.localizedDescription)
        }
    }

    func clearMemoryCache() {
        CacheCleaner.clearMemory()
        engine.releaseWorkingMemory()
        applyPlaybackPolicy()
        refreshStats()
        present("RAM", "Released wallpaper decoders and in-memory caches.")
    }

    func clearDiskCache() {
        Task {
            do {
                let removed = try await CacheCleaner.clearDisk(preservingLibraryRoot: store.rootURL)
                refreshStats()
                present("Cache", removed == 0 ? "No cache files to remove." : "Cleared \(removed) cache items.")
            } catch {
                present("Cache", error.localizedDescription)
            }
        }
    }

    func startEnergySoak() {
        Task {
            do {
                try await energyLogStore.startSoak()
                await refreshEnergyReport()
                present("Energy Log", "24-hour sample window started. Samples append while LumaWall runs.")
            } catch {
                present("Energy Log", error.localizedDescription)
            }
        }
    }

    func resetEnergySoak() {
        Task {
            do {
                try await energyLogStore.clearSoak()
                await refreshEnergyReport()
                present("Energy Log", "Sample window cleared. Rolling 24h samples remain.")
            } catch {
                present("Energy Log", error.localizedDescription)
            }
        }
    }

    func copyEnergyProof() {
        guard let proof = energySoakReport?.proofSummary else {
            present("Energy Log", "Start a sample window and wait for readings before copying.")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(proof, forType: .string)
        present("Energy Log", energySoakReport?.meets24HourGate == true
            ? "Copied 24h energy report to the clipboard."
            : "Copied in-progress energy report to the clipboard.")
    }

    private func refreshEnergyReport() async {
        energySoakReport = await energyLogStore.report()
    }

    // MARK: - Crash reporting (local only)

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    private func startCrashReporting() {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        CrashMonitor.install(
            store: crashReportStore,
            appVersion: appVersionString,
            osVersion: osVersion
        )
        crashReportStore.ingestRawDumps(appVersion: appVersionString, osVersion: osVersion)
        let unclean = crashReportStore.beginSession(appVersion: appVersionString, osVersion: osVersion)
        crashReports = crashReportStore.reports()
        lastSessionEndedUncleanly = unclean != nil

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            CrashMonitor.markCleanShutdown()
        }
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.shutdown() }
        }
    }

    /// Invalidate timers, cancel pending work, and remove observers.
    /// Called on termination; also the safety net for previews/tests that
    /// recreate the model (which previously leaked all of the below).
    func shutdown() {
        playlistTimer?.invalidate()
        statsTimer?.invalidate()
        dayNightTimer?.invalidate()
        coverageTimer?.invalidate()
        playlistTimer = nil
        statsTimer = nil
        dayNightTimer = nil
        coverageTimer = nil
        displayRefreshWorkItem?.cancel()
        displayRefreshWorkItem = nil
        nativeRestoreWorkItem?.cancel()
        nativeRestoreWorkItem = nil
        gameModeMonitor.stop()
        powerSourceRegistration.invalidate()
        let center = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let distributedCenter = DistributedNotificationCenter.default()
        for observer in [appearanceObserver, reduceMotionObserver, screenObserver, willTerminateObserver].compactMap({ $0 }) {
            center.removeObserver(observer)
        }
        // Tokens originate from default, workspace, and distributed centers;
        // removing from a center that doesn't own the token is a harmless no-op.
        for observer in automationObservers + coverageObservers + lockObservers + powerObservers {
            center.removeObserver(observer)
            workspaceCenter.removeObserver(observer)
            distributedCenter.removeObserver(observer)
        }
        automationObservers.removeAll()
        coverageObservers.removeAll()
        lockObservers.removeAll()
        powerObservers.removeAll()
    }

    func copyCrashReport(_ report: CrashReport) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.formattedText, forType: .string)
        present("Diagnostics", "Crash report copied to the clipboard.")
    }

    func revealCrashReports() {
        NSWorkspace.shared.activateFileViewerSelecting([crashReportStore.directoryURL])
    }

    func clearCrashReports() {
        crashReportStore.clearAll()
        crashReports = []
        lastSessionEndedUncleanly = false
        present("Diagnostics", "Crash reports cleared.")
    }

    func createPlaylist(name: String, from selection: [WallpaperAsset], shuffled: Bool, intervalMinutes: Int) {
        guard !selection.isEmpty else { return }
        beginPlaylistEditor()
        playlistEditor?.name = name
        playlistEditor?.orderedIDs = selection.map(\.id)
        playlistEditor?.shuffled = shuffled
        playlistEditor?.intervalMinutes = max(1, intervalMinutes)
        savePlaylistEditor()
    }

    func beginPlaylistEditor(existing: WallpaperPlaylist? = nil) {
        if let existing {
            playlistEditor = PlaylistEditorState(
                id: existing.id,
                existingID: existing.id,
                name: existing.name,
                orderedIDs: existing.wallpaperIDs,
                shuffled: existing.shuffled,
                intervalMinutes: existing.intervalMinutes
            )
        } else {
            let id = PlaylistID()
            playlistEditor = PlaylistEditorState(
                id: id,
                existingID: nil,
                name: "",
                orderedIDs: [],
                shuffled: false,
                intervalMinutes: 30
            )
        }
    }

    func toggleEditorEntry(_ asset: WallpaperAsset) {
        guard var draft = playlistEditor else { return }
        if let index = draft.orderedIDs.firstIndex(of: asset.id) {
            draft.orderedIDs.remove(at: index)
        } else {
            draft.orderedIDs.append(asset.id)
        }
        playlistEditor = draft
    }

    func moveEditorEntry(from source: Int, to destination: Int) {
        guard var draft = playlistEditor, draft.orderedIDs.indices.contains(source) else { return }
        let id = draft.orderedIDs.remove(at: source)
        draft.orderedIDs.insert(id, at: min(destination, draft.orderedIDs.count))
        playlistEditor = draft
    }

    /// Explicit copy-writeback setters for the editor draft. Direct optional-chain
    /// mutation (`playlistEditor?.name = …`) is fragile under `@Observable`
    /// tracking; these mirror `toggleEditorEntry`'s proven pattern.
    func setPlaylistEditorName(_ name: String) {
        guard var draft = playlistEditor else { return }
        draft.name = name
        playlistEditor = draft
    }

    func setPlaylistEditorInterval(_ minutes: Int) {
        guard var draft = playlistEditor else { return }
        draft.intervalMinutes = minutes
        playlistEditor = draft
    }

    func setPlaylistEditorShuffled(_ shuffled: Bool) {
        guard var draft = playlistEditor else { return }
        draft.shuffled = shuffled
        playlistEditor = draft
    }

    func savePlaylistEditor() {
        guard let draft = playlistEditor, !draft.orderedIDs.isEmpty else { return }
        Task {
            let playlist = WallpaperPlaylist(
                id: draft.existingID ?? draft.id,
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Playlist \(playlists.count + 1)"
                    : draft.name,
                wallpaperIDs: draft.orderedIDs,
                shuffled: draft.shuffled,
                intervalMinutes: max(1, draft.intervalMinutes)
            )
            try? await playlistStore.upsert(playlist)
            playlists = await playlistStore.all()
            playlistEditor = nil
        }
    }

    func deletePlaylist(_ playlist: WallpaperPlaylist) {
        if activePlaylistID == playlist.id { stopPlaylistRotation() }
        Task {
            try? await playlistStore.remove(id: playlist.id)
            playlists = await playlistStore.all()
        }
    }

    func applyPlaylist(_ playlist: WallpaperPlaylist) {
        let ids = playlist.shuffled ? playlist.wallpaperIDs.shuffled() : playlist.wallpaperIDs
        guard let firstID = ids.first,
              let asset = assets.first(where: { $0.id == firstID }) else { return }
        automations.dayNightEnabled = false
        automations.appearanceEnabled = false
        persistAutomations()
        activePlaylistID = playlist.id
        playlistIDs = ids
        playlistCursor = 0
        applyToAll(asset, continuingPlaylist: true)
        startPlaylistRotation(ids: ids, intervalMinutes: playlist.intervalMinutes)
    }

    func stepPlaylist(_ delta: Int) {
        guard !playlistIDs.isEmpty else { return }
        playlistCursor = (playlistCursor + delta + playlistIDs.count) % playlistIDs.count
        persistPlaylistPlaybackState()
        let nextID = playlistIDs[playlistCursor]
        guard let asset = assets.first(where: { $0.id == nextID }) else { return }
        applyToAll(asset, continuingPlaylist: true)
    }

    func stopPlaylistRotation() {
        playlistTimer?.invalidate()
        playlistTimer = nil
        activePlaylistID = nil
        playlistIDs = []
        playlistNextAdvanceAt = nil
        Task { try? await playlistPlaybackStore.clear() }
    }

    func refreshDisplays() {
        displayRefreshWorkItem?.cancel()
        displays = displayCoordinator.refresh()
        refreshActive()
        Task {
            // Overlay geometry tracks the burst immediately (kill-free);
            // the native half waits for the topology to settle (below).
            await engine.restoreOverlay(using: assets)
            refreshActive()
            applyPlaybackPolicy()
        }
        scheduleSettledNativeRestore()
    }

    private var displayRefreshWorkItem: DispatchWorkItem?
    private var nativeRestoreWorkItem: DispatchWorkItem?

    /// Latched occlusion verdicts (see OcclusionLatch): raw window coverage is
    /// evaluated every policy tick, but the paused verdict holds until coverage
    /// falls back past the release thresholds.
    private var occlusionLatch = OcclusionLatch()

    private func scheduleDebouncedDisplayRefresh(delay: TimeInterval = 0.6) {
        displayRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshDisplays() }
        displayRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Native restore after the topology goes quiet. A monitor handshake flips
    /// modes (and momentarily drops the display) several times over a few
    /// seconds; restoring + killing WallpaperAgent on each flip orphans
    /// in-flight surfaces and strands half-negotiated ones on screen. Waiting
    /// for 2.5s of quiet collapses the burst into a single restore of the
    /// settled topology. Re-armed by every screen-parameters event.
    private func scheduleSettledNativeRestore(delay: TimeInterval = 2.5) {
        nativeRestoreWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.engine.restoreNative(using: self.assets)
                self.refreshActive()
                self.applyPlaybackPolicy()
            }
        }
        nativeRestoreWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startPlaylistRotation(
        ids: [WallpaperID],
        intervalMinutes: Int,
        nextAdvanceAt: Date? = nil
    ) {
        playlistIDs = ids
        playlistTimer?.invalidate()
        let seconds = TimeInterval(max(1, intervalMinutes) * 60)
        let fireDate = max(nextAdvanceAt ?? Date().addingTimeInterval(seconds), Date().addingTimeInterval(0.25))
        playlistNextAdvanceAt = fireDate
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let playlistID = self.activePlaylistID,
                      let playlist = self.playlists.first(where: { $0.id == playlistID }) else { return }
                self.stepPlaylist(1)
                self.startPlaylistRotation(ids: self.playlistIDs, intervalMinutes: playlist.intervalMinutes)
            }
        }
        timer.tolerance = min(2, seconds * 0.02)
        RunLoop.main.add(timer, forMode: .common)
        playlistTimer = timer
        persistPlaylistPlaybackState()
    }

    private func persistPlaylistPlaybackState() {
        guard let activePlaylistID else { return }
        let state = PlaylistPlaybackState(
            playlistID: activePlaylistID,
            orderedIDs: playlistIDs,
            cursor: playlistCursor,
            nextAdvanceAt: playlistNextAdvanceAt
        )
        Task { try? await playlistPlaybackStore.save(state) }
    }

    private func restorePlaylistPlaybackState() async {
        guard let saved = await playlistPlaybackStore.current(),
              let playlist = playlists.first(where: { $0.id == saved.playlistID }) else {
            try? await playlistPlaybackStore.clear()
            return
        }
        let ids = Set(saved.orderedIDs) == Set(playlist.wallpaperIDs)
            ? saved.orderedIDs
            : (playlist.shuffled ? playlist.wallpaperIDs.shuffled() : playlist.wallpaperIDs)
        guard !ids.isEmpty else {
            try? await playlistPlaybackStore.clear()
            return
        }
        activePlaylistID = playlist.id
        playlistIDs = ids
        playlistCursor = min(max(saved.cursor, 0), ids.count - 1)
        guard let schedule = PlaylistSchedule.resume(
            nextAdvanceAt: saved.nextAdvanceAt,
            intervalMinutes: playlist.intervalMinutes,
            cursor: playlistCursor,
            itemCount: ids.count
        ) else { return }
        playlistCursor = schedule.cursor
        if playlistCursor != saved.cursor,
           let asset = assets.first(where: { $0.id == ids[playlistCursor] }) {
            try? await engine.applyToAll(asset)
        }
        startPlaylistRotation(
            ids: ids,
            intervalMinutes: playlist.intervalMinutes,
            nextAdvanceAt: schedule.nextAdvanceAt
        )
    }

    func displaysUsing(_ asset: WallpaperAsset) -> [ConnectedDisplay] {
        displays.filter { activeByDisplay[$0.displayID] == asset.id }
    }

    func asset(for id: WallpaperID?) -> WallpaperAsset? {
        guard let id else { return nil }
        return assets.first { $0.id == id }
    }

    func setDayNightEnabled(_ enabled: Bool) {
        automations.dayNightEnabled = enabled
        if enabled {
            automations.appearanceEnabled = false
            stopPlaylistRotation()
        }
        persistAutomations()
        evaluateAutomations(force: true)
    }

    func setAppearanceEnabled(_ enabled: Bool) {
        automations.appearanceEnabled = enabled
        if enabled {
            automations.dayNightEnabled = false
            stopPlaylistRotation()
        }
        persistAutomations()
        evaluateAutomations(force: true)
    }

    func setDayStartHour(_ hour: Int) {
        automations.dayStartHour = min(max(hour, 0), 23)
        persistAutomations()
        syncDayNightTimer()
        evaluateAutomations(force: true)
    }

    func setNightStartHour(_ hour: Int) {
        automations.nightStartHour = min(max(hour, 0), 23)
        persistAutomations()
        syncDayNightTimer()
        evaluateAutomations(force: true)
    }

    func setUseSunriseSunset(_ enabled: Bool) {
        automations.useSunriseSunset = enabled
        if enabled { LocationDaylightProvider.shared.requestIfNeeded() }
        persistAutomations()
        evaluateAutomations(force: true)
    }

    func setPowerSourceRule(_ rule: PowerSourceRule) {
        automations.powerSourceRule = rule
        persistAutomations()
        evaluateAutomations(force: true)
    }

    func setWeekdayMask(_ mask: UInt8) {
        automations.weekdayMask = mask
        persistAutomations()
        evaluateAutomations(force: true)
    }

    func setDoNotInterrupt(start: Int?, end: Int?) {
        automations.doNotInterruptStartHour = start.map { min(max($0, 0), 23) }
        automations.doNotInterruptEndHour = end.map { min(max($0, 0), 23) }
        persistAutomations()
        evaluateAutomations(force: true)
    }

    func toggleWeekday(_ weekday: Int) {
        guard (0...6).contains(weekday) else { return }
        let bit: UInt8 = 1 << weekday
        if automations.weekdayMask == 0 {
            automations.weekdayMask = 0b0111_1111 ^ bit
        } else {
            automations.weekdayMask ^= bit
            if automations.weekdayMask == 0 || automations.weekdayMask == 0b0111_1111 {
                automations.weekdayMask = 0
            }
        }
        persistAutomations()
        evaluateAutomations(force: true)
    }

    func isWeekdaySelected(_ weekday: Int) -> Bool {
        guard (0...6).contains(weekday) else { return true }
        if automations.weekdayMask == 0 { return true }
        return (automations.weekdayMask & (1 << weekday)) != 0
    }

    func clearWeekdayFilter() {
        automations.weekdayMask = 0
        persistAutomations()
        evaluateAutomations(force: true)
    }

    func assignAutomation(slot: AutomationSlot, asset: WallpaperAsset) {
        switch slot {
        case .day: automations.dayWallpaperID = asset.id
        case .night: automations.nightWallpaperID = asset.id
        case .light: automations.lightWallpaperID = asset.id
        case .dark: automations.darkWallpaperID = asset.id
        case .lock:
            automations.lockScreenWallpaperID = asset.id
            Task { await applyLockScreenWallpaper(asset, announceUnavailable: true) }
        }
        automationPickSlot = nil
        persistAutomations()
        evaluateAutomations(force: true)
    }

    func clearAutomation(slot: AutomationSlot) {
        switch slot {
        case .day: automations.dayWallpaperID = nil
        case .night: automations.nightWallpaperID = nil
        case .light: automations.lightWallpaperID = nil
        case .dark: automations.darkWallpaperID = nil
        case .lock: automations.lockScreenWallpaperID = nil
        }
        persistAutomations()
        evaluateAutomations(force: true)
    }

    private func applyLockScreenWallpaper(_ asset: WallpaperAsset, announceUnavailable: Bool = false) async {
        guard engine.mode == .native else {
            if announceUnavailable {
                present("Lock Screen", "Lock-screen assignment needs the macOS 26 wallpaper extension build.")
            }
            return
        }
        do {
            let entry = try await NativeWallpaperDeployment.ensureDeployed(asset: asset)
            try NativeWallpaperAssignmentService.applyLockScreen(entry: entry)
        } catch {
            present("Lock Screen", error.localizedDescription)
        }
    }

    private func persistAutomations() {
        Task { try? await automationStore.save(automations) }
        syncDayNightTimer()
    }

    private func syncDayNightTimer() {
        dayNightTimer?.invalidate()
        dayNightTimer = nil
        guard automations.dayNightEnabled else { return }
        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        let coordinate = LocationDaylightProvider.shared.coordinate
        // The timer used to arm only the fixed day/night hours, but the
        // verdict can also flip on solar transitions, quiet-hours end, and
        // weekday re-entry — none of which that covered, so switches landed
        // late, were skipped in quiet hours, or never fired at all.
        guard let fireDate = automations.nextEvaluationDates(
            after: now,
            calendar: calendar,
            latitude: coordinate?.latitude,
            longitude: coordinate?.longitude
        ).first else { return }
        let interval = max(1, fireDate.timeIntervalSince(now))
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateAutomations(force: false)
                self?.syncDayNightTimer()
            }
        }
        timer.tolerance = min(30, interval * 0.01)
        RunLoop.main.add(timer, forMode: .common)
        dayNightTimer = timer
    }

    private func observeAppearanceChanges() {
        appearanceObserver = DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                self?.evaluateAutomations(force: false)
            }
        }
    }

    private func observeAutomationClockChanges() {
        let center = NotificationCenter.default
        for name in [
            NSNotification.Name.NSSystemClockDidChange,
            NSNotification.Name.NSSystemTimeZoneDidChange,
            NSApplication.didBecomeActiveNotification
        ] {
            automationObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.syncDayNightTimer()
                        self?.evaluateAutomations(force: false)
                        await self?.consumePendingShortcutIfNeeded()
                    }
                }
            )
        }
    }

    /// Re-evaluate when the first location fix lands. Solar automations start
    /// on the hour-based fallback (no coordinate yet); without this they sit
    /// there until the next armed boundary instead of switching to true
    /// sunrise/sunset immediately.
    private func observeFirstLocationFix() {
        LocationDaylightProvider.shared.onFirstFix = { [weak self] in
            Task { @MainActor in
                self?.syncDayNightTimer()
                self?.evaluateAutomations(force: false)
            }
        }
    }

    private func observeReduceMotion() {
        reduceMotionActive = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        reduceMotionObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reduceMotionActive = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self?.applyPlaybackPolicy()
            }
        }
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // didChangeScreenParameters fires in bursts during join/cut/mode
            // probes. Restoring on every fire rewrote Index.plist + killall'd
            // WallpaperAgent repeatedly → visible glitch loop. Debounce.
            Task { @MainActor in self?.scheduleDebouncedDisplayRefresh() }
        }
    }

    func evaluateAutomations(force: Bool) {
        guard automations.allowsWeekday() else { return }
        guard !automations.isDoNotInterrupt() else { return }
        guard automations.powerSourceRule.allows(isOnBattery: PowerStatus.current().isOnBattery) else { return }

        let targetID: WallpaperID?
        if automations.dayNightEnabled {
            if automations.useSunriseSunset {
                LocationDaylightProvider.shared.requestIfNeeded()
            }
            let coordinate = LocationDaylightProvider.shared.coordinate
            targetID = automations.isDayPeriod(
                latitude: coordinate?.latitude,
                longitude: coordinate?.longitude
            ) ? automations.dayWallpaperID : automations.nightWallpaperID
        } else if automations.appearanceEnabled {
            targetID = isSystemDarkAppearance() ? automations.darkWallpaperID : automations.lightWallpaperID
        } else {
            return
        }
        guard let targetID, let asset = assets.first(where: { $0.id == targetID }) else { return }
        if !force, lastAutomationWallpaperID == targetID { return }
        lastAutomationWallpaperID = targetID
        stopPlaylistRotation()
        Task {
            do {
                try await engine.applyToAll(asset)
                try? await store.recordApply(id: asset.id)
                try? await recentsStore.push(asset.id)
                await reload()
            } catch {
                present("Automation", error.localizedDescription)
            }
        }
    }

    private func isSystemDarkAppearance() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func bootstrap() async {
        await reload()
        playlists = await playlistStore.all()
        await restorePlaylistPlaybackState()
        automations = await automationStore.current()
        displays = displayCoordinator.refresh()
        await engine.restoreOverlay(using: assets)
        refreshActive()
        refreshStats()
        applyPlaybackPolicy()
        // Native side follows after settle, like any other topology event,
        // at login the displays may still be negotiating modes.
        scheduleSettledNativeRestore()
        syncDayNightTimer()
        evaluateAutomations(force: false)
        notePlaylistLoginIfNeeded()
        await refreshEnergyReport()
        if automations.useSunriseSunset {
            LocationDaylightProvider.shared.requestIfNeeded()
        }
        if let lockID = automations.lockScreenWallpaperID,
           let asset = assets.first(where: { $0.id == lockID }) {
            await applyLockScreenWallpaper(asset)
        }
        await consumePendingShortcutIfNeeded()
    }

    private func consumePendingShortcutIfNeeded() async {
        guard let pending = UserDefaults.standard.string(forKey: "lumawall.pendingShortcutApply") else { return }
        UserDefaults.standard.removeObject(forKey: "lumawall.pendingShortcutApply")
        let asset: WallpaperAsset?
        if pending == "__featured__" {
            asset = featured
        } else {
            asset = assets.first { $0.name.compare(pending, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
                ?? assets.first { $0.name.localizedCaseInsensitiveContains(pending) }
        }
        guard let asset else {
            present("Shortcuts", pending == "__featured__"
                ? "No wallpaper is ready to apply."
                : "No wallpaper matched \"\(pending)\".")
            return
        }
        stopPlaylistRotation()
        do {
            try await engine.applyToAll(asset)
            try? await store.recordApply(id: asset.id)
            try? await recentsStore.push(asset.id)
            await reload()
        } catch {
            present("Shortcuts", error.localizedDescription)
        }
    }

    func reload() async {
        assets = await store.assets(sortedBy: librarySort)
        recentIDs = await recentsStore.all()
        refreshActive()
        refreshStats()
    }

    private func refreshActive() {
        activeByDisplay = Dictionary(uniqueKeysWithValues: engine.activeDisplayIDs.compactMap { id in
            guard let wallpaper = engine.wallpaperID(on: id) else { return nil }
            return (id, wallpaper)
        })
        displays = displayCoordinator.displays
    }

    private func startStatsPolling() {
        refreshStats(includeDiskUsage: true)
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStats() }
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    func refreshStats(includeDiskUsage: Bool = false) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            processMemoryMB = Double(info.resident_size) / 1_048_576
        }
        activeDecoderCount = engine.activeDecoderCount
        reduceMotionActive = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let cpu = cpuSampler.sample()
        processCPUPercent = cpu.process
        systemCPUPercent = cpu.system
        let previousPower = PowerStatus(isOnBattery: isOnBattery, percent: batteryPercent)
        let power = PowerStatus.current()
        batteryPercent = power.percent
        isOnBattery = power.isOnBattery
        if power != previousPower {
            applyPlaybackPolicy()
        }
        statsTick += 1
        if includeDiskUsage || statsTick.isMultiple(of: 4) {
            Task { @MainActor in
                let bytes = await store.diskUsageBytes()
                libraryDiskMB = Double(bytes) / 1_048_576
            }
        }
        if statsTick == 1 || statsTick.isMultiple(of: 4) {
            let sample = EnergySample(
                processCPUPercent: processCPUPercent,
                systemCPUPercent: systemCPUPercent,
                processMemoryMB: processMemoryMB,
                batteryPercent: batteryPercent,
                isOnBattery: isOnBattery,
                decoderCount: activeDecoderCount,
                powerProfile: powerProfile.rawValue,
                playbackActive: !playbackStopped && !activeByDisplay.isEmpty
            )
            Task { @MainActor in
                try? await energyLogStore.record(sample)
                await refreshEnergyReport()
            }
        }
    }

    private func observeLockAndSleep() {
        let distributed = DistributedNotificationCenter.default()
        lockObservers.append(
            distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.sessionLocked = true
                    self?.applyPlaybackPolicy()
                }
            }
        )
        lockObservers.append(
            distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.sessionLocked = false
                    self?.applyPlaybackPolicy()
                }
            }
        )
        let workspace = NSWorkspace.shared.notificationCenter
        lockObservers.append(
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.displaysAsleep = true
                    self?.applyPlaybackPolicy()
                }
            }
        )
        lockObservers.append(
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.displaysAsleep = false
                    self?.applyPlaybackPolicy()
                    self?.notePlaylistWake()
                }
            }
        )
        lockObservers.append(
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.notePlaylistWake() }
            }
        )
    }

    private func observeGameMode() {
        gameModeMonitor.onChange = { [weak self] in
            self?.applyPlaybackPolicy()
        }
        gameModeMonitor.start()
    }

    private func notePlaylistWake() {
        guard activePlaylistID != nil, !playlistIDs.isEmpty else { return }
        if let lastPlaylistWakeAdvance, Date().timeIntervalSince(lastPlaylistWakeAdvance) < 30 {
            return
        }
        lastPlaylistWakeAdvance = Date()
        // Advance once on wake so overnight playlists move without waiting for the next timer fire.
        stepPlaylist(1)
        if let playlistID = activePlaylistID,
           let playlist = playlists.first(where: { $0.id == playlistID }) {
            startPlaylistRotation(ids: playlistIDs, intervalMinutes: playlist.intervalMinutes)
        }
    }

    private func notePlaylistLoginIfNeeded() {
        guard !didAdvancePlaylistOnLogin else { return }
        didAdvancePlaylistOnLogin = true
        // Login item launches stay accessory and usually never become active for a click.
        guard launchAtLogin, NSApp.activationPolicy() == .accessory || !NSApp.isActive else { return }
        guard activePlaylistID != nil else { return }
        stepPlaylist(1)
        if let playlistID = activePlaylistID,
           let playlist = playlists.first(where: { $0.id == playlistID }) {
            startPlaylistRotation(ids: playlistIDs, intervalMinutes: playlist.intervalMinutes)
        }
    }

    private func observePowerChanges() {
        let center = NotificationCenter.default
        for name in [
            ProcessInfo.thermalStateDidChangeNotification,
            Notification.Name.NSProcessInfoPowerStateDidChange
        ] {
            powerObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.applyPlaybackPolicy() }
                }
            )
        }
        observePowerSourceChanges()
    }

    /// Event-driven AC↔battery (and capacity) transitions via IOKit. The
    /// notifications above cover thermal and Low Power Mode, but nothing posts
    /// for unplug/replug, without this, Automatic only noticed the switch at
    /// the next 15s stats tick (or never, if the tick's power comparison was
    /// skipped), which reads as "Automatic does nothing".
    private func observePowerSourceChanges() {
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let model = Unmanaged<AppModel>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                model.applyPlaybackPolicy()
                // Power-source rules gate automations: re-evaluate so unplug /
                // replug applies (or lifts) the rule instead of waiting for
                // the next timer. Dedup inside evaluate keeps this a no-op
                // when the target is unchanged.
                model.evaluateAutomations(force: false)
            }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(
            callback,
            Unmanaged.passUnretained(self).toOpaque()
        )?.takeRetainedValue() else { return }
        powerSourceRegistration.set(source)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    private func observeDesktopCoverage() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification
        ]
        for name in names {
            coverageObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.applyPlaybackPolicy() }
                }
            )
        }
        // Workspace/Space notifications handle normal transitions. This slow fallback
        // catches apps that resize opaque windows without publishing a workspace event.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applyPlaybackPolicy() }
        }
        timer.tolerance = 8
        RunLoop.main.add(timer, forMode: .common)
        coverageTimer = timer
        applyPlaybackPolicy()
    }

    func applyPlaybackPolicy() {
        let power = PowerStatus.current()
        batteryPercent = power.percent
        isOnBattery = power.isOnBattery
        let coverage = DisplayOcclusion.analysis(in: displays)
        // Hysteresis: hold the paused verdict until coverage falls back past
        // the release thresholds, so a window sitting at the enter boundary
        // can't strobe pause/resume on every evaluation.
        occlusionLatch.prune(to: Set(displays.map(\.displayID)))
        for display in displays {
            occlusionLatch.update(
                displayID: display.displayID,
                ratio: coverage.coverage[display.displayID] ?? 0,
                rawCovered: coverage.covered.contains(display.displayID),
                rawFullscreen: coverage.fullscreen.contains(display.displayID)
            )
        }
        let coveredDisplays = occlusionLatch.covered
        let fullscreenDisplays = occlusionLatch.fullscreen
        let allowLiveOnLock = engine.mode == .native
        for display in displays {
            let obscured = (pauseWhenObscured && coveredDisplays.contains(display.displayID))
                || fullscreenDisplays.contains(display.displayID)
            let conditions = PlaybackConditions(
                profile: powerProfile,
                isOnBattery: power.isOnBattery,
                batteryPercent: power.percent,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                thermalState: ProcessInfo.processInfo.thermalState,
                displayIsAsleep: displaysAsleep,
                sessionIsLocked: pauseOnLock && sessionLocked,
                displayIsObscured: obscured,
                userPaused: userPaused || pausedDisplayIDs.contains(display.displayID),
                hideDesktopVideo: hideDesktopVideo,
                allowLiveOnLock: allowLiveOnLock,
                gameModeActive: gameModeMonitor.isActive,
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )
            engine.apply(tier: PlaybackPolicy.resolve(conditions), to: display.displayID)
        }
        if engine.mode == .native {
            let pausedCG = Set(pausedDisplayIDs.compactMap { id in displays.first(where: { $0.displayID == id })?.cgDisplayID })
            let coveredCG = Set(coveredDisplays.compactMap { id in displays.first(where: { $0.displayID == id })?.cgDisplayID })
            let fullscreenCG = Set(fullscreenDisplays.compactMap { id in displays.first(where: { $0.displayID == id })?.cgDisplayID })
            NativeWallpaperPrefsBridge.write(
                userPaused: userPaused,
                pauseWhenOccluded: pauseWhenObscured,
                alwaysPauseDesktop: hideDesktopVideo,
                pausedDisplays: pausedCG,
                occludedDisplays: coveredCG,
                fullscreenDisplays: fullscreenCG,
                desktopOccluded: coveredDisplays.count == displays.count && !displays.isEmpty,
                screenSaverIsOurs: WallpaperStoreProbe.screenSaverIsOurs(),
                powerProfile: powerProfile.rawValue
            )
        }
        playbackStopped = displays.contains { engine.wallpaperID(on: $0.displayID) != nil }
            && displays.allSatisfy { display in
                guard engine.wallpaperID(on: display.displayID) != nil else { return true }
                switch engine.tier(on: display.displayID) {
                case .full, .reduced, .minimal: return false
                default: return true
                }
            }
    }

    private func present(_ title: String, _ message: String) {
        nativeHostLog.error("alert: \(title, privacy: .public), \(message, privacy: .public)")
        let alert = AppAlert(title: title, message: message)
        if activeAlert == nil {
            activeAlert = alert
        } else {
            alertQueue.append(alert)
        }
    }

    /// Dismiss the active alert and show the next queued one, if any.
    func acknowledgeAlert() {
        activeAlert = alertQueue.isEmpty ? nil : alertQueue.removeFirst()
    }
}
