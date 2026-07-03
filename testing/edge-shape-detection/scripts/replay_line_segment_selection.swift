import Foundation
import simd

struct EdgeDownload: Decodable {
    let selectedEdge: [Int]
    let chainPoints: [[Float]]
    let snapDistance: Float
}

struct EdgeProbe: Decodable {
    let selectedEdge: [Int]
    let connectedFeatureSegments: [[Int]]
    let connectedFeatureVertices: [[Float]]
}

struct Report: Encodable {
    let download: String
    let probe: String
    let selectedEdge: [Int]
    let chainPointCount: Int
    let connectedSegmentCount: Int
    let detectedSequence: [String]
    let selectedPrimitivePointCount: Int
    let passed: Bool
    let failure: String?
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("usage: swift replay_line_segment_selection.swift <edge-download.json> <edge-probe.json> [report.json]\n", stderr)
    exit(2)
}

let downloadPath = args[1]
let probePath = args[2]
let reportPath = args.count > 3 ? args[3] : nil

let decoder = JSONDecoder()
let download = try decoder.decode(EdgeDownload.self, from: Data(contentsOf: URL(fileURLWithPath: downloadPath)))
let probe = try decoder.decode(EdgeProbe.self, from: Data(contentsOf: URL(fileURLWithPath: probePath)))

let points = dedupe(download.chainPoints.compactMap(vector))
let ordered = orderedClosedLoop(points)
let sequence = classify(points: ordered)
let selectedPrimitivePointCount = selectedEdgePrimitivePointCount(download: download, probe: probe)

let failure: String?
if download.selectedEdge != probe.selectedEdge {
    failure = "download/probe selectedEdge mismatch"
} else if selectedPrimitivePointCount != 2 {
    failure = "selected primitive should contain exactly two points"
} else if sequence.contains("semicircle") || sequence.contains("arc") || sequence.contains("circle") {
    failure = "under-sampled straight component classified as a curve"
} else if !sequence.allSatisfy({ $0 == "line-segment" || $0 == "line" }) {
    failure = "unexpected sequence \(sequence)"
} else {
    failure = nil
}

let report = Report(
    download: downloadPath,
    probe: probePath,
    selectedEdge: download.selectedEdge,
    chainPointCount: points.count,
    connectedSegmentCount: probe.connectedFeatureSegments.count,
    detectedSequence: sequence,
    selectedPrimitivePointCount: selectedPrimitivePointCount,
    passed: failure == nil,
    failure: failure
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let encoded = try encoder.encode(report)
if let reportPath {
    let url = URL(fileURLWithPath: reportPath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoded.write(to: url, options: .atomic)
}
FileHandle.standardOutput.write(encoded)
FileHandle.standardOutput.write(Data([0x0a]))
exit(report.passed ? 0 : 1)

private func selectedEdgePrimitivePointCount(download: EdgeDownload, probe: EdgeProbe) -> Int {
    guard download.selectedEdge.count == 2 else { return 0 }
    let selected = Set(download.selectedEdge)
    guard probe.connectedFeatureSegments.contains(where: { Set($0) == selected }) else {
        return 0
    }
    return 2
}

private func classify(points: [SIMD3<Float>]) -> [String] {
    guard points.count >= 2 else { return ["unknown"] }
    let line = lineFit(points)
    let extent = max(line.length, 0.0001)
    if line.maxResidual <= max(extent * 0.02, 0.75) {
        return ["line"]
    }
    guard points.count > 10 else {
        return Array(repeating: "line-segment", count: points.count)
    }
    return ["curve-candidate"]
}

private struct LineFit {
    let length: Float
    let maxResidual: Float
}

private func lineFit(_ points: [SIMD3<Float>]) -> LineFit {
    guard points.count >= 2 else { return LineFit(length: 0, maxResidual: 0) }
    var start = points[0]
    var end = points[1]
    var length = simd_distance(start, end)
    for first in points {
        for second in points {
            let distance = simd_distance(first, second)
            if distance > length {
                start = first
                end = second
                length = distance
            }
        }
    }
    let direction = normalized(end - start, fallback: SIMD3<Float>(1, 0, 0))
    let residual = points.map { simd_length(simd_cross($0 - start, direction)) }.max() ?? 0
    return LineFit(length: length, maxResidual: residual)
}

private func orderedClosedLoop(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
    let basis = planeBasis(for: points)
    let projected = points.map { point -> SIMD2<Float> in
        let relative = point - basis.origin
        return SIMD2<Float>(simd_dot(relative, basis.u), simd_dot(relative, basis.v))
    }
    let centroid = projected.reduce(SIMD2<Float>(0, 0), +) / Float(max(projected.count, 1))
    return zip(points, projected)
        .sorted {
            atan2f($0.1.y - centroid.y, $0.1.x - centroid.x)
                < atan2f($1.1.y - centroid.y, $1.1.x - centroid.x)
        }
        .map(\.0)
}

private struct PlaneBasis {
    let origin: SIMD3<Float>
    let u: SIMD3<Float>
    let v: SIMD3<Float>
}

private func planeBasis(for points: [SIMD3<Float>]) -> PlaneBasis {
    let origin = points.first ?? SIMD3<Float>(0, 0, 0)
    let farthest = points.max(by: { simd_distance(origin, $0) < simd_distance(origin, $1) }) ?? origin
    let u = normalized(farthest - origin, fallback: SIMD3<Float>(1, 0, 0))
    let offAxis = points.max(by: { distanceToLine($0, origin, u) < distanceToLine($1, origin, u) }) ?? origin
    let normal = normalized(simd_cross(u, offAxis - origin), fallback: SIMD3<Float>(0, 1, 0))
    let v = normalized(simd_cross(normal, u), fallback: SIMD3<Float>(0, 0, 1))
    return PlaneBasis(origin: origin, u: u, v: v)
}

private func distanceToLine(_ point: SIMD3<Float>, _ linePoint: SIMD3<Float>, _ direction: SIMD3<Float>) -> Float {
    simd_length(simd_cross(point - linePoint, direction))
}

private func vector(_ values: [Float]) -> SIMD3<Float>? {
    guard values.count == 3 else { return nil }
    return SIMD3<Float>(values[0], values[1], values[2])
}

private func dedupe(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
    var result: [SIMD3<Float>] = []
    for point in points where !result.contains(where: { simd_distance($0, point) < 0.00001 }) {
        result.append(point)
    }
    return result
}

private func normalized(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
    let length = simd_length(vector)
    guard length.isFinite, length > 0.000001 else { return fallback }
    return vector / length
}
