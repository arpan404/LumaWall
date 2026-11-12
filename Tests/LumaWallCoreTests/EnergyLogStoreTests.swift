import Foundation
import LumaWallCore
import Testing

struct EnergyLogStoreTests {
    @Test func reportsSoakAveragesAnd24HourGate() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var samples: [EnergySample] = []
        for index in 0..<5 {
            samples.append(
                EnergySample(
                    date: start.addingTimeInterval(Double(index) * 3_600),
                    processCPUPercent: Double(index + 1),
                    systemCPUPercent: 10,
                    processMemoryMB: 100 + Double(index * 10),
                    batteryPercent: 80 - index,
                    isOnBattery: true,
                    decoderCount: 1,
                    powerProfile: "automatic",
                    playbackActive: true
                )
            )
        }
        let short = EnergyLogStore.makeReport(
            samples: samples,
            startedAt: start,
            endedAt: start.addingTimeInterval(4 * 3_600)
        )
        #expect(short.sampleCount == 5)
        #expect(short.averageProcessCPU == 3)
        #expect(short.peakProcessCPU == 5)
        #expect(short.averageMemoryMB == 120)
        #expect(short.batteryDeltaPercent == -4)
        #expect(!short.meets24HourGate)

        let long = EnergyLogStore.makeReport(
            samples: samples,
            startedAt: start,
            endedAt: start.addingTimeInterval(24 * 3_600)
        )
        #expect(long.meets24HourGate)
        #expect(long.proofSummary.contains("24h threshold met"))
    }

    @Test func persistsSamplesAndPrunesOlderThanRetention() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EnergyLogStore(rootURL: root)
        let now = Date()
        try await store.startSoak(at: now.addingTimeInterval(-2 * 3_600))
        let stale = EnergySample(
            date: now.addingTimeInterval(-25 * 3_600),
            processCPUPercent: 9,
            systemCPUPercent: 20,
            processMemoryMB: 200,
            batteryPercent: 50,
            isOnBattery: false,
            decoderCount: 2,
            powerProfile: "automatic",
            playbackActive: false
        )
        let fresh = EnergySample(
            date: now.addingTimeInterval(-1 * 3_600),
            processCPUPercent: 2,
            systemCPUPercent: 12,
            processMemoryMB: 110,
            batteryPercent: 90,
            isOnBattery: false,
            decoderCount: 1,
            powerProfile: "automatic",
            playbackActive: true
        )
        try await store.record(stale, now: now)
        try await store.record(fresh, now: now)
        let snapshot = await store.current()
        #expect(snapshot.samples.count == 1)
        #expect(snapshot.samples[0].processCPUPercent == 2)
        let report = await store.report(now: now)
        #expect(report?.sampleCount == 1)
        #expect(report?.proofSummary.contains("LumaWall Energy Log") == true)
    }

    @Test func persistsCompactJSONWithoutPrettyPrinting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EnergyLogStore(rootURL: root)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.startSoak(at: now)
        try await store.record(EnergySample(
            date: now,
            processCPUPercent: 1.5, systemCPUPercent: 2.5, processMemoryMB: 100,
            batteryPercent: 80, isOnBattery: true, decoderCount: 1,
            powerProfile: "automatic", playbackActive: true
        ), now: now)

        let url = root.appendingPathComponent("EnergyLog.json")
        let text = try #require(String(data: Data(contentsOf: url), encoding: .utf8))
        #expect(!text.contains("\n"))
        #expect(!text.contains("\r"))
        #expect(!text.contains("  "))
        // Compact output still decodes to the same snapshot.
        let snapshot = await store.current()
        #expect(StoreIO.readJSON(from: url, as: EnergyLogSnapshot.self) == snapshot)
    }

    @Test func clearSoakResetsWindowButKeepsSamples() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EnergyLogStore(rootURL: root)
        try await store.startSoak()
        #expect(await store.current().soakStartedAt != nil)
        try await store.clearSoak()
        #expect(await store.current().soakStartedAt == nil)
    }

    @Test func relaunchPrunesStalePersistedSamples() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let first = try EnergyLogStore(rootURL: root)
        try await first.record(EnergySample(
            date: now.addingTimeInterval(-25 * 3_600),
            processCPUPercent: 9, systemCPUPercent: 20, processMemoryMB: 200,
            batteryPercent: 50, isOnBattery: false, decoderCount: 2,
            powerProfile: "automatic", playbackActive: false
        ), now: now)
        try await first.record(EnergySample(
            date: now.addingTimeInterval(-1 * 3_600),
            processCPUPercent: 2, systemCPUPercent: 12, processMemoryMB: 110,
            batteryPercent: 90, isOnBattery: false, decoderCount: 1,
            powerProfile: "automatic", playbackActive: true
        ), now: now)

        // A fresh process loading the persisted file must prune on init, so a
        // relaunch never resurrects out-of-retention samples.
        let second = try EnergyLogStore(rootURL: root)
        let snapshot = await second.current()
        #expect(snapshot.samples.count == 1)
        #expect(snapshot.samples[0].processCPUPercent == 2)
    }
}
