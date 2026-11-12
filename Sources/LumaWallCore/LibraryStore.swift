import Foundation

public actor LibraryStore {
    public enum StoreError: LocalizedError, Equatable {
        case duplicate(WallpaperAsset)
        case missingAsset
        case invalidLocation

        public var errorDescription: String? {
            switch self {
            case let .duplicate(asset): "This video is already installed as \"\(asset.name)\"."
            case .missingAsset: "The wallpaper is no longer installed."
            case .invalidLocation: "The wallpaper points outside the library and was not deleted from disk."
            }
        }
    }

    public let rootURL: URL
    private let indexURL: URL
    private var assetsByID: [WallpaperID: WallpaperAsset] = [:]
    /// Last measured total and when it was taken. The stats label asks every
    /// few seconds, and walking every asset folder for each tick dominated the
    /// UI's background work. Store mutations invalidate it, and the TTL picks
    /// up files written outside the store (the 720p battery sibling lives in
    /// the asset folder, so a pure mutation hook would miss it).
    private var cachedDiskUsage: (bytes: Int64, at: Date)?
    private static let diskUsageTTL: TimeInterval = 5 * 60

    public init(rootURL: URL? = nil) throws {
        let base = try StorePaths.appSupportBase(rootURL: rootURL)
        self.rootURL = base
        self.indexURL = base.appendingPathComponent("Library.json")
        if let decoded: [WallpaperAsset] = StoreIO.readJSON(from: indexURL, as: [WallpaperAsset].self) {
            assetsByID = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
        }
    }

    public func assets(sortedBy sort: LibrarySort = .newest) -> [WallpaperAsset] {
        let values = Array(assetsByID.values)
        switch sort {
        case .newest:
            return values.sorted { $0.createdAt > $1.createdAt }
        case .oldest:
            return values.sorted { $0.createdAt < $1.createdAt }
        case .name:
            return values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .resolution:
            return values.sorted {
                ($0.pixelSize.width * $0.pixelSize.height) > ($1.pixelSize.width * $1.pixelSize.height)
            }
        case .mostUsed:
            return values.sorted {
                if $0.applyCount == $1.applyCount {
                    return ($0.lastAppliedAt ?? .distantPast) > ($1.lastAppliedAt ?? .distantPast)
                }
                return $0.applyCount > $1.applyCount
            }
        }
    }

    public func asset(id: WallpaperID) -> WallpaperAsset? { assetsByID[id] }

    public func asset(contentHash: String) -> WallpaperAsset? {
        assetsByID.values.first { $0.contentHash == contentHash }
    }

    public func install(_ asset: WallpaperAsset) throws {
        if let duplicate = assetsByID.values.first(where: { $0.contentHash == asset.contentHash }) {
            throw StoreError.duplicate(duplicate)
        }
        assetsByID[asset.id] = asset
        try persist()
        // The asset's media folder was written before install, so the cached
        // total predates it.
        invalidateDiskUsageCache()
    }

    public func update(_ asset: WallpaperAsset) throws {
        guard assetsByID[asset.id] != nil else { throw StoreError.missingAsset }
        assetsByID[asset.id] = asset
        try persist()
    }

    public func rename(id: WallpaperID, to name: String) throws {
        guard var asset = assetsByID[id] else { throw StoreError.missingAsset }
        asset.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        assetsByID[id] = asset
        try persist()
    }

    public func setCategory(id: WallpaperID, category: WallpaperCategory) throws {
        guard var asset = assetsByID[id] else { throw StoreError.missingAsset }
        asset.category = category
        assetsByID[id] = asset
        try persist()
    }

    public func recordApply(id: WallpaperID, at date: Date = .now) throws {
        guard var asset = assetsByID[id] else { throw StoreError.missingAsset }
        asset.applyCount += 1
        asset.lastAppliedAt = date
        assetsByID[id] = asset
        try persist()
    }

    public func remove(id: WallpaperID) throws {
        guard let asset = assetsByID.removeValue(forKey: id) else { throw StoreError.missingAsset }
        try persist()
        // The media folder must be exactly this entry's own folder. A corrupt
        // or hand-edited Library.json could otherwise point mediaURL at an
        // arbitrary directory (or a sibling entry's folder) and this delete
        // would wipe it. The index entry is already gone; refuse the disk
        // delete loudly instead of silently honoring a bad path.
        let folder = asset.mediaURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let expected = self.folder(for: id).resolvingSymlinksInPath()
        guard folder == expected else {
            throw StoreError.invalidLocation
        }
        try? FileManager.default.removeItem(at: folder)
        invalidateDiskUsageCache()
    }

    public func folder(for id: WallpaperID) -> URL {
        rootURL.appendingPathComponent(id.rawValue.uuidString, isDirectory: true)
    }

    public func diskUsageBytes() -> Int64 {
        let now = Date()
        if let cachedDiskUsage,
           now.timeIntervalSince(cachedDiskUsage.at) < Self.diskUsageTTL {
            return cachedDiskUsage.bytes
        }
        let urls = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let url = urls?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        cachedDiskUsage = (total, now)
        return total
    }

    /// Drops the cached total after media changes made outside this store's own
    /// mutations, such as an import folder that was created and then removed.
    func invalidateDiskUsageCache() {
        cachedDiskUsage = nil
    }

    private func persist() throws {
        let values = assetsByID.values.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
        try StoreIO.writeJSON(values, to: indexURL)
    }
}
