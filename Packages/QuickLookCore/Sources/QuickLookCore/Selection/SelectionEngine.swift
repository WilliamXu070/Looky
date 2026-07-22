import simd

public struct SelectionEngine: Sendable {
    private struct EdgeRecord: Sendable {
        let id: MeshEdgeID
        var triangles: [MeshTriangleID]
        var isFeature: Bool
    }

    public let mesh: MeshSnapshot
    public let settings: SelectionSettings
    private let edges: [MeshEdgeID: EdgeRecord]
    private let featureIndex: FeatureEdgeBVH
    private let trianglesByEdge: [MeshEdgeID: [MeshTriangleID]]
    private let featureEdgesByVertex: [Int: [MeshEdgeID]]

    public init(mesh: MeshSnapshot, settings: SelectionSettings = .init()) {
        self.mesh = mesh
        self.settings = settings

        var records: [MeshEdgeID: EdgeRecord] = [:]
        for triangle in mesh.triangles {
            for edge in triangle.edges {
                records[edge, default: EdgeRecord(id: edge, triangles: [], isFeature: false)]
                    .triangles.append(triangle.id)
            }
        }

        for (edgeID, record) in records {
            var updated = record
            if record.triangles.count != 2 {
                updated.isFeature = true
            } else if
                let first = mesh.triangles[safe: record.triangles[0].rawValue],
                let second = mesh.triangles[safe: record.triangles[1].rawValue]
            {
                let cosine = max(-1, min(1, simd_dot(first.normal, second.normal)))
                updated.isFeature = acos(cosine) >= settings.featureEdgeDegrees * .pi / 180
            }
            records[edgeID] = updated
        }

        edges = records
        trianglesByEdge = records.mapValues(\.triangles)
        let segments = records.values.filter(\.isFeature).compactMap { record -> MeshSegment? in
            guard mesh.vertices.indices.contains(record.id.a), mesh.vertices.indices.contains(record.id.b) else {
                return nil
            }
            return MeshSegment(
                id: record.id,
                start: mesh.vertices[record.id.a],
                end: mesh.vertices[record.id.b]
            )
        }
        featureIndex = FeatureEdgeBVH(segments: segments)
        var featureAdjacency: [Int: [MeshEdgeID]] = [:]
        for segment in segments {
            featureAdjacency[segment.id.a, default: []].append(segment.id)
            featureAdjacency[segment.id.b, default: []].append(segment.id)
        }
        featureEdgesByVertex = featureAdjacency.mapValues { $0.sorted() }
    }

    public func resolve(_ query: SelectionQuery) -> SelectionResolution {
        guard mesh.triangles.indices.contains(query.triangleID.rawValue) else {
            return SelectionResolution(
                kind: .none,
                entity: nil,
                seedTriangle: nil,
                nearestFeatureEdgeDistance: nil,
                edgeThreshold: edgeThreshold,
                reason: "none: invalid hit triangle",
                acceleration: .cpuBVH
            )
        }

        let nearest = featureIndex.nearest(to: query.localPoint)
        if let nearest, nearest.distance <= edgeThreshold {
            let component = finiteFeatureEdges(from: nearest.segment.id)
            let points = orderedPoints(for: component, seed: nearest.segment.id)
            return SelectionResolution(
                kind: .edge,
                entity: .edge(SelectedEdge(source: mesh.sourceID, edges: component, points: points)),
                seedTriangle: query.triangleID,
                nearestFeatureEdgeDistance: nearest.distance,
                edgeThreshold: edgeThreshold,
                reason: "edge selected: inside feature threshold",
                acceleration: .cpuBVH
            )
        }

        let patch = surfacePatch(from: query.triangleID)
        return SelectionResolution(
            kind: .surface,
            entity: .surface(SelectedSurface(source: mesh.sourceID, triangles: patch)),
            seedTriangle: query.triangleID,
            nearestFeatureEdgeDistance: nearest?.distance,
            edgeThreshold: edgeThreshold,
            reason: "surface selected: outside feature threshold",
            acceleration: .cpuBVH
        )
    }

