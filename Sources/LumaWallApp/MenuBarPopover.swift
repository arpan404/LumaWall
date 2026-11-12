import AppKit
import LumaWallCore
import SwiftUI

struct MenuBarPopover: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var selectedIndex = 0
    @State private var isVisible = false
    @Namespace private var scopeNamespace

    private struct ActiveSlide: Identifiable {
        let id: String
        let asset: WallpaperAsset
        let displayName: String
    }

    private var slides: [ActiveSlide] {
        model.displays.compactMap { display in
            guard let wallpaperID = model.activeByDisplay[display.displayID],
                  let asset = model.asset(for: wallpaperID) else { return nil }
            return ActiveSlide(
                id: "\(display.displayID.rawValue)-\(wallpaperID.rawValue)",
                asset: asset,
                displayName: display.name
            )
        }
    }

    private var currentSlide: ActiveSlide? {
        guard !slides.isEmpty else { return nil }
        return slides[min(selectedIndex, slides.count - 1)]
    }

    var body: some View {
        // Diagnostics read the @ObservationIgnored stats; track the tick.
        let _ = model.statsRevision
        VStack(spacing: 10) {
            headerSection

            if slides.isEmpty {
                emptyStateSection
            } else {
                heroSection
                playbackScopePicker
            }

            quickLinksSection
            diagnosticsSection
            settingsSection
            footerSection
        }
        .padding(14)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            isVisible = true
            model.refreshStats()
        }
        .onDisappear { isVisible = false }
        .onChange(of: slides.count) { _, count in
            selectedIndex = min(selectedIndex, max(0, count - 1))
        }
    }

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 10) {
            BrandMark(size: 24, glowing: false)
            Text("LumaWall")
                .font(.system(size: 15, weight: .bold))
            Spacer()
            Text(versionString)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var heroSection: some View {
        ZStack {
            // The menu-bar window can keep its SwiftUI content alive after it
            // closes; only keep a decoder while the popover is actually shown.
            if let slide = currentSlide, isVisible {
                LoopingVideoView(url: slide.asset.mediaURL)
                    .id(slide.id)
            }
            if slides.count > 1 {
                HStack {
                    carouselArrow(systemName: "chevron.left", step: -1)
                    Spacer()
                    carouselArrow(systemName: "chevron.right", step: 1)
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(height: 168)
        .overlay(alignment: .bottom) { heroScrim }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var heroScrim: some View {
        if let slide = currentSlide {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(slide.asset.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(scrimSubtitle(for: slide))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 1, opacity: 0.72))
                        .lineLimit(1)
                }
                Spacer()
                if slides.count > 1 { pageDots }
            }
            .padding(10)
            .padding(.top, 26)
            .background {
                LinearGradient(
                    colors: [.clear, Color(white: 0, opacity: 0.72)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }

    private func scrimSubtitle(for slide: ActiveSlide) -> String {
        var parts: [String] = []
        if slides.count > 1 { parts.append(slide.displayName) }
        parts.append(playbackStatusText)
        return parts.joined(separator: " · ")
    }

    private var playbackStatusText: String {
        switch model.playbackScope {
        case .paused: return "Paused"
        case .lockScreen: return "Playing on Lock Screen"
        case .everywhere:
            if model.playbackStopped || model.activeByDisplay.isEmpty { return "Idle" }
            return "Playing"
        }
    }

    private func carouselArrow(systemName: String, step: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                let count = slides.count
                selectedIndex = (selectedIndex + step + count) % count
            }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(.black.opacity(0.35), in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private var pageDots: some View {
        HStack(spacing: 4) {
            ForEach(0 ..< slides.count, id: \.self) { index in
                Circle()
                    .fill(Color(white: 1, opacity: index == selectedIndex ? 1 : 0.35))
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.bottom, 4)
    }

    private var playbackScopePicker: some View {
        HStack(spacing: 0) {
            ForEach(PlaybackScope.allCases, id: \.self) { scope in
                let isSelected = scope == model.playbackScope
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        model.setPlaybackScope(scope)
                    }
                } label: {
                    Text(scope.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background {
                            if isSelected {
                                Capsule().fill(Theme.accent.opacity(0.28))
                                    .matchedGeometryEffect(id: "scope", in: scopeNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.quinary, in: Capsule())
    }

    private var emptyStateSection: some View {
        VStack(spacing: 8) {
            BrandMark(size: 40, glowing: false)
            if model.assets.isEmpty {
                Text("Add a video to your Library\nto get started")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Open LumaWall") { openMainWindow() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Text("Pick a wallpaper in LumaWall\nto see it here")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Open Library") {
                    model.section = .library
                    openMainWindow(preservingSection: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var quickLinksSection: some View {
        HStack(spacing: 6) {
            Menu {
                if model.recentAssets.isEmpty {
                    Text("Apply a wallpaper to add it here")
                } else {
                    ForEach(model.recentAssets.prefix(8)) { asset in
                        Button(asset.name) { model.apply(asset) }
                    }
                }
            } label: {
                Label("Recents", systemImage: "clock.arrow.circlepath")
            }
            .menuStyle(.button)

            Menu {
                Button("New Playlist") {
                    model.section = .library
                    model.beginPlaylistEditor()
                    openMainWindow(preservingSection: true)
                }
                if !model.playlists.isEmpty { Divider() }
                ForEach(model.playlists) { playlist in
                    Button(playlist.name) { model.applyPlaylist(playlist) }
                }
                if model.activePlaylistID != nil {
                    Divider()
                    Button("Stop Playlist", role: .destructive) { model.stopPlaylistRotation() }
                }
            } label: {
                Label("Playlists", systemImage: "rectangle.stack")
            }
            .menuStyle(.button)

            Menu {
                ForEach(PowerProfile.allCases, id: \.self) { profile in
                    Button {
                        model.setPowerProfile(profile)
                    } label: {
                        if model.powerProfile == profile {
                            Label(profile.label, systemImage: "checkmark")
                        } else {
                            Text(profile.label)
                        }
                    }
                }
            } label: {
                Label(model.powerProfile.label, systemImage: model.powerProfile.symbol)
            }
            .menuStyle(.button)
        }
        .controlSize(.small)
    }

    private var diagnosticsSection: some View {
        HStack(spacing: 10) {
            Label(String(format: "%.1f%%", model.processCPUPercent), systemImage: "cpu")
            Label(String(format: "%.0f MB", model.processMemoryMB), systemImage: "memorychip")
            if model.libraryDiskMB > 0 {
                Label(String(format: "%.0f MB", model.libraryDiskMB), systemImage: "internaldrive")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.7)
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)

            HStack(spacing: 6) {
                Toggle("Launch at Login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Toggle("Pause When Hidden", isOn: Binding(
                    get: { model.pauseWhenObscured },
                    set: { model.setPauseWhenObscured($0) }
                ))
            }
            .toggleStyle(MenuBarPillToggleStyle())
        }
    }

    private var footerSection: some View {
        HStack(spacing: 5) {
            Button { openMainWindow() } label: {
                Label("Library", systemImage: "film.stack")
            }
            .buttonStyle(MenuBarChipButtonStyle())

            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Choose", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(MenuBarChipButtonStyle())
            .help("Open macOS Wallpaper Settings")

            Spacer(minLength: 0)

            if model.activePlaylistID != nil {
                Button { model.stepPlaylist(-1) } label: {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(MenuBarRoundIconButtonStyle())

                Button { model.stepPlaylist(1) } label: {
                    Image(systemName: "forward.end.fill")
                }
                .buttonStyle(MenuBarRoundIconButtonStyle())
            }

            Button(action: model.reapplyActive) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(MenuBarRoundIconButtonStyle())
            .help("Reapply active wallpapers")

            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(MenuBarRoundIconButtonStyle())
            .help("Quit LumaWall")
        }
    }

    /// Read once: `body` re-evaluates on every stats tick.
    private static let versionString: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        return "v\(version)"
    }()

    private var versionString: String { Self.versionString }

    private func openMainWindow(preservingSection: Bool = false) {
        if !preservingSection {
            model.section = .home
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
        for window in NSApp.windows where window.canBecomeKey || window.isMiniaturized {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Menu bar styles

private struct MenuBarChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(configuration.isPressed ? 0.9 : 1), in: Capsule())
    }
}

private struct MenuBarRoundIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 26, height: 26)
            .background(.quaternary.opacity(configuration.isPressed ? 0.9 : 1), in: Circle())
    }
}

private struct MenuBarPillToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                configuration.label
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Capsule()
                    .fill(configuration.isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                    .frame(width: 18, height: 11)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .frame(width: 7, height: 7)
                            .padding(2)
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
