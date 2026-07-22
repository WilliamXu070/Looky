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
    private let exactSurfacesByTriangle: [MeshTriangleID: SelectedSurface]
    private let inferredSurfacesByTriangle: [MeshTriangleID: SelectedSurface]
    public let exactEdges: [SelectedEdge]
    public let points: [SelectedPoint]

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

        var exactSurfaces: [MeshTriangleID: SelectedSurface] = [:]
        for face in mesh.topologyHints?.faces ?? [] {
            let triangles = face.triangles.sorted()
            let surface = SelectedSurface(
                source: mesh.sourceID,
                triangles: triangles,
                id: Self.qualifiedID(mesh: mesh, sourceID: face.sourceID),
                entitySource: .exactTopology,
                descriptor: face.descriptor
            )
            for triangle in triangles where exactSurfaces[triangle] == nil {
                exactSurfaces[triangle] = surface
            }
        }
        exactSurfacesByTriangle = exactSurfaces

        let semanticEdges: [SelectedEdge] = (mesh.topologyHints?.edges ?? []).compactMap { edge in
            let orderedPoints: [SIMD3<Float>]
            if edge.points.count >= 2 {
                orderedPoints = edge.points
            } else {
                orderedPoints = edge.edges.sorted().flatMap { meshEdge -> [SIMD3<Float>] in
                    guard mesh.vertices.indices.contains(meshEdge.a), mesh.vertices.indices.contains(meshEdge.b) else {
                        return []
                    }
                    return [mesh.vertices[meshEdge.a], mesh.vertices[meshEdge.b]]
                }
            }
            guard orderedPoints.count >= 2 else { return nil }
            return SelectedEdge(
                source: mesh.sourceID,
                edges: edge.edges.sorted(),
                points: orderedPoints,
                id: Self.qualifiedID(mesh: mesh, sourceID: edge.sourceID),
                entitySource: .exactTopology,
                descriptor: edge.descriptor,
                incidentFaceIDs: edge.incidentFaceIDs
            )
        }.sorted { $0.id < $1.id }
        exactEdges = semanticEdges

        var inferredSurfaces: [MeshTriangleID: SelectedSurface] = [:]
        if exactSurfaces.isEmpty {
            for region in SurfacePrimitiveDetector.detect(
                mesh: mesh,
                featureEdgeDegrees: settings.featureEdgeDegrees
            ) {
                let surface = SelectedSurface(
                    source: mesh.sourceID,
                    triangles: region.triangles,
                    id: region.id,
                    entitySource: .inferredGeometry,
                    descriptor: region.descriptor
                )
                for triangle in region.triangles where inferredSurfaces[triangle] == nil {
                    inferredSurfaces[triangle] = surface
                }
            }
        }
        inferredSurfacesByTriangle = inferredSurfaces
        points = Self.makeSelectionPoints(
            mesh: mesh,
            exactEdges: semanticEdges,
            featureEdgesByVertex: featureAdjacency,
            records: records,
            exactSurfacesByTriangle: exactSurfaces,
            inferredSurfacesByTriangle: inferredSurfaces
        )
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

        guard let surface = surface(at: query.triangleID) else {
            return SelectionResolution(
                kind: .none,
                entity: nil,
                seedTriangle: query.triangleID,
                nearestFeatureEdgeDistance: nearest?.distance,
                edgeThreshold: edgeThreshold,
                reason: "none: hit surface is not exact topology, planar, or cylindrical",
                rejectionCode: .unsupportedSurface,
                acceleration: .cpuBVH
            )
        }
        return SelectionResolution(
            kind: .surface,
            entity: .surface(surface),
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

    public func surface(at triangleID: MeshTriangleID) -> SelectedSurface? {
        exactSurfacesByTriangle[triangleID] ?? inferredSurfacesByTriangle[triangleID]
    }

    public func exactFaceID(at triangleID: MeshTriangleID) -> SelectionEntityID? {
        exactSurfacesByTriangle[triangleID]?.id
    }

    public func points(incidentTo surface: SelectedSurface?) -> [SelectedPoint] {
        guard let surface else { return points }
        return points.filter { point in
            point.incidentFaceIDs.isEmpty || point.incidentFaceIDs.contains(where: {
                surface.id.rawValue == $0 || surface.id.rawValue.hasSuffix($0)
            })
        }
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

    private static func qualifiedID(mesh: MeshSnapshot, sourceID: String) -> SelectionEntityID {
        SelectionEntityID(
            "\(mesh.sourceID.model):\(mesh.sourceID.node):\(mesh.sourceID.geometry):\(sourceID)"
        )
    }

    private struct PointSeed {
        var position: SIMD3<Float>
        var entitySource: SelectionEntitySource
        var parentEntityIDs: Set<SelectionEntityID>
        var incidentFaceIDs: Set<String>
    }

    private static func makeSelectionPoints(
        mesh: MeshSnapshot,
        exactEdges: [SelectedEdge],
        featureEdgesByVertex: [Int: [MeshEdgeID]],
        records: [MeshEdgeID: EdgeRecord],
        exactSurfacesByTriangle: [MeshTriangleID: SelectedSurface],
        inferredSurfacesByTriangle: [MeshTriangleID: SelectedSurface]
    ) -> [SelectedPoint] {
        let tolerance = max(mesh.maxExtent * 0.000_01, 0.000_001)
        var vertexSeeds: [PointSeed] = []
        var curveCenters: [SelectedPoint] = []

        for edge in exactEdges where edge.points.count >= 2 {
            let isClosed = simd_distance(edge.points[0], edge.points[edge.points.count - 1]) <= tolerance
            if !isClosed {
                for endpoint in [edge.points[0], edge.points[edge.points.count - 1]] {
                    mergeVertexSeed(
                        PointSeed(
                            position: endpoint,
                            entitySource: .exactTopology,
                            parentEntityIDs: [edge.id],
                            incidentFaceIDs: edge.incidentFaceIDs
                        ),
                        into: &vertexSeeds,
                        tolerance: tolerance
                    )
                }
            }

            if edge.descriptor.kind == .circle,
               let circle = EdgePrimitiveFitter.fittedCircle(
                    points: edge.points,
                    tolerance: max(tolerance * 8, mesh.maxExtent * 0.000_2)
               ) {
                curveCenters.append(
                    SelectedPoint(
                        id: SelectionEntityID("\(edge.id.rawValue):point:center"),
                        source: mesh.sourceID,
                        entitySource: edge.entitySource,
                        kind: .curveCenter,
                        position: circle.center,
                        parentEntityIDs: [edge.id],
                        incidentFaceIDs: edge.incidentFaceIDs
                    )
                )
            }
        }

        if exactEdges.isEmpty {
            for (vertexIndex, incidentEdges) in featureEdgesByVertex.sorted(by: { $0.key < $1.key }) {
                guard mesh.vertices.indices.contains(vertexIndex),
                      isSelectableFeatureVertex(
                        vertexIndex,
                        incidentEdges: incidentEdges,
                        mesh: mesh
                      ) else {
                    continue
                }
                let faceIDs = Set(incidentEdges.flatMap { edge in
                    (records[edge]?.triangles ?? []).compactMap { triangleID in
                        (exactSurfacesByTriangle[triangleID] ?? inferredSurfacesByTriangle[triangleID])?.id.rawValue
                    }
                })
                let pointID = SelectionEntityID(
                    "\(mesh.sourceID.model):\(mesh.sourceID.node):\(mesh.sourceID.geometry):point:vertex:\(vertexIndex)"
                )
                let parentIDs = Set(incidentEdges.map { edge in
                    SelectionEntityID(
                        "\(mesh.sourceID.model):\(mesh.sourceID.node):\(mesh.sourceID.geometry):inferred:edge:\(edge.a)-\(edge.b)"
                    )
                })
                vertexSeeds.append(
                    PointSeed(
                        position: mesh.vertices[vertexIndex],
                        entitySource: .inferredGeometry,
                        parentEntityIDs: parentIDs.isEmpty ? [pointID] : parentIDs,
                        incidentFaceIDs: faceIDs
                    )
                )
            }
        }

        let vertices = vertexSeeds.map { seed -> SelectedPoint in
            let parents = seed.parentEntityIDs.sorted()
            let identity = parents.map(\.rawValue).joined(separator: "+")
            let id = SelectionEntityID(
                "\(mesh.sourceID.model):\(mesh.sourceID.node):\(mesh.sourceID.geometry):point:vertex:\(identity)"
            )
            return SelectedPoint(
                id: id,
                source: mesh.sourceID,
                entitySource: seed.entitySource,
                kind: .vertex,
                position: seed.position,
                parentEntityIDs: seed.parentEntityIDs,
                incidentFaceIDs: seed.incidentFaceIDs
            )
        }
        return (vertices + curveCenters).sorted { $0.id < $1.id }
    }

    private static func mergeVertexSeed(
        _ seed: PointSeed,
        into seeds: inout [PointSeed],
        tolerance: Float
    ) {
        if let index = seeds.firstIndex(where: { simd_distance($0.position, seed.position) <= tolerance }) {
            seeds[index].parentEntityIDs.formUnion(seed.parentEntityIDs)
            seeds[index].incidentFaceIDs.formUnion(seed.incidentFaceIDs)
            if seed.entitySource == .exactTopology {
                seeds[index].entitySource = .exactTopology
            }
        } else {
            seeds.append(seed)
        }
    }

    private static func isSelectableFeatureVertex(
        _ vertexIndex: Int,
        incidentEdges: [MeshEdgeID],
        mesh: MeshSnapshot
    ) -> Bool {
        guard incidentEdges.count == 2 else { return true }
        let origin = mesh.vertices[vertexIndex]
        let directions = incidentEdges.compactMap { edge -> SIMD3<Float>? in
            let other = edge.a == vertexIndex ? edge.b : edge.a
            guard mesh.vertices.indices.contains(other) else { return nil }
            return GeometryMath.normalized(mesh.vertices[other] - origin, fallback: .zero)
        }
        guard directions.count == 2 else { return true }
        let straightContinuationLimit: Float = -0.906_307_8
        return simd_dot(directions[0], directions[1]) > straightContinuationLimit
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
