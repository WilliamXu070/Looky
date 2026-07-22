import simd

public struct SurfaceMeasurement: Equatable, Sendable {
    public let area: Float
    public let perimeter: Float
}

public enum MeasurementEngine {
    public static func edgeLength(points: [SIMD3<Float>]) -> Float {
        GeometryMath.polylineLength(points)
    }

    public static func surface(
        mesh: MeshSnapshot,
        triangles selected: [MeshTriangleID]
    ) -> SurfaceMeasurement {
        var edgeCounts: [MeshEdgeID: Int] = [:]
        var area: Float = 0
        for id in selected {
            guard mesh.triangles.indices.contains(id.rawValue) else { continue }
            let triangle = mesh.triangles[id.rawValue]
            let indices = triangle.indices
            area += GeometryMath.triangleArea(
                mesh.vertices[indices[0]],
                mesh.vertices[indices[1]],
                mesh.vertices[indices[2]]
            )
            for edge in triangle.edges {
                edgeCounts[edge, default: 0] += 1
            }
        }
        let perimeter = edgeCounts.reduce(Float(0)) { partial, entry in
            guard entry.value == 1,
                  mesh.vertices.indices.contains(entry.key.a),
                  mesh.vertices.indices.contains(entry.key.b)
            else { return partial }
            return partial + simd_distance(mesh.vertices[entry.key.a], mesh.vertices[entry.key.b])
        }
        return SurfaceMeasurement(area: area, perimeter: perimeter)
    }
}
