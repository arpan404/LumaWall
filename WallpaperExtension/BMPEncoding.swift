import Accelerate
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
    guard width > 0, height > 0 else { return nil }

    let bytesPerPixel = 3 // 24bpp BGR
    let (rawRowBytes, rowOverflow) = width.multipliedReportingOverflow(by: bytesPerPixel)
    let (bgraRowBytes, bgraRowOverflow) = width.multipliedReportingOverflow(by: 4)
    guard !rowOverflow, !bgraRowOverflow else { return nil }

    let paddedRowBytes = (rawRowBytes + 3) & ~3
    let (pixelDataSize, pixelOverflow) = paddedRowBytes.multipliedReportingOverflow(by: height)
    let (bgraDataSize, bgraSizeOverflow) = bgraRowBytes.multipliedReportingOverflow(by: height)
    guard !pixelOverflow, !bgraSizeOverflow else { return nil }

    var bgraData = Data(count: bgraDataSize)
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

    // Build BMP: 14-byte file header + 40-byte BITMAPINFOHEADER + pixel data.
    // The destination Data is zeroed, so row padding and any bytes vImage does
    // not touch stay zero as the BMP format expects.
    let fileHeaderSize = 14
    let dibHeaderSize = 40
    let headerSize = fileHeaderSize + dibHeaderSize
    let fileSize = headerSize + pixelDataSize

    var bmp = Data(count: fileSize)

    // The CGContext uses premultipliedFirst + little-endian, whose memory layout
    // is BGRA. vImage's RGBA8888 -> RGB888 conversion copies the first three
    // bytes of each pixel in order, so feeding it the BGRA buffer emits BGR —
    // exactly the byte order this BMP needs — and drops alpha in one pass.
    let converted = bgraData.withUnsafeBytes { srcRaw -> Bool in
        bmp.withUnsafeMutableBytes { dstRaw -> Bool in
            guard let srcBase = srcRaw.baseAddress,
                  let dstBase = dstRaw.baseAddress else { return false }

            let dstPixelBase = dstBase.advanced(by: headerSize)
            var srcBuffer = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: srcBase),
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: bgraRowBytes,
            )
            var dstBuffer = vImage_Buffer(
                data: dstPixelBase,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: paddedRowBytes,
            )

            let error = vImageConvert_RGBA8888toRGB888(
                &srcBuffer, &dstBuffer, vImage_Flags(kvImageNoFlags),
            )
            if error == kvImageNoError { return true }

            // Fallback for any vImage failure: the scalar BGRA -> BGR loop.
            let src = srcBase.assumingMemoryBound(to: UInt8.self)
            let dst = dstPixelBase.assumingMemoryBound(to: UInt8.self)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let si = y * bgraRowBytes + x * 4
                    let di = y * paddedRowBytes + x * 3
                    dst[di] = src[si] // B
                    dst[di + 1] = src[si + 1] // G
                    dst[di + 2] = src[si + 2] // R
                }
            }
            return true
        }
    }

    guard converted else { return nil }

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
