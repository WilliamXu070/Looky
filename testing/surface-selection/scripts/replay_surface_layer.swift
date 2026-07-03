import Foundation
import simd

private struct PointKey: Hashable, Comparable {
    let x: Int64
    let y: Int64
    let z: Int64

    static func < (lhs: PointKey, rhs: PointKey) -> Bool {
        if lhs.x != rhs.x { return lhs.x < rhs.x }
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        return lhs.z < rhs.z
    }
}

private struct EdgeKey: Hashable {
    let a: PointKey
    let b: PointKey
}

private struct Triangle {
    let label: String
    let points: [SIMD3<Float>]

    var normal: SIMD3<Float> {
        let raw = simd_cross(points[1] - points[0], points[2] - points[0])
        let length = simd_length(raw)
        return length > 0 ? raw / length : SIMD3<Float>(0, 0, 1)
    }

    var localEdges: [(SIMD3<Float>, SIMD3<Float>)] {
        [
            (points[0], points[1]),
            (points[1], points[2]),
            (points[2], points[0]),
        ]
    }
}

private struct EdgeEntry {
    let triangleIndex: Int
    let start: SIMD3<Float>
    let end: SIMD3<Float>
}

private struct SelectionResult: Codable {
    let name: String
    let passed: Bool
    let reason: String
    let promotedToSurface: Bool
    let selectedTriangleCount: Int
    let expectedTriangleCount: Int
    let selectedLabels: [String]
    let nearestFeatureEdgeDistance: Float
    let promotionThreshold: Float
}

private struct Report: Codable {
    let producedAt: String
    let passed: Bool
    let fixture: String
    let notes: [String]
    let results: [SelectionResult]
}

private final class SurfaceLayerHarness {
    let triangles: [Triangle]
    let maxExtent: Float
    let weldTolerance: Float
    let edgeAngleDegrees: Float = 25

