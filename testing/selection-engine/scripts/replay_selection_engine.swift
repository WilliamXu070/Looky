import Foundation
import simd

private enum SelectionKind: String, Codable {
    case edge
    case surface
    case none
}

private struct PointKey: Hashable, Comparable {
    let x: Int64
    let y: Int64
    let z: Int64

    static func < (lhs: PointKey, rhs: PointKey) -> Bool {
        if lhs.x != rhs.x { return lhs.x < rhs.x }
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        return lhs.z < rhs.z
    }

    var stableDescription: String {
        "\(x),\(y),\(z)"
    }
}

private struct EdgeKey: Hashable {
    let a: PointKey
    let b: PointKey

    var stableDescription: String {
        "\(a.stableDescription)-\(b.stableDescription)"
    }
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

private struct FeatureEdge {
    let key: EdgeKey
    let start: SIMD3<Float>
    let end: SIMD3<Float>
    let triangleIndices: [Int]
}

private struct SurfaceCandidate {
    let entityID: String
    let surfaceID: String
    let seedTriangle: Int
    let triangleIndices: [Int]
    let selectedLabels: [String]
    let nearestFeatureEdgeDistance: Float
    let promotionThreshold: Float
}

private struct EdgeCandidate {
    let entityID: String
    let loopID: String
    let distance: Float
    let threshold: Float
    let start: SIMD3<Float>
    let end: SIMD3<Float>
    let triangleIndices: [Int]
}

private struct ResolverOutcome {
    let kind: SelectionKind
    let entityID: String?
    let surfaceID: String?
    let loopID: String?
    let triangleIndices: [Int]
    let selectedLabels: [String]
    let hitTriangle: Int?
    let hitDistance: Float?
    let snapDistance: Float?
    let edgeCandidate: EdgeCandidate?
    let surfaceCandidate: SurfaceCandidate?
    let rejectedAlternative: CandidateReport?
    let note: String
}

private struct CandidateReport: Codable {
    let kind: SelectionKind
    let entityID: String?
    let surfaceID: String?
    let loopID: String?
    let distance: Float?
    let threshold: Float?
    let triangleCount: Int
    let selectedLabels: [String]
    let reason: String
}

private struct SelectionReport: Codable {
    let kind: SelectionKind
    let entityID: String?
    let surfaceID: String?
    let loopID: String?
    let triangleCount: Int
    let triangleIndices: [Int]
    let selectedLabels: [String]
    let hitTriangle: Int?
    let hitDistance: Float?
    let snapDistance: Float?
    let note: String
}

private struct CaseReport: Codable {
    let name: String
    let fixture: String
    let passed: Bool
    let failures: [String]
    let reason: String
    let hit: [Float]
    let expected: ExpectedReport
    let actual: SelectionReport
    let candidates: CandidateBundleReport
}

private struct ExpectedReport: Codable {
    let kind: SelectionKind
    let surfaceID: String?
    let exactTriangleCount: Int?
    let loopIDRequired: Bool
    let loopIDMatchesCase: String?
    let forbiddenLabels: [String]
}

private struct CandidateBundleReport: Codable {
    let edge: CandidateReport?
    let surface: CandidateReport?
    let rejectedAlternative: CandidateReport?
}

private struct Report: Codable {
    let producedAt: String
    let passed: Bool
    let fixtureVersion: String
    let contract: [String]
    let results: [CaseReport]
}

private struct SelectionFixture {
    let name: String
    let triangles: [Triangle]
}

private struct ExpectedSelection {
    let kind: SelectionKind
    let surfaceID: String?
    let exactTriangleCount: Int?
    let loopIDRequired: Bool
    let loopIDMatchesCase: String?
    let forbiddenLabels: Set<String>

