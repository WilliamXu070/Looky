import Foundation
import simd

enum ShapeKind: String, Codable {
    case line
    case semicircle
    case arc
    case circle
    case fragmented
    case unknown
}

struct ExpectationFile: Decodable {
    let cases: [ShapeExpectation]
}

struct ShapeExpectation: Decodable {
    let name: String
    let source: String
    let expectedShape: ShapeKind
    let expectedRawOrderShape: ShapeKind?
    let notes: String?
}

struct SavedEdgeRecord: Decodable {
    let chainKind: String
    let chainPoints: [[Float]]
    let selectedEdge: [Int]
    let snappedWorldPoint: [Float]?
    let hitWorldPoint: [Float]?
    let snapDistance: Float?
    let isExactEdge: Bool?
}

struct ShapeRunReport: Encodable {
    let startedAt: String
    let passCount: Int
    let failCount: Int
    let cases: [ShapeCaseReport]
}

struct ShapeCaseReport: Encodable {
    let name: String
    let source: String
    let expectedShape: ShapeKind?
    let expectedRawOrderShape: ShapeKind?
    let detectedShape: ShapeKind
    let rawOrderShape: ShapeKind
    let passed: Bool
    let failureBucket: String?
    let metrics: ShapeMetrics
    let notes: String?
}

struct ShapeMetrics: Encodable {
    let pointCount: Int
    let chainKind: String
    let selectedEdge: [Int]
    let rawPolylineLength: Float
    let orderedPolylineLength: Float
    let rawOrderSweepDegrees: Float
    let angularCoverageDegrees: Float
    let circleRadius: Float
    let circleMeanResidual: Float
    let circleMaxResidual: Float
    let lineLength: Float
    let lineMeanResidual: Float
    let lineMaxResidual: Float
    let stepMedian: Float
    let stepMax: Float
}

private struct CircleFit {
    let center: SIMD2<Float>
    let radius: Float
    let meanResidual: Float
    let maxResidual: Float
    let angularCoverageDegrees: Float
}

private struct LineFit {
    let length: Float
    let meanResidual: Float
    let maxResidual: Float
}

private struct PlaneBasis {
    let origin: SIMD3<Float>
    let u: SIMD3<Float>
    let v: SIMD3<Float>
    let normal: SIMD3<Float>
}

let parsed = parseArguments(CommandLine.arguments)
let expectations: [ShapeExpectation]

if let expectationsPath = parsed.expectationsPath {
    let data = try Data(contentsOf: URL(fileURLWithPath: expectationsPath))
    expectations = try JSONDecoder().decode(ExpectationFile.self, from: data).cases
} else if !parsed.sources.isEmpty {
    expectations = parsed.sources.map {
        ShapeExpectation(
            name: URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent,
            source: $0,
            expectedShape: .unknown,
            expectedRawOrderShape: nil,
            notes: nil
        )
    }
} else {
    fputs("usage: swift replay_shape_detection.swift --expectations <file.json> [--report <out.json>] [edge-download.json ...]\n", stderr)
    exit(2)
}

let reports = expectations.map(runCase)
let passCount = reports.filter(\.passed).count
let failCount = reports.count - passCount

let runReport = ShapeRunReport(
    startedAt: ISO8601DateFormatter().string(from: Date()),
    passCount: passCount,
    failCount: failCount,
    cases: reports
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try encoder.encode(runReport)

if let reportPath = parsed.reportPath {
    let url = URL(fileURLWithPath: reportPath)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
}

FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([0x0a]))
exit(failCount == 0 ? 0 : 1)

