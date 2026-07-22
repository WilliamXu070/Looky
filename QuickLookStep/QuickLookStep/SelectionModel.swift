import Foundation
import QuickLookCore
import SceneKit
import simd

struct SelectionModelSettings: Equatable {
    var featureEdgeDegrees: Float = 25.0
    var smoothSurfaceBoundaryDegrees: Float = 65.0
    var planarSurfaceDegrees: Float = 7.0
    var weldedVertexToleranceScale: Float = 0.00002
    var weldedVertexToleranceMinimum: Float = 0.000001
    var coplanarToleranceScale: Float = 0.00015
    var coplanarToleranceMinimum: Float = 0.000001
}

struct SelectionModel {
    let vertices: [SIMD3<Float>]
    private(set) var triangles: [SelectionTriangle]
    private(set) var edges: [SelectionEdge]
    private(set) var surfacePatches: [SelectionSurfacePatch]
    private(set) var edgeLoops: [SelectionEdgeLoop]
    let weldedEdgeBuckets: [SelectionWeldedEdgeKey: [SelectionWeldedEdgeEntry]]
    let featureEdgeSegments: [SelectionFeatureSegment]
    let featureEdgeFingerprint: UInt64
    private let featureEdgeIndex: FeatureEdgeBVH
    let maxExtent: Float
    let settings: SelectionModelSettings

    var geometricEdgeBuckets: [SelectionWeldedEdgeKey: [SelectionWeldedEdgeEntry]] {
        weldedEdgeBuckets
    }

    private let edgeIDsByKey: [SelectionEdgeKey: SelectionEdgeID]
    private(set) var surfacePatchIDsByTriangle: [SelectionTriangleID: SelectionSurfacePatchID]
    private(set) var edgeLoopIDsByEdge: [SelectionEdgeID: SelectionEdgeLoopID]

    init?(geometry: SCNGeometry, settings: SelectionModelSettings = .init()) {
        guard let snapshot = SelectionGeometryReader.snapshot(
            from: geometry,
            sourceID: MeshSourceID(model: "scene", node: "node", geometry: "geometry")
        ) else {
            return nil
        }
        self.init(snapshot: snapshot, settings: settings)
    }

    init?(snapshot: MeshSnapshot, settings: SelectionModelSettings = .init()) {
        self.init(
            mesh: SelectionGeometryMesh(
                vertices: snapshot.vertices,
                triangleVertexIndices: snapshot.triangles.map(\.indices)
            ),
            settings: settings
        )
    }

