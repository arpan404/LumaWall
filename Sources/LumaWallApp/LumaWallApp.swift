import AppKit
import LumaWallCore
import SwiftUI

#if LUMAWALL_TEST_HOST
// Playback tests create their own sessions and temporary media. Keep the test
// host from restoring real wallpapers or opening the user's library stores.
@main
struct LumaWallTestHost: App {
    var body: some Scene {
        WindowGroup { Color.clear.frame(width: 32, height: 32) }
    }
}
#else
@main
struct LumaWallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("LumaWall", id: "main") {
            RootView(model: model)
                .frame(minWidth: 1_080, minHeight: 700)
        }
        .defaultSize(width: 1_280, height: 840)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)

        MenuBarExtra {
            MenuBarPopover(model: model)
        } label: {
            Image(nsImage: MenuBarIcon.image(badge: model.activePlaylistID != nil))
        }
        .menuBarExtraStyle(.window)
    }
}
#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        DispatchQueue.main.async { sender.setActivationPolicy(.accessory) }
        return false
    }

    nonisolated func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DispatchQueue.main.async { sender.setActivationPolicy(.regular) }
        return true
    }
}

private struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            AtmosphereBackground()
            VStack(spacing: 0) {
                AppChrome(model: model)
                Rectangle().fill(Theme.line).frame(height: 1)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .dropDestination(for: URL.self) { urls, _ in model.importVideos(urls); return true }
        .alert(
            model.activeAlert?.title ?? "",
            isPresented: Binding(
                get: { model.activeAlert != nil },
                set: { if !$0 { model.acknowledgeAlert() } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.activeAlert?.message ?? "")
        }
        .sheet(
            item: Binding(
                get: { model.topSheet },
                set: { model.setTopSheet($0) }
            )
        ) { route in
            switch route {
            case .preview(let asset): PreviewSheet(model: model, asset: asset)
            case .assign(let display): AssignSheet(model: model, display: display)
            case .automation(let slot): AutomationPickSheet(model: model, slot: slot)
            case .playlistEditor: PlaylistEditorSheet(model: model)
            }
        }
        .overlay {
            if model.isImporting || model.isApplying {
                BusyOverlay(text: model.isImporting ? "Preparing wallpaper…" : "Applying to desktop…")
            }
        }
        .onAppear { model.refreshDisplays() }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.keyWindow?.identifier = NSUserInterfaceItemIdentifier("LumaWallMainWindow")
        }
    }

    @ViewBuilder private var content: some View {
        switch model.section {
        case .home: HomePage(model: model)
        case .library: LibraryPage(model: model)
        case .displays: DisplaysPage(model: model)
        case .settings: SettingsPage(model: model)
        }
    }
}

private struct AtmosphereBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.bgTop, Theme.bgBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle()
                .fill(Theme.accent.opacity(0.11))
                .frame(width: 560, height: 560)
                .blur(radius: 110)
                .offset(x: 380, y: -260)
            Circle()
                .fill(Theme.warm.opacity(0.045))
                .frame(width: 480, height: 480)
                .blur(radius: 100)
                .offset(x: -320, y: 300)
            LinearGradient(
                colors: [.white.opacity(0.03), .clear, .white.opacity(0.015)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Top chrome

private struct AppChrome: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 16) {
            Button { model.section = .home } label: {
                HStack(spacing: 8) {
                    BrandMark(size: 30)
                    Text(L10n.appName)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .focusable(false)
            .help(L10n.home)
            .accessibilityLabel(L10n.brandHome)

            HStack(spacing: 3) {
                ForEach(AppModel.Section.allCases) { item in
                    Button {
                        withAnimation(.snappy(duration: 0.24)) { model.section = item }
                    } label: {
                        Text(item.title)
                            .font(.system(size: 12, weight: model.section == item ? .semibold : .medium))
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background {
                                if model.section == item {
                                    Capsule().fill(.white.opacity(0.94))
                                }
                            }
                            .foregroundStyle(model.section == item ? Color.black : Color.white.opacity(0.68))
                    }
                    .buttonStyle(.plain)
                    // Keep the tab keyboard-focusable, but suppress SwiftUI's
                    // bright blue focus plate; the white capsule already conveys
                    // the selected destination in this custom navigation bar.
                    .focusEffectDisabled()
                    .accessibilityLabel(item.title)
                    .accessibilityAddTraits(model.section == item ? [.isSelected] : [])
                }
            }
            .padding(4)
            .background(.black.opacity(0.24), in: Capsule())
            .overlay(Capsule().stroke(Theme.line))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Main navigation"))

            Spacer(minLength: 10)

            LibrarySearchField(text: $model.searchText, onSubmit: { model.section = .library })
                .frame(width: 188, height: 28)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(.white.opacity(0.06), in: Capsule())
                .overlay(Capsule().stroke(Theme.line))
                .accessibilityLabel(L10n.search)
                .onChange(of: model.searchText) { _, value in
                    if !value.isEmpty, model.section != .library {
                        model.section = .library
                    }
                }

            Button(action: model.togglePause) {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.10), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(model.isPaused ? L10n.resume : L10n.pause)
            .accessibilityLabel(model.isPaused ? L10n.resume : L10n.pause)
            .keyboardShortcut("p", modifiers: [.command])

            Button(action: model.chooseVideos) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.10), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(L10n.importVideos)
            .accessibilityLabel(L10n.importVideos)
            .keyboardShortcut("i", modifiers: [.command])
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 10)
        .background(.black.opacity(0.12))
        .background(ChromeHitSurface())
    }
}

/// Hidden-title-bar windows put this chrome under the drag region. This view
/// claims mouse events so search, pause, and import actually receive clicks.
private struct ChromeHitSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeHitView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ChromeHitView: NSView {
    override nonisolated var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.toolbar = nil
    }
}

private struct LibrarySearchField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search library"
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 13)
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submitted(_:))
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: LibrarySearchField
        init(_ parent: LibrarySearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            parent.text = (obj.object as? NSSearchField)?.stringValue ?? ""
        }

        @objc func submitted(_ sender: NSSearchField) {
            parent.text = sender.stringValue
            parent.onSubmit()
        }
    }
}

// MARK: - Home

private struct HomePage: View {
    @Bindable var model: AppModel
    @State private var selectedCategory: WallpaperCategory?

    private var recentlyAddedAssets: [WallpaperAsset] {
        let assets = selectedCategory.map(model.assets(in:)) ?? model.assets
        return Array(assets.prefix(12))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                FeaturedHero(model: model)

                if model.assets.isEmpty {
                    EmptyInvite(action: model.chooseVideos)
                        .padding(.horizontal, 28)
                } else {
                    categorySelector

                    horizontalRow(
                        title: "Recently Added",
                        subtitle: selectedCategory.map { "Newest wallpapers in \($0.title)" }
                            ?? "Newest wallpapers in your library",
                        assets: recentlyAddedAssets,
                        seeAll: {
                            model.categoryFilter = selectedCategory
                            model.section = .library
                        }
                    )
                }

                HStack(spacing: 12) {
                    QuickLink(symbol: "display.2", title: "Displays", detail: model.displays.isEmpty ? "Detect screens" : "\(model.displays.count) connected") {
                        model.section = .displays
                    }
                    QuickLink(symbol: "rectangle.stack.fill", title: "Library", detail: model.playlists.isEmpty ? "Playlists & schedules" : "\(model.playlists.count) playlists") {
                        model.section = .library
                    }
                    QuickLink(symbol: "leaf.fill", title: "Energy", detail: model.powerProfile.label) {
                        model.section = .settings
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 30)
            }
            .padding(.top, 0)
        }
    }

    private var categorySelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                FilterChip(title: "All", selected: selectedCategory == nil) {
                    selectedCategory = nil
                }
                ForEach(WallpaperCategory.allCases) { category in
                    FilterChip(title: category.title, selected: selectedCategory == category) {
                        selectedCategory = category
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 2)
        }
        .accessibilityLabel("Wallpaper categories")
    }

    @ViewBuilder
    private func horizontalRow(
        title: String,
        subtitle: String,
        assets: [WallpaperAsset],
        showCategory: Bool = true,
        seeAll: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: title, subtitle: subtitle, action: seeAll)
                .padding(.horizontal, 28)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(assets) { asset in
                        WallpaperTile(
                            model: model,
                            asset: asset,
                            width: 268,
                            showCategory: showCategory
                        )
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 10)
            }
        }
    }
}

