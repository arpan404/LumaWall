import AppKit
import Foundation
import ImageIO
import SwiftUI

/// In-memory poster thumbnail cache.
///
/// SwiftUI `body` must never do disk IO + image decode (`NSImage(contentsOf:)`
/// blocks the main thread per tile, per stats tick). This actor memoizes
/// downsampled posters in an `NSCache` (thread-safe, system-evictable) so
/// repeated `body` evaluations hit memory without holding 4K bitmaps for
/// 224-point tiles.
actor PosterCache {
    static let shared = PosterCache()

    /// Longest decoded edge for cached posters. Tiles are ~448 px wide on a
    /// 2x display, so 720 leaves headroom without the 4K decode.
    static let thumbnailMaxPixel = 720

    private let cache = NSCache<NSURL, NSImage>()

    init() {
        cache.countLimit = 200
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    /// Cached poster image, or nil when `url` is nil/unreadable.
    func image(for url: URL?) -> NSImage? {
        guard let url else { return nil }
        let key = url as NSURL
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = Self.thumbnailImage(for: url, maxPixel: Self.thumbnailMaxPixel) else { return nil }
        cache.setObject(image, forKey: key, cost: Self.pixelCost(of: image))
        return image
    }

    func remove(_ url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    /// Downsample straight from ImageIO so a 4K file never materializes as a
    /// full-size `NSImage`. Static and synchronous so the wallpaper overlay
    /// (an AppKit layer tree) can reuse it without an actor hop.
    nonisolated static func thumbnailImage(for url: URL, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        // NSBitmapImageRep keeps the decoded pixel dimensions exact;
        // NSImage(cgImage:size:) reports a backing-scale multiplied size.
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = NSSize(width: cgImage.width, height: cgImage.height)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    private nonisolated static func pixelCost(of image: NSImage) -> Int {
        image.representations.reduce(0) { total, rep in
            total + max(rep.pixelsWide, 0) * max(rep.pixelsHigh, 0) * 4
        }
    }
}

/// Async poster image that never blocks `body` on disk IO.
///
/// Loads via `PosterCache` in `.task(id:)` so URL changes cancel prior loads
/// and view reuse can't show a stale poster's image.
struct PosterImage: View {
    let url: URL?
    var contentMode: SwiftUI.ContentMode = .fill

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Theme.panelStrong
            }
        }
        .task(id: url) {
            if let url {
                image = await PosterCache.shared.image(for: url)
            } else {
                image = nil
            }
        }
    }
}
