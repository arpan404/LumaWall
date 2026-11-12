import AppKit
import SwiftUI

enum Brand {
    static let iconImage: NSImage = {
        for bundle in resourceBundles {
            if let url = bundle.url(forResource: "AppIcon", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return NSImage(size: NSSize(width: 128, height: 128))
    }()

    private static var resourceBundles: [Bundle] {
        #if SWIFT_PACKAGE
        [Bundle.module, Bundle.main]
        #else
        [Bundle.main]
        #endif
    }
}

struct BrandMark: View {
    var size: CGFloat = 34
    var glowing = true

    var body: some View {
        Image(nsImage: Brand.iconImage)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.223, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.223, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: glowing ? Theme.accent.opacity(0.30) : .clear, radius: glowing ? 8 : 0, y: 2)
            .accessibilityLabel(L10n.appName)
    }
}

enum Theme {
    // Accessibility contrast changes are rare; the getters below are called
    // from many `body` evaluations, so cache the flag instead of asking
    // NSWorkspace on every access. One observer keeps it fresh.
    @MainActor private static var cachedIncreaseContrast =
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    @MainActor private static var contrastObserver: NSObjectProtocol?

    @MainActor private static func refreshIncreaseContrast() {
        cachedIncreaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    @MainActor private static func ensureContrastObserver() {
        guard contrastObserver == nil else { return }
        contrastObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                refreshIncreaseContrast()
            }
        }
    }

    @MainActor static var increaseContrast: Bool {
        ensureContrastObserver()
        return cachedIncreaseContrast
    }

    static let bgTop = Color(red: 0.035, green: 0.05, blue: 0.062)
    static let bgBottom = Color(red: 0.015, green: 0.028, blue: 0.038)
    static let sidebar = Color(red: 0.025, green: 0.036, blue: 0.046)
    @MainActor static var panel: Color { Color.white.opacity(increaseContrast ? 0.10 : 0.04) }
    @MainActor static var panelStrong: Color { Color.white.opacity(increaseContrast ? 0.16 : 0.07) }
    @MainActor static var line: Color { Color.white.opacity(increaseContrast ? 0.28 : 0.08) }
    static let accent = Color(red: 0.20, green: 0.82, blue: 0.76)
    static let warm = Color(red: 0.96, green: 0.80, blue: 0.52)
    @MainActor static var textDim: Color { Color.white.opacity(increaseContrast ? 0.78 : 0.55) }
}
