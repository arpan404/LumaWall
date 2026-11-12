import AppKit
import Foundation
import LumaWallCore

// Microbenchmarks for the hot paths touched by the optimization pass.
// Run before and after a change with the same machine state; numbers are
// wall-clock medians, not absolute promises.

struct Result: Codable {
    var name: String
    var unit: String
    var coldMS: Double?
    var warmMS: Double?
    var perUnitNS: Double?
    var bytes: Int?
    var note: String?
}

func nowNS() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

@discardableResult
func measure(_ iterations: Int, _ body: () -> Void) -> Double {
    var samples: [Double] = []
    samples.reserveCapacity(iterations)
    for _ in 0 ..< iterations {
        let start = nowNS()
        body()
        samples.append(Double(nowNS() - start) / 1_000_000)
    }
    samples.sort()
    return samples[samples.count / 2]
}

func benchmarkOcclusion() -> Result {
    var displays: [DisplayOcclusion.DisplayFrame] = []
    let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    for index in 0 ..< 3 {
        displays.append(DisplayOcclusion.DisplayFrame(
            displayID: DisplayID(rawValue: "display-\(index)"),
            frame: screen.offsetBy(dx: CGFloat(index) * 1920, dy: 0),
            isMain: index == 0
        ))
    }
    var windows: [DisplayOcclusion.Window] = []
    windows.reserveCapacity(1200)
    for index in 0 ..< 1200 {
        let row = index % 30
        let column = (index / 30) % 40
        let rect = CGRect(
            x: CGFloat(column) * 96,
            y: CGFloat(row) * 90,
            width: index.isMultiple(of: 37) ? 1800 : 420,
            height: index.isMultiple(of: 37) ? 1000 : 380
        )
        windows.append(DisplayOcclusion.Window(rect: rect, layer: 0))
    }
    var sink: CGFloat = 0
    _ = DisplayOcclusion.analyze(displays: displays, windows: windows)
    let ms = measure(50) {
        let analysis = DisplayOcclusion.analyze(displays: displays, windows: windows)
        sink += analysis.coverage.values.reduce(0, +)
    }
    return Result(name: "occlusion.analyze", unit: "ms", coldMS: nil, warmMS: ms, perUnitNS: nil, bytes: Int(sink), note: "3 displays x 1200 windows")
}

func benchmarkDiskUsage() async -> Result {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("lumawall-bench-library-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let payload = Data(count: 32 * 1024)
    for index in 0 ..< 600 {
        try? payload.write(to: root.appendingPathComponent("asset-\(index).bin"))
    }
    let store = try! LibraryStore(rootURL: root)
    let start = nowNS()
    _ = await store.diskUsageBytes()
    let coldMS = Double(nowNS() - start) / 1_000_000
    var samples: [Double] = []
    samples.reserveCapacity(20)
    for _ in 0 ..< 20 {
        let tick = nowNS()
        _ = await store.diskUsageBytes()
        samples.append(Double(nowNS() - tick) / 1_000_000)
    }
    samples.sort()
    let warmMS = samples[samples.count / 2]
    return Result(name: "library.diskUsage", unit: "ms", coldMS: coldMS, warmMS: warmMS, perUnitNS: nil, bytes: nil, note: "600 files / 19 MB")
}

func benchmarkEnergyLogWrite() -> Result {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumawall-bench-store-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("EnergyLog.json")
    var samples: [EnergySample] = []
    samples.reserveCapacity(1440)
    for index in 0 ..< 1440 {
        samples.append(EnergySample(
            date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60),
            processCPUPercent: 3.14159,
            systemCPUPercent: 12.3456,
            processMemoryMB: 412.75,
            batteryPercent: 87,
            isOnBattery: true,
            decoderCount: 2,
            powerProfile: "automatic",
            playbackActive: true
        ))
    }
    let snapshot = EnergyLogSnapshot(samples: samples)
    let ms = measure(10) {
        try? StoreIO.writeJSON(snapshot, to: url)
    }
    let bytes = (try? Data(contentsOf: url).count) ?? 0
    return Result(name: "store.writeEnergyLog", unit: "ms", coldMS: nil, warmMS: ms, perUnitNS: nil, bytes: bytes, note: "1440 samples")
}

func benchmarkAccessibilityRead() -> Result {
    _ = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    let count = 20_000
    let start = nowNS()
    for _ in 0 ..< count {
        _ = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }
    let ns = Double(nowNS() - start) / Double(count)
    return Result(name: "theme.accessibilityRead", unit: "ns/call", coldMS: nil, warmMS: nil, perUnitNS: ns, bytes: nil, note: "upper bound for uncached Theme")
}

func benchmarkWindowList() -> Result {
    _ = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    let ms = measure(20) {
        _ = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    }
    return Result(name: "policy.windowList", unit: "ms", coldMS: nil, warmMS: ms, perUnitNS: nil, bytes: nil, note: "CGWindowListCopyWindowInfo")
}

func benchmarkPowerRead() -> Result {
    _ = PowerStatus.current()
    let ms = measure(100) {
        _ = PowerStatus.current()
    }
    return Result(name: "power.current", unit: "ms", coldMS: nil, warmMS: ms, perUnitNS: nil, bytes: nil, note: "IOKit power-source read")
}

func benchmarkFileExists() -> Result {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lumawall-bench-exists")
    try? Data("x".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let count = 100_000
    let start = nowNS()
    for _ in 0 ..< count {
        _ = FileManager.default.fileExists(atPath: url.path)
    }
    let ns = Double(nowNS() - start) / Double(count)
    return Result(name: "variant.fileExists", unit: "ns/call", coldMS: nil, warmMS: nil, perUnitNS: ns, bytes: nil, note: "per resolvedURL lookup")
}

let results = [
    benchmarkOcclusion(),
    await benchmarkDiskUsage(),
    benchmarkEnergyLogWrite(),
    benchmarkAccessibilityRead(),
    benchmarkWindowList(),
    benchmarkPowerRead(),
    benchmarkFileExists(),
]

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try encoder.encode(results)
if let index = CommandLine.arguments.firstIndex(of: "--json"), index + 1 < CommandLine.arguments.count {
    try data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
}
print(String(decoding: data, as: UTF8.self))