private struct FeaturedHero: View {
    @Bindable var model: AppModel
    @State private var slideIndex = 0

    private static let slideDuration: Duration = .seconds(4)

    private var assets: [WallpaperAsset] { model.assets }
    private var currentAsset: WallpaperAsset? {
        guard !assets.isEmpty else { return nil }
        return assets[slideIndex % assets.count]
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            slideshowBackground

            LinearGradient(
                colors: [.clear, .black.opacity(0.35), .black.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 9) {
                    BrandMark(size: 24)
                    Text(currentAsset == nil ? "YOUR WALLPAPER, IN MOTION" : statusLabel)
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(Theme.accent)
                }
                Text(currentAsset?.name ?? "Make your desktop feel alive.")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 2)
                    .animation(.easeInOut(duration: 0.35), value: currentAsset?.id)
                Text(currentAsset.map(meta) ?? "Private local video wallpapers. Import once, apply instantly, stay offline.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: 520, alignment: .leading)
                    .animation(.easeInOut(duration: 0.35), value: currentAsset?.id)
                HStack(spacing: 10) {
                    if let currentAsset {
                        PrimaryButton("Use as Wallpaper", symbol: "display") { model.apply(currentAsset) }
                        GhostButton("All Displays", symbol: "rectangle.on.rectangle") { model.applyToAll(currentAsset) }
                        GhostButton("Preview", symbol: "play.fill") { model.previewAsset = currentAsset }
                    } else {
                        PrimaryButton("Import your first wallpaper", symbol: "plus", action: model.chooseVideos)
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 36)
            .frame(maxWidth: 760, alignment: .leading)

            if assets.count > 1 {
                slideIndicators
                    .padding(.trailing, 36)
                    .padding(.bottom, 36)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 420)
        .onAppear { syncSlideIndex() }
        .onChange(of: assets.map(\.id)) { _, _ in
            syncSlideIndex()
        }
        // Auto-cancelled by SwiftUI on disappear / count change. Keyed on the
        // count (not the ID list) so metadata reloads from apply/recordApply
        // don't restart the 4s cadence and make the hero jitter.
        .task(id: assets.count) {
            guard assets.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.slideDuration)
                guard !Task.isCancelled else { break }
                withAnimation(.easeInOut(duration: 0.7)) {
                    slideIndex = (slideIndex + 1) % assets.count
                }
            }
        }
    }

    @ViewBuilder
    private var slideshowBackground: some View {
        ZStack {
            if let asset = currentAsset {
                LoopingVideoView(url: asset.mediaURL)
                    .id(asset.id)
                    .transition(.opacity)
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.06, green: 0.18, blue: 0.20),
                        Color(red: 0.03, green: 0.06, blue: 0.09),
                        Color(red: 0.02, green: 0.04, blue: 0.06)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay(alignment: .trailing) {
                    BrandMark(size: 200, glowing: false)
                        .opacity(0.10)
                        .offset(x: -28, y: -20)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 420)
        .clipped()
        .animation(.easeInOut(duration: 0.7), value: slideIndex)
    }

    private var slideIndicators: some View {
        HStack(spacing: 6) {
            ForEach(Array(assets.enumerated()), id: \.element.id) { index, _ in
                Capsule()
                    .fill(index == slideIndex % assets.count ? Theme.accent : .white.opacity(0.28))
                    .frame(width: index == slideIndex % assets.count ? 18 : 6, height: 6)
                    .animation(.snappy(duration: 0.25), value: slideIndex)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.7)) {
                            slideIndex = index
                        }
                    }
            }
        }
        .accessibilityLabel("Wallpaper \(slideIndex + 1) of \(assets.count)")
    }

    private var statusLabel: String {
        guard let currentAsset else { return "FEATURED" }
        if model.isActive(currentAsset) { return "NOW PLAYING" }
        if assets.count > 1 { return "PREVIEWING \(slideIndex + 1) OF \(assets.count)" }
        return "FEATURED FROM YOUR LIBRARY"
    }

    private func meta(_ asset: WallpaperAsset) -> String {
        "\(Int(asset.pixelSize.width)) × \(Int(asset.pixelSize.height))  ·  \(Int(asset.framesPerSecond)) FPS  ·  \(asset.category.title)"
    }

    private func syncSlideIndex() {
        guard !assets.isEmpty else {
            slideIndex = 0
            return
        }
        if slideIndex >= assets.count {
            slideIndex = 0
        }
        if let featured = model.featured,
           let index = assets.firstIndex(where: { $0.id == featured.id }) {
            slideIndex = index
        }
    }
}

// MARK: - Library

private struct LibraryPage: View {
    @Bindable var model: AppModel
    @State private var selectedID: WallpaperID?
    @State private var showsAdvancedAutomations = false

    private static let cardWidth: CGFloat = 224
    private static let cardHeight: CGFloat = 150

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                PageHeader(
                    title: "Library",
                    subtitle: "Your wallpapers, playlists, and automatic cycles"
                ) {
                    PrimaryButton("Import", symbol: "plus", action: model.chooseVideos)
                }