    public var edgeThreshold: Float {
        max(mesh.maxExtent * settings.edgeThresholdScale, 0.000_001)
    }

    private func finiteFeatureEdges(from seed: MeshEdgeID) -> [MeshEdgeID] {
        guard edges[seed]?.isFeature == true else { return [] }
        if let hinted = mesh.topologyHints?.edges.first(where: { $0.edges.contains(seed) }) {
            return hinted.edges.sorted()
        }

        var path = [seed]
        var visited: Set<MeshEdgeID> = [seed]
        extendFeaturePath(&path, visited: &visited, from: seed.a, previousVertex: seed.b, prepend: true)
        extendFeaturePath(&path, visited: &visited, from: seed.b, previousVertex: seed.a, prepend: false)
        return path
    }

    private func extendFeaturePath(
        _ path: inout [MeshEdgeID],
        visited: inout Set<MeshEdgeID>,
        from vertex: Int,
        previousVertex: Int,
        prepend: Bool
    ) {
        var current = vertex
        var previous = previousVertex
        let minimumContinuationCosine = cos(Float.pi * 35 / 180)

        while mesh.vertices.indices.contains(current), mesh.vertices.indices.contains(previous) {
            let incoming = GeometryMath.normalized(mesh.vertices[current] - mesh.vertices[previous], fallback: .zero)
            let candidates = (featureEdgesByVertex[current] ?? []).compactMap { edge -> (MeshEdgeID, Int, Float)? in
                guard !visited.contains(edge) else { return nil }
                let next = edge.a == current ? edge.b : edge.a
                guard mesh.vertices.indices.contains(next) else { return nil }
                let outgoing = GeometryMath.normalized(mesh.vertices[next] - mesh.vertices[current], fallback: .zero)
                return (edge, next, simd_dot(incoming, outgoing))
            }
            guard let best = candidates.sorted(by: {
                $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 > $1.2
            }).first, best.2 >= minimumContinuationCosine else {
                break
            }
            visited.insert(best.0)
            if prepend {
                path.insert(best.0, at: 0)
            } else {
                path.append(best.0)
            }
            previous = current
            current = best.1
        }
    }

    private func orderedPoints(for component: [MeshEdgeID], seed: MeshEdgeID) -> [SIMD3<Float>] {
        guard !component.isEmpty else { return [] }
        var adjacency: [Int: [Int]] = [:]
        for edge in component {
            adjacency[edge.a, default: []].append(edge.b)
            adjacency[edge.b, default: []].append(edge.a)
        }
        let start = adjacency.first(where: { $0.value.count == 1 })?.key ?? seed.a
        var points: [SIMD3<Float>] = []
        var previous: Int?
        var current = start
        var visitedEdges: Set<MeshEdgeID> = []
        while mesh.vertices.indices.contains(current) {
            points.append(mesh.vertices[current])
            guard let next = adjacency[current]?.first(where: {
                $0 != previous && !visitedEdges.contains(MeshEdgeID(current, $0))
            }) else { break }
            visitedEdges.insert(MeshEdgeID(current, next))
            previous = current
            current = next
        }
        return points
    }

    private func surfacePatch(from seed: MeshTriangleID) -> [MeshTriangleID] {
        if let hinted = mesh.topologyHints?.faces.first(where: { $0.triangles.contains(seed) }) {
            return hinted.triangles.sorted()
        }

        var visited: Set<MeshTriangleID> = [seed]
        var queue = [seed]
        while let current = queue.popLast(), let triangle = mesh.triangles[safe: current.rawValue] {
            for edge in triangle.edges where edges[edge]?.isFeature != true {
                for neighbor in trianglesByEdge[edge] ?? [] where neighbor != current {
                    guard let next = mesh.triangles[safe: neighbor.rawValue] else { continue }
                    let cosine = max(-1, min(1, simd_dot(triangle.normal, next.normal)))
                    let angle = acos(cosine) * 180 / .pi
                    if angle <= settings.smoothSurfaceDegrees && visited.insert(neighbor).inserted {
                        queue.append(neighbor)
                    }
                }
            }
        }
        return visited.sorted()
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
