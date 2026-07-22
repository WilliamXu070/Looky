import AppKit
import Foundation
import SceneKit
import simd

struct ProbeRecord: Codable {
    let producedAt: String
    let modelHint: String
    let sceneNodeName: String
    let chainKind: String
    let selectedTriangle: Int
    let selectedEdge: [Int]
    let hitLocalPoint: [Float]
    let hitWorldPoint: [Float]
    let hitWorldNormal: [Float]
    let snappedPoint: [Float]
    let snapDistance: Float
    let isExactEdge: Bool
    let visitedTriangles: Int
    let connectedFeatureVertices: [[Float]]
    let connectedFeatureSegments: [[Int]]
    let surroundingTriangles: [ProbeTriangleRecord]
}

struct ProbeTriangleRecord: Codable {
    let indices: [Int]
    let points: [[Float]]
}

extension SIMD3 where Scalar == Float {
    func asArray() -> [Float] {
        [x, y, z]
    }
}

struct EdgeChain {
    let points: [SIMD3<Float>]
    let kind: String
}

struct EdgeKey: Hashable {
    let a: Int
    let b: Int

    init(_ first: Int, _ second: Int) {
        if first < second {
            a = first
            b = second
        } else {
            a = second
            b = first
        }
    }

    func otherVertex(from vertex: Int) -> Int? {
        if vertex == a {
            return b
        }
        if vertex == b {
            return a
        }
        return nil
    }
}

struct MeshTriangle {
    let indices: [Int]
    let normal: SIMD3<Float>
    var neighborTriangleIndices: [Int] = []

    var edgeKeys: [EdgeKey] {
        [
            EdgeKey(indices[0], indices[1]),
            EdgeKey(indices[1], indices[2]),
            EdgeKey(indices[2], indices[0]),
        ]
    }

    func localEdges(in vertices: [SIMD3<Float>]) -> [(SIMD3<Float>, SIMD3<Float>)] {
        [
            (vertices[indices[0]], vertices[indices[1]]),
            (vertices[indices[1]], vertices[indices[2]]),
            (vertices[indices[2]], vertices[indices[0]]),
        ]
    }
}

struct MeshEdge {
    let a: Int
    let b: Int
    var triangleIndices: [Int] = []
    var displayNormal = SIMD3<Float>(0, 1, 0)
    var isFeatureEdge = false
}

struct EdgePrimitiveIndex {
    let vertices: [SIMD3<Float>]
    private(set) var triangles: [MeshTriangle]
    private(set) var edges: [EdgeKey: MeshEdge]
    let maxExtent: Float
    let arcFitToleranceMultiplier: Float
    let minimumLineLengthScale: Float
    let minimumArcLengthScale: Float
    let lineDeviationDegrees: Float
    let minimumArcSweepDegrees: Float
    let arcRansacIterations: Int
    let minimumArcInlierRatio: Float
    let arcInlierGapAllowance: Int
    let minimumArcCoverage: Float

    var minimumLineLength: Float {
        max(maxExtent * minimumLineLengthScale, 2.0)
    }

    var minimumArcLength: Float {
        max(maxExtent * minimumArcLengthScale, 2.5)
    }

    var minimumArcSweep: Float {
        minimumArcSweepDegrees * .pi / 180.0
    }

    init(selectionModel: SelectionModel, settings: EdgeFitSettings = .init()) {
        vertices = selectionModel.vertices
        triangles = selectionModel.triangles.map { triangle in
            MeshTriangle(
                indices: triangle.vertexIndices,
                normal: triangle.normal,
                neighborTriangleIndices: triangle.neighborTriangleIDs.map(\.rawValue)
            )
        }
        edges = Dictionary(uniqueKeysWithValues: selectionModel.edges.map { edge in
            (
                EdgeKey(edge.a, edge.b),
                MeshEdge(
                    a: edge.a,
                    b: edge.b,
                    triangleIndices: edge.triangleIDs.map(\.rawValue),
                    displayNormal: edge.displayNormal,
                    isFeatureEdge: edge.isFeatureEdge || edge.isWeldedFeatureEdge
                )
            )
        })
        maxExtent = selectionModel.maxExtent
        self.arcFitToleranceMultiplier = max(settings.arcToleranceMultiplier, 1.0)
        self.minimumLineLengthScale = max(0.0005, settings.minimumLineLengthScale)
        self.minimumArcLengthScale = max(0.0005, settings.minimumArcLengthScale)
        self.lineDeviationDegrees = max(0.001, settings.lineDeviationDegrees)
        self.minimumArcSweepDegrees = max(settings.minimumArcSweepDegrees, 1.0)
        self.minimumArcCoverage = max(0.4, min(settings.minimumArcCoverage, 1.0))
        self.arcRansacIterations = min(max(settings.arcRansacIterations, 12), 240)
        self.minimumArcInlierRatio = max(0.55, min(settings.minimumArcInlierRatio, 0.99))
        self.arcInlierGapAllowance = max(0, settings.arcInlierGapAllowance)
    }

