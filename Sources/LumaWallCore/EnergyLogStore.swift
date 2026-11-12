import Foundation

public struct EnergySample: Codable, Equatable, Sendable {
    public var date: Date
    public var processCPUPercent: Double
    public var systemCPUPercent: Double
    public var processMemoryMB: Double
    public var batteryPercent: Int
    public var isOnBattery: Bool
    public var decoderCount: Int
    public var powerProfile: String
    public var playbackActive: Bool

    public init(
        date: Date = .now,
        processCPUPercent: Double,
        systemCPUPercent: Double,
        processMemoryMB: Double,
        batteryPercent: Int,
        isOnBattery: Bool,
        decoderCount: Int,
        powerProfile: String,
        playbackActive: Bool
    ) {
        self.date = date
        self.processCPUPercent = processCPUPercent
        self.systemCPUPercent = systemCPUPercent
        self.processMemoryMB = processMemoryMB
        self.batteryPercent = batteryPercent
        self.isOnBattery = isOnBattery
        self.decoderCount = decoderCount
        self.powerProfile = powerProfile
        self.playbackActive = playbackActive
    }
}

public struct EnergySoakReport: Equatable, Sendable {
    public var startedAt: Date
    public var endedAt: Date
    public var sampleCount: Int
    public var durationHours: Double
    public var averageProcessCPU: Double
    public var peakProcessCPU: Double
    public var averageMemoryMB: Double
    public var peakMemoryMB: Double
    public var averageDecoders: Double
    public var peakDecoders: Int
    public var batteryStartPercent: Int?
    public var batteryEndPercent: Int?
    public var batteryDeltaPercent: Int?
    public var onBatterySampleRatio: Double
    public var meets24HourGate: Bool

    public var proofSummary: String {
        let hours = String(format: "%.1f", durationHours)
        let cpu = String(format: "%.2f", averageProcessCPU)
        let peakCPU = String(format: "%.1f", peakProcessCPU)
        let ram = String(format: "%.0f", averageMemoryMB)
        let peakRAM = String(format: "%.0f", peakMemoryMB)
        let decoders = String(format: "%.2f", averageDecoders)
        var lines = [
            "LumaWall Energy Log",
            "Window: \(hours)h · \(sampleCount) samples",
            "App CPU avg \(cpu)% (peak \(peakCPU)%)",
            "RAM avg \(ram) MB (peak \(peakRAM) MB)",
            "Decoders avg \(decoders) (peak \(peakDecoders))",
            "Battery samples: \(Int((onBatterySampleRatio * 100).rounded()))%"
        ]
        if let start = batteryStartPercent, let end = batteryEndPercent, let delta = batteryDeltaPercent {
            lines.append("Battery \(start)% → \(end)% (Δ \(delta)) while on battery")
        }
        lines.append(meets24HourGate ? "24h threshold met" : "Under 24h (still collecting)")
        return lines.joined(separator: "\n")
    }
}

public struct EnergyLogSnapshot: Codable, Equatable, Sendable {
    public var samples: [EnergySample]
    public var soakStartedAt: Date?

    public init(samples: [EnergySample] = [], soakStartedAt: Date? = nil) {
        self.samples = samples
        self.soakStartedAt = soakStartedAt
    }
}

public actor EnergyLogStore {
    public static let retention: TimeInterval = 24 * 60 * 60

    private let fileURL: URL
    private var snapshot = EnergyLogSnapshot()

    public init(rootURL: URL? = nil) throws {
        let base = try StorePaths.appSupportBase(rootURL: rootURL)
        self.fileURL = base.appendingPathComponent("EnergyLog.json")
        if let decoded: EnergyLogSnapshot = StoreIO.readJSON(from: fileURL, as: EnergyLogSnapshot.self) {
            snapshot = Self.pruned(decoded, now: .now)
        }
    }

    public func current() -> EnergyLogSnapshot { snapshot }

    public func startSoak(at date: Date = .now) throws {
        snapshot.soakStartedAt = date
        try persist()
    }

    public func clearSoak() throws {
        snapshot.soakStartedAt = nil
        try persist()
    }

    public func record(_ sample: EnergySample, now: Date = .now) throws {
        snapshot.samples.append(sample)
        snapshot = Self.pruned(snapshot, now: now)
        try persist()
    }

    public func report(now: Date = .now) -> EnergySoakReport? {
        snapshot = Self.pruned(snapshot, now: now)
        let start = snapshot.soakStartedAt ?? snapshot.samples.first?.date
        guard let start else { return nil }
        let window = snapshot.samples.filter { $0.date >= start && $0.date <= now }
        guard !window.isEmpty else { return nil }
        return Self.makeReport(samples: window, startedAt: start, endedAt: now)
    }

    public static func makeReport(
        samples: [EnergySample],
        startedAt: Date,
        endedAt: Date
    ) -> EnergySoakReport {
        let cpu = samples.map(\.processCPUPercent)
        let memory = samples.map(\.processMemoryMB)
        let decoders = samples.map(\.decoderCount)
        let onBattery = samples.filter(\.isOnBattery)
        let batteryDelta: Int?
        let batteryStart = onBattery.first?.batteryPercent
        let batteryEnd = onBattery.last?.batteryPercent
        if let batteryStart, let batteryEnd {
            batteryDelta = batteryEnd - batteryStart
        } else {
            batteryDelta = nil
        }
        let duration = max(0, endedAt.timeIntervalSince(startedAt))
        return EnergySoakReport(
            startedAt: startedAt,
            endedAt: endedAt,
            sampleCount: samples.count,
            durationHours: duration / 3_600,
            averageProcessCPU: average(cpu),
            peakProcessCPU: cpu.max() ?? 0,
            averageMemoryMB: average(memory),
            peakMemoryMB: memory.max() ?? 0,
            averageDecoders: average(decoders.map(Double.init)),
            peakDecoders: decoders.max() ?? 0,
            batteryStartPercent: batteryStart,
            batteryEndPercent: batteryEnd,
            batteryDeltaPercent: batteryDelta,
            onBatterySampleRatio: samples.isEmpty ? 0 : Double(onBattery.count) / Double(samples.count),
            meets24HourGate: duration >= retention - 60
        )
    }

    private func persist() throws {
        // StoreIO's compact encoder keeps each minute's full-snapshot write
        // durable without the pretty-printed padding that made it 443 KB.
        try StoreIO.writeJSON(snapshot, to: fileURL)
    }

    private static func pruned(_ snapshot: EnergyLogSnapshot, now: Date) -> EnergyLogSnapshot {
        let cutoff = now.addingTimeInterval(-retention)
        var next = snapshot
        next.samples.removeAll { $0.date < cutoff }
        return next
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
