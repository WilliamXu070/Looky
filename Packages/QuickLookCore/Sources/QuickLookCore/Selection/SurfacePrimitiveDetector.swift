import simd

public struct InferredSurfaceRegion: Equatable, Sendable {
    public let id: SelectionEntityID
    public let triangles: [MeshTriangleID]
    public let descriptor: SurfaceDescriptor
}

public enum SurfacePrimitiveDetector {
    private struct WeldedVertexKey: Hashable {
        let x: Int64
        let y: Int64
        let z: Int64
    }

    private struct WeldedEdgeKey: Hashable {
        let a: WeldedVertexKey
        let b: WeldedVertexKey

        init(_ first: WeldedVertexKey, _ second: WeldedVertexKey) {
            if Self.less(first, second) {
                a = first
                b = second
            } else {
                a = second
                b = first
            }
        }

        private static func less(_ lhs: WeldedVertexKey, _ rhs: WeldedVertexKey) -> Bool {
            if lhs.x != rhs.x { return lhs.x < rhs.x }
            if lhs.y != rhs.y { return lhs.y < rhs.y }
            return lhs.z < rhs.z
        }
    }

    private struct Adjacency {
        let neighbors: [[MeshTriangleID]]
        let sharedEdges: [WeldedEdgeKey: [MeshTriangleID]]
        let edgeKeysByTriangle: [[WeldedEdgeKey]]
    }

    public static func detect(
        mesh: MeshSnapshot,
        featureEdgeDegrees: Float = 25,
        planeNormalDegrees: Float = 3
    ) -> [InferredSurfaceRegion] {
        guard !mesh.triangles.isEmpty, mesh.maxExtent.isFinite, mesh.maxExtent > 0 else {
            return []
        }

        let adjacency = makeAdjacency(mesh: mesh)
        let planeTolerance = max(mesh.maxExtent * 0.00015, 0.000001)
        let planeNormalDot = cos(planeNormalDegrees * .pi / 180)
        let featureNormalDot = cos(featureEdgeDegrees * .pi / 180)
        var assigned = Set<MeshTriangleID>()
        var result: [InferredSurfaceRegion] = []

        for triangle in mesh.triangles where !assigned.contains(triangle.id) {
            let region = planarRegion(
                seed: triangle.id,
                mesh: mesh,
                adjacency: adjacency,
                blocked: assigned,
                normalDot: planeNormalDot,
                distanceTolerance: planeTolerance
            )
            guard !region.isEmpty,
                  hasPrimitiveBoundary(
                    region: Set(region),
                    mesh: mesh,
                    adjacency: adjacency,
                    featureNormalDot: featureNormalDot
                  ) else {
                continue
            }

            let residuals = planeResiduals(region: region, mesh: mesh, seed: triangle.id)
            let descriptor = SurfaceDescriptor(
                kind: .plane,
                origin: mesh.vertices[triangle.indices[0]],
                normal: triangle.normal,
                fitRMS: rms(residuals),
                fitMaximumResidual: residuals.max()
            )
            let sorted = region.sorted()
            result.append(
                InferredSurfaceRegion(
                    id: inferredID(mesh: mesh, kind: .plane, seed: sorted[0]),
                    triangles: sorted,
                    descriptor: descriptor
                )
            )
            assigned.formUnion(region)
        }

        for triangle in mesh.triangles where !assigned.contains(triangle.id) {
            let component = smoothComponent(
                seed: triangle.id,
                mesh: mesh,
                adjacency: adjacency,
                blocked: assigned,
                featureNormalDot: featureNormalDot
            )
            assigned.formUnion(component)
            guard let descriptor = fitCylinder(region: component, mesh: mesh) else {
                continue
            }
            let sorted = component.sorted()
            result.append(
                InferredSurfaceRegion(
                    id: inferredID(mesh: mesh, kind: .cylinder, seed: sorted[0]),
                    triangles: sorted,
                    descriptor: descriptor
                )
            )
        }

        return result.sorted { $0.id < $1.id }
    }

