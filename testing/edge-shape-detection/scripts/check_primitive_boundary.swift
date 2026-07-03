import Foundation
import simd

// MARK: - JSON record types

struct SavedEdgeRecord: Decodable {
    let chainPoints: [[Float]]
    let selectedEdge: [Int]
    let snappedWorldPoint: [Float]?
}

struct PrimitiveGroup {
    let kind: String
    let points: [SIMD3<Float>]
}

struct SelectionResult {
    let queryPoint: SIMD3<Float>
    let selectedPrimitiveKind: String
    let selectedPrimitiveIndex: Int
    let selectedPoints: [SIMD3<Float>]
}

struct BoundaryCheck {
    let fromKind: String
    let fromIndex: Int
    let fromPoint: SIMD3<Float>
    let toKind: String
    let toIndex: Int
    let toPoint: SIMD3<Float>
    let distance: Float
    let passed: Bool
}

struct PrimitiveSummary {
    let kind: String
    let index: Int
    let pointCount: Int
    let length: Float
    let startPoint: SIMD3<Float>
    let endPoint: SIMD3<Float>
}

// MARK: - Main

let args = CommandLine.arguments
let source = args.count > 1 ? args[1] : "testing/edge-shape-detection/polygons/saved/thor-connected-edge-semicircle.json"
let output = args.count > 2 ? args[2] : nil

let data = try Data(contentsOf: URL(fileURLWithPath: source))
let saved = try JSONDecoder().decode(SavedEdgeRecord.self, from: data)
let rawPoints = saved.chainPoints.compactMap(vector)
let points = dedupe(rawPoints)

    guard let primitives = capsulePrimitiveGroups(points) else {
        print("FAIL: capsulePrimitiveGroups returned nil")
        exit(2)
    }
let kinds = primitives.map(\.kind)
if kinds != ["line", "semicircle", "line", "semicircle"] {
    print("FAIL: expected [line, semicircle, line, semicircle], got \(kinds)")
    for (i, p) in primitives.enumerated() {
        print("  prim[\(i)]: \(p.kind), \(p.points.count) pts, first \(p.points.first!), last \(p.points.last!)")
    }
    exit(2)
}

// Compute selection for every input point
var selections: [SelectionResult] = []

for point in points {
    guard let result = selectedPrimitivePoints(primitives: primitives, nearest: point) else {
        print("FAIL: no primitive selected for point \(point)")
        exit(3)
    }
    selections.append(result)
}

// Group selections by primitive index
var selectionsByPrimitive: [Int: [SelectionResult]] = [:]
for sel in selections {
    selectionsByPrimitive[sel.selectedPrimitiveIndex, default: []].append(sel)
}

// Summarize each primitive
var summaries: [PrimitiveSummary] = []
for (index, group) in primitives.enumerated() {
    let length = openLength(group.points)
    summaries.append(PrimitiveSummary(
        kind: group.kind,
        index: index,
        pointCount: group.points.count,
        length: length,
        startPoint: group.points.first!,
        endPoint: group.points.last!
    ))
}

// ----- Checks -----
var failures: [String] = []

// Check 1: Selection consistency — all query points mapping to same primitive return identical selected points
for (primIndex, results) in selectionsByPrimitive {
    let expectedPoints = results[0].selectedPoints
    let expectedCount = expectedPoints.count
    let expectedLength = openLength(expectedPoints)
    let expectedStart = expectedPoints.first!
    let expectedEnd = expectedPoints.last!

    for (i, result) in results.enumerated() {
        let count = result.selectedPoints.count
        let length = openLength(result.selectedPoints)
        if count != expectedCount {
            failures.append("prim[\(primIndex)] query[\(i)] pointCount mismatch: \(count) vs expected \(expectedCount)")
        }
        if abs(length - expectedLength) > 0.001 {
            failures.append("prim[\(primIndex)] query[\(i)] length mismatch: \(length) vs expected \(expectedLength)")
        }
        if simd_distance(result.selectedPoints.first!, expectedStart) > 0.001 {
            failures.append("prim[\(primIndex)] query[\(i)] startPoint mismatch")
        }
        if simd_distance(result.selectedPoints.last!, expectedEnd) > 0.001 {
            failures.append("prim[\(primIndex)] query[\(i)] endPoint mismatch")
        }
    }

    // Also check that the query points assigned to this primitive actually map to it correctly
    for (i, result) in results.enumerated() {
        let distancesToThisPrimitive = primitives[primIndex].points.map {
            pointToPrimitiveDistance(result.queryPoint, $0)
        }.min() ?? .greatestFiniteMagnitude

        for (otherIndex, _) in primitives.enumerated() where otherIndex != primIndex {
            let distancesToOther = primitives[otherIndex].points.map {
                pointToPrimitiveDistance(result.queryPoint, $0)
            }.min() ?? .greatestFiniteMagnitude
            
            if distancesToOther < distancesToThisPrimitive - 0.001 {
                failures.append("prim[\(primIndex)] query[\(i)] point \(result.queryPoint) is closer to prim[\(otherIndex)] than its own")
            }
        }
    }
}