    init(triangles: [Triangle]) {
        self.triangles = triangles
        let allPoints = triangles.flatMap(\.points)
        let minPoint = allPoints.reduce(SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)) {
            SIMD3<Float>(min($0.x, $1.x), min($0.y, $1.y), min($0.z, $1.z))
        }
        let maxPoint = allPoints.reduce(SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)) {
            SIMD3<Float>(max($0.x, $1.x), max($0.y, $1.y), max($0.z, $1.z))
        }
        self.maxExtent = simd_length(maxPoint - minPoint)
        self.weldTolerance = max(maxExtent * 0.00002, 0.000001)
    }

    var promotionThreshold: Float {
        max(maxExtent * 0.00008, 0.001)
    }

    var surfacePlaneTolerance: Float {
        max(maxExtent * 0.00015, 0.000001)
    }

    func selectSurface(from hit: SIMD3<Float>) -> (promoted: Bool, selected: [Int], nearestEdgeDistance: Float) {
        let nearestDistance = nearestFeatureEdgeDistance(to: hit)
        guard nearestDistance > promotionThreshold,
              let seed = closestTriangleIndex(to: hit) else {
            return (false, [], nearestDistance)
        }
        return (true, inferredSurfaceTriangles(startingFrom: seed), nearestDistance)
    }

    private func closestTriangleIndex(to point: SIMD3<Float>) -> Int? {
        var bestIndex: Int?
        var bestDistance = Float.greatestFiniteMagnitude
        for (index, triangle) in triangles.enumerated() {
            let distance = pointTriangleDistanceSquared(point, triangle.points[0], triangle.points[1], triangle.points[2])
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    private func nearestFeatureEdgeDistance(to point: SIMD3<Float>) -> Float {
        geometricEdgeBuckets()
            .values
            .filter(isFeatureEdge)
            .flatMap { $0.prefix(1) }
            .map { distance(point, toSegmentFrom: $0.start, to: $0.end) }
            .min() ?? Float.greatestFiniteMagnitude
    }

    private func connectedSurfaceTriangles(startingFrom seed: Int) -> [Int] {
        let edgeBuckets = geometricEdgeBuckets()
        var result: [Int] = []
        var queue = [seed]
        var cursor = 0
        var visited = Set<Int>([seed])

        while cursor < queue.count {
            let triangleIndex = queue[cursor]
            cursor += 1
            result.append(triangleIndex)

            for edge in triangles[triangleIndex].localEdges {
                let key = geometricEdgeKey(from: edge.0, to: edge.1)
                guard let entries = edgeBuckets[key], !isFeatureEdge(entries) else {
                    continue
                }
                for entry in entries where entry.triangleIndex != triangleIndex {
                    if visited.insert(entry.triangleIndex).inserted {
                        queue.append(entry.triangleIndex)
                    }
                }
            }
        }

        return result.sorted()
    }

    private func inferredSurfaceTriangles(startingFrom seed: Int) -> [Int] {
        let smooth = smoothSurfaceTriangles(startingFrom: seed)
        guard !smooth.isEmpty else { return [] }
        return smooth.sorted()
    }

    private func smoothSurfaceTriangles(startingFrom seed: Int) -> [Int] {
        let edgeBuckets = geometricEdgeBuckets()
        var result: [Int] = []
        var queue = [seed]
        var cursor = 0
        var visited = Set<Int>([seed])

        while cursor < queue.count {
            let triangleIndex = queue[cursor]
            cursor += 1
            result.append(triangleIndex)

            for edge in triangles[triangleIndex].localEdges {
                let key = geometricEdgeKey(from: edge.0, to: edge.1)
                guard let entries = edgeBuckets[key], !isBoundaryEdge(entries, creaseDegrees: 65) else {
                    continue
                }
                for entry in entries where entry.triangleIndex != triangleIndex {
                    if visited.insert(entry.triangleIndex).inserted {
                        queue.append(entry.triangleIndex)
                    }
                }
            }
        }

        return result
    }

    private func isPlanarSurface(triangleIndices: [Int], seed: Int) -> Bool {
        let seedTriangle = triangles[seed]
        let normal = seedTriangle.normal
        let point = seedTriangle.points[0]
        let dotLimit = cosf(7 * .pi / 180)
        let tolerance = surfacePlaneTolerance

        for triangleIndex in triangleIndices {
            let triangle = triangles[triangleIndex]
            guard simd_dot(normal, triangle.normal) >= dotLimit else {
                return false
            }
            for vertex in triangle.points {
                if abs(simd_dot(vertex - point, normal)) > tolerance {
                    return false
                }
            }
        }
        return true
    }

    private func coplanarSurfaceTriangles(matching seed: Int) -> [Int] {
        let seedTriangle = triangles[seed]
        let normal = seedTriangle.normal
        let point = seedTriangle.points[0]
        let dotLimit = cosf(7 * .pi / 180)
        let tolerance = surfacePlaneTolerance

        return triangles.indices.filter { index in
            let triangle = triangles[index]
            guard simd_dot(normal, triangle.normal) >= dotLimit else {
                return false
            }
            return triangle.points.allSatisfy { abs(simd_dot($0 - point, normal)) <= tolerance * 1.5 }
        }
    }

    private func geometricEdgeBuckets() -> [EdgeKey: [EdgeEntry]] {
        var buckets: [EdgeKey: [EdgeEntry]] = [:]
        for (triangleIndex, triangle) in triangles.enumerated() {
            for edge in triangle.localEdges {
                buckets[geometricEdgeKey(from: edge.0, to: edge.1), default: []].append(
                    EdgeEntry(triangleIndex: triangleIndex, start: edge.0, end: edge.1)
                )
            }
        }
        return buckets
    }

    private func isFeatureEdge(_ entries: [EdgeEntry]) -> Bool {
        isBoundaryEdge(entries, creaseDegrees: edgeAngleDegrees)
    }

    private func isBoundaryEdge(_ entries: [EdgeEntry], creaseDegrees: Float) -> Bool {
        guard entries.count >= 2 else {
            return true
        }
        let normals = entries.map { triangles[$0.triangleIndex].normal }
        let creaseDotLimit = cosf(creaseDegrees * .pi / 180)
        for i in 0..<normals.count {
            for j in (i + 1)..<normals.count where simd_dot(normals[i], normals[j]) < creaseDotLimit {
                return true
            }
        }
        return false
    }

    private func geometricEdgeKey(from start: SIMD3<Float>, to end: SIMD3<Float>) -> EdgeKey {
        let first = quantized(start)
        let second = quantized(end)
        return second < first ? EdgeKey(a: second, b: first) : EdgeKey(a: first, b: second)
    }

    private func quantized(_ point: SIMD3<Float>) -> PointKey {
        PointKey(
            x: Int64((point.x / weldTolerance).rounded()),
            y: Int64((point.y / weldTolerance).rounded()),
            z: Int64((point.z / weldTolerance).rounded())
        )
    }
}

private func makeFixture() -> [Triangle] {
    func tri(_ label: String, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Triangle {
        Triangle(label: label, points: [a, b, c])
    }

    let z: Float = 0
    let top: [Triangle] = [
        tri("top", SIMD3<Float>(0, 0, z), SIMD3<Float>(2, 0, z), SIMD3<Float>(0, 1, z)),
        tri("top", SIMD3<Float>(2, 0, z), SIMD3<Float>(2, 1, z), SIMD3<Float>(0, 1, z)),
        tri("top", SIMD3<Float>(2, 0, z), SIMD3<Float>(4, 0, z), SIMD3<Float>(2, 1, z)),
        tri("top", SIMD3<Float>(4, 0, z), SIMD3<Float>(4, 1, z), SIMD3<Float>(2, 1, z)),
        tri("top", SIMD3<Float>(0, 1, z), SIMD3<Float>(2, 1, z), SIMD3<Float>(0, 2, z)),
        tri("top", SIMD3<Float>(2, 1, z), SIMD3<Float>(2, 2, z), SIMD3<Float>(0, 2, z)),
        tri("top", SIMD3<Float>(2, 1, z), SIMD3<Float>(4, 1, z), SIMD3<Float>(2, 2, z)),
        tri("top", SIMD3<Float>(4, 1, z), SIMD3<Float>(4, 2, z), SIMD3<Float>(2, 2, z)),
    ]

    let side: [Triangle] = [
        tri("front-side", SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 0, -1), SIMD3<Float>(4, 0, 0)),
        tri("front-side", SIMD3<Float>(4, 0, 0), SIMD3<Float>(0, 0, -1), SIMD3<Float>(4, 0, -1)),
        tri("back-side", SIMD3<Float>(0, 2, 0), SIMD3<Float>(4, 2, 0), SIMD3<Float>(0, 2, -1)),
        tri("back-side", SIMD3<Float>(4, 2, 0), SIMD3<Float>(4, 2, -1), SIMD3<Float>(0, 2, -1)),
        tri("left-side", SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 2, 0), SIMD3<Float>(0, 0, -1)),
        tri("left-side", SIMD3<Float>(0, 2, 0), SIMD3<Float>(0, 2, -1), SIMD3<Float>(0, 0, -1)),
        tri("right-side", SIMD3<Float>(4, 0, 0), SIMD3<Float>(4, 0, -1), SIMD3<Float>(4, 2, 0)),
        tri("right-side", SIMD3<Float>(4, 2, 0), SIMD3<Float>(4, 0, -1), SIMD3<Float>(4, 2, -1)),
    ]

    return top + side
}