    init?(mesh: SelectionGeometryMesh, settings: SelectionModelSettings = .init()) {
        guard !mesh.vertices.isEmpty, !mesh.triangleVertexIndices.isEmpty else {
            return nil
        }

        let maxExtent = SelectionGeometryMath.maxExtent(of: mesh.vertices)
        let weldedTolerance = Self.weldedVertexTolerance(maxExtent: maxExtent, settings: settings)

        var triangles: [SelectionTriangle] = []
        triangles.reserveCapacity(mesh.triangleVertexIndices.count)
        for (index, indices) in mesh.triangleVertexIndices.enumerated() {
            let normal = SelectionGeometryMath.triangleNormal(
                mesh.vertices[indices[0]],
                mesh.vertices[indices[1]],
                mesh.vertices[indices[2]]
            )
            triangles.append(
                SelectionTriangle(
                    id: SelectionTriangleID(rawValue: index),
                    vertexIndices: indices,
                    normal: normal
                )
            )
        }

        var edges: [SelectionEdge] = []
        var edgeIDsByKey: [SelectionEdgeKey: SelectionEdgeID] = [:]

        for triangleIndex in triangles.indices {
            let triangleID = triangles[triangleIndex].id
            for edgeKey in triangles[triangleIndex].edgeKeys {
                let edgeID: SelectionEdgeID
                if let existing = edgeIDsByKey[edgeKey] {
                    edgeID = existing
                } else {
                    edgeID = SelectionEdgeID(rawValue: edges.count)
                    edgeIDsByKey[edgeKey] = edgeID
                    let weldedKey = Self.weldedEdgeKey(
                        from: mesh.vertices[edgeKey.a],
                        to: mesh.vertices[edgeKey.b],
                        tolerance: weldedTolerance
                    )
                    edges.append(
                        SelectionEdge(
                            id: edgeID,
                            key: edgeKey,
                            weldedKey: weldedKey
                        )
                    )
                }

                edges[edgeID.rawValue].triangleIDs.append(triangleID)
                triangles[triangleIndex].edgeIDs.append(edgeID)
            }
        }

        Self.populateTopology(
            triangles: &triangles,
            edges: &edges,
            featureEdgeDegrees: settings.featureEdgeDegrees
        )

        let weldedEdgeBuckets = Self.buildWeldedEdgeBuckets(
            vertices: mesh.vertices,
            triangles: triangles,
            maxExtent: maxExtent,
            settings: settings
        )
        Self.populateWeldedFeatureFlags(
            edges: &edges,
            buckets: weldedEdgeBuckets,
            triangles: triangles,
            featureEdgeDegrees: settings.featureEdgeDegrees
        )
        let featureEdgeSegments = Self.buildFeatureEdgeSegments(
            buckets: weldedEdgeBuckets,
            edges: edges
        )
        let featureEdgeIndex = FeatureEdgeBVH(
            segments: featureEdgeSegments.enumerated().map { index, segment in
                MeshSegment(
                    id: MeshEdgeID(index * 2, index * 2 + 1),
                    start: segment.start,
                    end: segment.end
                )
            }
        )

        self.vertices = mesh.vertices
        self.triangles = triangles
        self.edges = edges
        self.surfacePatches = []
        self.edgeLoops = []
        self.weldedEdgeBuckets = weldedEdgeBuckets
        self.featureEdgeSegments = featureEdgeSegments
        self.featureEdgeFingerprint = Self.fingerprint(featureEdgeSegments)
        self.featureEdgeIndex = featureEdgeIndex
        self.maxExtent = maxExtent
        self.settings = settings
        self.edgeIDsByKey = edgeIDsByKey
        self.surfacePatchIDsByTriangle = [:]
        self.edgeLoopIDsByEdge = [:]

        rebuildSurfacePatches()
        rebuildEdgeLoops()
    }

    func triangle(_ id: SelectionTriangleID) -> SelectionTriangle? {
        guard triangles.indices.contains(id.rawValue) else {
            return nil
        }
        return triangles[id.rawValue]
    }

    func edge(_ id: SelectionEdgeID) -> SelectionEdge? {
        guard edges.indices.contains(id.rawValue) else {
            return nil
        }
        return edges[id.rawValue]
    }

    func surfacePatch(_ id: SelectionSurfacePatchID) -> SelectionSurfacePatch? {
        guard surfacePatches.indices.contains(id.rawValue) else {
            return nil
        }
        return surfacePatches[id.rawValue]
    }

    func edgeLoop(_ id: SelectionEdgeLoopID) -> SelectionEdgeLoop? {
        guard edgeLoops.indices.contains(id.rawValue) else {
            return nil
        }
        return edgeLoops[id.rawValue]
    }

    func triangleID(at index: Int) -> SelectionTriangleID? {
        guard triangles.indices.contains(index) else {
            return nil
        }
        return SelectionTriangleID(rawValue: index)
    }

    func closestTriangleID(to point: SIMD3<Float>) -> SelectionTriangleID? {
        var bestID: SelectionTriangleID?
        var bestDistance = Float.greatestFiniteMagnitude

        for triangle in triangles {
            let a = vertices[triangle.vertexIndices[0]]
            let b = vertices[triangle.vertexIndices[1]]
            let c = vertices[triangle.vertexIndices[2]]
            let distance = SelectionGeometryMath.pointTriangleDistanceSquared(point, a, b, c)
            if distance < bestDistance {
                bestDistance = distance
                bestID = triangle.id
            }
        }

        return bestID
    }

