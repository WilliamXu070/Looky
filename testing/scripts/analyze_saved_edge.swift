import Foundation
import simd

struct SavedEdgeRecord: Decodable {
    let chainKind: String
    let chainPoints: [[Float]]
    let selectedEdge: [Int]
    let snappedWorldPoint: [Float]?
    let hitWorldPoint: [Float]?
    let snapDistance: Float?
}

struct EdgeAnalysisReport: Encodable {
    let file: String
    let chainKind: String
    let selectedEdge: [Int]
    let pointCount: Int
    let currentOrderLength: Float
    let nearestNeighborLength: Float
    let currentStepStats: StepStats
    let nearestNeighborStepStats: StepStats
    let currentOrderCircleResidual: Float
    let nearestNeighborCircleResidual: Float
    let currentOrderSweepDegrees: Float
    let nearestNeighborSweepDegrees: Float
    let likelySemicircleInCurrentOrder: Bool
    let likelySemicircleAfterReorder: Bool
    let conclusion: String
}

struct StepStats: Encodable {
    let min: Float
    let median: Float
    let max: Float
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("usage: swift testing/scripts/analyze_saved_edge.swift <edge-download.json>\n", stderr)
    exit(2)
}

let path = args[1]
let data = try Data(contentsOf: URL(fileURLWithPath: path))
let decoded = try JSONDecoder().decode(SavedEdgeRecord.self, from: data)
let points = decoded.chainPoints.map { SIMD3<Float>($0[0], $0[1], $0[2]) }

guard points.count >= 3 else {
    fputs("not enough points\n", stderr)
    exit(1)
}

let currentLengths = segmentLengths(points)
let currentLength = currentLengths.reduce(0, +)
let reordered = greedyNearestNeighborOrder(points)
let reorderedLengths = segmentLengths(reordered)
let reorderedLength = reorderedLengths.reduce(0, +)

let currentCircle = circleFitReport(points)
let reorderedCircle = circleFitReport(reordered)

let currentSemicircle = isLikelySemicircle(circle: currentCircle, pointCount: points.count)
let reorderedSemicircle = isLikelySemicircle(circle: reorderedCircle, pointCount: reordered.count)

let conclusion: String
if currentSemicircle {
    conclusion = "current-order already looks like a whole semicircle"
} else if reorderedSemicircle {
    conclusion = "current-order chain is not semicircle-ready; simple geometric reordering recovers one semicircle-like curve"
} else {
    conclusion = "current-order chain does not behave like one whole semicircle, and even nearest-neighbor reordering does not cleanly recover it"
}