    var minimumArcSeedPointCount: Int { 5 }

    var minimumArcPointCount: Int {
        max(minimumArcSeedPointCount + 2, Int(maxExtent * 0.0005))
    }

    func closestTriangleIndex(to point: SIMD3<Float>) -> Int? {
        var bestIndex: Int?
        var bestDistance = Float.greatestFiniteMagnitude

        for (index, triangle) in triangles.enumerated() {
            let a = vertices[triangle.indices[0]]
            let b = vertices[triangle.indices[1]]
            let c = vertices[triangle.indices[2]]
            let distance = SelectionGeometryMath.pointTriangleDistanceSquared(point, a, b, c)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }

        return bestIndex
    }

    func edgeChain(from seedEdge: EdgeKey) -> EdgeChain? {
        guard let seed = edges[seedEdge], !seed.triangleIndices.isEmpty else {
            return nil
        }
        if !seed.isFeatureEdge {
            return EdgeChain(
                points: [vertices[seed.a], vertices[seed.b]],
                kind: String(format: "single-edge only length=%.2f", simd_distance(vertices[seed.a], vertices[seed.b]))
            )
        }

        let incident = featureEdgesByVertex()
        let rawPath = rawFeaturePath(from: seedEdge, incident: incident)

        if let line = fittedLineSelection(in: rawPath, seedEdge: seedEdge) {
            return line
        }

        if let arc = fittedArcSelection(in: rawPath, seedEdge: seedEdge) {
            return arc
        }

        return nil
    }

    func connectedFeatureEdgeComponent(startingFrom seedEdge: EdgeKey) -> Set<EdgeKey> {
        guard let seed = edges[seedEdge], seed.isFeatureEdge else {
            return []
        }

        var component: Set<EdgeKey> = []
        var queue: [EdgeKey] = [seedEdge]
        var visitedEdges: Set<EdgeKey> = []
        let incident = featureEdgesByVertex()

        while let edgeKey = queue.popLast() {
            guard visitedEdges.insert(edgeKey).inserted else {
                continue
            }
            guard let edge = edges[edgeKey], edge.isFeatureEdge else {
                continue
            }
            component.insert(edgeKey)
            let neighbors = incident[edge.a, default: []] + incident[edge.b, default: []]
            for next in neighbors where !visitedEdges.contains(next) {
                if let candidate = edges[next], candidate.isFeatureEdge {
                    queue.append(next)
                }
            }
        }
        return component
    }

    func connectedFeatureVertices(componentEdges: Set<EdgeKey>) -> [[Float]]? {
        var outputVertices: [SIMD3<Float>] = []
        var seen: Set<Int> = []

        for edgeKey in componentEdges {
            if !seen.contains(edgeKey.a) {
                seen.insert(edgeKey.a)
                outputVertices.append(vertices[edgeKey.a])
            }
            if !seen.contains(edgeKey.b) {
                seen.insert(edgeKey.b)
                outputVertices.append(vertices[edgeKey.b])
            }
        }

        guard !outputVertices.isEmpty else {
            return nil
        }
        return outputVertices.map { [$0.x, $0.y, $0.z] }
    }

    func connectedFeatureSegments(componentEdges: Set<EdgeKey>) -> [[Int]]? {
        guard !componentEdges.isEmpty else {
            return nil
        }
        var orderedSegments: [[Int]] = []
        orderedSegments.reserveCapacity(componentEdges.count)
        for edgeKey in componentEdges {
            orderedSegments.append([edgeKey.a, edgeKey.b])
        }
        return orderedSegments
    }

    func nearestFeatureEdge(to point: SIMD3<Float>, maxDistance: Float = .greatestFiniteMagnitude) -> EdgeKey? {
        var bestEdge: EdgeKey?
        var bestDistance = Float.greatestFiniteMagnitude

        for (edgeKey, edge) in edges where edge.isFeatureEdge {
            let start = vertices[edge.a]
            let end = vertices[edge.b]
            let ab = end - start
            let denominator = simd_dot(ab, ab)
            let t = denominator > 0 ? max(0, min(1, simd_dot(point - start, ab) / denominator)) : 0
            let projected = start + ab * t
            let distance = simd_distance(point, projected)
            if distance < bestDistance {
                bestDistance = distance
                bestEdge = edgeKey
            }
        }

        guard bestDistance <= maxDistance else {
            return nil
        }
        return bestEdge
    }