                playlistsShelf
                dayNightShelf
                lightDarkShelf
                allWallpapersSection
                advancedShelf
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 44)
        }
        .sheet(
            item: Binding(
                get: { selectedID.map(SelectedInspector.init(assetID:)) },
                set: { selectedID = $0?.assetID }
            )
        ) { selection in
            // Look up live so library reloads while the sheet is open keep
            // working instead of pinning a stale snapshot.
            if let asset = model.asset(for: selection.assetID) {
                LibraryInspectorSheet(model: model, asset: asset)
            }
        }
    }

    /// Identifiable wrapper giving the inspector sheet stable identity across
    /// library reloads (a derived `isPresented` boolean loses which asset is
    /// shown and drops the sheet when the asset value changes).
    private struct SelectedInspector: Identifiable {
        let assetID: WallpaperID
        var id: WallpaperID { assetID }
    }

    private var allWallpapersSection: some View {
        // Filtering is O(assets); compute once per body instead of four times
        // (subtitle, empty checks, grid, toolbar count).
        let filtered = model.filteredAssets
        return VStack(alignment: .leading, spacing: 14) {
            shelfHeader(
                title: "All Wallpapers",
                subtitle: model.assets.isEmpty
                    ? "Import an MP4 or MOV to start your collection"
                    : "\(filtered.count) of \(model.assets.count) shown",
                trailing: { EmptyView() }
            )
            libraryToolbar(filteredCount: filtered.count)
            if model.assets.isEmpty {
                EmptyInvite(action: model.chooseVideos)
            } else if filtered.isEmpty {
                ContentUnavailableView(
                    "No Matching Wallpapers",
                    systemImage: "rectangle.stack.badge.minus",
                    description: Text("Clear a filter or try a different search.")
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 16)],
                    spacing: 18
                ) {
                    ForEach(filtered) { asset in
                        LibrarySelectionTile(
                            model: model,
                            asset: asset,
                            isSelected: selectedID == asset.id
                        ) { selectedID = asset.id }
                    }
                }
            }
        }
    }

    private var selectedAsset: WallpaperAsset? {
        guard let selectedID else { return nil }
        return model.asset(for: selectedID)
    }

    private func libraryToolbar(filteredCount: Int) -> some View {
        HStack(spacing: 10) {
            TextField("Search your library", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180, maxWidth: 320)
            Picker("Resolution", selection: $model.resolutionFilter) {
                ForEach(ResolutionFilter.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 130)
            Picker("Category", selection: $model.categoryFilter) {
                Text("All categories").tag(Optional<WallpaperCategory>.none)
                ForEach(WallpaperCategory.allCases) { Text($0.title).tag(Optional($0)) }
            }
            .frame(width: 150)
            Picker("Sort", selection: Binding(
                get: { model.librarySort },
                set: { model.setSort($0) }
            )) {
                ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 125)
            Toggle(isOn: $model.favoritesOnly) {
                Label("Favorites", systemImage: "heart.fill")
            }
            .toggleStyle(.button)
            Spacer(minLength: 8)
            Text("\(filteredCount) of \(model.assets.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.textDim)
        }
        .controlSize(.small)
    }

    private func shelfHeader<Trailing: View>(
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim)
            }
            Spacer(minLength: 8)
            trailing()
        }
    }

    private var playlistsShelf: some View {
        VStack(alignment: .leading, spacing: 14) {
            shelfHeader(
                title: "Playlists",
                subtitle: "Rotate through a set of wallpapers on a timer",
                trailing: {
                    if model.activePlaylistID != nil {
                        Button("Stop rotation") { model.stopPlaylistRotation() }
                            .buttonStyle(.link)
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
            )
            ShelfRow {
                ShelfAddCard(
                    title: "New Playlist",
                    caption: model.assets.isEmpty ? "Import a video first" : "Pick videos and an interval",
                    width: Self.cardWidth,
                    height: Self.cardHeight
                ) { model.beginPlaylistEditor() }
                .disabled(model.assets.isEmpty)

                ForEach(model.playlists) { playlist in
                    PlaylistShelfCard(
                        model: model,
                        playlist: playlist,
                        width: Self.cardWidth,
                        height: Self.cardHeight
                    )
                }
            }
        }
    }

    private var dayNightShelf: some View {
        VStack(alignment: .leading, spacing: 14) {
            shelfHeader(
                title: "Day / Night",
                subtitle: model.automations.useSunriseSunset
                    ? "Switches at sunrise and sunset"
                    : "Switches at \(formattedHour(model.automations.dayStartHour)) and \(formattedHour(model.automations.nightStartHour))",
                trailing: {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { model.automations.dayNightEnabled },
                            set: { model.setDayNightEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel("Enable day and night cycle")
                }
            )
            ShelfRow {
                AutomationSlotCard(
                    symbol: "sun.max.fill",
                    title: "Day",
                    detail: "Choose wallpaper",
                    footnote: model.automations.useSunriseSunset
                        ? "From sunrise"
                        : "From \(formattedHour(model.automations.dayStartHour))",
                    asset: model.asset(for: model.automations.dayWallpaperID),
                    height: Self.cardHeight
                ) { model.automationPickSlot = .day }
                .frame(width: Self.cardWidth)

                AutomationSlotCard(
                    symbol: "moon.fill",
                    title: "Night",
                    detail: "Choose wallpaper",
                    footnote: model.automations.useSunriseSunset
                        ? "From sunset"
                        : "From \(formattedHour(model.automations.nightStartHour))",
                    asset: model.asset(for: model.automations.nightWallpaperID),
                    height: Self.cardHeight
                ) { model.automationPickSlot = .night }
                .frame(width: Self.cardWidth)

                scheduleCard
            }
            .opacity(model.automations.dayNightEnabled ? 1 : 0.6)
        }
    }

    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Schedule")
                .font(.system(size: 13, weight: .semibold))
            Toggle(
                "Sunrise / sunset",
                isOn: Binding(
                    get: { model.automations.useSunriseSunset },
                    set: { model.setUseSunriseSunset($0) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 11))

            if model.automations.useSunriseSunset {
                Text("Needs Location When In Use so LumaWall can estimate daylight for your region.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                compactSchedulePicker(
                    "Day",
                    selection: Binding(
                        get: { model.automations.dayStartHour },
                        set: { model.setDayStartHour($0) }
                    )
                )
                compactSchedulePicker(
                    "Night",
                    selection: Binding(
                        get: { model.automations.nightStartHour },
                        set: { model.setNightStartHour($0) }
                    )
                )
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: Self.cardWidth, height: Self.cardHeight, alignment: .topLeading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.line))
    }

    private var lightDarkShelf: some View {
        VStack(alignment: .leading, spacing: 14) {
            shelfHeader(
                title: "Light / Dark",
                subtitle: "Follows the macOS system appearance",
                trailing: {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { model.automations.appearanceEnabled },
                            set: { model.setAppearanceEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel("Enable light and dark cycle")
                }
            )
            ShelfRow {
                AutomationSlotCard(
                    symbol: "sun.max.fill",
                    title: "Light",
                    detail: "Choose wallpaper",
                    footnote: "Light mode",
                    asset: model.asset(for: model.automations.lightWallpaperID),
                    height: Self.cardHeight
                ) { model.automationPickSlot = .light }
                .frame(width: Self.cardWidth)

                AutomationSlotCard(
                    symbol: "moon.fill",
                    title: "Dark",
                    detail: "Choose wallpaper",
                    footnote: "Dark mode",
                    asset: model.asset(for: model.automations.darkWallpaperID),
                    height: Self.cardHeight
                ) { model.automationPickSlot = .dark }
                .frame(width: Self.cardWidth)
            }
            .opacity(model.automations.appearanceEnabled ? 1 : 0.6)
        }
    }

    private var advancedShelf: some View {
        DisclosureGroup(isExpanded: $showsAdvancedAutomations) {
            VStack(alignment: .leading, spacing: 22) {
                automationRulesSection
                lockScreenSection
            }
            .padding(.top, 14)
        } label: {
            Text("Advanced rules and lock screen")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textDim)
        }
    }

    private func compactSchedulePicker(_ title: String, selection: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textDim)
            Picker(title, selection: selection) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(formattedHour(hour)).tag(hour)
                }
            }
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(Theme.panelStrong.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }

    private func schedulePicker(_ title: String, selection: Binding<Int>) -> some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .semibold))
            Spacer()
            Picker(title, selection: selection) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(formattedHour(hour)).tag(hour)
                }
            }
            .labelsHidden()
            .frame(width: 120)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
    }

    private func formattedHour(_ hour: Int) -> String {
        let date = Calendar.current.date(from: DateComponents(hour: hour)) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    private var automationRulesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            automationHeader(
                title: "Rules",
                subtitle: "Limit when automations can change the desktop.",
                enabled: true,
                expanded: model.automationRulesExpanded,
                onEnable: { _ in },
                onToggleExpand: { model.automationRulesExpanded.toggle() },
                showsEnable: false
            )

            if model.automationRulesExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Active days")
                        .font(.system(size: 12, weight: .semibold))
                    HStack(spacing: 8) {
                        ForEach(Array(["S", "M", "T", "W", "T", "F", "S"].enumerated()), id: \.offset) { index, label in
                            Button {
                                model.toggleWeekday(index)
                            } label: {
                                Text(label)
                                    .font(.system(size: 12, weight: .bold))
                                    .frame(width: 32, height: 32)
                                    .background(
                                        model.isWeekdaySelected(index) ? Theme.accent.opacity(0.22) : Theme.panel,
                                        in: Circle()
                                    )
                                    .overlay(Circle().stroke(model.isWeekdaySelected(index) ? Theme.accent.opacity(0.55) : Theme.line))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(weekdayName(index))
                        }
                        if model.automations.weekdayMask != 0 {
                            Button("Every day") { model.clearWeekdayFilter() }
                                .buttonStyle(.link)
                        }
                    }

                    Divider().overlay(Theme.line)

                    Toggle(
                        "Do not interrupt",
                        isOn: Binding(
                            get: {
                                model.automations.doNotInterruptStartHour != nil
                                    && model.automations.doNotInterruptEndHour != nil
                            },
                            set: { enabled in
                                if enabled {
                                    model.setDoNotInterrupt(start: 22, end: 7)
                                } else {
                                    model.setDoNotInterrupt(start: nil, end: nil)
                                }
                            }
                        )
                    )
                    .toggleStyle(.switch)

                    if model.automations.doNotInterruptStartHour != nil,
                       model.automations.doNotInterruptEndHour != nil {
                        HStack(spacing: 14) {
                            schedulePicker(
                                "Quiet from",
                                selection: Binding(
                                    get: { model.automations.doNotInterruptStartHour ?? 22 },
                                    set: {
                                        model.setDoNotInterrupt(
                                            start: $0,
                                            end: model.automations.doNotInterruptEndHour ?? 7
                                        )
                                    }
                                )
                            )
                            schedulePicker(
                                "Quiet until",
                                selection: Binding(
                                    get: { model.automations.doNotInterruptEndHour ?? 7 },
                                    set: {
                                        model.setDoNotInterrupt(
                                            start: model.automations.doNotInterruptStartHour ?? 22,
                                            end: $0
                                        )
                                    }
                                )
                            )
                        }
                    }

                    HStack {
                        Text("Power source")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Picker(
                            "Power source",
                            selection: Binding(
                                get: { model.automations.powerSourceRule },
                                set: { model.setPowerSourceRule($0) }
                            )
                        ) {
                            ForEach(PowerSourceRule.allCases) { rule in
                                Text(rule.title).tag(rule)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
                }
            }
        }
    }

    private var lockScreenSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            automationHeader(
                title: "Lock Screen",
                subtitle: "Assign a different video for the lock screen when the native wallpaper host is active.",
                enabled: true,
                expanded: model.lockAutomationExpanded,
                onEnable: { _ in },
                onToggleExpand: { model.lockAutomationExpanded.toggle() },
                showsEnable: false
            )

            if model.lockAutomationExpanded {
                AutomationSlotCard(
                    symbol: "lock.fill",
                    title: "Lock Screen",
                    detail: model.wallpaperHostMode == .native
                        ? "Choose wallpaper"
                        : "Needs macOS 26 native host",
                    footnote: "Idle / lock surface",
                    asset: model.asset(for: model.automations.lockScreenWallpaperID),
                    height: Self.cardHeight
                ) {
                    model.automationPickSlot = .lock
                }
                .frame(width: Self.cardWidth)
                .opacity(model.wallpaperHostMode == .native ? 1 : 0.55)
                .disabled(model.wallpaperHostMode != .native)
            }
        }
    }

    private func weekdayName(_ index: Int) -> String {
        ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][index]
    }

    private func automationHeader(
        title: String,
        subtitle: String,
        enabled: Bool,
        expanded: Bool,
        onEnable: @escaping (Bool) -> Void,
        onToggleExpand: @escaping () -> Void,
        showsEnable: Bool = true
    ) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                if showsEnable {
                    Text("Enable")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textDim)
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { enabled },
                            set: { newValue in onEnable(newValue) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                Button(action: onToggleExpand) {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct LibrarySelectionTile: View {
    @Bindable var model: AppModel
    let asset: WallpaperAsset
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 9) {
                WallpaperPosterFrame(posterURL: asset.posterURL, cornerRadius: 13) {
                    EmptyView()
                }
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 6) {
                        if model.isActive(asset) {
                            Text("IN USE")
                                .padding(.horizontal, 7)
                                .frame(height: 18)
                                .foregroundStyle(.black)
                                .background(Theme.accent, in: Capsule())
                        }
                        if model.isFavorite(asset) {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(.pink)
                                .frame(width: 22, height: 22)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                    }
                    .font(.system(size: 9, weight: .bold))
                    .padding(9)
                }

                Text(asset.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("\(asset.resolutionLabel) · \(Int(asset.framesPerSecond)) FPS · \(asset.category.title)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                isSelected ? Theme.accent.opacity(0.13) : Theme.panel,
                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(isSelected ? Theme.accent : Theme.line, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Preview") { model.previewAsset = asset }
            Button("Use on Main Display") { model.apply(asset) }
            Button("Use on All Displays") { model.applyToAll(asset) }
            Button(model.isFavorite(asset) ? "Remove Favorite" : "Add Favorite") {
                model.toggleFavorite(asset)
            }
            Divider()
            Button("Remove from Library", role: .destructive) { model.remove(asset) }
        }
        .accessibilityLabel("\(asset.name), \(asset.resolutionLabel), \(Int(asset.framesPerSecond)) frames per second")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct LibraryInspector: View {
    @Bindable var model: AppModel
    let asset: WallpaperAsset?
    @State private var draftName = ""

    var body: some View {
        Group {
            if let asset {
                GeometryReader { viewport in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 16) {
                        poster(asset)
                        TextField("Wallpaper name", text: $draftName)
                            .font(.title3.weight(.semibold))
                            .textFieldStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .clipped()
                            .onSubmit { commitName(asset) }
                        metadata(asset)
                        Divider().overlay(Theme.line)
                        Picker("Category", selection: Binding(
                            get: { asset.category },
                            set: { model.setCategory($0, for: asset) }
                        )) {
                            ForEach(WallpaperCategory.allCases) { category in
                                Label(category.title, systemImage: category.symbol).tag(category)
                            }
                        }
                        .pickerStyle(.menu)

                        if !model.displaysUsing(asset).isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Currently displayed on")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.textDim)
                                ForEach(model.displaysUsing(asset)) { display in
                                    Label(display.name, systemImage: "display")
                                        .font(.subheadline)
                                }
                            }
                        }

                        Menu {
                            Button("Main Display") { model.apply(asset) }
                            Button("All Displays") { model.applyToAll(asset) }
                            if model.displays.count > 1 {
                                Button("Span Across Displays") { model.spanAcrossAllDisplays(asset) }
                            }
                            Divider()
                            ForEach(model.displays) { display in
                                Button(display.name) { model.apply(asset, to: display.displayID) }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "display")
                                Text("Use as Wallpaper")
                                    .font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        }
                        .menuStyle(.borderlessButton)

                        HStack {
                            GhostButton("Preview", symbol: "play.fill") { model.previewAsset = asset }
                            GhostButton(
                                model.isFavorite(asset) ? "Favorited" : "Favorite",
                                symbol: model.isFavorite(asset) ? "heart.fill" : "heart"
                            ) { model.toggleFavorite(asset) }
                        }
                        Button("Remove from Library", role: .destructive) { model.remove(asset) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red.opacity(0.9))
                        }
                        // Scroll views otherwise let media and long filenames choose
                        // an oversized ideal width, which can push the leading edge
                        // underneath the inspector's rounded border.
                        .frame(width: max(viewport.size.width - 36, 1), alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 18)
                    }
                    .scrollIndicators(.visible)
                }
                .onAppear { draftName = asset.name }
                .onChange(of: asset.id) { _, _ in draftName = asset.name }
            } else {
                ContentUnavailableView(
                    "Select a Wallpaper",
                    systemImage: "rectangle.stack",
                    description: Text("Its details and display controls will appear here.")
                )
            }
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func poster(_ asset: WallpaperAsset) -> some View {
        Group {
            PosterImage(url: asset.posterURL)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 10, contentMode: .fit)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if model.isActive(asset) {
                Text("PLAYING")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Theme.accent, in: Capsule())
                    .padding(10)
            }
        }
    }

    private func metadata(_ asset: WallpaperAsset) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            inspectorRow("Resolution", "\(Int(asset.pixelSize.width)) × \(Int(asset.pixelSize.height))")
            inspectorRow("Frame rate", "\(Int(asset.framesPerSecond)) FPS")
            inspectorRow("Duration", asset.duration.formatted(.number.precision(.fractionLength(1))) + " sec")
            inspectorRow("Added", asset.createdAt.formatted(date: .abbreviated, time: .omitted))
            inspectorRow("Used", "\(asset.applyCount) time\(asset.applyCount == 1 ? "" : "s")")
            inspectorRow("Audio", asset.containsAudio ? "Present" : "Removed")
        }
        .font(.system(size: 11))
    }

    private func inspectorRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(Theme.textDim)
            Text(value).monospacedDigit()
        }
    }

    private func commitName(_ asset: WallpaperAsset) {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != asset.name else {
            draftName = asset.name
            return
        }
        model.rename(asset, to: trimmed)
    }
}