    init(
        kind: SelectionKind,
        surfaceID: String? = nil,
        exactTriangleCount: Int? = nil,
        loopIDRequired: Bool = false,
        loopIDMatchesCase: String? = nil,
        forbiddenLabels: Set<String> = []
    ) {
        self.kind = kind
        self.surfaceID = surfaceID
        self.exactTriangleCount = exactTriangleCount
        self.loopIDRequired = loopIDRequired
        self.loopIDMatchesCase = loopIDMatchesCase
        self.forbiddenLabels = forbiddenLabels
    }
}

private struct SelectionTestCase {
    let name: String
    let fixture: SelectionFixture
    let hit: SIMD3<Float>
    let expected: ExpectedSelection
    let reason: String
}

private final class SelectionEngineHarness {
    let triangles: [Triangle]
    let maxExtent: Float
    let weldTolerance: Float

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
        self.weldTolerance = max(maxExtent * 0.00002, 0.01)
    }

    var edgeSelectionThreshold: Float {
        max(maxExtent * 0.018, 0.35)
    }

    var surfacePromotionThreshold: Float {
        max(maxExtent * 0.00008, 0.003)
    }

    var surfacePlaneTolerance: Float {
        max(maxExtent * 0.00015, 0.004)
    }

    var hitDistanceThreshold: Float {
        max(maxExtent * 0.05, 0.25)
    }

    func resolve(hit point: SIMD3<Float>) -> ResolverOutcome {
        guard let closest = closestTriangle(to: point),
              closest.distance <= hitDistanceThreshold else {
            return ResolverOutcome(
                kind: .none,
                entityID: nil,
                surfaceID: nil,
                loopID: nil,
                triangleIndices: [],
                selectedLabels: [],
                hitTriangle: nil,
                hitDistance: closestTriangle(to: point)?.distance,
                snapDistance: nil,
                edgeCandidate: nil,
                surfaceCandidate: nil,
                rejectedAlternative: nil,
                note: "No geometry hit within the offline resolver hit-distance threshold."
            )
        }

        let edgeCandidate = nearestCreasedEdgeCandidate(to: point)
        let nearestFeatureDistance = nearestSurfaceFeatureEdgeDistance(to: point)
        let surfaceCandidate = nearestFeatureDistance > surfacePromotionThreshold
            ? makeSurfaceCandidate(seedTriangle: closest.index, nearestFeatureDistance: nearestFeatureDistance)
            : nil

        if let edgeCandidate, edgeCandidate.distance <= edgeSelectionThreshold {
            return ResolverOutcome(
                kind: .edge,
                entityID: edgeCandidate.entityID,
                surfaceID: nil,
                loopID: edgeCandidate.loopID,
                triangleIndices: [],
                selectedLabels: [],
                hitTriangle: closest.index,
                hitDistance: closest.distance,
                snapDistance: edgeCandidate.distance,
                edgeCandidate: edgeCandidate,
                surfaceCandidate: surfaceCandidate,
                rejectedAlternative: surfaceCandidate.map {
                    surfaceReport($0, reason: "Surface candidate existed, but the local creased-edge threshold selected edge first.")
                },
                note: "Resolved as edge because a creased feature edge was inside the edge threshold."
            )
        }

        if let surfaceCandidate {
            let labels = labels(for: surfaceCandidate.triangleIndices)
            return ResolverOutcome(
                kind: .surface,
                entityID: surfaceCandidate.entityID,
                surfaceID: surfaceCandidate.surfaceID,
                loopID: nil,
                triangleIndices: surfaceCandidate.triangleIndices,
                selectedLabels: labels,
                hitTriangle: closest.index,
                hitDistance: closest.distance,
                snapDistance: nil,
                edgeCandidate: edgeCandidate,
                surfaceCandidate: surfaceCandidate,
                rejectedAlternative: edgeCandidate.map {
                    edgeReport($0, reason: "Nearest edge candidate was outside the local edge threshold, so surface won.")
                },
                note: "Resolved as surface after edge gating."
            )
        }

        return ResolverOutcome(
            kind: .none,
            entityID: nil,
            surfaceID: nil,
            loopID: nil,
            triangleIndices: [],
            selectedLabels: [],
            hitTriangle: closest.index,
            hitDistance: closest.distance,
            snapDistance: nil,
            edgeCandidate: edgeCandidate,
            surfaceCandidate: nil,
            rejectedAlternative: edgeCandidate.map {
                edgeReport($0, reason: "Edge candidate existed but was outside the local edge threshold.")
            },
            note: "Geometry was hit, but neither edge nor surface selection passed the resolver gates."
        )
    }

