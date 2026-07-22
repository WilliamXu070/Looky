import Foundation
import simd

public struct MeshSnapshot: Sendable {
    public let sourceID: MeshSourceID
    public let vertices: [SIMD3<Float>]
    public let triangles: [MeshTriangle]
    public let sourceUnit: ModelUnit
    public let transform: ModelTransform
    public let topologyHints: TopologyHints?

    public init(
        sourceID: MeshSourceID,
        vertices: [SIMD3<Float>],
        triangleIndices: [SIMD3<Int32>],
        sourceUnit: ModelUnit = .unknown,
        transform: ModelTransform = .init(),
        topologyHints: TopologyHints? = nil
    ) {
        self.sourceID = sourceID
        self.vertices = vertices
        self.sourceUnit = sourceUnit
        self.transform = transform
        self.topologyHints = topologyHints
        triangles = triangleIndices.enumerated().compactMap { index, indices in
            let values = [Int(indices.x), Int(indices.y), Int(indices.z)]
            guard values.allSatisfy(vertices.indices.contains) else { return nil }
            return MeshTriangle(
                id: MeshTriangleID(index),
                vertexIndices: indices,
                normal: GeometryMath.triangleNormal(
                    vertices[values[0]],
                    vertices[values[1]],
                    vertices[values[2]]
                )
            )
        }
    }

    public var maxExtent: Float {
        GeometryMath.maxExtent(of: vertices)
    }
}