    func nearestFeatureEdge(to point: SIMD3<Float>, maxDistance: Float = .greatestFiniteMagnitude) -> SelectionEdgeDistance? {
        var best: SelectionEdgeDistance?

        for edge in edges where edge.isFeatureEdge {
            let start = vertices[edge.a]
            let end = vertices[edge.b]
            let closest = SelectionGeometryMath.closestPoint(onSegmentFrom: start, to: end, point: point)
            let distance = simd_distance(point, closest)
            if distance < (best?.distance ?? Float.greatestFiniteMagnitude) {
                best = SelectionEdgeDistance(edgeID: edge.id, distance: distance, closestPoint: closest)
            }
        }

        guard let best, best.distance <= maxDistance else {
            return nil
        }
        return best
    }

    func nearestFeatureEdgeDistance(to point: SIMD3<Float>) -> Float {
        nearestFeatureEdgeDistanceCPU(to: point)
    }

    func nearestFeatureEdgeDistance(
        to point: SIMD3<Float>,
        backend: SelectionDistanceBackend?,
        minimumSegmentCount: Int = 256
    ) -> SelectionDistanceResult {
        guard !featureEdgeSegments.isEmpty else {
            return SelectionDistanceResult(distance: Float.greatestFiniteMagnitude, acceleration: "cpu")
        }

        guard featureEdgeSegments.count >= minimumSegmentCount else {
            return SelectionDistanceResult(distance: nearestFeatureEdgeDistanceCPU(to: point), acceleration: "cpu")
        }

        guard let backend,
              let distance = backend.nearestFeatureEdgeDistance(
                point: point,
                segments: featureEdgeSegments,
                fingerprint: featureEdgeFingerprint
              )
        else {
            return SelectionDistanceResult(distance: nearestFeatureEdgeDistanceCPU(to: point), acceleration: "unavailable")
        }

        return SelectionDistanceResult(distance: distance, acceleration: backend.name)
    }

    private func nearestFeatureEdgeDistanceCPU(to point: SIMD3<Float>) -> Float {
        featureEdgeIndex.nearest(to: point)?.distance ?? Float.greatestFiniteMagnitude
    }

