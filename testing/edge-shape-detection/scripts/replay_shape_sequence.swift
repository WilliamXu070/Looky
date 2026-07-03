import Foundation
import simd

struct SavedEdgeRecord: Decodable {
    let chainKind: String
    let chainPoints: [[Float]]
    let selectedEdge: [Int]
    let snappedWorldPoint: [Float]?
}

struct SequenceReport: Encodable {
    let source: String
    let chainKind: String
    let selectedEdge: [Int]
    let pointCount: Int
    let expectedSequence: [String]
    let detectedSequence: [String]
    let passed: Bool
    let orderedClosedLength: Float
    let rawClosedLength: Float
    let segments: [SegmentReport]
}

struct SegmentReport: Encodable {
    let kind: String
    let pointCount: Int
    let length: Float
    let lineMaxResidual: Float?
    let circleRadius: Float?
    let circleMaxResidual: Float?
    let coverageDegrees: Float?
}

private struct PlaneBasis {
    let origin: SIMD3<Float>
    let u: SIMD3<Float>
    let v: SIMD3<Float>
    let normal: SIMD3<Float>
}

private struct CircleFit {
    let center: SIMD2<Float>
    let radius: Float
    let maxResidual: Float
    let coverageDegrees: Float
}

let args = CommandLine.arguments
let source = args.count > 1
    ? args[1]
    : "/tmp/quicklook-edge-download/edge-download-2026-06-05T13-21-40Z.json"
let output = args.count > 2 ? args[2] : nil

let data = try Data(contentsOf: URL(fileURLWithPath: source))
let saved = try JSONDecoder().decode(SavedEdgeRecord.self, from: data)
let points = dedupe(saved.chainPoints.compactMap(vector))
let ordered = orderedClosedLoop(points)
let segments = segmentLoop(ordered)
let rotated = rotateToStartWithLongestLine(segments)
let detectedSequence = rotated.map(\.kind)
let expectedSequence = ["line", "semicircle", "line", "semicircle"]

