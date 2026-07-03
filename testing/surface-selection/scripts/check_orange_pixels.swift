import AppKit
import Foundation

struct Result: Codable {
    let image: String
    let width: Int
    let height: Int
    let orangePixels: Int
    let totalPixels: Int
    let orangeRatio: Double
    let minimumOrangeRatio: Double
    let passed: Bool
}

guard CommandLine.arguments.count >= 2 else {
    fputs("usage: swift check_orange_pixels.swift <image.png> [min_ratio] [report.json]\n", stderr)
    exit(2)
}

let imagePath = CommandLine.arguments[1]
let minimumRatio = CommandLine.arguments.count >= 3 ? (Double(CommandLine.arguments[2]) ?? 0.008) : 0.008
let reportPath = CommandLine.arguments.count >= 4 ? CommandLine.arguments[3] : nil

guard let image = NSImage(contentsOfFile: imagePath),
      let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff) else {
    fputs("could not read image: \(imagePath)\n", stderr)
    exit(2)
}

let width = bitmap.pixelsWide
let height = bitmap.pixelsHigh
var orangePixels = 0

for y in 0..<height {
    for x in 0..<width {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
            continue
        }
        let red = color.redComponent
        let green = color.greenComponent
        let blue = color.blueComponent
        let alpha = color.alphaComponent

        if alpha > 0.25,
           red > 0.85,
           green > 0.35,
           green < 0.75,
           blue < 0.45,
           red > green + 0.20,
           green > blue + 0.05 {
            orangePixels += 1
        }
    }
}

let totalPixels = width * height
let ratio = totalPixels > 0 ? Double(orangePixels) / Double(totalPixels) : 0
let passed = ratio >= minimumRatio
let result = Result(
    image: imagePath,
    width: width,
    height: height,
    orangePixels: orangePixels,
    totalPixels: totalPixels,
    orangeRatio: ratio,
    minimumOrangeRatio: minimumRatio,
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

print(String(format: "orangeRatio=%.5f orangePixels=%d totalPixels=%d image=%@", ratio, orangePixels, totalPixels, imagePath))
exit(passed ? 0 : 1)