private func runCase(_ expectation: ShapeExpectation) -> ShapeCaseReport {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: expectation.source))
        let saved = try JSONDecoder().decode(SavedEdgeRecord.self, from: data)
        let points = saved.chainPoints.compactMap(vector)
        let analysis = analyze(points: points, saved: saved)
        let detected = detectShape(from: analysis)
        let raw = detectRawOrderShape(from: analysis)

        let expectedShapePass = expectation.expectedShape == .unknown || detected == expectation.expectedShape
        let rawShapePass = expectation.expectedRawOrderShape == nil || raw == expectation.expectedRawOrderShape
        let passed = expectedShapePass && rawShapePass

        return ShapeCaseReport(
            name: expectation.name,
            source: expectation.source,
            expectedShape: expectation.expectedShape == .unknown ? nil : expectation.expectedShape,
            expectedRawOrderShape: expectation.expectedRawOrderShape,
            detectedShape: detected,
            rawOrderShape: raw,
            passed: passed,
            failureBucket: passed ? nil : failureBucket(expected: expectation, detected: detected, raw: raw),
            metrics: analysis.metrics,
            notes: expectation.notes
        )
    } catch {
        return ShapeCaseReport(
            name: expectation.name,
            source: expectation.source,
            expectedShape: expectation.expectedShape,
            expectedRawOrderShape: expectation.expectedRawOrderShape,
            detectedShape: .unknown,
            rawOrderShape: .unknown,
            passed: false,
            failureBucket: "unreadable-input: \(error.localizedDescription)",
            metrics: emptyMetrics(),
            notes: expectation.notes
        )
    }
}

private struct Analysis {
    let metrics: ShapeMetrics
    let circle: CircleFit
    let line: LineFit
    let rawOrderCircle: CircleFit
}

private func analyze(points rawPoints: [SIMD3<Float>], saved: SavedEdgeRecord) -> Analysis {
    let points = dedupe(rawPoints)
    let ordered = greedyNearestNeighborOrder(points)
    let basis = planeBasis(for: points)
    let projected = project(points, onto: basis)
    let orderedProjected = project(ordered, onto: basis)
    let circle = circleFit(projected)
    let line = lineFit(points)
    let rawOrderCircle = circleFit(projected, orderedAngles: projected)

    let rawLengths = segmentLengths(points)
    let orderedLengths = segmentLengths(ordered)
    let rawPolylineLength = rawLengths.reduce(0, +)
    let orderedPolylineLength = orderedLengths.reduce(0, +)
    let rawSweep = unwrappedSweepDegrees(projected: projected, center: circle.center)
    let stepStats = stats(orderedLengths)

    return Analysis(
        metrics: ShapeMetrics(
            pointCount: points.count,
            chainKind: saved.chainKind,
            selectedEdge: saved.selectedEdge,
            rawPolylineLength: rawPolylineLength,
            orderedPolylineLength: orderedPolylineLength,
            rawOrderSweepDegrees: rawSweep,
            angularCoverageDegrees: circle.angularCoverageDegrees,
            circleRadius: circle.radius,
            circleMeanResidual: circle.meanResidual,
            circleMaxResidual: circle.maxResidual,
            lineLength: line.length,
            lineMeanResidual: line.meanResidual,
            lineMaxResidual: line.maxResidual,
            stepMedian: stepStats.median,
            stepMax: stepStats.max
        ),
        circle: circle,
        line: line,
        rawOrderCircle: rawOrderCircle
    )
}

private func detectShape(from analysis: Analysis) -> ShapeKind {
    let extent = max(analysis.line.length, analysis.circle.radius * 2)
    let lineMeanLimit = max(extent * 0.006, 0.2)
    let lineMaxLimit = max(extent * 0.02, 0.75)

    if analysis.line.length > 0,
       analysis.line.meanResidual <= lineMeanLimit,
       analysis.line.maxResidual <= lineMaxLimit {
        return .line
    }

    let circleMeanLimit = max(analysis.circle.radius * 0.08, 0.6)
    let circleMaxLimit = max(analysis.circle.radius * 0.18, 3.0)
    let circleFitIsUsable = analysis.circle.radius.isFinite
        && analysis.circle.meanResidual <= circleMeanLimit
        && analysis.circle.maxResidual <= circleMaxLimit

    guard circleFitIsUsable else {
        return .fragmented
    }

    let coverage = analysis.circle.angularCoverageDegrees
    if coverage >= 140, coverage <= 225 {
        return .semicircle
    }
    if coverage > 325 {
        return .circle
    }
    if coverage >= 25 {
        return .arc
    }
    return .unknown
}

private func detectRawOrderShape(from analysis: Analysis) -> ShapeKind {
    if analysis.metrics.rawOrderSweepDegrees > 720 {
        return .fragmented
    }
    return detectShape(from: analysis)
}