private struct AutomationSlotCard: View {
    let symbol: String
    let title: String
    let detail: String
    let footnote: String
    let asset: WallpaperAsset?
    var height: CGFloat = 168
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                PosterImage(url: asset?.posterURL)
                LinearGradient(
                    colors: [.black.opacity(0.55), .black.opacity(0.15), .clear],
                    startPoint: .bottom,
                    endPoint: .top
                )
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: symbol)
                        Text(title).font(.system(size: 13, weight: .semibold))
                    }
                    Spacer()
                    if asset == nil {
                        Image(systemName: "plus")
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer()
                    Text(asset?.name ?? detail)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(footnote)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Theme.line)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ShelfRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                content()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 1)
        }
    }
}

private struct ShelfAddCard: View {
    let title: String
    let caption: String
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center)
            }
            .padding(14)
            .frame(width: width, height: height)
            .background(Theme.panel.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(style: StrokeStyle(lineWidth: 1.2, dash: [7, 5]))
                    .foregroundStyle(Theme.line)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct PlaylistShelfCard: View {
    @Bindable var model: AppModel
    let playlist: WallpaperPlaylist
    let width: CGFloat
    let height: CGFloat

    private var isActive: Bool { model.activePlaylistID == playlist.id }

    private var posterURL: URL? {
        for id in playlist.wallpaperIDs {
            if let url = model.asset(for: id)?.posterURL {
                return url
            }
        }
        return nil
    }

    var body: some View {
        Button(action: toggleRotation) {
            ZStack {
                PosterImage(url: posterURL)
                LinearGradient(
                    colors: [.black.opacity(0.78), .black.opacity(0.2), .clear],
                    startPoint: .bottom,
                    endPoint: .top
                )
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: isActive ? "play.fill" : "list.and.film")
                        if isActive {
                            Text("ACTIVE")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 7)
                                .frame(height: 17)
                                .background(Theme.accent.opacity(0.92), in: Capsule())
                                .foregroundStyle(.black)
                        }
                    }
                    Spacer()
                    Text(playlist.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("\(playlist.wallpaperIDs.count) items · \(playlist.shuffled ? "Shuffled" : "Ordered") · every \(playlist.intervalMinutes)m")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .foregroundStyle(.white)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isActive ? Theme.accent.opacity(0.55) : Theme.line, lineWidth: isActive ? 1.6 : 1)
            )
        }
        .buttonStyle(.plain)
        .help(isActive ? "Stop rotation" : "Start this playlist")
        .accessibilityLabel("\(playlist.name) playlist")
        .contextMenu {
            Button(isActive ? "Stop Rotation" : "Apply Playlist", action: toggleRotation)
            Button("Edit…") { model.beginPlaylistEditor(existing: playlist) }
            Divider()
            Button("Delete", role: .destructive) { model.deletePlaylist(playlist) }
        }
    }

    private func toggleRotation() {
        if isActive {
            model.stopPlaylistRotation()
        } else {
            model.applyPlaylist(playlist)
        }
    }
}

