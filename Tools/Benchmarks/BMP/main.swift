import CoreGraphics
import Foundation

// BMP snapshot encoder benchmark. Uses a deterministic 4K image so the
// checksum can be compared across the before/after runs: the optimized encoder
// must produce byte-identical output.

func makeFrame(width: Int, height: Int) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )!
    for index in 0 ..< 24 {
        context.setFillColor(CGColor(
            red: CGFloat(index % 5) / 5,
            green: CGFloat(index % 7) / 7,
            blue: CGFloat(index % 11) / 11,
            alpha: 1
        ))
        context.fill(CGRect(
            x: 0,
            y: index * height / 24,
            width: width,
            height: height / 24 + 1
        ))
    }
    return context.makeImage()!
}

let image = makeFrame(width: 3840, height: 2160)
var samples: [Double] = []
samples.reserveCapacity(5)
var encodedBytes = 0
var checksum: UInt64 = 0xCBF2_9CE4_8422_2325
for _ in 0 ..< 5 {
    let start = DispatchTime.now().uptimeNanoseconds
    let data = bmpData(from: image)
    samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    encodedBytes = data?.count ?? 0
    checksum = 0xCBF2_9CE4_8422_2325
    if let data {
        for byte in data {
            checksum = (checksum ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
    }
}
samples.sort()

let result: [String: Any] = [
    "name": "bmp.encode4K",
    "unit": "ms",
    "warmMS": samples[samples.count / 2],
    "bytes": encodedBytes,
    "checksum": String(format: "%016llx", checksum),
    "note": "3840x2160 BGR24 + header",
]
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
if let index = CommandLine.arguments.firstIndex(of: "--json"), index + 1 < CommandLine.arguments.count {
    try data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
}
print(String(decoding: data, as: UTF8.self))
