import CoreGraphics
import Foundation

/// Encode a decoded video frame as a 24-bit BMP in the layout WallpaperAgent's
/// snapshot cache expects: top-down rows, BGR byte order, 4-byte row padding.
///
/// Kept as a pure function (no I/O, no logging) so the pixel conversion can be
/// exercised and benchmarked without the extension runtime.
func bmpData(from image: CGImage) -> Data? {
    let width = image.width
    let height = image.height
    let bytesPerPixel = 3 // 24bpp BGR
    let rawRowBytes = width * bytesPerPixel
    let paddedRowBytes = (rawRowBytes + 3) & ~3
    let pixelDataSize = paddedRowBytes * height

    let bgraRowBytes = width * 4
    var bgraData = Data(count: bgraRowBytes * height)
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    let rendered = bgraData.withUnsafeMutableBytes { rawBuf -> Bool in
        guard let ctx = CGContext(
            data: rawBuf.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bgraRowBytes,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
        ) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }

    guard rendered else { return nil }

    // Convert BGRA → BGR24 with row padding
    var pixelData = Data(count: pixelDataSize)
    bgraData.withUnsafeBytes { bgra in
        pixelData.withUnsafeMutableBytes { bgr in
            let src = bgra.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let dst = bgr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let si = y * bgraRowBytes + x * 4
                    let di = y * paddedRowBytes + x * 3
                    dst[di] = src[si] // B
                    dst[di + 1] = src[si + 1] // G
                    dst[di + 2] = src[si + 2] // R
                }
            }
        }
    }

    // Build BMP: 14-byte file header + 40-byte BITMAPINFOHEADER + pixel data
    let fileHeaderSize = 14
    let dibHeaderSize = 40
    let headerSize = fileHeaderSize + dibHeaderSize
    let fileSize = headerSize + pixelDataSize

    var bmp = Data(count: headerSize)

    bmp[0] = 0x42; bmp[1] = 0x4D // "BM"
    bmpWriteLE32(&bmp, offset: 2, value: UInt32(fileSize))
    bmpWriteLE32(&bmp, offset: 10, value: UInt32(headerSize))

    let d = fileHeaderSize
    bmpWriteLE32(&bmp, offset: d, value: UInt32(dibHeaderSize))
    bmpWriteLE32(&bmp, offset: d + 4, value: UInt32(bitPattern: Int32(width)))
    bmpWriteLE32(&bmp, offset: d + 8, value: UInt32(bitPattern: Int32(-height))) // top-down
    bmpWriteLE16(&bmp, offset: d + 12, value: 1) // planes
    bmpWriteLE16(&bmp, offset: d + 14, value: 24) // bits per pixel
    bmpWriteLE32(&bmp, offset: d + 16, value: 0) // BI_RGB
    bmpWriteLE32(&bmp, offset: d + 20, value: UInt32(pixelDataSize))

    bmp.append(pixelData)
    return bmp
}

private func bmpWriteLE32(_ data: inout Data, offset: Int, value: UInt32) {
    data[offset] = UInt8(value & 0xFF)
    data[offset + 1] = UInt8((value >> 8) & 0xFF)
    data[offset + 2] = UInt8((value >> 16) & 0xFF)
    data[offset + 3] = UInt8((value >> 24) & 0xFF)
}

private func bmpWriteLE16(_ data: inout Data, offset: Int, value: UInt16) {
    data[offset] = UInt8(value & 0xFF)
    data[offset + 1] = UInt8((value >> 8) & 0xFF)
}