    private static func makeAdjacency(mesh: MeshSnapshot) -> Adjacency {
        let tolerance = max(mesh.maxExtent * 0.00002, 0.000001)
        func key(_ vertex: SIMD3<Float>) -> WeldedVertexKey {
            WeldedVertexKey(
                x: Int64((vertex.x / tolerance).rounded()),
                y: Int64((vertex.y / tolerance).rounded()),
                z: Int64((vertex.z / tolerance).rounded())
            )
        }

        var sharedEdges: [WeldedEdgeKey: [MeshTriangleID]] = [:]
        var edgeKeysByTriangle = [[WeldedEdgeKey]](repeating: [], count: mesh.triangles.count)
        for triangle in mesh.triangles {
            let indices = triangle.indices
            let keys = [
                WeldedEdgeKey(key(mesh.vertices[indices[0]]), key(mesh.vertices[indices[1]])),
                WeldedEdgeKey(key(mesh.vertices[indices[1]]), key(mesh.vertices[indices[2]])),
                WeldedEdgeKey(key(mesh.vertices[indices[2]]), key(mesh.vertices[indices[0]])),
            ]
            edgeKeysByTriangle[triangle.id.rawValue] = keys
            for edge in keys {
                sharedEdges[edge, default: []].append(triangle.id)
            }
        }

        var neighbors = [[MeshTriangleID]](repeating: [], count: mesh.triangles.count)
        for entries in sharedEdges.values where entries.count > 1 {
            for triangle in entries {
                neighbors[triangle.rawValue].append(contentsOf: entries.filter { $0 != triangle })
            }
        }
        neighbors = neighbors.map { Array(Set($0)).sorted() }
        return Adjacency(neighbors: neighbors, sharedEdges: sharedEdges, edgeKeysByTriangle: edgeKeysByTriangle)
    }