// Check 2: Boundary integrity — adjacent primitives meet at the same point
let adjacentPairs = [(0, 1), (1, 2), (2, 3), (3, 0)]
for (fromIdx, toIdx) in adjacentPairs {
    let fromPrim = primitives[fromIdx]
    let toPrim = primitives[toIdx]
    let dist = simd_distance(fromPrim.points.last!, toPrim.points.first!)
    if dist > 0.01 {
        failures.append("boundary prim[\(fromIdx)].last -> prim[\(toIdx)].first distance \(dist) exceeds 0.01")
    }
}

let allPassed = failures.isEmpty

let primSummaryLines = summaries.map { s in
    "  [\(s.index)] \(s.kind): \(s.pointCount) pts, length \(s.length), start \(s.startPoint), end \(s.endPoint)"
}.joined(separator: "\n")

let boundaryResults = adjacentPairs.map { (fromIdx, toIdx) -> BoundaryCheck in
    let fromPrim = primitives[fromIdx]
    let toPrim = primitives[toIdx]
    let dist = simd_distance(fromPrim.points.last!, toPrim.points.first!)
    return BoundaryCheck(
        fromKind: fromPrim.kind, fromIndex: fromIdx,
        fromPoint: fromPrim.points.last!,
        toKind: toPrim.kind, toIndex: toIdx,
        toPoint: toPrim.points.first!,
        distance: dist,
        passed: dist <= 0.01
    )
}

let boundaryLines = boundaryResults.map { b in
    "  prim[\(b.fromIndex)] \(b.fromKind).last -> prim[\(b.toIndex)] \(b.toKind).first: distance \(b.distance) \(b.passed ? "OK" : "FAIL")"
}.joined(separator: "\n")

let summary: [String: Any] = [
    "source": source,
    "pointCount": points.count,
    "primitives": summaries.map { s in
        [
            "kind": s.kind,
            "index": s.index,
            "pointCount": s.pointCount,
            "length": s.length,
            "startPoint": [s.startPoint.x, s.startPoint.y, s.startPoint.z],
            "endPoint": [s.endPoint.x, s.endPoint.y, s.endPoint.z]
        ] as [String: Any]
    },
    "boundaryChecks": boundaryResults.map { b in
        [
            "from": "prim[\(b.fromIndex)] \(b.fromKind).last",
            "to": "prim[\(b.toIndex)] \(b.toKind).first",
            "distance": b.distance,
            "passed": b.passed
        ] as [String: Any]
    },
    "queryPointGrouping": Dictionary(uniqueKeysWithValues: selectionsByPrimitive.map { (key, results) in
        (String(key), [
            "queryPointCount": results.count,
            "selectedPointCount": results[0].selectedPoints.count,
            "selectedLength": openLength(results[0].selectedPoints)
        ] as [String: Any])
    }),
    "passed": allPassed,
    "failures": failures
]

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let encoded = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])

if let output {
    let url = URL(fileURLWithPath: output)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoded.write(to: url, options: .atomic)
}

FileHandle.standardOutput.write(encoded)
FileHandle.standardOutput.write(Data([0x0a]))

print("\nPrimitives:")
print(primSummaryLines)
print("\nBoundaries:")
print(boundaryLines)
print("\n\(allPassed ? "PASS" : "FAIL") — \(failures.count) failure(s)")
if !failures.isEmpty {
    for f in failures {
        print("  - \(f)")
    }
}

exit(allPassed ? 0 : 1)

// MARK: - Shape detection subset

