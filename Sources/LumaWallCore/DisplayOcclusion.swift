import CoreGraphics
import Foundation

/// Per-display window-coverage verdicts used by playback policy.
///
/// Extracted from the app target so the geometry math is testable and
/// benchmarkable without spinning up `AppModel`. The analysis parses the window
/// server list once and evaluates every display against it.
public struct DisplayOcclusionAnalysis: Equatable, Sendable {
    public var covered: Set<DisplayID>
    public var fullscreen: Set<DisplayID>
    /// Max single-window coverage ratio per display, for hysteresis.
    public var coverage: [DisplayID: CGFloat]

    public init(
        covered: Set<DisplayID> = [],
        fullscreen: Set<DisplayID> = [],
        coverage: [DisplayID: CGFloat] = [:]
    ) {
        self.covered = covered
        self.fullscreen = fullscreen
        self.coverage = coverage
    }
}

public enum DisplayOcclusion {
    public struct DisplayFrame: Sendable {
        public var displayID: DisplayID
        public var frame: CGRect
        public var isMain: Bool

        public init(displayID: DisplayID, frame: CGRect, isMain: Bool) {
            self.displayID = displayID
            self.frame = frame
            self.isMain = isMain
        }
    }

    public struct Window: Sendable {
        public var rect: CGRect
        public var layer: Int

        public init(rect: CGRect, layer: Int) {
            self.rect = rect
            self.layer = layer
        }
    }

    /// Live analysis from the current window server list.
    public static func analysis(in displays: [ConnectedDisplay]) -> DisplayOcclusionAnalysis {
        let desktopLayer = Int(CGWindowLevelForKey(.desktopIconWindow))
        let desktop = displays.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        // Mirror Quartz rects around the PRIMARY display's top (see
        // ScreenGeometry.cocoaWindow): the union's maxY is only correct when
        // no display extends above the primary. A taller sidecar or stacked
        // layout otherwise shifts every window rect and coverage misfires.
        let primaryHeight = displays.first(where: \.isMain)?.frame.height ?? desktop.maxY
        guard !desktop.isNull,
              let info = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
              ) as? [[String: Any]]
        else { return DisplayOcclusionAnalysis() }

        var windows: [Window] = []
        windows.reserveCapacity(info.count)
        for dict in info {
            let layer = dict[kCGWindowLayer as String] as? Int ?? 0
            if layer <= desktopLayer { continue }
            guard let bounds = dict[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let quartz = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )
            windows.append(Window(
                rect: ScreenGeometry.cocoaWindow(fromQuartz: quartz, primaryHeight: primaryHeight),
                layer: layer
            ))
        }
        return analyze(displays: displays.map {
            DisplayFrame(displayID: $0.displayID, frame: $0.frame, isMain: $0.isMain)
        }, windows: windows)
    }

    /// Pure coverage math over a prepared window list.
    public static func analyze(
        displays: [DisplayFrame],
        windows: [Window]
    ) -> DisplayOcclusionAnalysis {
        guard !displays.isEmpty, !windows.isEmpty else { return DisplayOcclusionAnalysis() }
        // Hoisted once: mapping window rects inside the display loop re-copied
        // every window per display.
        let rects = windows.map(\.rect)
        var covered: Set<DisplayID> = []
        var fullscreen: Set<DisplayID> = []
        var coverage: [DisplayID: CGFloat] = [:]
        covered.reserveCapacity(displays.count)
        fullscreen.reserveCapacity(displays.count)
        coverage.reserveCapacity(displays.count)
        for display in displays {
            let ratio = ScreenGeometry.coverageRatio(screen: display.frame, windows: rects)
            coverage[display.displayID] = ratio
            // Require near-total occlusion before auto-pausing (see
            // PlaybackPolicyThresholds). Lower values flap pause/resume on
            // maximized windows with menu bar/dock visible (~96% coverage).
            if ratio >= PlaybackPolicyThresholds.occlusionCovered {
                covered.insert(display.displayID)
            }
            let ownsFullscreen = windows.contains { window in
                // Same math as ScreenGeometry.coverageRatio for a one-window
                // list, without allocating a temporary `[window.rect]` per
                // window per display.
                let rect = window.rect
                return windowCoverageRatio(screen: display.frame, window: rect)
                    >= PlaybackPolicyThresholds.fullscreenCoverage
                    && abs(rect.width - display.frame.width) < PlaybackPolicyThresholds.fullscreenWidthTolerance
                    && abs(rect.height - display.frame.height) < PlaybackPolicyThresholds.fullscreenHeightTolerance
            }
            if ownsFullscreen {
                fullscreen.insert(display.displayID)
            }
        }
        return DisplayOcclusionAnalysis(covered: covered, fullscreen: fullscreen, coverage: coverage)
    }

    /// `ScreenGeometry.coverageRatio(screen:windows:)` for a single window.
    private static func windowCoverageRatio(screen: CGRect, window: CGRect) -> CGFloat {
        let area = screen.width * screen.height
        guard area > 0 else { return 0 }
        let hit = window.intersection(screen)
        guard !hit.isNull, !hit.isInfinite else { return 0 }
        return (hit.width * hit.height) / area
    }
}