    private func makeSurfaceCandidate(seedTriangle: Int, nearestFeatureDistance: Float) -> SurfaceCandidate? {
        let selected = inferredSurfaceTriangles(startingFrom: seedTriangle)
        guard !selected.isEmpty else {
            return nil
        }
        let surfaceID = commonSurfaceID(for: selected)
        return SurfaceCandidate(
            entityID: "surface:\(surfaceID)",
            surfaceID: surfaceID,
            seedTriangle: seedTriangle,
            triangleIndices: selected,
            selectedLabels: labels(for: selected),
            nearestFeatureEdgeDistance: nearestFeatureDistance,
            promotionThreshold: surfacePromotionThreshold
        )
    }

    private func closestTriangle(to point: SIMD3<Float>) -> (index: Int, distance: Float)? {
        var bestIndex: Int?
        var bestDistance = Float.greatestFiniteMagnitude
        for (index, triangle) in triangles.enumerated() {
            let distance = sqrt(pointTriangleDistanceSquared(point, triangle.points[0], triangle.points[1], triangle.points[2]))
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex.map { ($0, bestDistance) }
    }

    private func nearestCreasedEdgeCandidate(to point: SIMD3<Float>) -> EdgeCandidate? {
        let features = creasedFeatureEdges()
        guard !features.isEmpty else {
            return nil
        }

        var best: (feature: FeatureEdge, distance: Float)?
        for feature in features {
            let distance = distance(point, toSegmentFrom: feature.start, to: feature.end)
            if best == nil ||
                distance < best!.distance ||
                (distance == best!.distance && feature.key.stableDescription < best!.feature.key.stableDescription) {
                best = (feature, distance)
            }
        }

        guard let selected = best else {
            return nil
        }
        let loopID = loopID(startingFrom: selected.feature.key, among: features)
        let edgeID = "edge:\(stableHash(selected.feature.key.stableDescription))"
        return EdgeCandidate(
            entityID: edgeID,
            loopID: loopID,
            distance: selected.distance,
            threshold: edgeSelectionThreshold,
            start: selected.feature.start,
            end: selected.feature.end,
            triangleIndices: selected.feature.triangleIndices
        )
    }

    private func nearestSurfaceFeatureEdgeDistance(to point: SIMD3<Float>) -> Float {
        let edges = geometricEdgeBuckets()
            .compactMap { _, entries -> EdgeEntry? in
                guard let first = entries.first, isSurfaceFeatureEdge(entries) else {
                    return nil
                }
                return first
            }

        guard !edges.isEmpty else {
            return Float.greatestFiniteMagnitude
        }

        return edges
            .map { distance(point, toSegmentFrom: $0.start, to: $0.end) }
            .min() ?? Float.greatestFiniteMagnitude
    }

    private func inferredSurfaceTriangles(startingFrom seed: Int) -> [Int] {
        let smooth = smoothSurfaceTriangles(startingFrom: seed)
        guard !smooth.isEmpty else {
            return []
        }
        if isPlanarSurface(triangleIndices: smooth, seed: seed) {
            let expanded = coplanarSurfaceTriangles(matching: seed)
            if expanded.count >= smooth.count {
                return expanded.sorted()
            }
        }
        return smooth.sorted()
    }

    private func smoothSurfaceTriangles(startingFrom seed: Int) -> [Int] {
        guard seed >= 0, seed < triangles.count else {
            return []
        }

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
                guard let entries = edgeBuckets[key],
                      !isSurfaceBoundaryEdge(entries, creaseDegrees: 65) else {
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

        for triangleIndex in triangleIndices {
            let triangle = triangles[triangleIndex]
            guard simd_dot(normal, triangle.normal) >= dotLimit else {
                return false
            }
            for vertex in triangle.points {
                if abs(simd_dot(vertex - point, normal)) > surfacePlaneTolerance {
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

        return triangles.indices.filter { index in
            let triangle = triangles[index]
            guard simd_dot(normal, triangle.normal) >= dotLimit else {
                return false
            }
            return triangle.points.allSatisfy {
                abs(simd_dot($0 - point, normal)) <= surfacePlaneTolerance * 1.5
            }
        }
    }

    private func commonSurfaceID(for triangleIndices: [Int]) -> String {
        let labels = labels(for: triangleIndices)
        if labels.count == 1, let label = labels.first {
            return label
        }
        return "mixed:\(labels.joined(separator: "+"))"
    }

    private func labels(for triangleIndices: [Int]) -> [String] {
        Array(Set(triangleIndices.map { triangles[$0].label })).sorted()
    }

    private func creasedFeatureEdges() -> [FeatureEdge] {
        geometricEdgeBuckets().compactMap { key, entries in
            guard let first = entries.first, isCreasedFeatureEdge(entries, creaseDegrees: 25) else {
                return nil
            }
            return FeatureEdge(
                key: key,
                start: first.start,
                end: first.end,
                triangleIndices: entries.map(\.triangleIndex).sorted()
            )
        }
    }

    private func loopID(startingFrom seed: EdgeKey, among features: [FeatureEdge]) -> String {
        let byKey = Dictionary(uniqueKeysWithValues: features.map { ($0.key, $0) })
        var incident: [PointKey: [EdgeKey]] = [:]
        for feature in features {
            incident[feature.key.a, default: []].append(feature.key)
            incident[feature.key.b, default: []].append(feature.key)
        }

        var component = Set<EdgeKey>()
        var queue = [seed]
        var visited = Set<EdgeKey>()

        while let edge = queue.popLast() {
            guard visited.insert(edge).inserted, byKey[edge] != nil else {
                continue
            }
            component.insert(edge)
            for point in [edge.a, edge.b] {
                for next in incident[point, default: []] where !visited.contains(next) {
                    queue.append(next)
                }
            }
        }

        let signature = component
            .map(\.stableDescription)
            .sorted()
            .joined(separator: "|")
        return "loop:\(stableHash(signature)):edges-\(component.count)"
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

    private func isSurfaceFeatureEdge(_ entries: [EdgeEntry]) -> Bool {
        isSurfaceBoundaryEdge(entries, creaseDegrees: 25)
    }

    private func isSurfaceBoundaryEdge(_ entries: [EdgeEntry], creaseDegrees: Float) -> Bool {
        guard entries.count >= 2 else {
            return true
        }
        return isCreasedFeatureEdge(entries, creaseDegrees: creaseDegrees)
    }

    private func isCreasedFeatureEdge(_ entries: [EdgeEntry], creaseDegrees: Float) -> Bool {
        guard entries.count >= 2 else {
            return false
        }
        let normals = entries.map { triangles[$0.triangleIndex].normal }
        let dotLimit = cosf(creaseDegrees * .pi / 180)
        for i in 0..<normals.count {
            for j in (i + 1)..<normals.count where simd_dot(normals[i], normals[j]) < dotLimit {
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

private func makePlateFixture() -> SelectionFixture {
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
        tri("front-side", SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 0, -1), SIMD3<Float>(2, 0, 0)),
        tri("front-side", SIMD3<Float>(2, 0, 0), SIMD3<Float>(0, 0, -1), SIMD3<Float>(2, 0, -1)),
        tri("front-side", SIMD3<Float>(2, 0, 0), SIMD3<Float>(2, 0, -1), SIMD3<Float>(4, 0, 0)),
        tri("front-side", SIMD3<Float>(4, 0, 0), SIMD3<Float>(2, 0, -1), SIMD3<Float>(4, 0, -1)),
        tri("back-side", SIMD3<Float>(0, 2, 0), SIMD3<Float>(2, 2, 0), SIMD3<Float>(0, 2, -1)),
        tri("back-side", SIMD3<Float>(2, 2, 0), SIMD3<Float>(2, 2, -1), SIMD3<Float>(0, 2, -1)),
        tri("back-side", SIMD3<Float>(2, 2, 0), SIMD3<Float>(4, 2, 0), SIMD3<Float>(2, 2, -1)),
        tri("back-side", SIMD3<Float>(4, 2, 0), SIMD3<Float>(4, 2, -1), SIMD3<Float>(2, 2, -1)),
        tri("left-side", SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, -1)),
        tri("left-side", SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 1, -1), SIMD3<Float>(0, 0, -1)),
        tri("left-side", SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 2, 0), SIMD3<Float>(0, 1, -1)),
        tri("left-side", SIMD3<Float>(0, 2, 0), SIMD3<Float>(0, 2, -1), SIMD3<Float>(0, 1, -1)),
        tri("right-side", SIMD3<Float>(4, 0, 0), SIMD3<Float>(4, 0, -1), SIMD3<Float>(4, 1, 0)),
        tri("right-side", SIMD3<Float>(4, 1, 0), SIMD3<Float>(4, 0, -1), SIMD3<Float>(4, 1, -1)),
        tri("right-side", SIMD3<Float>(4, 1, 0), SIMD3<Float>(4, 1, -1), SIMD3<Float>(4, 2, 0)),
        tri("right-side", SIMD3<Float>(4, 2, 0), SIMD3<Float>(4, 1, -1), SIMD3<Float>(4, 2, -1)),
    ]

    return SelectionFixture(name: "creased-plate", triangles: top + side)
}

private func makeOffsetPlaneFixture() -> SelectionFixture {
    func tri(_ label: String, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Triangle {
        Triangle(label: label, points: [a, b, c])
    }

    let topZ: Float = 0
    let lowerZ: Float = -0.015
    return SelectionFixture(
        name: "nearby-offset-plane",
        triangles: [
            tri("top", SIMD3<Float>(0, 0, topZ), SIMD3<Float>(2, 0, topZ), SIMD3<Float>(0, 2, topZ)),
            tri("top", SIMD3<Float>(2, 0, topZ), SIMD3<Float>(2, 2, topZ), SIMD3<Float>(0, 2, topZ)),
            tri("lower-offset", SIMD3<Float>(2.3, 0, lowerZ), SIMD3<Float>(4.3, 0, lowerZ), SIMD3<Float>(2.3, 2, lowerZ)),
            tri("lower-offset", SIMD3<Float>(4.3, 0, lowerZ), SIMD3<Float>(4.3, 2, lowerZ), SIMD3<Float>(2.3, 2, lowerZ)),
        ]
    )
}

private func makeCylinderFixture() -> SelectionFixture {
    func point(_ x: Float, _ angle: Float) -> SIMD3<Float> {
        SIMD3<Float>(x, cosf(angle), sinf(angle))
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
        triangles.append(tri("cylinder", p00, p10, p01))
        triangles.append(tri("cylinder", p10, p11, p01))
    }

    return SelectionFixture(name: "half-cylinder", triangles: triangles)
}

private func makeRoundedLoopFixture() -> SelectionFixture {
    func tri(_ label: String, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Triangle {
        Triangle(label: label, points: [a, b, c])
    }

    let points = capsuleLoopPoints()
    var triangles: [Triangle] = []
    triangles.reserveCapacity(points.count * 4)

    for index in 0..<points.count {
        let p0 = points[index]
        let p1 = points[(index + 1) % points.count]
        let mid = (p0 + p1) * 0.5
        let outward = normalized(SIMD3<Float>(mid.x, mid.y, 0), fallback: SIMD3<Float>(0, 1, 0))
        let o0 = p0 + outward * 0.35
        let o1 = p1 + outward * 0.35
        let d0 = p0 + SIMD3<Float>(0, 0, -0.5)
        let d1 = p1 + SIMD3<Float>(0, 0, -0.5)

        triangles.append(tri("top-adjacent", p0, p1, o1))
        triangles.append(tri("top-adjacent", p0, o1, o0))
        triangles.append(tri("inner-wall", p0, d0, p1))
        triangles.append(tri("inner-wall", p1, d0, d1))
    }

    return SelectionFixture(name: "rounded-feature-loop", triangles: triangles)
}

private func capsuleLoopPoints() -> [SIMD3<Float>] {
    let radius: Float = 0.5
    let halfLength: Float = 1.1
    let arcSegments = 12
    var points: [SIMD3<Float>] = [
        SIMD3<Float>(-halfLength, radius, 0),
        SIMD3<Float>(halfLength, radius, 0),
    ]

    for step in 1...arcSegments {
        let angle = (.pi / 2) - Float(step) * .pi / Float(arcSegments)
        points.append(SIMD3<Float>(halfLength + radius * cosf(angle), radius * sinf(angle), 0))
    }

    points.append(SIMD3<Float>(-halfLength, -radius, 0))

    for step in 1...arcSegments {
        let angle = (-.pi / 2) - Float(step) * .pi / Float(arcSegments)
        points.append(SIMD3<Float>(-halfLength + radius * cosf(angle), radius * sinf(angle), 0))
    }

    if let first = points.first, let last = points.last, simd_distance(first, last) < 0.0001 {
        points.removeLast()
    }
    return points
}

private func pointTriangleDistanceSquared(
    _ point: SIMD3<Float>,
    _ a: SIMD3<Float>,
    _ b: SIMD3<Float>,
    _ c: SIMD3<Float>
) -> Float {
    let rawNormal = simd_cross(b - a, c - a)
    let length = simd_length(rawNormal)
    guard length > 0 else {
        return min(
            distanceSquared(point, toSegmentFrom: a, to: b),
            distanceSquared(point, toSegmentFrom: b, to: c),
            distanceSquared(point, toSegmentFrom: c, to: a)
        )
    }

    let normal = rawNormal / length
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
    guard abs(denominator) > 0 else {
        return false
    }
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

private func normalized(_ value: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
    let length = simd_length(value)
    return length > 0 ? value / length : fallback
}

private func stableHash(_ value: String) -> String {
    var hash: UInt64 = 1469598103934665603
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1099511628211
    }
    let raw = String(hash, radix: 16)
    return String(repeating: "0", count: max(0, 16 - raw.count)) + raw
}

private func edgeReport(_ candidate: EdgeCandidate, reason: String) -> CandidateReport {
    CandidateReport(
        kind: .edge,
        entityID: candidate.entityID,
        surfaceID: nil,
        loopID: candidate.loopID,
        distance: candidate.distance,
        threshold: candidate.threshold,
        triangleCount: 0,
        selectedLabels: [],
        reason: reason
    )
}

private func surfaceReport(_ candidate: SurfaceCandidate, reason: String) -> CandidateReport {
    CandidateReport(
        kind: .surface,
        entityID: candidate.entityID,
        surfaceID: candidate.surfaceID,
        loopID: nil,
        distance: candidate.nearestFeatureEdgeDistance,
        threshold: candidate.promotionThreshold,
        triangleCount: candidate.triangleIndices.count,
        selectedLabels: candidate.selectedLabels,
        reason: reason
    )
}

private func report(for outcome: ResolverOutcome) -> SelectionReport {
    SelectionReport(
        kind: outcome.kind,
        entityID: outcome.entityID,
        surfaceID: outcome.surfaceID,
        loopID: outcome.loopID,
        triangleCount: outcome.triangleIndices.count,
        triangleIndices: outcome.triangleIndices,
        selectedLabels: outcome.selectedLabels,
        hitTriangle: outcome.hitTriangle,
        hitDistance: outcome.hitDistance,
        snapDistance: outcome.snapDistance,
        note: outcome.note
    )
}

private func evaluate(
    testCase: SelectionTestCase,
    outcome: ResolverOutcome,
    previous: [String: ResolverOutcome]
) -> [String] {
    var failures: [String] = []
    let expected = testCase.expected

    if outcome.kind != expected.kind {
        failures.append("expected kind \(expected.kind.rawValue), got \(outcome.kind.rawValue)")
    }

    if let surfaceID = expected.surfaceID, outcome.surfaceID != surfaceID {
        failures.append("expected surfaceID \(surfaceID), got \(outcome.surfaceID ?? "nil")")
    }

    if let exact = expected.exactTriangleCount, outcome.triangleIndices.count != exact {
        failures.append("expected triangleCount \(exact), got \(outcome.triangleIndices.count)")
    }

    if expected.loopIDRequired && outcome.loopID == nil {
        failures.append("expected non-nil loopID")
    }

    if let matchName = expected.loopIDMatchesCase {
        guard let expectedLoop = previous[matchName]?.loopID else {
            failures.append("reference case \(matchName) did not produce a loopID")
            return failures
        }
        if outcome.loopID != expectedLoop {
            failures.append("expected loopID to match \(matchName), got \(outcome.loopID ?? "nil") vs \(expectedLoop)")
        }
    }

    let forbidden = expected.forbiddenLabels.intersection(outcome.selectedLabels)
    if !forbidden.isEmpty {
        failures.append("selected forbidden labels \(Array(forbidden).sorted())")
    }

    return failures
}

private func run(_ testCase: SelectionTestCase, previous: [String: ResolverOutcome]) -> (CaseReport, ResolverOutcome) {
    let harness = SelectionEngineHarness(triangles: testCase.fixture.triangles)
    let outcome = harness.resolve(hit: testCase.hit)
    let failures = evaluate(testCase: testCase, outcome: outcome, previous: previous)

    let expected = ExpectedReport(
        kind: testCase.expected.kind,
        surfaceID: testCase.expected.surfaceID,
        exactTriangleCount: testCase.expected.exactTriangleCount,
        loopIDRequired: testCase.expected.loopIDRequired,
        loopIDMatchesCase: testCase.expected.loopIDMatchesCase,
        forbiddenLabels: Array(testCase.expected.forbiddenLabels).sorted()
    )

    let candidates = CandidateBundleReport(
        edge: outcome.edgeCandidate.map {
            edgeReport($0, reason: $0.distance <= $0.threshold ? "Inside edge threshold." : "Outside edge threshold.")
        },
        surface: outcome.surfaceCandidate.map {
            surfaceReport($0, reason: "Surface candidate after promotion gate.")
        },
        rejectedAlternative: outcome.rejectedAlternative
    )

    return (
        CaseReport(
            name: testCase.name,
            fixture: testCase.fixture.name,
            passed: failures.isEmpty,
            failures: failures,
            reason: testCase.reason,
            hit: testCase.hit.asArray(),
            expected: expected,
            actual: report(for: outcome),
            candidates: candidates
        ),
        outcome
    )
}

private extension SIMD3 where Scalar == Float {
    func asArray() -> [Float] {
        [x, y, z]
    }
}

private let plate = makePlateFixture()
private let offsetPlane = makeOffsetPlaneFixture()
private let cylinder = makeCylinderFixture()
private let roundedLoop = makeRoundedLoopFixture()

private let cases: [SelectionTestCase] = [
    SelectionTestCase(
        name: "center-face-resolves-surface",
        fixture: plate,
        hit: SIMD3<Float>(2.0, 1.0, 0.0),
        expected: ExpectedSelection(kind: .surface, surfaceID: "top", exactTriangleCount: 8),
        reason: "A click comfortably inside a planar face should select the whole bounded surface."
    ),
    SelectionTestCase(
        name: "near-feature-edge-resolves-edge",
        fixture: plate,
        hit: SIMD3<Float>(0.02, 1.0, 0.0),
        expected: ExpectedSelection(kind: .edge, loopIDRequired: true),
        reason: "A click near a creased feature edge should stay edge selection, even when a surface candidate exists."
    ),
    SelectionTestCase(
        name: "offset-plane-does-not-merge",
        fixture: offsetPlane,
        hit: SIMD3<Float>(1.0, 1.0, 0.0),
        expected: ExpectedSelection(
            kind: .surface,
            surfaceID: "top",
            exactTriangleCount: 2,
            forbiddenLabels: ["lower-offset"]
        ),
        reason: "A recessed parallel plane must not be swallowed into the selected top surface."
    ),
    SelectionTestCase(
        name: "curved-cylinder-resolves-complete-surface",
        fixture: cylinder,
        hit: SIMD3<Float>(2.0, 0.0, 1.0),
        expected: ExpectedSelection(kind: .surface, surfaceID: "cylinder", exactTriangleCount: 24),
        reason: "A smooth cylindrical patch should select the full curved surface, not one triangle island."
    ),
    SelectionTestCase(
        name: "far-blank-click-resolves-none",
        fixture: plate,
        hit: SIMD3<Float>(20.0, 20.0, 5.0),
        expected: ExpectedSelection(kind: .none),
        reason: "A far click with no geometry hit must not jump to a distant feature edge."
    ),
    SelectionTestCase(
        name: "rounded-feature-top-adjacent-edge",
        fixture: roundedLoop,
        hit: SIMD3<Float>(0.0, 0.53, 0.0),
        expected: ExpectedSelection(kind: .edge, loopIDRequired: true),
        reason: "The rounded feature loop should produce a stable loop ID when selected from the top-adjacent face."
    ),
    SelectionTestCase(
        name: "rounded-feature-wall-adjacent-edge-same-loop-id",
        fixture: roundedLoop,
        hit: SIMD3<Float>(0.0, 0.5, -0.12),
        expected: ExpectedSelection(
            kind: .edge,
            loopIDRequired: true,
            loopIDMatchesCase: "rounded-feature-top-adjacent-edge"
        ),
        reason: "The same rounded feature selected from the adjacent wall should resolve to the same loop ID."
    ),
]

private var reports: [CaseReport] = []
private var previousOutcomes: [String: ResolverOutcome] = [:]

for testCase in cases {
    let result = run(testCase, previous: previousOutcomes)
    reports.append(result.0)
    previousOutcomes[testCase.name] = result.1
}

private let outputPath = CommandLine.arguments.dropFirst().first ?? "testing/selection-engine/reports/latest.json"
private let outputURL = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

private let reportPayload = Report(
    producedAt: ISO8601DateFormatter().string(from: Date()),
    passed: reports.allSatisfy(\.passed),
    fixtureVersion: "selection-engine-golden-v1",
    contract: [
        "No geometry hit resolves to none; it must not jump to the nearest distant feature.",
        "Creased feature edges inside the local edge threshold resolve as edge before surface.",
        "Face clicks outside the local edge gate promote to bounded surface patches.",
        "Planar patches may merge across same-plane islands but not nearby offset planes.",
        "Smooth cylindrical-style patches select as complete curved surfaces.",
        "The same rounded feature selected from adjacent surfaces keeps a stable loop ID.",
    ],
    results: reports
)

private let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(reportPayload).write(to: outputURL, options: .atomic)

print("selection-engine report: \(outputURL.path)")
print(reportPayload.passed ? "PASS" : "FAIL")
exit(reportPayload.passed ? 0 : 1)