private func capsulePrimitiveGroups(_ rawPoints: [SIMD3<Float>]) -> [PrimitiveGroup]? {
    let points = orderedClosedLoop(dedupe(rawPoints))
    guard points.count >= 12 else { return nil }

    let basis = planeBasis(for: points)
    let projected = project(points, onto: basis)
    let axes = pcaAxes(projected)
    let capsulePoints: [(world: SIMD3<Float>, coord: SIMD2<Float>)] = zip(points, projected).map { pair in
        let point = pair.1
        let relative = point - axes.centroid
        let coord = SIMD2<Float>(simd_dot(relative, axes.major), simd_dot(relative, axes.minor))
        return (world: pair.0, coord: coord)
    }

    let sValues = capsulePoints.map(\.coord.x)
    let tValues = capsulePoints.map(\.coord.y)
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

    var top: [(world: SIMD3<Float>, coord: SIMD2<Float>)] = []
    var bottom: [(world: SIMD3<Float>, coord: SIMD2<Float>)] = []
    var leftCap: [(world: SIMD3<Float>, coord: SIMD2<Float>)] = []
    var rightCap: [(world: SIMD3<Float>, coord: SIMD2<Float>)] = []

    for cp in capsulePoints {
        let s = cp.coord.x
        let t = cp.coord.y
        let yDistTop = abs(t - maxT)
        let yDistBottom = abs(t - minT)
        let xDistLeft = abs(s - leftCenterS)
        let xDistRight = abs(s - rightCenterS)

        let railScale = height
        let capScale = width * 1.5

        let scores: [(zone: String, score: Float)] = [
            ("top", yDistTop / railScale),
            ("bottom", yDistBottom / railScale),
            ("left", xDistLeft / capScale),
            ("right", xDistRight / capScale),
        ]
        guard let best = scores.min(by: { $0.score < $1.score }) else { continue }
        switch best.zone {
        case "top": top.append(cp)
        case "bottom": bottom.append(cp)
        case "left": leftCap.append(cp)
        case "right": rightCap.append(cp)
        default: break
        }
    }

        guard top.count >= 2, bottom.count >= 2, leftCap.count >= 6, rightCap.count >= 6 else {
        return nil
    }

    let topLine = lineGroup(top, ascending: true)
    let right = capGroup(rightCap, center: SIMD2<Float>(rightCenterS, centerT), radius: radius, maxT: maxT, minT: minT, startsAtTop: true)
    let bottomLine = lineGroup(bottom, ascending: false)
    let left = capGroup(leftCap, center: SIMD2<Float>(leftCenterS, centerT), radius: radius, maxT: maxT, minT: minT, startsAtTop: false)

    guard right.kind == "semicircle", left.kind == "semicircle" else {
        return nil
    }

    let correctedRight = PrimitiveGroup(
        kind: right.kind,
        points: [topLine.points.last!] + right.points + [bottomLine.points.first!]
    )
    let correctedLeft = PrimitiveGroup(
        kind: left.kind,
        points: [bottomLine.points.last!] + left.points + [topLine.points.first!]
    )
    return [topLine, correctedRight, bottomLine, correctedLeft]
}

private func selectedPrimitivePoints(primitives: [PrimitiveGroup], nearest snappedPoint: SIMD3<Float>) -> SelectionResult? {
    guard primitives.map(\.kind) == ["line", "semicircle", "line", "semicircle"],
          let selected = primitives.enumerated().min(by: { lhs, rhs in
              primitiveMinDistance(lhs.element, to: snappedPoint) < primitiveMinDistance(rhs.element, to: snappedPoint)
          }),
          selected.element.points.count >= 2 else {
        return nil
    }
    return SelectionResult(
        queryPoint: snappedPoint,
        selectedPrimitiveKind: selected.element.kind,
        selectedPrimitiveIndex: selected.offset,
        selectedPoints: selected.element.points
    )
}

private func primitiveMinDistance(_ primitive: PrimitiveGroup, to point: SIMD3<Float>) -> Float {
    guard primitive.points.count >= 2 else {
        return primitive.points.first.map { simd_distance($0, point) } ?? .greatestFiniteMagnitude
    }
    var best = Float.greatestFiniteMagnitude
    for pair in zip(primitive.points, primitive.points.dropFirst()) {
        best = min(best, pointToSegmentDistance(point, pair.0, pair.1))
    }
    return best
}

private func pointToPrimitiveDistance(_ point: SIMD3<Float>, _ primitive: SIMD3<Float>) -> Float {
    simd_distance(point, primitive)
}

private func pointToSegmentDistance(_ point: SIMD3<Float>, _ start: SIMD3<Float>, _ end: SIMD3<Float>) -> Float {
    let segment = end - start
    let length = simd_length(segment)
    guard length > 0.000001 else { return simd_distance(point, start) }
    let t = simd_dot(point - start, segment) / (length * length)
    let clamped = max(0, min(1, t))
    let projection = start + clamped * segment
    return simd_distance(point, projection)
}