    private static func planarRegion(
        seed: MeshTriangleID,
        mesh: MeshSnapshot,
        adjacency: Adjacency,
        blocked: Set<MeshTriangleID>,
        normalDot: Float,
        distanceTolerance: Float
    ) -> Set<MeshTriangleID> {
        let seedTriangle = mesh.triangles[seed.rawValue]
        let seedPoint = mesh.vertices[seedTriangle.indices[0]]
        var result: Set<MeshTriangleID> = [seed]
        var queue = [seed]
        var cursor = 0
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1
            for neighbor in adjacency.neighbors[current.rawValue] {
                guard !blocked.contains(neighbor), !result.contains(neighbor) else { continue }
                let candidate = mesh.triangles[neighbor.rawValue]
                guard abs(simd_dot(seedTriangle.normal, candidate.normal)) >= normalDot else { continue }
                let fits = candidate.indices.allSatisfy { index in
                    abs(simd_dot(mesh.vertices[index] - seedPoint, seedTriangle.normal)) <= distanceTolerance
                }
                if fits {
                    result.insert(neighbor)
                    queue.append(neighbor)
                }
            }
        }
        return result
    }

    private static func hasPrimitiveBoundary(
        region: Set<MeshTriangleID>,
        mesh: MeshSnapshot,
        adjacency: Adjacency,
        featureNormalDot: Float
    ) -> Bool {
        for triangleID in region {
            let triangle = mesh.triangles[triangleID.rawValue]
            for edge in adjacency.edgeKeysByTriangle[triangleID.rawValue] {
                for neighborID in adjacency.sharedEdges[edge] ?? [] where !region.contains(neighborID) {
                    let neighbor = mesh.triangles[neighborID.rawValue]
                    if abs(simd_dot(triangle.normal, neighbor.normal)) > featureNormalDot {
                        return false
                    }
                }
            }
        }
        return true
    }

    private static func planeResiduals(
        region: Set<MeshTriangleID>,
        mesh: MeshSnapshot,
        seed: MeshTriangleID
    ) -> [Float] {
        let triangle = mesh.triangles[seed.rawValue]
        let point = mesh.vertices[triangle.indices[0]]
        return region.flatMap { triangleID in
            mesh.triangles[triangleID.rawValue].indices.map {
                abs(simd_dot(mesh.vertices[$0] - point, triangle.normal))
            }
        }
    }

    private static func smoothComponent(
        seed: MeshTriangleID,
        mesh: MeshSnapshot,
        adjacency: Adjacency,
        blocked: Set<MeshTriangleID>,
        featureNormalDot: Float
    ) -> Set<MeshTriangleID> {
        var result: Set<MeshTriangleID> = [seed]
        var queue = [seed]
        var cursor = 0
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1
            let triangle = mesh.triangles[current.rawValue]
            for neighbor in adjacency.neighbors[current.rawValue] {
                guard !blocked.contains(neighbor), !result.contains(neighbor) else { continue }
                let candidate = mesh.triangles[neighbor.rawValue]
                if abs(simd_dot(triangle.normal, candidate.normal)) > featureNormalDot {
                    result.insert(neighbor)
                    queue.append(neighbor)
                }
            }
        }
        return result
    }

    private static func fitCylinder(
        region: Set<MeshTriangleID>,
        mesh: MeshSnapshot
    ) -> SurfaceDescriptor? {
        guard region.count >= 6 else { return nil }
        let triangles = region.sorted().map { mesh.triangles[$0.rawValue] }
        let sampledNormals = stride(from: 0, to: triangles.count, by: max(1, triangles.count / 64))
            .map { triangles[$0].normal }
        var bestAxis = SIMD3<Float>.zero
        var bestCrossSquared: Float = 0
        for first in sampledNormals.indices {
            for second in sampledNormals.indices where second > first {
                let cross = simd_cross(sampledNormals[first], sampledNormals[second])
                let lengthSquared = simd_length_squared(cross)
                if lengthSquared > bestCrossSquared {
                    bestCrossSquared = lengthSquared
                    bestAxis = cross
                }
            }
        }
        guard bestCrossSquared > 0.0001 else { return nil }
        let axis = GeometryMath.normalized(bestAxis, fallback: .zero)
        guard simd_length_squared(axis) > 0 else { return nil }

        let reference = abs(axis.x) < 0.8 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        let basisU = GeometryMath.normalized(simd_cross(axis, reference), fallback: .zero)
        let basisV = GeometryMath.normalized(simd_cross(axis, basisU), fallback: .zero)
        let points = triangles.flatMap { $0.indices.map { mesh.vertices[$0] } }
        let projected = points.map { SIMD2<Float>(simd_dot($0, basisU), simd_dot($0, basisV)) }
        guard let circle = fitCircle(points: projected) else { return nil }

        let residuals = projected.map { abs(simd_distance($0, circle.center) - circle.radius) }
        let maximumResidual = residuals.max() ?? .greatestFiniteMagnitude
        let tolerance = max(mesh.maxExtent * 0.0002, circle.radius * 0.005)
        let maximumAxisNormalDot = triangles.map { abs(simd_dot($0.normal, axis)) }.max() ?? 1
        guard maximumResidual <= tolerance,
              maximumAxisNormalDot <= sin(12 * .pi / 180) else {
            return nil
        }

        let meanAxisPosition = points.reduce(Float(0)) { $0 + simd_dot($1, axis) } / Float(points.count)
        let origin = basisU * circle.center.x + basisV * circle.center.y + axis * meanAxisPosition
        return SurfaceDescriptor(
            kind: .cylinder,
            origin: origin,
            axis: axis,
            radius: circle.radius,
            fitRMS: rms(residuals),
            fitMaximumResidual: maximumResidual
        )
    }

    private static func fitCircle(points: [SIMD2<Float>]) -> (center: SIMD2<Float>, radius: Float)? {
        guard points.count >= 3 else { return nil }
        var matrix = simd_float3x3(columns: (.zero, .zero, .zero))
        var vector = SIMD3<Float>.zero
        for point in points {
            let row = SIMD3<Float>(point.x, point.y, 1)
            matrix += simd_float3x3(rows: [row * row.x, row * row.y, row])
            vector += row * -(point.x * point.x + point.y * point.y)
        }
        let determinant = simd_determinant(matrix)
        guard determinant.isFinite, abs(determinant) > 1e-10 else { return nil }
        let solution = matrix.inverse * vector
        let center = SIMD2<Float>(-solution.x * 0.5, -solution.y * 0.5)
        let radiusSquared = simd_length_squared(center) - solution.z
        guard radiusSquared.isFinite, radiusSquared > 0 else { return nil }
        return (center, sqrt(radiusSquared))
    }

    private static func inferredID(
        mesh: MeshSnapshot,
        kind: SurfacePrimitiveKind,
        seed: MeshTriangleID
    ) -> SelectionEntityID {
        SelectionEntityID(
            "\(mesh.sourceID.model):\(mesh.sourceID.node):\(mesh.sourceID.geometry):inferred:\(kind.rawValue):\(seed.rawValue)"
        )
    }

    private static func rms(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        return sqrt(values.reduce(Float(0)) { $0 + $1 * $1 } / Float(values.count))
    }
}