private struct LibraryInspectorSheet: View {
    @Bindable var model: AppModel
    let asset: WallpaperAsset
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            LibraryInspector(model: model, asset: asset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Spacer()
                Button("Done", action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 420, height: 660)
    }
}

private struct AutomationPickSheet: View {
    @Bindable var model: AppModel
    let slot: AppModel.AutomationSlot
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                BrandMark(size: 28)
                Text("Choose \(slot.title) wallpaper").font(.title2.bold())
            }
            if model.assets.isEmpty {
                Text("Import a wallpaper first.").foregroundStyle(Theme.textDim)
            } else {
                List(model.assets) { asset in
                    Button {
                        model.assignAutomation(slot: slot, asset: asset)
                        dismiss()
                    } label: {
                        HStack {
                            Text(asset.name)
                            Spacer()
                            if model.asset(for: id(for: slot))?.id == asset.id {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                if model.asset(for: id(for: slot)) != nil {
                    Button("Clear slot", role: .destructive) {
                        model.clearAutomation(slot: slot)
                        dismiss()
                    }
                }
                Spacer()
                Button("Close", action: dismiss.callAsFunction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 500)
    }

    private func id(for slot: AppModel.AutomationSlot) -> WallpaperID? {
        switch slot {
        case .day: model.automations.dayWallpaperID
        case .night: model.automations.nightWallpaperID
        case .light: model.automations.lightWallpaperID
        case .dark: model.automations.darkWallpaperID
        case .lock: model.automations.lockScreenWallpaperID
        }
    }
}

// MARK: - Displays / Playlists / Settings

private struct DisplaysPage: View {
    @Bindable var model: AppModel
    private var bounds: CGRect {
        model.displays.map(\.frame).reduce(.null) { $0.union($1) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(L10n.displays)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                topology
                    .frame(height: 260)
                    .padding(20)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.line))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16)], spacing: 16) {
                    ForEach(model.displays) { DisplayCard(model: model, display: $0) }
                }
            }
            .padding(28)
        }
        .onAppear { model.refreshDisplays() }
    }

    private var topology: some View {
        GeometryReader { geo in
            let world = bounds.isNull ? CGRect(x: 0, y: 0, width: 1, height: 1) : bounds
            let scale = min(geo.size.width / max(world.width, 1), geo.size.height / max(world.height, 1)) * 0.78
            let offsetX = (geo.size.width - world.width * scale) / 2 - world.minX * scale
            let offsetY = (geo.size.height - world.height * scale) / 2 - world.minY * scale
            ZStack(alignment: .topLeading) {
                ForEach(model.displays) { display in
                    let rect = CGRect(
                        x: display.frame.minX * scale + offsetX,
                        y: (world.maxY - display.frame.maxY) * scale + offsetY,
                        width: max(display.frame.width * scale, 160),
                        height: max(display.frame.height * scale, 90)
                    )
                    DisplayMapTile(model: model, display: display)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
    }
}

private struct DisplayMapTile: View {
    @Bindable var model: AppModel
    let display: ConnectedDisplay

    var body: some View {
        let asset = model.asset(for: model.activeByDisplay[display.displayID])
        Button {
            model.assignTarget = display
        } label: {
            Color.clear
                .overlay {
                    Group {
                        PosterImage(url: asset?.posterURL)
                    }
                }
                .clipped()
                .overlay(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(display.name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(asset?.name ?? "No wallpaper")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.black.opacity(0.78), .clear], startPoint: .bottom, endPoint: .top))
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(asset == nil ? Theme.line : Theme.accent, lineWidth: asset == nil ? 1 : 2)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct DisplayCard: View {
    @Bindable var model: AppModel
    let display: ConnectedDisplay

    var body: some View {
        let asset = model.asset(for: model.activeByDisplay[display.displayID])
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    PosterImage(url: asset?.posterURL)
                }
                .frame(width: 72, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(display.name).font(.headline).lineLimit(1)
                        if display.isMain {
                            Text("Main")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.white.opacity(0.08), in: Capsule())
                        }
                    }
                    Text("\(Int(display.pixelSize.width))×\(Int(display.pixelSize.height)) · \(Int(display.refreshRate)) Hz")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                    Text(asset?.name ?? "No wallpaper assigned")
                        .font(.subheadline)
                        .foregroundStyle(asset == nil ? Theme.textDim : .primary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack {
                PrimaryButton("Choose…", symbol: nil) { model.assignTarget = display }
                if asset != nil {
                    GhostButton(
                        model.pausedDisplayIDs.contains(display.displayID) ? "Resume" : "Pause",
                        symbol: nil
                    ) { model.togglePause(on: display) }
                    GhostButton("Clear", symbol: nil) { model.clearDisplay(display) }
                }
            }
        }
        .padding(18)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.line))
    }
}

