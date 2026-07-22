#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO

struct TestRun: Decodable {
    let reports: [Report]
}

struct Report: Decodable {
    let file: String
    let events: [Event]
}

struct Event: Decodable {
    let action: String
    let snapshotPath: String?
}

struct Raster {
    let width: Int
    let height: Int
    let pixels: [UInt8]
    let mask: [Bool]

    var foregroundCount: Int {
        mask.reduce(0) { $0 + ($1 ? 1 : 0) }
    }
}

private let supportedExtensions = Set(["glb", "gltf", "obj", "stl", "3mf"])
private let minimumForegroundRatio = 0.02
private let minimumMaskIntersectionOverUnion = 0.985
private let maximumForegroundMeanAbsoluteError = 12.0

private func loadRaster(at path: String) throws -> Raster {
    let url = URL(fileURLWithPath: path) as CFURL
    guard
        let source = CGImageSourceCreateWithURL(url, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        throw NSError(
            domain: "RenderParity",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not decode \(path)"]
        )
    }

    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
        | CGImageAlphaInfo.premultipliedLast.rawValue
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        throw NSError(
            domain: "RenderParity",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Could not create raster context for \(path)"]
        )
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    let cornerOffsets = [
        0,
        (width - 1) * 4,
        (height - 1) * width * 4,
        ((height - 1) * width + width - 1) * 4,
    ]
    let background = (0..<3).map { channel in
        cornerOffsets.map { Int(pixels[$0 + channel]) }.sorted()[cornerOffsets.count / 2]
    }
    let mask = stride(from: 0, to: pixels.count, by: 4).map { offset in
        let difference = (0..<3).reduce(0) { partial, channel in
            partial + abs(Int(pixels[offset + channel]) - background[channel])
        }
        return difference >= 24
    }
    return Raster(width: width, height: height, pixels: pixels, mask: mask)
}

private func compare(_ reference: Raster, _ candidate: Raster) -> (iou: Double, mae: Double) {
    precondition(reference.width == candidate.width && reference.height == candidate.height)
    var intersection = 0
    var union = 0
    var absoluteDifference = 0
    var comparedChannels = 0

    for pixelIndex in reference.mask.indices {
        let referenceVisible = reference.mask[pixelIndex]
        let candidateVisible = candidate.mask[pixelIndex]
        if referenceVisible && candidateVisible { intersection += 1 }
        if referenceVisible || candidateVisible {
            union += 1
            let offset = pixelIndex * 4
            for channel in 0..<3 {
                absoluteDifference += abs(
                    Int(reference.pixels[offset + channel])
                        - Int(candidate.pixels[offset + channel])
                )
                comparedChannels += 1
            }
        }
    }

    let iou = union > 0 ? Double(intersection) / Double(union) : 0
    let mae = comparedChannels > 0
        ? Double(absoluteDifference) / Double(comparedChannels)
        : Double.greatestFiniteMagnitude
    return (iou, mae)
}

guard CommandLine.arguments.count == 2 else {
    fputs("usage: check_render_parity.swift <testing-result.json>\n", stderr)
    exit(2)
}

let resultURL = URL(fileURLWithPath: CommandLine.arguments[1])
let run = try JSONDecoder().decode(TestRun.self, from: Data(contentsOf: resultURL))
var rasters: [(format: String, raster: Raster, path: String)] = []

for report in run.reports {
    let format = URL(fileURLWithPath: report.file).pathExtension.lowercased()
    guard supportedExtensions.contains(format) else { continue }
    guard
        let path = report.events.first(where: { $0.action == "fixed-isometric-camera" })?.snapshotPath
    else {
        fputs("missing fixed-isometric-camera screenshot for \(report.file)\n", stderr)
        exit(1)
    }
    let raster = try loadRaster(at: path)
    let ratio = Double(raster.foregroundCount) / Double(raster.width * raster.height)
    print(String(format: "%@ foreground=%.3f path=%@", format, ratio, path))
    guard ratio >= minimumForegroundRatio else {
        fputs("\(format) render is blank or nearly blank (foreground ratio \(ratio))\n", stderr)
        exit(1)
    }
    rasters.append((format, raster, path))
}

guard rasters.count == supportedExtensions.count else {
    fputs("expected screenshots for \(supportedExtensions.sorted()), got \(rasters.map(\.format).sorted())\n", stderr)
    exit(1)
}

let reference = rasters[0]
var failed = false
for candidate in rasters.dropFirst() {
    guard
        reference.raster.width == candidate.raster.width,
        reference.raster.height == candidate.raster.height
    else {
        fputs("dimension mismatch: \(reference.format) vs \(candidate.format)\n", stderr)
        failed = true
        continue
    }
    let metrics = compare(reference.raster, candidate.raster)
    print(String(format: "%@ vs %@ maskIoU=%.5f foregroundMAE=%.3f", reference.format, candidate.format, metrics.iou, metrics.mae))
    if metrics.iou < minimumMaskIntersectionOverUnion {
        fputs("silhouette mismatch: \(reference.format) vs \(candidate.format)\n", stderr)
        failed = true
    }
    if metrics.mae > maximumForegroundMeanAbsoluteError {
        fputs("shading/material mismatch: \(reference.format) vs \(candidate.format)\n", stderr)
        failed = true
    }
}

if failed { exit(1) }
print("render parity passed")