private func makeSplitCoplanarFixture() -> [Triangle] {
    func tri(_ label: String, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Triangle {
        Triangle(label: label, points: [a, b, c])
    }

    let z: Float = 0
    return [
        tri("top-left", SIMD3<Float>(0, 0, z), SIMD3<Float>(2, 0, z), SIMD3<Float>(0, 2, z)),
        tri("top-left", SIMD3<Float>(2, 0, z), SIMD3<Float>(2, 2, z), SIMD3<Float>(0, 2, z)),
        tri("top-right", SIMD3<Float>(2.05, 0, z), SIMD3<Float>(4.05, 0, z), SIMD3<Float>(2.05, 2, z)),
        tri("top-right", SIMD3<Float>(4.05, 0, z), SIMD3<Float>(4.05, 2, z), SIMD3<Float>(2.05, 2, z)),
        tri("side", SIMD3<Float>(0, 0, z), SIMD3<Float>(0, 0, -1), SIMD3<Float>(2, 0, z)),
        tri("side", SIMD3<Float>(2, 0, z), SIMD3<Float>(0, 0, -1), SIMD3<Float>(2, 0, -1)),
        tri("side", SIMD3<Float>(2.05, 0, z), SIMD3<Float>(2.05, 0, -1), SIMD3<Float>(4.05, 0, z)),
        tri("side", SIMD3<Float>(4.05, 0, z), SIMD3<Float>(2.05, 0, -1), SIMD3<Float>(4.05, 0, -1)),
    ]
}

private func makeOffsetPlaneFixture() -> [Triangle] {
    func tri(_ label: String, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Triangle {
        Triangle(label: label, points: [a, b, c])
    }

    let topZ: Float = 0
    let lowerZ: Float = -0.015
    return [
        tri("top", SIMD3<Float>(0, 0, topZ), SIMD3<Float>(2, 0, topZ), SIMD3<Float>(0, 2, topZ)),
        tri("top", SIMD3<Float>(2, 0, topZ), SIMD3<Float>(2, 2, topZ), SIMD3<Float>(0, 2, topZ)),
        tri("lower-offset", SIMD3<Float>(2.3, 0, lowerZ), SIMD3<Float>(4.3, 0, lowerZ), SIMD3<Float>(2.3, 2, lowerZ)),
        tri("lower-offset", SIMD3<Float>(4.3, 0, lowerZ), SIMD3<Float>(4.3, 2, lowerZ), SIMD3<Float>(2.3, 2, lowerZ)),
    ]
}

private func makeHalfCylinderFixture() -> [Triangle] {
    makeRuledSurfaceFixture(label: "cylinder", radiusAtStart: 1.0, radiusAtEnd: 1.0)
}

private func makeSmallInternalCylinderFixture() -> [Triangle] {
    func point(_ z: Float, _ angle: Float) -> SIMD3<Float> {
        let radius: Float = 0.00635
        let cx: Float = 0.0254
        let cy: Float = 0.0127
        return SIMD3<Float>(
            cx + radius * cosf(angle),
            cy + radius * sinf(angle),
            z
        )
    }

    func tri(_ label: String, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Triangle {
        Triangle(label: label, points: [a, b, c])
    }

    let segments = 64
    let z0: Float = 0
    let z1: Float = 0.0254
    var triangles: [Triangle] = []
    triangles.reserveCapacity(segments * 2)

    for index in 0..<segments {
        let a0 = Float(index) * 2 * .pi / Float(segments)
        let a1 = Float(index + 1) * 2 * .pi / Float(segments)
        let p00 = point(z0, a0)
        let p10 = point(z1, a0)
        let p01 = point(z0, a1)
        let p11 = point(z1, a1)
        triangles.append(tri("internal-cylinder", p00, p10, p01))
        triangles.append(tri("internal-cylinder", p10, p11, p01))
    }

    return triangles
}

private func makeConeFixture() -> [Triangle] {
    makeRuledSurfaceFixture(label: "cone", radiusAtStart: 1.0, radiusAtEnd: 0.45)
}

private func makeRuledSurfaceFixture(label: String, radiusAtStart: Float, radiusAtEnd: Float) -> [Triangle] {
    func point(_ x: Float, _ angle: Float) -> SIMD3<Float> {
        let t = x / 4.0
        let radius = radiusAtStart + (radiusAtEnd - radiusAtStart) * t
        return SIMD3<Float>(x, radius * cosf(angle), radius * sinf(angle))
    }

    func tri(_ label: String, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Triangle {
        Triangle(label: label, points: [a, b, c])
    }

    let segments = 12
    var triangles: [Triangle] = []
    triangles.reserveCapacity(segments * 2)

    for index in 0..<segments {
        let a0 = Float(index) * .pi / Float(segments)
        let a1 = Float(index + 1) * .pi / Float(segments)
        let p00 = point(0, a0)
        let p10 = point(4, a0)
        let p01 = point(0, a1)
        let p11 = point(4, a1)
        triangles.append(tri(label, p00, p10, p01))
        triangles.append(tri(label, p10, p11, p01))
    }

    return triangles
}

private func pointTriangleDistanceSquared(
    _ point: SIMD3<Float>,
    _ a: SIMD3<Float>,
    _ b: SIMD3<Float>,
    _ c: SIMD3<Float>
) -> Float {
    let normal = simd_normalize(simd_cross(b - a, c - a))
    let projected = point - normal * simd_dot(point - a, normal)
    if pointInTriangle(projected, a, b, c) {
        return simd_length_squared(point - projected)
    }
    return min(
        distanceSquared(point, toSegmentFrom: a, to: b),
        distanceSquared(point, toSegmentFrom: b, to: c),
        distanceSquared(point, toSegmentFrom: c, to: a)
    )
}

private func pointInTriangle(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Bool {
    let v0 = c - a
    let v1 = b - a
    let v2 = p - a
    let dot00 = simd_dot(v0, v0)
    let dot01 = simd_dot(v0, v1)
    let dot02 = simd_dot(v0, v2)
    let dot11 = simd_dot(v1, v1)
    let dot12 = simd_dot(v1, v2)
    let denominator = dot00 * dot11 - dot01 * dot01
    guard abs(denominator) > 0 else { return false }
    let inv = 1 / denominator
    let u = (dot11 * dot02 - dot01 * dot12) * inv
    let v = (dot00 * dot12 - dot01 * dot02) * inv
    return u >= -0.0001 && v >= -0.0001 && (u + v) <= 1.0001
}

private func distance(_ point: SIMD3<Float>, toSegmentFrom a: SIMD3<Float>, to b: SIMD3<Float>) -> Float {
    sqrt(distanceSquared(point, toSegmentFrom: a, to: b))
}

private func distanceSquared(_ point: SIMD3<Float>, toSegmentFrom a: SIMD3<Float>, to b: SIMD3<Float>) -> Float {
    let ab = b - a
    let denominator = simd_dot(ab, ab)
    let t = denominator > 0 ? max(0, min(1, simd_dot(point - a, ab) / denominator)) : 0
    let projected = a + ab * t
    return simd_length_squared(point - projected)
}

private let outputPath = CommandLine.arguments.dropFirst().first ?? "testing/surface-selection/reports/latest.json"

private struct SurfaceTestCase {
    let name: String
    let triangles: [Triangle]
    let hit: SIMD3<Float>
    let promoted: Bool
    let expectedLabel: String?
    let reason: String
}

private func expectedIndices(in harness: SurfaceLayerHarness, label: String?) -> [Int] {
    guard let label else {
        return []
    }
    return harness.triangles.enumerated().filter { $0.element.label == label }.map(\.offset)
}

private func run(_ testCase: SurfaceTestCase) -> SelectionResult {
    let harness = SurfaceLayerHarness(triangles: testCase.triangles)
    let expected = expectedIndices(in: harness, label: testCase.expectedLabel)
    let selection = harness.selectSurface(from: testCase.hit)
    let selectedLabels = selection.selected.map { harness.triangles[$0].label }
    let selectedSet = Set(selection.selected)
    let expectedSet = Set(expected)
    let passed = selection.promoted == testCase.promoted && selectedSet == expectedSet
    let reason = passed
        ? testCase.reason
        : "expected promoted=\(testCase.promoted) triangles=\(expected), got promoted=\(selection.promoted) triangles=\(selection.selected)"
    return SelectionResult(
        name: testCase.name,
        passed: passed,
        reason: reason,
        promotedToSurface: selection.promoted,
        selectedTriangleCount: selection.selected.count,
        expectedTriangleCount: expected.count,
        selectedLabels: selectedLabels,
        nearestFeatureEdgeDistance: selection.nearestEdgeDistance,
        promotionThreshold: harness.promotionThreshold
    )
}

private let cases: [SurfaceTestCase] = [
    SurfaceTestCase(
        name: "center-top-face-promotes-to-whole-surface",
        triangles: makeFixture(),
        hit: SIMD3<Float>(2.0, 1.0, 0.0),
        promoted: true,
        expectedLabel: "top",
        reason: "A click comfortably inside the top face should select every connected top triangle."
    ),
    SurfaceTestCase(
        name: "near-feature-edge-stays-edge-selection",
        triangles: makeFixture(),
        hit: SIMD3<Float>(0.001, 1.0, 0.0),
        promoted: false,
        expectedLabel: nil,
        reason: "A click close to a feature edge must not promote to surface selection."
    ),
    SurfaceTestCase(
        name: "off-center-top-face-still-bounded-to-top",
        triangles: makeFixture(),
        hit: SIMD3<Float>(3.3, 1.4, 0.0),
        promoted: true,
        expectedLabel: "top",
        reason: "The selected surface must not leak into side triangles even with duplicated vertices."
    ),
    SurfaceTestCase(
        name: "disconnected-coplanar-island-stays-bounded",
        triangles: makeSplitCoplanarFixture(),
        hit: SIMD3<Float>(1.0, 1.0, 0.0),
        promoted: true,
        expectedLabel: "top-left",
        reason: "A same-plane mesh island separated by a real boundary gap must not be selected without adjacency evidence."
    ),
    SurfaceTestCase(
        name: "nearby-offset-plane-does-not-join-top-surface",
        triangles: makeOffsetPlaneFixture(),
        hit: SIMD3<Float>(1.0, 1.0, 0.0),
        promoted: true,
        expectedLabel: "top",
        reason: "A nearby recessed or lower parallel plane must not be grouped into the selected top face."
    ),
    SurfaceTestCase(
        name: "half-cylinder-selects-complete-curved-surface",
        triangles: makeHalfCylinderFixture(),
        hit: SIMD3<Float>(2.0, 0.0, 1.0),
        promoted: true,
        expectedLabel: "cylinder",
        reason: "A click on a cylindrical mesh surface should recover the full smooth cylindrical patch."
    ),
    SurfaceTestCase(
        name: "small-internal-cylinder-selects-complete-curved-surface",
        triangles: makeSmallInternalCylinderFixture(),
        hit: SIMD3<Float>(0.03175, 0.0127, 0.0127),
        promoted: true,
        expectedLabel: "internal-cylinder",
        reason: "A cube-hole-scale internal cylinder must not fragment under absolute weld tolerances."
    ),
    SurfaceTestCase(
        name: "tapered-cone-selects-complete-curved-surface",
        triangles: makeConeFixture(),
        hit: SIMD3<Float>(2.0, 0.0, 0.725),
        promoted: true,
        expectedLabel: "cone",
        reason: "A click on a conical mesh surface should recover the full smooth conical patch."
    ),
]

private let results = cases.map(run)

private let report = Report(
    producedAt: ISO8601DateFormatter().string(from: Date()),
    passed: results.allSatisfy(\.passed),
    fixture: "duplicated-vertex-plate-with-creased-side-faces",
    notes: [
        "This validates the surface layer in isolation, before GUI click automation.",
        "The fixture duplicates triangle vertices, matching STEP-style tessellation where vertex-ID adjacency can fail.",
        "Inferred surface traversal may cross smooth/non-feature edges but must stop at boundary or crease feature edges.",
        "Planar and curved surfaces stay bounded to welded smooth patches; disconnected same-plane islands require real adjacency evidence.",
        "The small internal-cylinder case guards against absolute tolerance floors that are larger than the repo cube-hole radius.",
    ],
    results: results
)

private let outputURL = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(report).write(to: outputURL)
print("surface-layer report: \(outputURL.path)")
print(report.passed ? "PASS" : "FAIL")
exit(report.passed ? 0 : 1)