    private static func fingerprint(_ segments: [SelectionFeatureSegment]) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for segment in segments {
            for value in [
                segment.start.x, segment.start.y, segment.start.z,
                segment.end.x, segment.end.y, segment.end.z,
            ] {
                hash ^= UInt64(value.bitPattern)
                hash &*= 1_099_511_628_211
            }
        }
        return hash
    }

    func surfacePatchID(forTriangle triangleID: SelectionTriangleID) -> SelectionSurfacePatchID? {
        surfacePatchIDsByTriangle[triangleID]
    }

    func surfacePatch(forTriangle triangleID: SelectionTriangleID) -> SelectionSurfacePatch? {
        surfacePatchID(forTriangle: triangleID).flatMap(surfacePatch)
    }

    func edgeLoopID(containing edgeID: SelectionEdgeID) -> SelectionEdgeLoopID? {
        edgeLoopIDsByEdge[edgeID]
    }

    func edgeLoop(containing edgeID: SelectionEdgeID) -> SelectionEdgeLoop? {
        edgeLoopID(containing: edgeID).flatMap(edgeLoop)
    }

    func edgeID(for key: SelectionEdgeKey) -> SelectionEdgeID? {
        edgeIDsByKey[key]
    }

    func connectedFeatureEdgeComponent(startingFrom seedEdgeID: SelectionEdgeID) -> Set<SelectionEdgeID> {
        guard let seed = edge(seedEdgeID), seed.isFeatureEdge else {
            return []
        }

        var component: Set<SelectionEdgeID> = []
        var queue: [SelectionEdgeID] = [seedEdgeID]
        var visitedEdges: Set<SelectionEdgeID> = []
        let incident = featureEdgesByVertex()

        while let edgeID = queue.popLast() {
            guard visitedEdges.insert(edgeID).inserted,
                  let edge = edge(edgeID),
                  edge.isFeatureEdge
            else {
                continue
            }

            component.insert(edgeID)
            let neighbors = (incident[edge.a] ?? []) + (incident[edge.b] ?? [])
            for next in neighbors where !visitedEdges.contains(next) {
                if self.edge(next)?.isFeatureEdge == true {
                    queue.append(next)
                }
            }
        }

        return component
    }

    func connectedSurfaceTriangleIDs(startingFrom seedTriangleID: SelectionTriangleID) -> [SelectionTriangleID] {
        guard triangle(seedTriangleID) != nil else {
            return []
        }

        var result: [SelectionTriangleID] = []
        var queue = [seedTriangleID]
        var cursor = 0
        var visited = Set<SelectionTriangleID>([seedTriangleID])

        while cursor < queue.count {
            let triangleID = queue[cursor]
            cursor += 1
            result.append(triangleID)

            guard let triangle = triangle(triangleID) else {
                continue
            }

            for edgeID in triangle.edgeIDs {
                guard let edge = edge(edgeID),
                      let entries = weldedEdgeBuckets[edge.weldedKey],
                      !isWeldedFeatureEdge(entries)
                else {
                    continue
                }

                for entry in entries where entry.triangleID != triangleID {
                    if visited.insert(entry.triangleID).inserted {
                        queue.append(entry.triangleID)
                    }
                }
            }
        }

        return result
    }

    func inferredSurfaceTriangleIDs(startingFrom seedTriangleID: SelectionTriangleID) -> [SelectionTriangleID] {
        let smoothPatch = smoothSurfacePatchTriangleIDs(startingFrom: seedTriangleID)
        guard !smoothPatch.isEmpty else {
            return []
        }

        return smoothPatch
    }

    func rawVertexPath(from seedEdgeID: SelectionEdgeID) -> [Int] {
        guard edge(seedEdgeID)?.isFeatureEdge == true else {
            return []
        }

        let incident = featureEdgesByVertex()
        var path = rawFeaturePath(from: seedEdgeID, incident: incident)
        guard path.count >= 2 else {
            return path
        }

        if path.first != path.last {
            if let first = path.first, let last = path.last, first > last {
                path.reverse()
            }
        } else {
            let interiorCount = path.count - 1
            guard interiorCount >= 2 else {
                return path
            }
            var minVertex = path[0]
            var minIndex = 0
            for index in 0..<interiorCount where path[index] < minVertex {
                minVertex = path[index]
                minIndex = index
            }
            if minIndex > 0 {
                var rotated = Array(path[minIndex..<interiorCount])
                rotated.append(contentsOf: path[0..<minIndex])
                rotated.append(path[minIndex])
                path = rotated
            }
        }

        return path
    }

    func edgePath(from seedEdgeID: SelectionEdgeID) -> [SelectionEdgeID] {
        edgePath(fromVertexPath: rawVertexPath(from: seedEdgeID))
    }

    private mutating func rebuildSurfacePatches() {
        var patchIDsByTriangleSet: [[SelectionTriangleID]: SelectionSurfacePatchID] = [:]

        for triangle in triangles {
            guard surfacePatchIDsByTriangle[triangle.id] == nil else {
                continue
            }

            let candidateIDs = sortedUnique(inferredSurfaceTriangleIDs(startingFrom: triangle.id))
            guard !candidateIDs.isEmpty else {
                continue
            }

            let patchID: SelectionSurfacePatchID
            if let existing = patchIDsByTriangleSet[candidateIDs] {
                patchID = existing
            } else {
                patchID = SelectionSurfacePatchID(rawValue: surfacePatches.count)
                patchIDsByTriangleSet[candidateIDs] = patchID
                surfacePatches.append(
                    SelectionSurfacePatch(
                        id: patchID,
                        seedTriangleID: triangle.id,
                        triangleIDs: candidateIDs,
                        isPlanar: isPlanarSurface(triangleIDs: candidateIDs, seedTriangleID: triangle.id)
                    )
                )
            }

            for triangleID in candidateIDs where surfacePatchIDsByTriangle[triangleID] == nil {
                surfacePatchIDsByTriangle[triangleID] = patchID
            }
        }
    }

    private mutating func rebuildEdgeLoops() {
        var visited: Set<SelectionEdgeID> = []
        let sortedFeatureEdgeIDs = edges
            .filter { $0.isFeatureEdge }
            .map(\.id)
            .sorted()

        for edgeID in sortedFeatureEdgeIDs where !visited.contains(edgeID) {
            let vertexPath = rawVertexPath(from: edgeID)
            let edgePath = self.edgePath(fromVertexPath: vertexPath)
            guard !edgePath.isEmpty else {
                continue
            }

            let loopID = SelectionEdgeLoopID(rawValue: edgeLoops.count)
            let loop = SelectionEdgeLoop(
                id: loopID,
                seedEdgeID: edgeID,
                edgeIDs: edgePath,
                vertexPath: vertexPath,
                isClosed: vertexPath.count > 2 && vertexPath.first == vertexPath.last
            )
            edgeLoops.append(loop)

            for pathEdgeID in edgePath {
                visited.insert(pathEdgeID)
                edgeLoopIDsByEdge[pathEdgeID] = loopID
            }
        }
    }

    private func smoothSurfacePatchTriangleIDs(startingFrom seedTriangleID: SelectionTriangleID) -> [SelectionTriangleID] {
        guard triangle(seedTriangleID) != nil else {
            return []
        }

        var result: [SelectionTriangleID] = []
        var queue = [seedTriangleID]
        var cursor = 0
        var visited = Set<SelectionTriangleID>([seedTriangleID])

        while cursor < queue.count {
            let triangleID = queue[cursor]
            cursor += 1
            result.append(triangleID)

            guard let triangle = triangle(triangleID) else {
                continue
            }

            for edgeID in triangle.edgeIDs {
                guard let edge = edge(edgeID),
                      let entries = weldedEdgeBuckets[edge.weldedKey],
                      !isWeldedBoundaryEdge(entries, creaseDegrees: settings.smoothSurfaceBoundaryDegrees)
                else {
                    continue
                }

                for entry in entries where entry.triangleID != triangleID {
                    if visited.insert(entry.triangleID).inserted {
                        queue.append(entry.triangleID)
                    }
                }
            }
        }

        return result
    }

    private func isPlanarSurface(triangleIDs: [SelectionTriangleID], seedTriangleID: SelectionTriangleID) -> Bool {
        guard let seed = triangle(seedTriangleID) else {
            return false
        }

        let seedNormal = seed.normal
        let seedPoint = vertices[seed.vertexIndices[0]]
        let normalDotLimit = cosf(settings.planarSurfaceDegrees * .pi / 180.0)
        let planeTolerance = surfacePlaneTolerance

        for triangleID in triangleIDs {
            guard let triangle = triangle(triangleID) else {
                continue
            }

            guard simd_dot(seedNormal, triangle.normal) >= normalDotLimit else {
                return false
            }

            for vertexIndex in triangle.vertexIndices {
                let distance = abs(simd_dot(vertices[vertexIndex] - seedPoint, seedNormal))
                if distance > planeTolerance {
                    return false
                }
            }
        }

        return true
    }

    private func coplanarSurfaceTriangleIDs(matching seedTriangleID: SelectionTriangleID) -> [SelectionTriangleID] {
        guard let seed = triangle(seedTriangleID) else {
            return []
        }

        let seedNormal = seed.normal
        let seedPoint = vertices[seed.vertexIndices[0]]
        let normalDotLimit = cosf(settings.planarSurfaceDegrees * .pi / 180.0)
        let planeTolerance = surfacePlaneTolerance

        var result: [SelectionTriangleID] = []
        result.reserveCapacity(triangles.count)

        for triangle in triangles {
            guard simd_dot(seedNormal, triangle.normal) >= normalDotLimit else {
                continue
            }

            let centroid = triangleCentroid(triangle)
            guard abs(simd_dot(centroid - seedPoint, seedNormal)) <= planeTolerance else {
                continue
            }

            var verticesOnPlane = true
            for vertexIndex in triangle.vertexIndices {
                let distance = abs(simd_dot(vertices[vertexIndex] - seedPoint, seedNormal))
                if distance > planeTolerance * 1.5 {
                    verticesOnPlane = false
                    break
                }
            }

            if verticesOnPlane {
                result.append(triangle.id)
            }
        }

        return result
    }

    private var surfacePlaneTolerance: Float {
        max(maxExtent * settings.coplanarToleranceScale, settings.coplanarToleranceMinimum)
    }

    private func triangleCentroid(_ triangle: SelectionTriangle) -> SIMD3<Float> {
        (
            vertices[triangle.vertexIndices[0]]
            + vertices[triangle.vertexIndices[1]]
            + vertices[triangle.vertexIndices[2]]
        ) / 3
    }

    private func isWeldedFeatureEdge(_ entries: [SelectionWeldedEdgeEntry]) -> Bool {
        isWeldedBoundaryEdge(entries, creaseDegrees: settings.featureEdgeDegrees)
    }

    private func isWeldedBoundaryEdge(_ entries: [SelectionWeldedEdgeEntry], creaseDegrees: Float) -> Bool {
        guard entries.count >= 2 else {
            return true
        }

        let normals = entries.compactMap { triangle($0.triangleID)?.normal }
        guard normals.count >= 2 else {
            return true
        }

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

    private func featureEdgesByVertex() -> [Int: [SelectionEdgeID]] {
        var result: [Int: [SelectionEdgeID]] = [:]
        for edge in edges where edge.isFeatureEdge {
            result[edge.a, default: []].append(edge.id)
            result[edge.b, default: []].append(edge.id)
        }

        for vertex in result.keys {
            result[vertex]?.sort()
        }
        return result
    }

    private func rawFeaturePath(
        from seedEdgeID: SelectionEdgeID,
        incident: [Int: [SelectionEdgeID]]
    ) -> [Int] {
        guard let seed = edge(seedEdgeID) else {
            return []
        }

        var path = [seed.a, seed.b]
        var visitedEdges = Set<SelectionEdgeID>([seedEdgeID])
        let continuityKind = edgeContinuityKind(seedEdgeID)

        extendRawFeaturePath(
            &path,
            currentVertex: seed.b,
            previousEdgeID: seedEdgeID,
            continuityKind: continuityKind,
            incident: incident,
            visitedEdges: &visitedEdges,
            append: true
        )
        extendRawFeaturePath(
            &path,
            currentVertex: seed.a,
            previousEdgeID: seedEdgeID,
            continuityKind: continuityKind,
            incident: incident,
            visitedEdges: &visitedEdges,
            append: false
        )

        return dedupedPath(path)
    }

    private func extendRawFeaturePath(
        _ path: inout [Int],
        currentVertex: Int,
        previousEdgeID: SelectionEdgeID,
        continuityKind: Int,
        incident: [Int: [SelectionEdgeID]],
        visitedEdges: inout Set<SelectionEdgeID>,
        append: Bool
    ) {
        var currentVertex = currentVertex
        var previousEdgeID = previousEdgeID

        while true {
            let candidates = (incident[currentVertex] ?? [])
                .filter { $0 != previousEdgeID && !visitedEdges.contains($0) }
                .filter { edgeContinuityKind($0) == continuityKind }
                .sorted()

            guard candidates.count == 1,
                  let candidate = candidates.first,
                  let edge = edge(candidate),
                  let nextVertex = edge.key.otherVertex(from: currentVertex)
            else {
                break
            }

            visitedEdges.insert(candidate)
            if append {
                path.append(nextVertex)
                if nextVertex == path.first {
                    break
                }
            } else {
                path.insert(nextVertex, at: 0)
                if nextVertex == path.last {
                    break
                }
            }

            previousEdgeID = candidate
            currentVertex = nextVertex
        }
    }

    private func edgeContinuityKind(_ edgeID: SelectionEdgeID) -> Int {
        guard let edge = edge(edgeID) else {
            return 0
        }
        return edge.triangleIDs.count == 1 ? 1 : 2
    }

    private func edgePath(fromVertexPath vertexPath: [Int]) -> [SelectionEdgeID] {
        guard vertexPath.count >= 2 else {
            return []
        }

        var path: [SelectionEdgeID] = []
        path.reserveCapacity(vertexPath.count - 1)

        for pair in zip(vertexPath, vertexPath.dropFirst()) {
            if let edgeID = edgeIDsByKey[SelectionEdgeKey(pair.0, pair.1)] {
                path.append(edgeID)
            }
        }

        return path
    }

    private func sortedUnique(_ triangleIDs: [SelectionTriangleID]) -> [SelectionTriangleID] {
        Array(Set(triangleIDs)).sorted()
    }

    private func dedupedPath(_ path: [Int]) -> [Int] {
        path.reduce(into: [Int]()) { partial, vertex in
            if partial.last != vertex {
                partial.append(vertex)
            }
        }
    }
}
