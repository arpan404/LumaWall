import AppKit
import Foundation
import ImageIO

// Cold poster load benchmark: one 4K JPEG, cache cleared between iterations.
// Prints the decoded pixel dimensions so before/after memory footprint is visible.

let posterURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("lumawall-bench-poster.jpg")

if !FileManager.default.fileExists(atPath: posterURL.path) {
    let width = 3840
    let height = 2160
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let colors = [
        CGColor(red: 0.05, green: 0.15, blue: 0.25, alpha: 1),
        CGColor(red: 0.20, green: 0.55, blue: 0.45, alpha: 1),
        CGColor(red: 0.75, green: 0.55, blue: 0.20, alpha: 1),
    ]
    for (index, color) in colors.enumerated() {
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: index * height / 3, width: width, height: height / 3 + 1))
    }
    let image = context.makeImage()!
    let destination = CGImageDestinationCreateWithURL(
        posterURL as CFURL, "public.jpeg" as CFString, 1, nil
    )!
    CGImageDestinationAddImage(destination, image, [
        kCGImageDestinationLossyCompressionQuality: 0.9,
    ] as CFDictionary)
    CGImageDestinationFinalize(destination)
}

func forceDraw(_ image: NSImage) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    let context = CGContext(
        data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    image.draw(
        in: CGRect(x: 0, y: 0, width: 320, height: 180),
        from: .zero,
        operation: .copy,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

var loadSamples: [Double] = []
var drawSamples: [Double] = []
var pixelsWide = 0
var pixelsHigh = 0
for _ in 0 ..< 10 {
    await PosterCache.shared.removeAll()
    let start = DispatchTime.now().uptimeNanoseconds
    let image = await PosterCache.shared.image(for: posterURL)
    loadSamples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    if let image {
        drawSamples.append(forceDraw(image))
        if let rep = image.representations.first {
            pixelsWide = rep.pixelsWide
            pixelsHigh = rep.pixelsHigh
        }
    }
}
loadSamples.sort()
drawSamples.sort()

let result: [String: Any] = [
    "name": "poster.coldLoad",
    "unit": "ms",
    "coldMS": loadSamples[loadSamples.count / 2],
    "warmMS": drawSamples.isEmpty ? 0 : drawSamples[drawSamples.count / 2],
    "pixelsWide": pixelsWide,
    "pixelsHigh": pixelsHigh,
    "note": "4K JPEG; coldMS=load, warmMS=first draw (decode)",
]
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
if let index = CommandLine.arguments.firstIndex(of: "--json"), index + 1 < CommandLine.arguments.count {
    try data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
}
print(String(decoding: data, as: UTF8.self))