let report = SequenceReport(
    source: source,
    chainKind: saved.chainKind,
    selectedEdge: saved.selectedEdge,
    pointCount: points.count,
    expectedSequence: expectedSequence,
    detectedSequence: detectedSequence,
    passed: detectedSequence == expectedSequence,
    orderedClosedLength: closedLength(ordered),
    rawClosedLength: closedLength(points),
    segments: rotated
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let encoded = try encoder.encode(report)
if let output {
    let url = URL(fileURLWithPath: output)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try encoded.write(to: url, options: .atomic)
}
FileHandle.standardOutput.write(encoded)
FileHandle.standardOutput.write(Data([0x0a]))
exit(report.passed ? 0 : 1)

private func segmentLoop(_ ordered: [SIMD3<Float>]) -> [SegmentReport] {
    guard ordered.count >= 8 else { return [] }
    if let capsule = capsuleSegments(ordered) {
        return capsule
    }
    if let extruded = extrudedSemicircleSegments(ordered) {
        return extruded
    }

    let basis = planeBasis(for: ordered)
    let projected = project(ordered, onto: basis)
    let turns = turnDegrees(projected)
    let lineFlags = turns.map { $0 < 1.25 }
    var groups = contiguousGroups(flags: lineFlags)
    groups = mergeSmallGroups(groups, minimumCount: 3, totalCount: ordered.count)

    let reports = groups.compactMap { group -> SegmentReport? in
        let indices = indicesFor(group: group, count: ordered.count)
        guard indices.count >= 2 else { return nil }
        let groupPoints = indices.map { ordered[$0] }
        let kind: String
        let lineResidual: Float?
        let circleRadius: Float?
        let circleResidual: Float?
        let coverage: Float?

        if group.isLine {
            kind = "line"
            lineResidual = lineMaxResidual(groupPoints)
            circleRadius = nil
            circleResidual = nil
            coverage = nil
        } else {
            let fit = circleFit(project(groupPoints, onto: basis))
            kind = fit.coverageDegrees >= 120 && fit.coverageDegrees <= 235
                ? "semicircle"
                : "arc"
            lineResidual = nil
            circleRadius = fit.radius
            circleResidual = fit.maxResidual
            coverage = fit.coverageDegrees
        }

        return SegmentReport(
            kind: kind,
            pointCount: groupPoints.count,
            length: openLength(groupPoints),
            lineMaxResidual: lineResidual,
            circleRadius: circleRadius,
            circleMaxResidual: circleResidual,
            coverageDegrees: coverage
        )
    }

    return mergeAdjacentSameKind(reports)
}

private func capsuleSegments(_ points: [SIMD3<Float>]) -> [SegmentReport]? {
    guard points.count >= 12 else { return nil }

    let basis = planeBasis(for: points)
    let projected = project(points, onto: basis)
    let axes = pcaAxes(projected)
    let coords = projected.map { point -> SIMD2<Float> in
        let relative = point - axes.centroid
        return SIMD2<Float>(simd_dot(relative, axes.major), simd_dot(relative, axes.minor))
    }

    let sValues = coords.map(\.x)
    let tValues = coords.map(\.y)
    guard let minS = sValues.min(),
          let maxS = sValues.max(),
          let minT = tValues.min(),
          let maxT = tValues.max() else {
        return nil
    }

    let width = maxS - minS
    let height = maxT - minT
    guard height > 0.0001, width > height * 2.4 else {
        return nil
    }

    let radius = height / 2
    let centerT = (minT + maxT) / 2
    let leftCenterS = minS + radius
    let rightCenterS = maxS - radius
    let railTolerance = max(radius * 0.12, width * 0.004)
    let capTolerance = max(radius * 0.18, width * 0.006)

    let top = coords.filter {
        abs($0.y - maxT) <= railTolerance &&
        $0.x >= leftCenterS - railTolerance &&
        $0.x <= rightCenterS + railTolerance
    }
    let bottom = coords.filter {
        abs($0.y - minT) <= railTolerance &&
        $0.x >= leftCenterS - railTolerance &&
        $0.x <= rightCenterS + railTolerance
    }
    let leftCap = coords.filter { $0.x <= leftCenterS + capTolerance }
    let rightCap = coords.filter { $0.x >= rightCenterS - capTolerance }

    guard top.count >= 2,
          bottom.count >= 2,
          leftCap.count >= 6,
          rightCap.count >= 6 else {
        return nil
    }

    let topLine = lineSegmentReport(kind: "line", points: top, targetT: maxT)
    let right = capSegmentReport(points: rightCap, center: SIMD2<Float>(rightCenterS, centerT), radius: radius)
    let bottomLine = lineSegmentReport(kind: "line", points: bottom, targetT: minT)
    let left = capSegmentReport(points: leftCap, center: SIMD2<Float>(leftCenterS, centerT), radius: radius)

    guard right.kind == "semicircle", left.kind == "semicircle" else {
        return nil
    }

    return [topLine, right, bottomLine, left]
}

private struct RailSegment {
    let points: [SIMD3<Float>]
    let report: SegmentReport
}

private enum CoordinateAxis: CaseIterable {
    case x
    case y
    case z
}

private func extrudedSemicircleSegments(_ points: [SIMD3<Float>]) -> [SegmentReport]? {
    guard points.count >= 12 else { return nil }

    for axis in CoordinateAxis.allCases {
        let values = points.map { coordinate($0, axis: axis) }
        guard let minValue = values.min(), let maxValue = values.max() else {
            continue
        }

        let range = maxValue - minValue
        guard range > 0.0001 else {
            continue
        }

        let levelTolerance = max(range * 0.02, 0.01)
        var lower: [SIMD3<Float>] = []
        var upper: [SIMD3<Float>] = []
        var middleCount = 0
        for point in points {
            let value = coordinate(point, axis: axis)
            if abs(value - minValue) <= levelTolerance {
                lower.append(point)
            } else if abs(value - maxValue) <= levelTolerance {
                upper.append(point)
            } else {
                middleCount += 1
            }
        }

        guard middleCount == 0,
              lower.count >= 6,
              upper.count >= 6,
              let lowerArc = semicircleRailSegment(points: lower, axis: axis),
              let upperArc = semicircleRailSegment(points: upper, axis: axis) else {
            continue
        }

        let lowerStart = lowerArc.points.first ?? lower[0]
        let lowerEnd = lowerArc.points.last ?? lower[lower.count - 1]
        let upperStart = upperArc.points.first ?? upper[0]
        let upperEnd = upperArc.points.last ?? upper[upper.count - 1]
        let alignedDistance = simd_distance(lowerStart, upperStart) + simd_distance(lowerEnd, upperEnd)
        let crossedDistance = simd_distance(lowerStart, upperEnd) + simd_distance(lowerEnd, upperStart)

        if alignedDistance <= crossedDistance {
            return [
                connectorLineSegment(lowerStart, upperStart),
                upperArc.report,
                connectorLineSegment(upperEnd, lowerEnd),
                lowerArc.report
            ]
        }

        return [
            connectorLineSegment(lowerStart, upperEnd),
            upperArc.report,
            connectorLineSegment(upperStart, lowerEnd),
            lowerArc.report
        ]
    }

    return nil
}

private func semicircleRailSegment(points: [SIMD3<Float>], axis: CoordinateAxis) -> RailSegment? {
    let projected = points.map { project($0, excluding: axis) }
    let fit = circleFit(projected)
    let residualLimit = max(fit.radius * 0.08, 0.05)
    guard fit.radius > 0.0001,
          fit.maxResidual <= residualLimit,
          fit.coverageDegrees >= 140,
          fit.coverageDegrees <= 220 else {
        return nil
    }

    let sorted = zip(points, projected)
        .sorted {
            atan2f($0.1.y - fit.center.y, $0.1.x - fit.center.x)
                < atan2f($1.1.y - fit.center.y, $1.1.x - fit.center.x)
        }
    let split = splitIndexAfterLargestAngularGap(sorted.map {
        atan2f($0.1.y - fit.center.y, $0.1.x - fit.center.x)
    })
    let ordered = Array(sorted[split...]) + Array(sorted[..<split])

    let report = SegmentReport(
        kind: "semicircle",
        pointCount: ordered.count,
        length: fit.radius * fit.coverageDegrees * .pi / 180,
        lineMaxResidual: nil,
        circleRadius: fit.radius,
        circleMaxResidual: fit.maxResidual,
        coverageDegrees: fit.coverageDegrees
    )
    return RailSegment(points: ordered.map(\.0), report: report)
}

private func connectorLineSegment(_ start: SIMD3<Float>, _ end: SIMD3<Float>) -> SegmentReport {
    SegmentReport(
        kind: "line",
        pointCount: 2,
        length: simd_distance(start, end),
        lineMaxResidual: 0,
        circleRadius: nil,
        circleMaxResidual: nil,
        coverageDegrees: nil
    )
}

private func splitIndexAfterLargestAngularGap(_ angles: [Float]) -> Int {
    guard angles.count >= 3 else { return 0 }
    let sorted = angles.sorted()
    var splitIndex = 0
    var maxGap: Float = -1
    for index in 0..<sorted.count {
        let nextIndex = (index + 1) % sorted.count
        let nextAngle = nextIndex == 0 ? sorted[0] + (2 * .pi) : sorted[nextIndex]
        let gap = nextAngle - sorted[index]
        if gap > maxGap {
            maxGap = gap
            splitIndex = nextIndex
        }
    }
    return splitIndex
}

private func lineSegmentReport(kind: String, points: [SIMD2<Float>], targetT: Float) -> SegmentReport {
    let sorted = points.sorted { $0.x < $1.x }
    let length = max(0, (sorted.last?.x ?? 0) - (sorted.first?.x ?? 0))
    let residual = points.map { abs($0.y - targetT) }.max() ?? 0
    return SegmentReport(
        kind: kind,
        pointCount: points.count,
        length: length,
        lineMaxResidual: residual,
        circleRadius: nil,
        circleMaxResidual: nil,
        coverageDegrees: nil
    )
}

private func capSegmentReport(points: [SIMD2<Float>], center: SIMD2<Float>, radius: Float) -> SegmentReport {
    let residual = points.map { abs(simd_distance($0, center) - radius) }.max() ?? 0
    let coverage = angularCoverageDegrees(points, center: center)
    let kind = coverage >= 140 && coverage <= 220 ? "semicircle" : "arc"
    return SegmentReport(
        kind: kind,
        pointCount: points.count,
        length: radius * coverage * .pi / 180,
        lineMaxResidual: nil,
        circleRadius: radius,
        circleMaxResidual: residual,
        coverageDegrees: coverage
    )
}

private struct PCAAxes {
    let centroid: SIMD2<Float>
    let major: SIMD2<Float>
    let minor: SIMD2<Float>
}

private func pcaAxes(_ points: [SIMD2<Float>]) -> PCAAxes {
    let centroid = points.reduce(SIMD2<Float>(0, 0), +) / Float(max(points.count, 1))
    var xx: Float = 0
    var xy: Float = 0
    var yy: Float = 0
    for point in points {
        let centered = point - centroid
        xx += centered.x * centered.x
        xy += centered.x * centered.y
        yy += centered.y * centered.y
    }
    let angle = 0.5 * atan2f(2 * xy, xx - yy)
    let major = normalized(SIMD2<Float>(cosf(angle), sinf(angle)), fallback: SIMD2<Float>(1, 0))
    let minor = SIMD2<Float>(-major.y, major.x)
    return PCAAxes(centroid: centroid, major: major, minor: minor)
}

private struct Group {
    let isLine: Bool
    let start: Int
    let end: Int
    let count: Int
}

private func contiguousGroups(flags: [Bool]) -> [Group] {
    guard !flags.isEmpty else { return [] }
    var groups: [Group] = []
    var start = 0
    var current = flags[0]
    for index in 1..<flags.count {
        if flags[index] != current {
            groups.append(Group(isLine: current, start: start, end: index - 1, count: index - start))
            start = index
            current = flags[index]
        }
    }
    groups.append(Group(isLine: current, start: start, end: flags.count - 1, count: flags.count - start))

    if groups.count > 1,
       let first = groups.first,
       let last = groups.last,
       first.isLine == last.isLine {
        let merged = Group(
            isLine: first.isLine,
            start: last.start,
            end: first.end,
            count: first.count + last.count
        )
        groups.removeFirst()
        groups.removeLast()
        groups.insert(merged, at: 0)
    }
    return groups
}

private func mergeSmallGroups(_ groups: [Group], minimumCount: Int, totalCount: Int) -> [Group] {
    guard groups.count > 2 else { return groups }
    return groups.filter { $0.count >= minimumCount }
}

private func indicesFor(group: Group, count: Int) -> [Int] {
    if group.start <= group.end {
        return Array(group.start...group.end)
    }
    return Array(group.start..<count) + Array(0...group.end)
}

private func mergeAdjacentSameKind(_ input: [SegmentReport]) -> [SegmentReport] {
    guard !input.isEmpty else { return [] }
    var result = input
    if result.count > 1,
       result.first?.kind == result.last?.kind {
        let first = result.removeFirst()
        let last = result.removeLast()
        let merged = SegmentReport(
            kind: first.kind,
            pointCount: first.pointCount + last.pointCount,
            length: first.length + last.length,
            lineMaxResidual: max(first.lineMaxResidual ?? 0, last.lineMaxResidual ?? 0),
            circleRadius: first.circleRadius ?? last.circleRadius,
            circleMaxResidual: max(first.circleMaxResidual ?? 0, last.circleMaxResidual ?? 0),
            coverageDegrees: (first.coverageDegrees ?? 0) + (last.coverageDegrees ?? 0)
        )
        result.insert(merged, at: 0)
    }
    return result
}

private func rotateToStartWithLongestLine(_ segments: [SegmentReport]) -> [SegmentReport] {
    guard let start = segments.enumerated()
        .filter({ $0.element.kind == "line" })
        .max(by: { $0.element.length < $1.element.length })?
        .offset else {
        return segments
    }
    return Array(segments[start...]) + Array(segments[..<start])
}

private func orderedClosedLoop(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
    let basis = planeBasis(for: points)
    let projected = project(points, onto: basis)
    let centroid = projected.reduce(SIMD2<Float>(0, 0), +) / Float(max(projected.count, 1))
    return zip(points, projected)
        .sorted {
            atan2f($0.1.y - centroid.y, $0.1.x - centroid.x)
            < atan2f($1.1.y - centroid.y, $1.1.x - centroid.x)
        }
        .map(\.0)
}

private func turnDegrees(_ points: [SIMD2<Float>]) -> [Float] {
    let count = points.count
    return (0..<count).map { index in
        let prev = points[(index - 1 + count) % count]
        let current = points[index]
        let next = points[(index + 1) % count]
        let a = normalized(current - prev, fallback: SIMD2<Float>(1, 0))
        let b = normalized(next - current, fallback: SIMD2<Float>(1, 0))
        let dot = max(-1, min(1, simd_dot(a, b)))
        return acosf(dot) * 180 / .pi
    }
}

private func planeBasis(for points: [SIMD3<Float>]) -> PlaneBasis {
    let origin = points.first ?? SIMD3<Float>(0, 0, 0)
    let farthest = points.max(by: { simd_distance(origin, $0) < simd_distance(origin, $1) }) ?? origin
    let u = normalized(farthest - origin, fallback: SIMD3<Float>(1, 0, 0))
    let offAxis = points.max(by: { distanceToLine($0, origin, u) < distanceToLine($1, origin, u) }) ?? origin
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

private func circleFit(_ points: [SIMD2<Float>]) -> CircleFit {
    guard points.count >= 3 else {
        return CircleFit(center: SIMD2<Float>(0, 0), radius: 0, maxResidual: 0, coverageDegrees: 0)
    }
    var ata = simd_float3x3()
    var atb = SIMD3<Float>(repeating: 0)
    for point in points {
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
    let residuals = points.map { abs(simd_distance($0, center) - radius) }
    return CircleFit(
        center: center,
        radius: radius,
        maxResidual: residuals.max() ?? 0,
        coverageDegrees: angularCoverageDegrees(points, center: center)
    )
}

private func angularCoverageDegrees(_ points: [SIMD2<Float>], center: SIMD2<Float>) -> Float {
    let twoPi = Float.pi * 2
    let angles = points.map { atan2f($0.y - center.y, $0.x - center.x) }.sorted()
    guard angles.count >= 2 else { return 0 }
    var maxGap: Float = 0
    for pair in zip(angles, angles.dropFirst()) {
        maxGap = max(maxGap, pair.1 - pair.0)
    }
    maxGap = max(maxGap, (angles[0] + twoPi) - angles[angles.count - 1])
    return (twoPi - maxGap) * 180 / .pi
}

private func lineMaxResidual(_ points: [SIMD3<Float>]) -> Float {
    guard let first = points.first, let last = points.last else { return 0 }
    let direction = normalized(last - first, fallback: SIMD3<Float>(1, 0, 0))
    return points.map { distanceToLine($0, first, direction) }.max() ?? 0
}

private func openLength(_ points: [SIMD3<Float>]) -> Float {
    zip(points, points.dropFirst()).map(simd_distance).reduce(0, +)
}

private func closedLength(_ points: [SIMD3<Float>]) -> Float {
    guard points.count >= 2 else { return 0 }
    return openLength(points) + simd_distance(points[0], points[points.count - 1])
}

private func distanceToLine(_ point: SIMD3<Float>, _ linePoint: SIMD3<Float>, _ direction: SIMD3<Float>) -> Float {
    simd_length(simd_cross(point - linePoint, direction))
}

private func coordinate(_ point: SIMD3<Float>, axis: CoordinateAxis) -> Float {
    switch axis {
    case .x:
        return point.x
    case .y:
        return point.y
    case .z:
        return point.z
    }
}

private func project(_ point: SIMD3<Float>, excluding axis: CoordinateAxis) -> SIMD2<Float> {
    switch axis {
    case .x:
        return SIMD2<Float>(point.y, point.z)
    case .y:
        return SIMD2<Float>(point.x, point.z)
    case .z:
        return SIMD2<Float>(point.x, point.y)
    }
}

private func normalized(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
    let length = simd_length(vector)
    guard length.isFinite, length > 0.000001 else { return fallback }
    return vector / length
}

private func normalized(_ vector: SIMD2<Float>, fallback: SIMD2<Float>) -> SIMD2<Float> {
    let length = simd_length(vector)
    guard length.isFinite, length > 0.000001 else { return fallback }
    return vector / length
}

private func vector(_ values: [Float]) -> SIMD3<Float>? {
    guard values.count >= 3 else { return nil }
    return SIMD3<Float>(values[0], values[1], values[2])
}

private func dedupe(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
    var result: [SIMD3<Float>] = []
    for point in points {
        if !result.contains(where: { simd_distance($0, point) < 0.00001 }) {
            result.append(point)
        }
    }
    return result
}
