import Foundation
import LumaWallCore
import Testing

struct LibraryStoreTests {
    @Test func persistsAndReloadsAssets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = sampleAsset(hash: "unique", category: .nature)
        let first = try LibraryStore(rootURL: root)
        try await first.install(asset)

        let second = try LibraryStore(rootURL: root)
        let loaded = await second.asset(id: asset.id)
        #expect(loaded?.id == asset.id)
        #expect(loaded?.name == asset.name)
        #expect(loaded?.contentHash == asset.contentHash)
        #expect(loaded?.category == .nature)
        #expect(loaded?.applyCount == 0)
    }

    @Test func rejectsContentDuplicatesWithDifferentNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(rootURL: root)
        try await store.install(sampleAsset(hash: "same", name: "First"))

        await #expect(throws: LibraryStore.StoreError.self) {
            try await store.install(sampleAsset(hash: "same", name: "Renamed Copy"))
        }
    }

    @Test func recordsApplyAndSortsMostUsed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(rootURL: root)
        let a = sampleAsset(hash: "a", name: "A")
        let b = sampleAsset(hash: "b", name: "B")
        try await store.install(a)
        try await store.install(b)
        try await store.recordApply(id: b.id)
        try await store.recordApply(id: b.id)
        try await store.recordApply(id: a.id)
        let sorted = await store.assets(sortedBy: .mostUsed)
        #expect(sorted.first?.id == b.id)
        #expect(sorted.first?.applyCount == 2)
    }

    @Test func migratesLegacyAssetsWithoutCategory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = """
        [{"id":{"rawValue":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"},"name":"Legacy","mediaURL":"file:///tmp/a.mov","duration":10,"framesPerSecond":30,"pixelSize":[1920,1080],"contentHash":"legacy","containsAudio":false}]
        """
        try Data(legacy.utf8).write(to: root.appendingPathComponent("Library.json"))
        let store = try LibraryStore(rootURL: root)
        let assets = await store.assets()
        #expect(assets.count == 1)
        #expect(assets[0].category == .other)
        #expect(assets[0].applyCount == 0)
    }

    @Test func updateRenameAndCategoryPersist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(rootURL: root)
        let asset = sampleAsset(hash: "mutable")
        try await store.install(asset)

        var renamed = asset
        renamed.name = "Changed"
        try await store.update(renamed)
        try await store.rename(id: asset.id, to: "  Trimmed  ")
        try await store.setCategory(id: asset.id, category: .space)

        let loaded = await store.asset(id: asset.id)
        #expect(loaded?.name == "Trimmed")
        #expect(loaded?.category == .space)
    }

    @Test func missingAssetOperationsThrow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(rootURL: root)
        let ghost = WallpaperID()
        await #expect(throws: LibraryStore.StoreError.self) {
            try await store.update(sampleAsset(hash: "ghost"))
        }
        await #expect(throws: LibraryStore.StoreError.self) {
            try await store.rename(id: ghost, to: "x")
        }
        await #expect(throws: LibraryStore.StoreError.self) {
            try await store.setCategory(id: ghost, category: .nature)
        }
        await #expect(throws: LibraryStore.StoreError.self) {
            try await store.recordApply(id: ghost)
        }
        await #expect(throws: LibraryStore.StoreError.self) {
            try await store.remove(id: ghost)
        }
    }

    @Test func removeDeletesAssetFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(rootURL: root)
        let id = WallpaperID()
        let folder = root.appendingPathComponent(id.rawValue.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let asset = WallpaperAsset(
            id: id,
            name: "Doomed",
            mediaURL: folder.appendingPathComponent("wallpaper.mov"),
            duration: 5,
            framesPerSecond: 30,
            pixelSize: CGSize(width: 1920, height: 1080),
            contentHash: "doomed",
            containsAudio: false
        )
        try await store.install(asset)
        #expect(await store.folder(for: id) == folder)

        try await store.remove(id: id)
        #expect(await store.asset(id: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func lookupByContentHashAndErrorText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(rootURL: root)
        try await store.install(sampleAsset(hash: "find-me", name: "Findable"))
        #expect(await store.asset(contentHash: "find-me")?.name == "Findable")
        #expect(await store.asset(contentHash: "absent") == nil)
        #expect(LibraryStore.StoreError.missingAsset.errorDescription == "The wallpaper is no longer installed.")
        #expect(
            LibraryStore.StoreError.duplicate(sampleAsset(hash: "x", name: "Dup")).errorDescription?
                .contains("Dup") == true
        )
    }

    @Test func sortsByNameResolutionAndAge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(rootURL: root)
        var small = sampleAsset(hash: "small", name: "banana")
        small.pixelSize = CGSize(width: 1280, height: 720)
        small.createdAt = Date(timeIntervalSince1970: 100)
        var big = sampleAsset(hash: "big", name: "Apple")
        big.pixelSize = CGSize(width: 3840, height: 2160)
        big.createdAt = Date(timeIntervalSince1970: 200)
        try await store.install(small)
        try await store.install(big)

        #expect(await store.assets(sortedBy: .name).map(\.name) == ["Apple", "banana"])
        #expect(await store.assets(sortedBy: .resolution).first?.contentHash == "big")
        #expect(await store.assets(sortedBy: .oldest).first?.contentHash == "small")
        #expect(await store.assets(sortedBy: .newest).first?.contentHash == "big")
    }

    @Test func diskUsageCountsLibraryFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(rootURL: root)
        try await store.install(sampleAsset(hash: "weighed"))
        let blob = root.appendingPathComponent("blob.bin")
        try Data(repeating: 7, count: 4096).write(to: blob)
        #expect(await store.diskUsageBytes() >= 4096)
    }

    @Test func diskUsageIsCachedUntilTheLibraryChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(rootURL: root)
        let blob = root.appendingPathComponent("blob.bin")
        try Data(repeating: 5, count: 4096).write(to: blob)

        let first = await store.diskUsageBytes()
        let second = await store.diskUsageBytes()
        #expect(first == second)
        #expect(first >= 4096)

        // install rewrites the index and invalidates, so the next read must
        // measure again rather than serve the pre-install total.
        try await store.install(sampleAsset(hash: "cache-invalidating"))
        #expect(await store.diskUsageBytes() > first)
    }

    @Test func storeIOWritesCompactJSONAndRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("compact.json")
        let value = CompactFixture(name: "Wallpaper", count: 3)

        try StoreIO.writeJSON(value, to: url)
        let text = try #require(String(data: Data(contentsOf: url), encoding: .utf8))
        #expect(!text.contains("\n"))
        #expect(!text.contains("\r"))
        #expect(!text.contains("  "))
        #expect(StoreIO.readJSON(from: url, as: CompactFixture.self) == value)
    }

    @Test func removeRefusesPathsOutsideEntryFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Bystander file outside any entry folder; a corrupt mediaURL must
        // never cause its deletion.
        let outside = root.appendingPathComponent("precious.mov")
        try Data(repeating: 1, count: 8).write(to: outside)
        let siblingID = WallpaperID()
        let siblingFolder = root.appendingPathComponent(siblingID.rawValue.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: siblingFolder, withIntermediateDirectories: true)

        func asset(id: WallpaperID, hash: String, mediaURL: URL) -> WallpaperAsset {
            WallpaperAsset(
                id: id, name: "x", mediaURL: mediaURL, duration: 1,
                framesPerSecond: 30, pixelSize: CGSize(width: 640, height: 480),
                contentHash: hash, containsAudio: false
            )
        }
        let store = try LibraryStore(rootURL: root)
        let escapeID = WallpaperID()
        try await store.install(asset(id: escapeID, hash: "stray", mediaURL: outside))
        let sibling = asset(id: siblingID, hash: "sibling", mediaURL: siblingFolder.appendingPathComponent("w.mov"))
        try await store.install(sibling)

        // Points outside the library root: index entry goes, file survives.
        await #expect(throws: LibraryStore.StoreError.invalidLocation) {
            try await store.remove(id: escapeID)
        }
        #expect(await store.asset(id: escapeID) == nil)
        #expect(FileManager.default.fileExists(atPath: outside.path))

        // Points at a sibling entry's folder: also refused.
        let hijackID = WallpaperID()
        try await store.install(asset(
            id: hijackID, hash: "hijacker",
            mediaURL: siblingFolder.appendingPathComponent("w.mov")
        ))
        await #expect(throws: LibraryStore.StoreError.invalidLocation) {
            try await store.remove(id: hijackID)
        }
        #expect(FileManager.default.fileExists(atPath: siblingFolder.path))
        #expect(LibraryStore.StoreError.invalidLocation.errorDescription?
            .contains("outside the library") == true)
    }

    @Test func corruptLibraryIsQuarantinedNotSilentlyReset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "not-json{{".write(
            to: root.appendingPathComponent("Library.json"), atomically: true, encoding: .utf8
        )

        let store = try LibraryStore(rootURL: root)
        #expect(await store.assets().isEmpty)
        let leftovers = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(leftovers.contains { $0.lastPathComponent.hasPrefix("Library.json.corrupt-") })
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Library.json").path))
    }

    @Test func mostUsedBreaksTiesByRecency() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(rootURL: root)
        let older = sampleAsset(hash: "older", name: "Older")
        let newer = sampleAsset(hash: "newer", name: "Newer")
        try await store.install(older)
        try await store.install(newer)
        // Equal apply counts: the more recently applied asset must win.
        try await store.recordApply(id: older.id, at: Date(timeIntervalSince1970: 1_000))
        try await store.recordApply(id: newer.id, at: Date(timeIntervalSince1970: 2_000))
        #expect(await store.assets(sortedBy: .mostUsed).map(\.contentHash) == ["newer", "older"])
    }

    private struct CompactFixture: Codable, Equatable {
        var name: String
        var count: Int
    }

    private func sampleAsset(
        hash: String,
        name: String = "Wallpaper",
        category: WallpaperCategory = .other
    ) -> WallpaperAsset {
        WallpaperAsset(
            name: name,
            mediaURL: URL(fileURLWithPath: "/tmp/wallpaper.mov"),
            duration: 12,
            framesPerSecond: 30,
            pixelSize: CGSize(width: 3_840, height: 2_160),
            contentHash: hash,
            containsAudio: false,
            category: category
        )
    }
}

struct RecentsStoreTests {
    @Test func keepsMostRecentFirstAndCapsAtTen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecentsStore(rootURL: root)
        for _ in 0..<12 {
            try await store.push(WallpaperID())
        }
        let ids = await store.all()
        #expect(ids.count == 10)
        let first = ids[0]
        try await store.push(first)
        #expect(await store.all().first == first)
        #expect(await store.all().count == 10)
    }

    @Test func removeAndClearDropEntries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecentsStore(rootURL: root)
        let a = WallpaperID()
        let b = WallpaperID()
        try await store.push(a)
        try await store.push(b)
        try await store.remove(a)
        #expect(await store.all() == [b])
        try await store.clear()
        #expect(await store.all().isEmpty)

        // Clearing persists: a reopened store stays empty.
        let reopened = try RecentsStore(rootURL: root)
        #expect(await reopened.all().isEmpty)
    }
}