    func nearestFeatureEdgeDistance(to point: SIMD3<Float>) -> Float {
        var bestDistance = Float.greatestFiniteMagnitude

        for edge in geometricFeatureEdges() {
            let start = edge.start
            let end = edge.end
            let ab = end - start
            let denominator = simd_dot(ab, ab)
            let t = denominator > 0 ? max(0, min(1, simd_dot(point - start, ab) / denominator)) : 0
            let projected = start + ab * t
            bestDistance = min(bestDistance, simd_distance(point, projected))
        }

        return bestDistance
    }

    func connectedSurfaceTriangles(startingFrom seedTriangle: Int) -> [Int] {
        guard seedTriangle >= 0, seedTriangle < triangles.count else {
            return []
        }

        var result: [Int] = []
        var queue = [seedTriangle]
        var cursor = 0
        var visited = Set<Int>([seedTriangle])
        let geometricEdges = geometricEdgeBuckets()

        while cursor < queue.count {
            let triangleIndex = queue[cursor]
            cursor += 1
            result.append(triangleIndex)

            let triangle = triangles[triangleIndex]
            for localEdge in triangle.localEdges(in: vertices) {
                let key = geometricEdgeKey(from: localEdge.0, to: localEdge.1)
                guard let entries = geometricEdges[key],
                      !isGeometricFeatureEdge(entries)
                else {
                    continue
                }

                for entry in entries where entry.triangleIndex != triangleIndex {
                    let neighbor = entry.triangleIndex
                    if visited.insert(neighbor).inserted {
                        queue.append(neighbor)
                    }
                }
            }
        }

        return result
    }

    func inferredSurfaceTriangles(startingFrom seedTriangle: Int) -> [Int] {
        let smoothPatch = smoothSurfacePatchTriangles(startingFrom: seedTriangle)
        guard !smoothPatch.isEmpty else {
            return []
        }

        return smoothPatch
    }

    func smoothSurfacePatchTriangles(startingFrom seedTriangle: Int) -> [Int] {
        guard seedTriangle >= 0, seedTriangle < triangles.count else {
            return []
        }

        var result: [Int] = []
        var queue = [seedTriangle]
        var cursor = 0
        var visited = Set<Int>([seedTriangle])
        let geometricEdges = geometricEdgeBuckets()

        while cursor < queue.count {
            let triangleIndex = queue[cursor]
            cursor += 1
            result.append(triangleIndex)

            let triangle = triangles[triangleIndex]
            for localEdge in triangle.localEdges(in: vertices) {
                let key = geometricEdgeKey(from: localEdge.0, to: localEdge.1)
                guard let entries = geometricEdges[key],
                      !isGeometricBoundaryEdge(entries, creaseDegrees: 65.0)
                else {
                    continue
                }

                for entry in entries where entry.triangleIndex != triangleIndex {
                    let neighbor = entry.triangleIndex
                    if visited.insert(neighbor).inserted {
                        queue.append(neighbor)
                    }
                }
            }
        }

        return result
    }

    func isPlanarSurface(triangleIndices: [Int], seedTriangle: Int) -> Bool {
        guard seedTriangle >= 0, seedTriangle < triangles.count else {
            return false
        }

        let seed = triangles[seedTriangle]
        let seedNormal = seed.normal
        let seedPoint = vertices[seed.indices[0]]
        let normalDotLimit = cosf(7.0 * .pi / 180.0)
        let planeTolerance = surfacePlaneTolerance

        for triangleIndex in triangleIndices {
            guard triangleIndex >= 0, triangleIndex < triangles.count else {
                continue
            }

            let triangle = triangles[triangleIndex]
            guard simd_dot(seedNormal, triangle.normal) >= normalDotLimit else {
                return false
            }

            for vertexIndex in triangle.indices {
                let distance = abs(simd_dot(vertices[vertexIndex] - seedPoint, seedNormal))
                if distance > planeTolerance {
                    return false
                }
            }
        }

        return true
    }

    func coplanarSurfaceTriangles(matching seedTriangle: Int) -> [Int] {
        guard seedTriangle >= 0, seedTriangle < triangles.count else {
            return []
        }

        let seed = triangles[seedTriangle]
        let seedNormal = seed.normal
        let seedPoint = vertices[seed.indices[0]]
        let normalDotLimit = cosf(7.0 * .pi / 180.0)
        let planeTolerance = surfacePlaneTolerance

        var result: [Int] = []
        result.reserveCapacity(triangles.count)

        for (triangleIndex, triangle) in triangles.enumerated() {
            guard simd_dot(seedNormal, triangle.normal) >= normalDotLimit else {
                continue
            }

            let centroid = triangleCentroid(triangle)
            guard abs(simd_dot(centroid - seedPoint, seedNormal)) <= planeTolerance else {
                continue
            }

            var verticesOnPlane = true
            for vertexIndex in triangle.indices {
                let distance = abs(simd_dot(vertices[vertexIndex] - seedPoint, seedNormal))
                if distance > planeTolerance * 1.5 {
                    verticesOnPlane = false
                    break
                }
            }

            if verticesOnPlane {
                result.append(triangleIndex)
            }
        }

        return result
    }