private struct SettingsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        // The CPU/RAM fields are @ObservationIgnored hot stats; this revision
        // is the observed signal that a 15 s sample landed.
        let _ = model.statsRevision
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.settings)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .accessibilityAddTraits(.isHeader)
                    Text(L10n.settingsSubtitle)
                        .foregroundStyle(Theme.textDim)
                }

                settingsGroup(title: L10n.wallpaperHost, symbol: "rectangle.on.rectangle.angled") {
                    settingsRow(
                        title: model.wallpaperHostMode == .native ? "System wallpaper (macOS 26)" : "Desktop overlay",
                        detail: model.wallpaperHostMode == .native
                            ? "Uses WallpaperExtensionKit through the LumaWall wallpaper extension."
                            : "Uses the poster plus live overlay. Native host needs macOS 26 and an app build that embeds the wallpaper extension.",
                        symbol: model.wallpaperHostMode == .native ? "checkmark.seal.fill" : "square.stack.3d.up"
                    ) {
                        EmptyView()
                    }
                }

                settingsGroup(title: L10n.playbackEnergy, symbol: "leaf.fill") {
                    VStack(spacing: 0) {
                        ForEach(PowerProfile.allCases, id: \.self) { profile in
                            Button { model.setPowerProfile(profile) } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: profile.symbol)
                                        .frame(width: 28, height: 28)
                                        .foregroundStyle(model.powerProfile == profile ? Theme.accent : .secondary)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(profile.label).fontWeight(.semibold)
                                        Text(profile.detail)
                                            .font(.system(size: 11))
                                            .foregroundStyle(Theme.textDim)
                                    }
                                    Spacer()
                                    Image(systemName: model.powerProfile == profile ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(model.powerProfile == profile ? Theme.accent : Color.white.opacity(0.22))
                                        .accessibilityHidden(true)
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 11)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(profile.label)
                            .accessibilityHint(profile.detail)
                            .accessibilityAddTraits(model.powerProfile == profile ? [.isSelected] : [])
                            if profile != PowerProfile.allCases.last {
                                Divider().overlay(Theme.line)
                            }
                        }
                        Divider().overlay(Theme.line)
                        settingsRow(
                            title: L10n.reduceMotion,
                            detail: model.reduceMotionActive
                                ? "System Reduce Motion is on. Live video stays on a still frame."
                                : "Follows System Settings → Accessibility → Display → Reduce motion.",
                            symbol: "figure.walk.motion"
                        ) {
                            Text(model.reduceMotionActive ? "On" : "Off")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(model.reduceMotionActive ? Theme.accent : Theme.textDim)
                                .accessibilityHidden(true)
                        }
                        Divider().overlay(Theme.line)
                        settingsRow(
                            title: L10n.pauseObscured,
                            detail: "Stops that screen when a window covers about 98% of it.",
                            symbol: "rectangle.slash"
                        ) {
                            Toggle(L10n.pauseObscured, isOn: Binding(
                                get: { model.pauseWhenObscured },
                                set: { model.setPauseWhenObscured($0) }
                            ))
                            .labelsHidden()
                            .accessibilityLabel(L10n.pauseObscured)
                        }
                        Divider().overlay(Theme.line)
                        settingsRow(
                            title: L10n.pauseLock,
                            detail: "Stops live video behind the lock screen. The still poster stays.",
                            symbol: "lock.fill"
                        ) {
                            Toggle(L10n.pauseLock, isOn: Binding(
                                get: { model.pauseOnLock },
                                set: { model.setPauseOnLock($0) }
                            ))
                            .labelsHidden()
                            .accessibilityLabel(L10n.pauseLock)
                        }
                        Divider().overlay(Theme.line)
                        settingsRow(
                            title: L10n.stillDesktop,
                            detail: model.wallpaperHostMode == .native
                                ? "Keeps the desktop still. Lock screen and screen saver can keep live video through the wallpaper extension."
                                : "Hides the live overlay on the desktop. System Settings still has the poster.",
                            symbol: "photo"
                        ) {
                            Toggle(L10n.stillDesktop, isOn: Binding(
                                get: { model.hideDesktopVideo },
                                set: { model.setHideDesktopVideo($0) }
                            ))
                            .labelsHidden()
                            .accessibilityLabel(L10n.stillDesktop)
                        }
                    }
                }

                settingsGroup(title: L10n.energyLog, symbol: "bolt.heart.fill") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.energyLogDetail)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                        if let report = model.energySoakReport {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                statusCell(title: "Duration", value: String(format: "%.1f h", report.durationHours))
                                statusCell(title: "Samples", value: "\(report.sampleCount)")
                                statusCell(title: "Avg CPU", value: String(format: "%.2f%%", report.averageProcessCPU))
                                statusCell(title: "Peak CPU", value: String(format: "%.1f%%", report.peakProcessCPU))
                                statusCell(title: "Avg RAM", value: String(format: "%.0f MB", report.averageMemoryMB))
                                statusCell(title: "Avg decoders", value: String(format: "%.2f", report.averageDecoders))
                                statusCell(
                                    title: "24h mark",
                                    value: report.meets24HourGate ? "Met" : "In progress"
                                )
                                statusCell(
                                    title: "Battery Δ",
                                    value: report.batteryDeltaPercent.map { "\($0)%" } ?? "—"
                                )
                            }
                        } else {
                            Text("No samples yet. Start a 24h window while wallpapers play.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textDim)
                        }
                        HStack(spacing: 10) {
                            GhostButton(L10n.startSoak, symbol: "timer") { model.startEnergySoak() }
                            GhostButton(L10n.copyProof, symbol: "doc.on.doc") { model.copyEnergyProof() }
                            GhostButton(L10n.resetSoak, symbol: "arrow.counterclockwise") { model.resetEnergySoak() }
                        }
                    }
                }

                settingsGroup(title: L10n.diagnostics, symbol: "stethoscope") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.diagnosticsDetail)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)

                        if model.lastSessionEndedUncleanly {
                            HStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Theme.warm)
                                    .accessibilityHidden(true)
                                Text("The previous session did not shut down cleanly. The report below has details.")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.warm.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }

                        if model.crashReports.isEmpty {
                            Text("No crashes recorded. LumaWall has been shutting down cleanly.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textDim)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(model.crashReports.prefix(5)) { report in
                                    HStack(spacing: 14) {
                                        Image(systemName: report.kind == .uncleanShutdown ? "bolt.slash" : "ladybug.fill")
                                            .frame(width: 28, height: 28)
                                            .foregroundStyle(.secondary)
                                            .accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(report.headline).fontWeight(.semibold)
                                            Text(report.date.formatted(date: .abbreviated, time: .shortened))
                                                .font(.system(size: 11))
                                                .foregroundStyle(Theme.textDim)
                                        }
                                        Spacer()
                                        GhostButton("Copy", symbol: "doc.on.doc") { model.copyCrashReport(report) }
                                    }
                                    .padding(.vertical, 9)
                                    .accessibilityElement(children: .combine)
                                    if report.id != model.crashReports.prefix(5).last?.id {
                                        Divider().overlay(Theme.line)
                                    }
                                }
                            }
                        }

                        HStack(spacing: 10) {
                            GhostButton("Show in Finder", symbol: "folder") { model.revealCrashReports() }
                            if !model.crashReports.isEmpty {
                                GhostButton("Clear reports", symbol: "trash") { model.clearCrashReports() }
                            }
                        }
                    }
                }

                settingsGroup(title: L10n.app, symbol: "app.badge") {
                    settingsRow(
                        title: L10n.launchAtLogin,
                        detail: "Starts LumaWall in the background after you sign in.",
                        symbol: "power"
                    ) {
                        Toggle(
                            L10n.launchAtLogin,
                            isOn: Binding(
                                get: { model.launchAtLogin },
                                set: { model.setLaunchAtLogin($0) }
                            )
                        )
                        .labelsHidden()
                        .accessibilityLabel(L10n.launchAtLogin)
                    }
                }

                settingsGroup(title: L10n.storage, symbol: "internaldrive.fill") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            StatPill(title: "Process RAM", value: String(format: "%.0f MB", model.processMemoryMB))
                            StatPill(title: "Active decoders", value: "\(model.activeDecoderCount)")
                            StatPill(title: "Library on disk", value: String(format: "%.0f MB", model.libraryDiskMB))
                            StatPill(title: "Wallpapers", value: "\(model.assets.count)")
                            Spacer()
                        }
                        Divider().overlay(Theme.line)
                        HStack(spacing: 10) {
                            GhostButton(L10n.clearRAM, symbol: "memorychip") { model.clearMemoryCache() }
                            GhostButton(L10n.clearDisk, symbol: "externaldrive") { model.clearDiskCache() }
                        }
                        Text("Clear RAM drops decoders and temporary caches. Imported videos stay on disk. Matching multi-display videos share one decoder on the overlay host.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textDim)
                    }
                }

                settingsGroup(title: L10n.status, symbol: "info.circle") {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        statusCell(title: "Playback", value: model.playbackStopped ? "Paused" : (model.activeByDisplay.isEmpty ? "Idle" : "Live"))
                        statusCell(title: "Displays", value: "\(model.activeByDisplay.count) of \(model.displays.count) live")
                        statusCell(title: "Energy", value: model.powerProfile.label)
                        statusCell(title: "Automations", value: automationStatus)
                        statusCell(title: "App CPU", value: String(format: "%.1f%%", model.processCPUPercent))
                        statusCell(title: "System CPU", value: String(format: "%.1f%%", model.systemCPUPercent))
                        statusCell(title: "Battery", value: model.isOnBattery ? "\(model.batteryPercent)% battery" : "Power adapter")
                        statusCell(title: "RAM", value: String(format: "%.0f MB", model.processMemoryMB))
                        statusCell(title: "Decoders", value: "\(model.activeDecoderCount)")
                        statusCell(title: "Reduce Motion", value: model.reduceMotionActive ? "On (still frame)" : "Off")
                        statusCell(
                            title: "Energy soak",
                            value: model.energySoakReport.map {
                                $0.meets24HourGate ? "24h met" : String(format: "%.1fh", $0.durationHours)
                            } ?? "Idle"
                        )
                    }
                }

                HStack(spacing: 14) {
                    BrandMark(size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.appName).font(.headline)
                        Text(L10n.tagline)
                            .font(.caption).foregroundStyle(Theme.textDim)
                        Text(Self.versionString).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
            }
            .padding(28)
        }
        .onAppear { model.refreshStats() }
    }

    private var automationStatus: String {
        if model.automations.dayNightEnabled { return "Day/Night" }
        if model.automations.appearanceEnabled { return "Light/Dark" }
        if model.activePlaylistID != nil { return "Playlist" }
        return "Off"
    }

    /// Read once: `body` re-evaluates on every stats tick.
    private static let versionString: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        return "v\(version)"
    }()

    private func settingsGroup<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content()
                .padding(16)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.line))
        }
        .accessibilityElement(children: .contain)
    }

    private func settingsRow<Trailing: View>(
        title: String,
        detail: String,
        symbol: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .frame(width: 28, height: 28)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
            }
            Spacer()
            trailing()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }

    private func statusCell(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textDim)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.panelStrong, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }

}

