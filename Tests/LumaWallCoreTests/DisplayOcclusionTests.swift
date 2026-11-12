import CoreGraphics
import LumaWallCore
import Testing

@Suite struct DisplayOcclusionTests {
    private static let mainID = DisplayID(rawValue: "main")
    private static let leftID = DisplayID(rawValue: "left")
    private static let rightID = DisplayID(rawValue: "right")
    private static let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    private static func display(
        _ id: DisplayID,
        frame: CGRect,
        isMain: Bool = false
    ) -> DisplayOcclusion.DisplayFrame {
        DisplayOcclusion.DisplayFrame(displayID: id, frame: frame, isMain: isMain)
    }

    private static func window(_ rect: CGRect) -> DisplayOcclusion.Window {
        DisplayOcclusion.Window(rect: rect, layer: 0)
    }

    @Test func singleFullscreenWindowCoversAndOwnsDisplay() {
        let display = Self.display(Self.mainID, frame: Self.frame, isMain: true)
        let analysis = DisplayOcclusion.analyze(
            displays: [display],
            windows: [Self.window(Self.frame)]
        )

        #expect(analysis.covered == [Self.mainID])
        #expect(analysis.fullscreen == [Self.mainID])
        #expect(analysis.coverage[Self.mainID] == 1)
    }

    @Test func nearTotalWindowBelowThresholdIsNotCovered() {
        let display = Self.display(Self.mainID, frame: Self.frame, isMain: true)
        // 1890/1920 ≈ 0.984375: above the release threshold but below the
        // 0.985 enter threshold, so it must not latch covered or fullscreen.
        let nearTotal = CGRect(x: 0, y: 0, width: 1890, height: 1080)
        let analysis = DisplayOcclusion.analyze(
            displays: [display],
            windows: [Self.window(nearTotal)]
        )

        #expect(analysis.covered.isEmpty)
        #expect(analysis.fullscreen.isEmpty)
        #expect(analysis.coverage[Self.mainID] == 0.984375)
    }

    @Test func windowCoveringOneOfThreeDisplaysOnlyCoversThatDisplay() {
        let leftFrame = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let rightFrame = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let displays = [
            Self.display(Self.leftID, frame: leftFrame),
            Self.display(Self.mainID, frame: Self.frame, isMain: true),
            Self.display(Self.rightID, frame: rightFrame),
        ]
        let analysis = DisplayOcclusion.analyze(
            displays: displays,
            windows: [Self.window(Self.frame)]
        )

        #expect(analysis.covered == [Self.mainID])
        #expect(analysis.fullscreen == [Self.mainID])
        #expect(analysis.coverage[Self.mainID] == 1)
        #expect(analysis.coverage[Self.leftID] == 0)
        #expect(analysis.coverage[Self.rightID] == 0)
    }

    @Test func twoSubThresholdWindowsDoNotAddUpToCoverage() {
        let display = Self.display(Self.mainID, frame: Self.frame, isMain: true)
        let leftHalf = CGRect(x: 0, y: 0, width: 960, height: 1080)
        let rightHalf = CGRect(x: 960, y: 0, width: 960, height: 1080)
        let analysis = DisplayOcclusion.analyze(
            displays: [display],
            windows: [Self.window(leftHalf), Self.window(rightHalf)]
        )

        #expect(analysis.coverage[Self.mainID] == 0.5)
        #expect(analysis.covered.isEmpty)
        #expect(analysis.fullscreen.isEmpty)
    }

    @Test func emptyInputsReturnEmptyAnalysis() {
        let display = Self.display(Self.mainID, frame: Self.frame, isMain: true)

        #expect(DisplayOcclusion.analyze(displays: [], windows: [Self.window(Self.frame)]).coverage.isEmpty)
        #expect(DisplayOcclusion.analyze(displays: [display], windows: []).coverage.isEmpty)
    }
}
