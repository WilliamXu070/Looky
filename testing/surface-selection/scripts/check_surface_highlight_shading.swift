import AppKit
import Foundation

struct SurfaceHighlightShadingResult: Codable {
    let image: String
    let width: Int
    let height: Int
    let highlightPixels: Int
    let highlightRatio: Double
    let luminanceP10: Double
    let luminanceP90: Double
    let luminanceRange: Double
    let minimumHighlightRatio: Double
    let minimumLuminanceRange: Double
    let passed: Bool
}

guard CommandLine.arguments.count >= 2 else {
    fputs(
        "usage: swift check_surface_highlight_shading.swift <image.png> [min_ratio] [min_luma_range] [report.json]\n",
        stderr
    )
    exit(2)
}

let imagePath = CommandLine.arguments[1]
let minimumRatio = CommandLine.arguments.count >= 3
    ? (Double(CommandLine.arguments[2]) ?? 0.015)
    : 0.015
let minimumLuminanceRange = CommandLine.arguments.count >= 4
    ? (Double(CommandLine.arguments[3]) ?? 0.025)
    : 0.025
let reportPath = CommandLine.arguments.count >= 5 ? CommandLine.arguments[4] : nil

guard let image = NSImage(contentsOfFile: imagePath),
      let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff) else {
    fputs("could not read image: \(imagePath)\n", stderr)
    exit(2)
}

var luminances: [Double] = []
luminances.reserveCapacity(bitmap.pixelsWide * bitmap.pixelsHigh / 20)

for y in 0..<bitmap.pixelsHigh {
    for x in 0..<bitmap.pixelsWide {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
            continue
        }
        let red = color.redComponent
        let green = color.greenComponent
        let blue = color.blueComponent
        guard color.alphaComponent > 0.25,
              red > 0.55,
              green > 0.08,
              blue < 0.50,
              red > green + 0.18,
              green > blue + 0.03 else {
            continue
        }
        luminances.append(Double(0.2126 * red + 0.7152 * green + 0.0722 * blue))
    }
}

luminances.sort()
func percentile(_ fraction: Double) -> Double {
    guard !luminances.isEmpty else { return 0 }
    let index = min(
        max(Int((Double(luminances.count - 1) * fraction).rounded()), 0),
        luminances.count - 1
    )
    return luminances[index]
}

let totalPixels = bitmap.pixelsWide * bitmap.pixelsHigh
let ratio = totalPixels > 0 ? Double(luminances.count) / Double(totalPixels) : 0
let p10 = percentile(0.10)
let p90 = percentile(0.90)
let range = p90 - p10
let passed = ratio >= minimumRatio && range >= minimumLuminanceRange
let result = SurfaceHighlightShadingResult(
    image: imagePath,
    width: bitmap.pixelsWide,
    height: bitmap.pixelsHigh,
    highlightPixels: luminances.count,
    highlightRatio: ratio,
    luminanceP10: p10,
    luminanceP90: p90,
    luminanceRange: range,
    minimumHighlightRatio: minimumRatio,
    minimumLuminanceRange: minimumLuminanceRange,
    passed: passed
)

if let reportPath {
    let outputURL = URL(fileURLWithPath: reportPath)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(result).write(to: outputURL, options: .atomic)
}

print(
    String(
        format: "highlightRatio=%.5f luminanceRange=%.5f p10=%.5f p90=%.5f image=%@",
        ratio,
        range,
        p10,
        p90,
        imagePath
    )
)
exit(passed ? 0 : 1)