private func lineGroup(_ points: [(world: SIMD3<Float>, coord: SIMD2<Float>)], ascending: Bool) -> PrimitiveGroup {
    let sorted = points.sorted { ascending ? $0.coord.x < $1.coord.x : $0.coord.x > $1.coord.x }
    return PrimitiveGroup(kind: "line", points: sorted.map(\.world))
}

private func capGroup(_ points: [(world: SIMD3<Float>, coord: SIMD2<Float>)], center: SIMD2<Float>, radius: Float, maxT: Float, minT: Float, startsAtTop: Bool) -> PrimitiveGroup {
    let sorted = points.sorted {
        atan2f($0.coord.y - center.y, $0.coord.x - center.x)
            < atan2f($1.coord.y - center.y, $1.coord.x - center.x)
    }
    guard sorted.count >= 3 else {
        return PrimitiveGroup(kind: "arc", points: sorted.map(\.world))
    }

    let angles = sorted.map { atan2f($0.coord.y - center.y, $0.coord.x - center.x) }
    var splitIndex = 0
    var maxGap: Float = -1
    for i in 0..<angles.count {
        let next = (i + 1) % angles.count
        let nextAngle = next == 0 ? angles[0] + (2 * .pi) : angles[next]
        let gap = nextAngle - angles[i]
        if gap > maxGap {
            maxGap = gap
            splitIndex = next
        }
    }
    let ordered = Array(sorted[splitIndex...]) + Array(sorted[..<splitIndex])
    let coords = ordered.map(\.coord)
    let coverage = angularCoverageDegrees(coords, center: center)
    let kind = coverage >= 140 && coverage <= 220 ? "semicircle" : "arc"

    // Orient cap so its first point matches the correct adjacent rail:
    //   If startsAtTop=true (right cap): first point should be closer to maxT
    //   If startsAtTop=false (left cap): first point should be closer to minT
    // If it's currently oriented wrong, reverse
    let firstT = ordered[0].coord.y
    let firstCloserToTop = abs(firstT - maxT) < abs(firstT - minT)
    if startsAtTop != firstCloserToTop {
        let reversed = Array(ordered.reversed())
        let revCoords = reversed.map(\.coord)
        let revCoverage = angularCoverageDegrees(revCoords, center: center)
        let revKind = revCoverage >= 140 && revCoverage <= 220 ? "semicircle" : "arc"
        return PrimitiveGroup(kind: revKind, points: reversed.map(\.world))
    }

    return PrimitiveGroup(kind: kind, points: ordered.map(\.world))
}

// MARK: - Shared geometry helpers

private struct PlaneBasis {
    let origin: SIMD3<Float>
    let u: SIMD3<Float>
    let v: SIMD3<Float>
}

private struct PCAAxes {
    let centroid: SIMD2<Float>
    let major: SIMD2<Float>
    let minor: SIMD2<Float>
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

private func planeBasis(for points: [SIMD3<Float>]) -> PlaneBasis {
    let origin = points.first ?? SIMD3<Float>(0, 0, 0)
    let farthest = points.max(by: { simd_distance(origin, $0) < simd_distance(origin, $1) }) ?? origin
    let u = normalized(farthest - origin, fallback: SIMD3<Float>(1, 0, 0))
    let offAxis = points.max(by: { distanceToLine($0, origin, u) < distanceToLine($1, origin, u) }) ?? origin
    let normal = normalized(simd_cross(u, offAxis - origin), fallback: SIMD3<Float>(0, 1, 0))
    let v = normalized(simd_cross(normal, u), fallback: SIMD3<Float>(0, 0, 1))
    return PlaneBasis(origin: origin, u: u, v: v)
}

private func project(_ points: [SIMD3<Float>], onto basis: PlaneBasis) -> [SIMD2<Float>] {
    points.map { point in
        let relative = point - basis.origin
        return SIMD2<Float>(simd_dot(relative, basis.u), simd_dot(relative, basis.v))
    }
}

private func pcaAxes(_ points: [SIMD2<Float>]) -> PCAAxes {
    let centroid = points.reduce(SIMD2<Float>(0, 0), +) / Float(max(points.count, 1))
    var xx: Float = 0; var xy: Float = 0; var yy: Float = 0
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

private func openLength(_ points: [SIMD3<Float>]) -> Float {
    zip(points, points.dropFirst()).map(simd_distance).reduce(0, +)
}

private func distanceToLine(_ point: SIMD3<Float>, _ linePoint: SIMD3<Float>, _ direction: SIMD3<Float>) -> Float {
    simd_length(simd_cross(point - linePoint, direction))
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