let report = EdgeAnalysisReport(
    file: path,
    chainKind: decoded.chainKind,
    selectedEdge: decoded.selectedEdge,
    pointCount: points.count,
    currentOrderLength: currentLength,
    nearestNeighborLength: reorderedLength,
    currentStepStats: stats(currentLengths),
    nearestNeighborStepStats: stats(reorderedLengths),
    currentOrderCircleResidual: currentCircle.maxResidual,
    nearestNeighborCircleResidual: reorderedCircle.maxResidual,
    currentOrderSweepDegrees: currentCircle.sweepDegrees,
    nearestNeighborSweepDegrees: reorderedCircle.sweepDegrees,
    likelySemicircleInCurrentOrder: currentSemicircle,
    likelySemicircleAfterReorder: reorderedSemicircle,
    conclusion: conclusion
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let output = try encoder.encode(report)
FileHandle.standardOutput.write(output)
FileHandle.standardOutput.write(Data([0x0a]))

struct CircleFitReport {
    let radius: Float
    let maxResidual: Float
    let meanResidual: Float
    let sweepDegrees: Float
    let planarResidual: Float
}

private func segmentLengths(_ points: [SIMD3<Float>]) -> [Float] {
    zip(points, points.dropFirst()).map(simd_distance)
}

private func stats(_ values: [Float]) -> StepStats {
    let sorted = values.sorted()
    guard let first = sorted.first, let last = sorted.last else {
        return StepStats(min: 0, median: 0, max: 0)
    }
    let median = sorted[sorted.count / 2]
    return StepStats(min: first, median: median, max: last)
}

private func greedyNearestNeighborOrder(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
    guard !points.isEmpty else { return [] }
    var remaining = Array(points.indices.dropFirst())
    var ordered = [points[0]]
    var current = points[0]

    while !remaining.isEmpty {
        var bestOffset = 0
        var bestDistance = Float.greatestFiniteMagnitude
        for (offset, idx) in remaining.enumerated() {
            let d = simd_distance(current, points[idx])
            if d < bestDistance {
                bestDistance = d
                bestOffset = offset
            }
        }
        let nextIndex = remaining.remove(at: bestOffset)
        let next = points[nextIndex]
        ordered.append(next)
        current = next
    }

    return ordered
}

private func circleFitReport(_ points: [SIMD3<Float>]) -> CircleFitReport {
    let origin = points[0]
    let xAxis = normalized(points.last! - origin)
    let tentative = normalized(points[points.count / 2] - origin)
    let normal = normalized(simd_cross(xAxis, tentative))
    let yAxis = normalized(simd_cross(normal, xAxis))

    let projected: [SIMD2<Float>] = points.map { point in
        let rel = point - origin
        return SIMD2<Float>(simd_dot(rel, xAxis), simd_dot(rel, yAxis))
    }

    let planarResidual = points.map { abs(simd_dot($0 - origin, normal)) }.max() ?? 0
    let circle = kasaCircle(projected)
    let residuals = projected.map { abs(simd_distance($0, circle.center) - circle.radius) }
    let maxResidual = residuals.max() ?? 0
    let meanResidual = residuals.reduce(0, +) / Float(max(residuals.count, 1))
    let sweep = arcSweepDegrees(projected: projected, center: circle.center)

    return CircleFitReport(
        radius: circle.radius,
        maxResidual: maxResidual,
        meanResidual: meanResidual,
        sweepDegrees: sweep,
        planarResidual: planarResidual
    )
}

private func kasaCircle(_ points: [SIMD2<Float>]) -> (center: SIMD2<Float>, radius: Float) {
    var ata = simd_float3x3()
    var atb = SIMD3<Float>(repeating: 0)

    for p in points {
        let row = SIMD3<Float>(2 * p.x, 2 * p.y, 1)
        ata += simd_float3x3(
            SIMD3<Float>(row.x * row.x, row.x * row.y, row.x * row.z),
            SIMD3<Float>(row.y * row.x, row.y * row.y, row.y * row.z),
            SIMD3<Float>(row.z * row.x, row.z * row.y, row.z * row.z)
        )
        atb += row * (p.x * p.x + p.y * p.y)
    }

    let solution = ata.inverse * atb
    let center = SIMD2<Float>(solution.x, solution.y)
    let radius = sqrt(max(0.0001, solution.z + simd_dot(center, center)))
    return (center, radius)
}

private func arcSweepDegrees(projected: [SIMD2<Float>], center: SIMD2<Float>) -> Float {
    let angles = projected.map { atan2f($0.y - center.y, $0.x - center.x) }
    guard let first = angles.first else { return 0 }
    var unwrapped = [first]
    for angle in angles.dropFirst() {
        var candidate = angle
        var delta = candidate - unwrapped.last!
        while delta > .pi { candidate -= 2 * .pi; delta = candidate - unwrapped.last! }
        while delta < -.pi { candidate += 2 * .pi; delta = candidate - unwrapped.last! }
        unwrapped.append(candidate)
    }
    let sweep = (unwrapped.max() ?? first) - (unwrapped.min() ?? first)
    return abs(sweep * 180 / .pi)
}

private func isLikelySemicircle(circle: CircleFitReport, pointCount: Int) -> Bool {
    pointCount >= 8 &&
    circle.planarResidual <= 0.5 &&
    circle.maxResidual <= 3.0 &&
    circle.sweepDegrees >= 140 &&
    circle.sweepDegrees <= 220
}

private func normalized(_ vector: SIMD3<Float>) -> SIMD3<Float> {
    let len = simd_length(vector)
    if len <= 0.000001 { return SIMD3<Float>(0, 1, 0) }
    return vector / len
}