private struct StatPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Theme.textDim)
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.panelStrong, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

// MARK: - Shared UI

private struct WallpaperPosterFrame<Overlay: View>: View {
    let posterURL: URL?
    var cornerRadius: CGFloat = 16
    @ViewBuilder var overlay: () -> Overlay

    init(
        posterURL: URL?,
        cornerRadius: CGFloat = 16,
        @ViewBuilder overlay: @escaping () -> Overlay = { EmptyView() }
    ) {
        self.posterURL = posterURL
        self.cornerRadius = cornerRadius
        self.overlay = overlay
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Theme.panelStrong)
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay {
                PosterImage(url: posterURL)
            }
            .overlay { overlay() }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct TileHoverActions: View {
    let onUse: () -> Void
    let onPreview: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onUse) {
                Label("Use", systemImage: "display")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)

            Button(action: onPreview) {
                Label("Preview", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(.white.opacity(0.12), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.2)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WallpaperTile: View {
    @Bindable var model: AppModel
    let asset: WallpaperAsset
    var width: CGFloat? = nil
    var showCategory: Bool = false
    @State private var hovering = false
    @State private var showVideo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WallpaperPosterFrame(posterURL: asset.posterURL, cornerRadius: 16) {
                ZStack {
                    // Hovering a grid tile shouldn't spin up a decoder for every
                    // pointer pass: wait until the cursor rests before creating
                    // the player.
                    if showVideo {
                        LoopingVideoView(url: asset.mediaURL)
                            .scaledToFill()
                            .transition(.opacity)
                        Color.black.opacity(0.28)
                            .transition(.opacity)
                    }
                }
            }
            .overlay(alignment: .top) {
                HStack {
                    if model.isActive(asset) {
                        Text("LIVE")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 7)
                            .frame(height: 20)
                            .background(Theme.accent.opacity(0.92), in: Capsule())
                            .foregroundStyle(.black)
                    }
                    Spacer()
                    Button { model.toggleFavorite(asset) } label: {
                        Image(systemName: model.isFavorite(asset) ? "heart.fill" : "heart")
                            .foregroundStyle(model.isFavorite(asset) ? .pink : .white)
                            .frame(width: 28, height: 28)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.isFavorite(asset) ? "Remove favorite" : "Add favorite")
                }
                .padding(10)
            }
            .overlay {
                if hovering {
                    TileHoverActions(
                        onUse: { model.apply(asset) },
                        onPreview: { model.previewAsset = asset }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(hovering ? Theme.accent.opacity(0.45) : Theme.line, lineWidth: 1)
            )
            .shadow(color: .black.opacity(hovering ? 0.28 : 0.14), radius: hovering ? 12 : 6, y: hovering ? 6 : 3)
            .animation(.snappy(duration: 0.22), value: hovering)
            .onHover { isHovering in
                hovering = isHovering
                if !isHovering { showVideo = false }
            }
            .task(id: hovering) {
                guard hovering else { return }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, hovering else { return }
                showVideo = true
            }
            .onDisappear { showVideo = false }

            VStack(alignment: .leading, spacing: 3) {
                Text(asset.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if showCategory {
                    Text("\(asset.category.title) · \(asset.resolutionLabel) · \(Int(asset.framesPerSecond)) FPS")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim)
                } else {
                    Text("\(Int(asset.pixelSize.width))×\(Int(asset.pixelSize.height)) · \(Int(asset.framesPerSecond)) FPS")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(width: width)
        .onTapGesture { model.previewAsset = asset }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(asset.name)
    }
}

private struct LibraryCard: View {
    @Bindable var model: AppModel
    let asset: WallpaperAsset
    @State private var draftName: String = ""
    @State private var isEditingName = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WallpaperTile(model: model, asset: asset, showCategory: true)

            if isEditingName {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { commitRename() }
                    .onAppear {
                        draftName = asset.name
                        nameFocused = true
                    }
                    .onChange(of: nameFocused) { _, focused in
                        if !focused { commitRename() }
                    }
            } else {
                Text(asset.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 2)
            }

            HStack(spacing: 8) {
                Menu {
                    ForEach(WallpaperCategory.allCases) { category in
                        Button {
                            model.setCategory(category, for: asset)
                        } label: {
                            HStack {
                                Text(category.title)
                                if asset.category == category {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label(asset.category.title, systemImage: asset.category.symbol)
                        .font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)

                Menu {
                    Button("Main Display") { model.apply(asset) }
                    Button("All Displays") { model.applyToAll(asset) }
                    if model.displays.count > 1 {
                        Button("Span Across Displays") { model.spanAcrossAllDisplays(asset) }
                    }
                    Divider()
                    ForEach(model.displays) { display in
                        Button(display.name) { model.apply(asset, to: display.displayID) }
                    }
                } label: {
                    Label("Apply to…", systemImage: "display")
                        .font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)

                Spacer()

                Button(role: .destructive) { model.remove(asset) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .contextMenu {
            Button("Rename…") {
                draftName = asset.name
                isEditingName = true
            }
            Button(model.isFavorite(asset) ? "Unlike" : "Like") {
                model.toggleFavorite(asset)
            }
            Divider()
            Button("Remove", role: .destructive) { model.remove(asset) }
        }
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditingName = false
        guard !trimmed.isEmpty, trimmed != asset.name else { return }
        model.rename(asset, to: trimmed)
    }
}

private struct AssignSheet: View {
    @Bindable var model: AppModel
    let display: ConnectedDisplay
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: WallpaperID?
    @State private var composition = DisplayComposition()

    private var selectedAsset: WallpaperAsset? {
        guard let selectedID else { return nil }
        return model.asset(for: selectedID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                BrandMark(size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Compose for \(display.name)").font(.title2.bold())
                    Text("\(Int(display.pixelSize.width))×\(Int(display.pixelSize.height))")
                        .font(.caption).foregroundStyle(Theme.textDim)
                }
            }
            if model.assets.isEmpty {
                Text("Import a wallpaper first.").foregroundStyle(Theme.textDim)
            } else {
                ZStack {
                    Rectangle().fill(.black)
                    PosterImage(url: selectedAsset?.posterURL, contentMode: contentMode)
                        .scaleEffect(composition.scale)
                        .rotationEffect(.degrees(composition.rotationDegrees))
                        .offset(x: composition.offset.x * 0.18, y: -composition.offset.y * 0.18)
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(max(display.frame.width / max(display.frame.height, 1), 1), contentMode: .fit)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))

                Picker("Wallpaper", selection: $selectedID) {
                    ForEach(model.assets) { asset in Text(asset.name).tag(Optional(asset.id)) }
                }

                HStack {
                    Picker("Sizing", selection: $composition.contentMode) {
                        Text("Fill").tag(LumaWallCore.ContentMode.fill)
                        Text("Fit").tag(LumaWallCore.ContentMode.fit)
                        Text("Stretch").tag(LumaWallCore.ContentMode.stretch)
                    }
                    .pickerStyle(.segmented)
                    Button("Reset") { composition = .init() }.buttonStyle(.borderless)
                }

                compositionSlider("Scale", value: $composition.scale, range: 0.5...2, format: "%.2f×")
                compositionSlider("Rotation", value: $composition.rotationDegrees, range: -180...180, format: "%.0f°")
                compositionSlider("Horizontal", value: xOffset, range: -600...600, format: "%.0f")
                compositionSlider("Vertical", value: yOffset, range: -600...600, format: "%.0f")

                HStack(spacing: 10) {
                    Text("Focal point")
                    Slider(value: focalX, in: 0...1)
                    Slider(value: focalY, in: 0...1)
                }
                .font(.system(size: 12, weight: .medium))
            }
            HStack {
                Button("Cancel", action: dismiss.callAsFunction).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply to Display") {
                    guard let selectedAsset else { return }
                    model.apply(selectedAsset, to: display.displayID, composition: composition)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedAsset == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 720)
        .onAppear {
            selectedID = model.activeByDisplay[display.displayID] ?? model.assets.first?.id
            composition = model.composition(on: display)
        }
    }

    private var contentMode: SwiftUI.ContentMode {
        switch composition.contentMode {
        case .fill: .fill
        case .fit: .fit
        case .stretch: .fill
        }
    }

    private var xOffset: Binding<Double> {
        Binding(get: { Double(composition.offset.x) }, set: { composition.offset.x = CGFloat($0) })
    }

    private var yOffset: Binding<Double> {
        Binding(get: { Double(composition.offset.y) }, set: { composition.offset.y = CGFloat($0) })
    }

    private var focalX: Binding<Double> {
        Binding(get: { Double(composition.focalPoint.x) }, set: { composition.focalPoint.x = CGFloat($0) })
    }

    private var focalY: Binding<Double> {
        Binding(get: { Double(composition.focalPoint.y) }, set: { composition.focalPoint.y = CGFloat($0) })
    }

    private func compositionSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String
    ) -> some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 72, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.textDim)
                .frame(width: 54, alignment: .trailing)
        }
        .font(.system(size: 12, weight: .medium))
    }
}

private struct PreviewSheet: View {
    @Bindable var model: AppModel
    let asset: WallpaperAsset
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            LoopingVideoView(url: asset.mediaURL)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(.black)
            HStack(spacing: 12) {
                BrandMark(size: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(asset.name).font(.title3.bold())
                    Text("\(Int(asset.pixelSize.width))×\(Int(asset.pixelSize.height)) · \(Int(asset.framesPerSecond)) FPS")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Category", selection: Binding(
                    get: { asset.category },
                    set: { model.setCategory($0, for: asset) }
                )) {
                    ForEach(WallpaperCategory.allCases) { category in
                        Text(category.title).tag(category)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                Button {
                    model.toggleFavorite(asset)
                } label: {
                    Image(systemName: model.isFavorite(asset) ? "heart.fill" : "heart")
                        .foregroundStyle(model.isFavorite(asset) ? .pink : .primary)
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                PrimaryButton("Use Wallpaper", symbol: "display") {
                    model.apply(asset)
                    dismiss()
                }
                Button("Done", action: dismiss.callAsFunction).keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 920, height: 600)
    }
}

private struct PlaylistEditorSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.playlistEditor?.existingID == nil ? "New playlist" : "Edit playlist")
                .font(.title2.bold())
            TextField("Name", text: nameBinding)
                .textFieldStyle(.roundedBorder)
            HStack {
                Text("Interval (minutes)")
                TextField("30", value: intervalBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                Toggle("Shuffle", isOn: shuffleBinding)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Library").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.assets) { asset in
                                Button { model.toggleEditorEntry(asset) } label: {
                                    HStack {
                                        Text(asset.name).lineLimit(1)
                                        Spacer()
                                        if model.playlistEditor?.orderedIDs.contains(asset.id) == true {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Order").font(.headline)
                    let ids = model.playlistEditor?.orderedIDs ?? []
                    ForEach(Array(ids.enumerated()), id: \.element.rawValue) { index, id in
                        if let asset = model.asset(for: id) {
                            HStack {
                                Text(asset.name).lineLimit(1)
                                Spacer()
                                Button("Up") { model.moveEditorEntry(from: index, to: max(0, index - 1)) }
                                    .disabled(index == 0)
                                Button("Down") { model.moveEditorEntry(from: index, to: index + 1) }
                                    .disabled(index == ids.count - 1)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            HStack {
                Spacer()
                Button("Cancel") {
                    model.playlistEditor = nil
                    dismiss()
                }
                Button("Save") {
                    model.savePlaylistEditor()
                    dismiss()
                }
                .disabled(model.playlistEditor?.orderedIDs.isEmpty ?? true)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { model.playlistEditor?.name ?? "" },
            set: { model.setPlaylistEditorName($0) }
        )
    }

    private var intervalBinding: Binding<Int> {
        Binding(
            get: { model.playlistEditor?.intervalMinutes ?? 30 },
            set: { model.setPlaylistEditorInterval($0) }
        )
    }

    private var shuffleBinding: Binding<Bool> {
        Binding(
            get: { model.playlistEditor?.shuffled ?? false },
            set: { model.setPlaylistEditorShuffled($0) }
        )
    }
}

private struct PrimaryButton: View {
    let title: String
    var symbol: String? = nil
    let action: () -> Void

    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol) }
                Text(title).fontWeight(.semibold)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Theme.accent, in: Capsule())
            .foregroundStyle(.black)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct GhostButton: View {
    let title: String
    var symbol: String? = nil
    let action: () -> Void

    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
                Text(title).fontWeight(.medium)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(Theme.line))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct FilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(selected ? Theme.accent : .white.opacity(0.06), in: Capsule())
                .foregroundStyle(selected ? .black : .white.opacity(0.72))
        }
        .buttonStyle(.plain)
    }
}

private struct QuickLink: View {
    let symbol: String, title: String, detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
        }
        .buttonStyle(.plain)
    }
}

private struct EmptyInvite: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                BrandMark(size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add your first wallpaper").font(.headline)
                    Text("Drop an MP4 or MOV anywhere in this window").foregroundStyle(Theme.textDim)
                }
                Spacer()
                Text("Choose Video").fontWeight(.semibold)
            }
            .padding(18)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(style: StrokeStyle(lineWidth: 1, dash: [6])))
        }
        .buttonStyle(.plain)
    }
}