private func failureBucket(expected: ShapeExpectation, detected: ShapeKind, raw: ShapeKind) -> String {
    if raw == .fragmented, detected == expected.expectedShape {
        return "raw-order-fragmented-but-shape-detector-recovered"
    }
    if expected.expectedShape == .semicircle, detected == .arc {
        return "under-merged-arc"
    }
    if expected.expectedShape == .semicircle, detected == .line {
        return "curve-misread-as-line"
    }
    if expected.expectedShape == .line, detected != .line {
        return "line-fit-rejected"
    }
    return "shape-mismatch"
}

private func vector(_ values: [Float]) -> SIMD3<Float>? {
    guard values.count >= 3 else { return nil }
    return SIMD3<Float>(values[0], values[1], values[2])
}

private func dedupe(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
    var result: [SIMD3<Float>] = []
    for point in points {
        if result.contains(where: { simd_distance($0, point) < 0.00001 }) {
            continue
        }
        result.append(point)
    }
    return result
}

private func greedyNearestNeighborOrder(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
    guard let first = points.first else { return [] }
    var remaining = Array(points.indices.dropFirst())
    var ordered = [first]
    var current = first

    while !remaining.isEmpty {
        var bestOffset = 0
        var bestDistance = Float.greatestFiniteMagnitude
        for (offset, index) in remaining.enumerated() {
            let distance = simd_distance(current, points[index])
            if distance < bestDistance {
                bestDistance = distance
                bestOffset = offset
            }
        }
        let nextIndex = remaining.remove(at: bestOffset)
        current = points[nextIndex]
        ordered.append(current)
    }

    return ordered
}

private func planeBasis(for points: [SIMD3<Float>]) -> PlaneBasis {
    let origin = points.first ?? SIMD3<Float>(0, 0, 0)
    let farthest = points.max(by: { simd_distance(origin, $0) < simd_distance(origin, $1) }) ?? origin
    let u = normalized(farthest - origin, fallback: SIMD3<Float>(1, 0, 0))
    let offAxis = points.max(by: { pointDistanceToLine($0, origin, u) < pointDistanceToLine($1, origin, u) }) ?? origin
    let normal = normalized(simd_cross(u, offAxis - origin), fallback: SIMD3<Float>(0, 1, 0))
    let v = normalized(simd_cross(normal, u), fallback: SIMD3<Float>(0, 0, 1))
    return PlaneBasis(origin: origin, u: u, v: v, normal: normal)
}

private func project(_ points: [SIMD3<Float>], onto basis: PlaneBasis) -> [SIMD2<Float>] {
    points.map { point in
        let relative = point - basis.origin
        return SIMD2<Float>(simd_dot(relative, basis.u), simd_dot(relative, basis.v))
    }
}

private func lineFit(_ points: [SIMD3<Float>]) -> LineFit {
    guard points.count >= 2 else {
        return LineFit(length: 0, meanResidual: 0, maxResidual: 0)
    }

    var a = points[0]
    var b = points[1]
    var length = simd_distance(a, b)
    for first in points {
        for second in points {
            let distance = simd_distance(first, second)
            if distance > length {
                a = first
                b = second
                length = distance
            }
        }
    }

    let direction = normalized(b - a, fallback: SIMD3<Float>(1, 0, 0))
    let residuals = points.map { pointDistanceToLine($0, a, direction) }
    return LineFit(
        length: length,
        meanResidual: residuals.reduce(0, +) / Float(max(residuals.count, 1)),
        maxResidual: residuals.max() ?? 0
    )
}

private func circleFit(_ projected: [SIMD2<Float>], orderedAngles: [SIMD2<Float>]? = nil) -> CircleFit {
    guard projected.count >= 3 else {
        return CircleFit(center: SIMD2<Float>(0, 0), radius: 0, meanResidual: 0, maxResidual: 0, angularCoverageDegrees: 0)
    }

    var ata = simd_float3x3()
    var atb = SIMD3<Float>(repeating: 0)

    for point in projected {
        let row = SIMD3<Float>(2 * point.x, 2 * point.y, 1)
        ata += simd_float3x3(
            SIMD3<Float>(row.x * row.x, row.x * row.y, row.x * row.z),
            SIMD3<Float>(row.y * row.x, row.y * row.y, row.y * row.z),
            SIMD3<Float>(row.z * row.x, row.z * row.y, row.z * row.z)
        )
        atb += row * (point.x * point.x + point.y * point.y)
    }

    let solution = ata.inverse * atb
    let center = SIMD2<Float>(solution.x, solution.y)
    let radius = sqrt(max(0.0001, solution.z + simd_dot(center, center)))
    let residuals = projected.map { abs(simd_distance($0, center) - radius) }
    let coverage = orderedAngles == nil
        ? angularCoverageDegrees(projected: projected, center: center)
        : unwrappedSweepDegrees(projected: orderedAngles!, center: center)

    return CircleFit(
        center: center,
        radius: radius,
        meanResidual: residuals.reduce(0, +) / Float(max(residuals.count, 1)),
        maxResidual: residuals.max() ?? 0,
        angularCoverageDegrees: coverage
    )
}

