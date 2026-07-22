import Foundation
import simd

extension SelectionModel {
    static func populateTopology(
        triangles: inout [SelectionTriangle],
        edges: inout [SelectionEdge],
        featureEdgeDegrees: Float
    ) {
        for index in edges.indices {
            let edge = edges[index]
            for first in edge.triangleIDs {
                for second in edge.triangleIDs where first != second {
                    if !triangles[first.rawValue].neighborTriangleIDs.contains(second) {
                        triangles[first.rawValue].neighborTriangleIDs.append(second)
                    }
                }
            }

            let normals = edge.triangleIDs.map { triangles[$0.rawValue].normal }
            edges[index].displayNormal = SelectionGeometryMath.averageNormal(normals)

            if edge.triangleIDs.count == 1 {
                edges[index].isFeatureEdge = true
            } else if edge.triangleIDs.count >= 2 {
                let dotLimit = cosf(featureEdgeDegrees * .pi / 180.0)
                var isCrease = false
                for i in 0..<normals.count {
                    for j in (i + 1)..<normals.count {
                        if simd_dot(normals[i], normals[j]) < dotLimit {
                            isCrease = true
                        }
                    }
                }
                edges[index].isFeatureEdge = isCrease
            }
        }

        for index in triangles.indices {
            triangles[index].neighborTriangleIDs.sort()
        }
    }

    static func populateWeldedFeatureFlags(
        edges: inout [SelectionEdge],
        buckets: [SelectionWeldedEdgeKey: [SelectionWeldedEdgeEntry]],
        triangles: [SelectionTriangle],
        featureEdgeDegrees: Float
    ) {
        let triangleNormals = Dictionary(uniqueKeysWithValues: triangles.map { ($0.id, $0.normal) })
        let dotLimit = cosf(featureEdgeDegrees * .pi / 180.0)

        for entries in buckets.values {
            let isFeature: Bool
            if entries.count < 2 {
                isFeature = true
            } else {
                let normals = entries.compactMap { triangleNormals[$0.triangleID] }
                var crease = normals.count < 2
                for i in 0..<normals.count {
                    for j in (i + 1)..<normals.count {
                        if simd_dot(normals[i], normals[j]) < dotLimit {
                            crease = true
                        }
                    }
                }
                isFeature = crease
            }

            for entry in entries {
                if let edgeID = entry.edgeID, edges.indices.contains(edgeID.rawValue) {
                    edges[edgeID.rawValue].isWeldedFeatureEdge = isFeature
                }
            }
        }
    }

    static func buildFeatureEdgeSegments(
        buckets: [SelectionWeldedEdgeKey: [SelectionWeldedEdgeEntry]],
        edges: [SelectionEdge]
    ) -> [SelectionFeatureSegment] {
        buckets
            .sorted { $0.key < $1.key }
            .compactMap { _, entries -> SelectionFeatureSegment? in
                guard let first = entries.first else {
                    return nil
                }
                let isFeature = entries.contains { entry in
                    guard let edgeID = entry.edgeID,
                          edges.indices.contains(edgeID.rawValue)
                    else {
                        return false
                    }
                    return edges[edgeID.rawValue].isWeldedFeatureEdge
                }
                guard isFeature else {
                    return nil
                }
                return SelectionFeatureSegment(start: first.start, end: first.end)
            }
    }

    static func buildWeldedEdgeBuckets(
        vertices: [SIMD3<Float>],
        triangles: [SelectionTriangle],
        maxExtent: Float,
        settings: SelectionModelSettings
    ) -> [SelectionWeldedEdgeKey: [SelectionWeldedEdgeEntry]] {
        let tolerance = weldedVertexTolerance(maxExtent: maxExtent, settings: settings)
        var buckets: [SelectionWeldedEdgeKey: [SelectionWeldedEdgeEntry]] = [:]
        buckets.reserveCapacity(triangles.count * 3)

        for triangle in triangles {
            for localEdgeIndex in 0..<3 {
                let firstIndex = triangle.vertexIndices[localEdgeIndex]
                let secondIndex = triangle.vertexIndices[(localEdgeIndex + 1) % 3]
                let key = weldedEdgeKey(
                    from: vertices[firstIndex],
                    to: vertices[secondIndex],
                    tolerance: tolerance
                )
                buckets[key, default: []].append(
                    SelectionWeldedEdgeEntry(
                        triangleID: triangle.id,
                        edgeID: triangle.edgeIDs.indices.contains(localEdgeIndex) ? triangle.edgeIDs[localEdgeIndex] : nil,
                        start: vertices[firstIndex],
                        end: vertices[secondIndex]
                    )
                )
            }
        }

        return buckets
    }

    static func weldedEdgeKey(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        tolerance: Float
    ) -> SelectionWeldedEdgeKey {
        SelectionWeldedEdgeKey(
            SelectionWeldedVertexKey(start, tolerance: tolerance),
            SelectionWeldedVertexKey(end, tolerance: tolerance)
        )
    }

    static func weldedVertexTolerance(maxExtent: Float, settings: SelectionModelSettings) -> Float {
        max(maxExtent * settings.weldedVertexToleranceScale, settings.weldedVertexToleranceMinimum)
    }
}