private struct BusyOverlay: View {
    let text: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.42).ignoresSafeArea()
            VStack(spacing: 12) {
                BrandMark(size: 40)
                ProgressView().controlSize(.large)
                Text(text).fontWeight(.semibold)
            }
            .padding(28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

private struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    init(title: String, subtitle: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 32, weight: .bold, design: .rounded))
                Text(subtitle).foregroundStyle(Theme.textDim)
            }
            Spacer()
            trailing()
        }
    }
}

private struct SectionHeading: View {
    let title: String
    let subtitle: String
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 20, weight: .bold, design: .rounded))
                Text(subtitle).font(.caption).foregroundStyle(Theme.textDim)
            }
            Spacer()
            if let action {
                Button("See all", systemImage: "chevron.right", action: action)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension PowerProfile {
    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .fullQuality: "Full Quality"
        case .batterySaver: "Battery Saver"
        case .staticOnBattery: "Static on Battery"
        }
    }

    var detail: String {
        switch self {
        case .automatic: "Full fidelity on power, adaptive on battery."
        case .fullQuality: "Prefer source frame rate whenever possible."
        case .batterySaver: "Always use the lowest animated tier."
        case .staticOnBattery: "Hold a still frame until you switch back."
        }
    }

    var symbol: String {
        switch self {
        case .automatic: "leaf.fill"
        case .fullQuality: "bolt.fill"
        case .batterySaver: "battery.50"
        case .staticOnBattery: "pause.rectangle.fill"
        }
    }
}