private func angularCoverageDegrees(projected: [SIMD2<Float>], center: SIMD2<Float>) -> Float {
    let twoPi = Float.pi * 2
    let angles = projected.map { atan2f($0.y - center.y, $0.x - center.x) }.sorted()
    guard angles.count >= 2 else { return 0 }

    var maxGap: Float = 0
    for pair in zip(angles, angles.dropFirst()) {
        maxGap = max(maxGap, pair.1 - pair.0)
    }
    maxGap = max(maxGap, (angles[0] + twoPi) - angles[angles.count - 1])
    return (twoPi - maxGap) * 180 / .pi
}

private func unwrappedSweepDegrees(projected: [SIMD2<Float>], center: SIMD2<Float>) -> Float {
    let angles = projected.map { atan2f($0.y - center.y, $0.x - center.x) }
    guard let first = angles.first else { return 0 }
    var unwrapped = [first]
    for angle in angles.dropFirst() {
        var candidate = angle
        var delta = candidate - unwrapped.last!
        while delta > .pi {
            candidate -= 2 * .pi
            delta = candidate - unwrapped.last!
        }
        while delta < -.pi {
            candidate += 2 * .pi
            delta = candidate - unwrapped.last!
        }
        unwrapped.append(candidate)
    }
    return abs(((unwrapped.max() ?? first) - (unwrapped.min() ?? first)) * 180 / .pi)
}

private func segmentLengths(_ points: [SIMD3<Float>]) -> [Float] {
    zip(points, points.dropFirst()).map(simd_distance)
}

private func stats(_ values: [Float]) -> (median: Float, max: Float) {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return (0, 0) }
    return (sorted[sorted.count / 2], sorted.last ?? 0)
}

private func pointDistanceToLine(_ point: SIMD3<Float>, _ linePoint: SIMD3<Float>, _ direction: SIMD3<Float>) -> Float {
    simd_length(simd_cross(point - linePoint, direction))
}

private func normalized(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
    let length = simd_length(vector)
    guard length.isFinite, length > 0.000001 else { return fallback }
    return vector / length
}

private func emptyMetrics() -> ShapeMetrics {
    ShapeMetrics(
        pointCount: 0,
        chainKind: "",
        selectedEdge: [],
        rawPolylineLength: 0,
        orderedPolylineLength: 0,
        rawOrderSweepDegrees: 0,
        angularCoverageDegrees: 0,
        circleRadius: 0,
        circleMeanResidual: 0,
        circleMaxResidual: 0,
        lineLength: 0,
        lineMeanResidual: 0,
        lineMaxResidual: 0,
        stepMedian: 0,
        stepMax: 0
    )
}

private func parseArguments(_ args: [String]) -> (expectationsPath: String?, reportPath: String?, sources: [String]) {
    var expectationsPath: String?
    var reportPath: String?
    var sources: [String] = []
    var index = 1

    while index < args.count {
        let arg = args[index]
        if arg == "--expectations", index + 1 < args.count {
            index += 1
            expectationsPath = args[index]
        } else if arg.hasPrefix("--expectations=") {
            expectationsPath = String(arg.dropFirst("--expectations=".count))
        } else if arg == "--report", index + 1 < args.count {
            index += 1
            reportPath = args[index]
        } else if arg.hasPrefix("--report=") {
            reportPath = String(arg.dropFirst("--report=".count))
        } else if !arg.hasPrefix("-") {
            sources.append(arg)
        }
        index += 1
    }

    return (expectationsPath, reportPath, sources)
}
