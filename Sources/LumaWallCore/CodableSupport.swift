import Foundation

extension JSONEncoder {
    static var lumaWall: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Persistence encoder: ISO-8601 dates for compatibility with existing
    /// files, no whitespace. The energy log appends a sample every minute, so
    /// pretty-printing it rewrote hundreds of kilobytes of indentation each
    /// time without adding any value to a machine-read file.
    static var lumaWallCompact: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = []
        return encoder
    }
}

extension JSONDecoder {
    static var lumaWall: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Shared persistence helpers for the JSON file stores.
///
/// Every store resolves the same base directory and writes atomically with
/// file protection; centralizing it here (instead of copy-pasting per actor)
/// keeps those guarantees from drifting. Reads quarantine undecodable files
/// instead of silently resetting them: previously a corrupt file loaded
/// defaults into memory and the next persist overwrote the evidence.
public enum StorePaths {
    public static func appSupportBase(rootURL: URL? = nil) throws -> URL {
        let base = rootURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("LumaWall", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}

public enum StoreIO {
    public static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder.lumaWallCompact.encode(value)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    /// Best-effort variant for contexts that must not throw (crash-time saves).
    @discardableResult
    public static func tryWriteJSON<T: Encodable>(_ value: T, to url: URL) -> Bool {
        (try? writeJSON(value, to: url)) != nil
    }

    /// Loads and decodes `type`, returning nil when the file is missing (normal
    /// first launch). When bytes exist but decoding fails, the file is moved
    /// aside as `<name>.corrupt-<epoch>` before returning nil, so a later
    /// persist cannot destroy the evidence.
    public static func readJSON<T: Decodable>(from url: URL, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let decoded = try? JSONDecoder.lumaWall.decode(type, from: data) {
            return decoded
        }
        quarantineCorruptFile(at: url)
        return nil
    }

    private static func quarantineCorruptFile(at url: URL) {
        let backup = url.deletingLastPathComponent().appendingPathComponent(
            "\(url.lastPathComponent).corrupt-\(Int(Date.now.timeIntervalSince1970))"
        )
        try? FileManager.default.moveItem(at: url, to: backup)
    }
}