    var surfacePlaneTolerance: Float {
        max(maxExtent * 0.00015, 0.000001)
    }

    func triangleCentroid(_ triangle: MeshTriangle) -> SIMD3<Float> {
        (vertices[triangle.indices[0]] + vertices[triangle.indices[1]] + vertices[triangle.indices[2]]) / 3
    }

    struct GeometricEdgeEntry {
        let triangleIndex: Int
        let start: SIMD3<Float>
        let end: SIMD3<Float>
    }

    struct GeometricFeatureEdge {
        let start: SIMD3<Float>
        let end: SIMD3<Float>
    }

    struct QuantizedPointKey: Hashable, Comparable {
        let x: Int64
        let y: Int64
        let z: Int64

        static func < (lhs: QuantizedPointKey, rhs: QuantizedPointKey) -> Bool {
            if lhs.x != rhs.x { return lhs.x < rhs.x }
            if lhs.y != rhs.y { return lhs.y < rhs.y }
            return lhs.z < rhs.z
        }
    }

    struct GeometricEdgeKey: Hashable {
        let a: QuantizedPointKey
        let b: QuantizedPointKey
    }

    func geometricFeatureEdges() -> [GeometricFeatureEdge] {
        geometricEdgeBuckets().compactMap { _, entries in
            guard let first = entries.first, isGeometricFeatureEdge(entries) else {
                return nil
            }
            return GeometricFeatureEdge(start: first.start, end: first.end)
        }
    }

    func geometricEdgeBuckets() -> [GeometricEdgeKey: [GeometricEdgeEntry]] {
        var buckets: [GeometricEdgeKey: [GeometricEdgeEntry]] = [:]
        buckets.reserveCapacity(edges.count)

        for (triangleIndex, triangle) in triangles.enumerated() {
            for localEdge in triangle.localEdges(in: vertices) {
                let key = geometricEdgeKey(from: localEdge.0, to: localEdge.1)
                buckets[key, default: []].append(
                    GeometricEdgeEntry(
                        triangleIndex: triangleIndex,
                        start: localEdge.0,
                        end: localEdge.1
                    )
                )
            }
        }

        return buckets
    }

    func isGeometricFeatureEdge(_ entries: [GeometricEdgeEntry]) -> Bool {
        isGeometricBoundaryEdge(entries, creaseDegrees: 25.0)
    }

    func isGeometricBoundaryEdge(_ entries: [GeometricEdgeEntry], creaseDegrees: Float) -> Bool {
        guard entries.count >= 2 else {
            return true
        }

        let normals = entries.map { triangles[$0.triangleIndex].normal }
        let dotLimit = cosf(creaseDegrees * .pi / 180.0)
        for i in 0..<normals.count {
            for j in (i + 1)..<normals.count {
                if simd_dot(normals[i], normals[j]) < dotLimit {
                    return true
                }
            }
        }
        return false
    }

    func geometricEdgeKey(from start: SIMD3<Float>, to end: SIMD3<Float>) -> GeometricEdgeKey {
        let first = quantizedPointKey(start)
        let second = quantizedPointKey(end)
        if second < first {
            return GeometricEdgeKey(a: second, b: first)
        }
        return GeometricEdgeKey(a: first, b: second)
    }

    func quantizedPointKey(_ point: SIMD3<Float>) -> QuantizedPointKey {
        let tolerance = max(maxExtent * 0.00002, 0.01)
        return QuantizedPointKey(
            x: Int64((point.x / tolerance).rounded()),
            y: Int64((point.y / tolerance).rounded()),
            z: Int64((point.z / tolerance).rounded())
        )
    }

    func surroundingTriangles(for componentEdges: Set<EdgeKey>, maxTriangles: Int) -> [ProbeTriangleRecord]? {
        guard !componentEdges.isEmpty else {
            return nil
        }

        var triangleIndices: Set<Int> = []
        for edgeKey in componentEdges {
            if let edge = edges[edgeKey] {
                for index in edge.triangleIndices {
                    triangleIndices.insert(index)
                }
            }
        }

        if triangleIndices.isEmpty {
            return nil
        }

        var outputTriangles: [ProbeTriangleRecord] = []
        outputTriangles.reserveCapacity(min(maxTriangles, triangleIndices.count))

        for index in triangleIndices.prefix(maxTriangles) {
            let sourceTriangle = self.triangles[index]
            let points = sourceTriangle.indices.map { vertexIndex in
                let vertex = vertices[vertexIndex]
                return [vertex.x, vertex.y, vertex.z]
            }
            outputTriangles.append(ProbeTriangleRecord(indices: sourceTriangle.indices, points: points))
        }
        return outputTriangles.isEmpty ? nil : outputTriangles
    }
}
