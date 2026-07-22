import Foundation
import simd

public enum SelectionKind: String, Codable, Sendable {
    case edge
    case surface
    case none
}

public enum SelectionAcceleration: String, Codable, Sendable {
    case cpuBVH = "cpu-bvh"
    case metal
    case unavailable
}

public struct SelectionSettings: Equatable, Sendable {
    public var featureEdgeDegrees: Float
    public var smoothSurfaceDegrees: Float
    public var edgeThresholdScale: Float

    public init(
        featureEdgeDegrees: Float = 25,
        smoothSurfaceDegrees: Float = 65,
        edgeThresholdScale: Float = 0.012
    ) {
        self.featureEdgeDegrees = featureEdgeDegrees
        self.smoothSurfaceDegrees = smoothSurfaceDegrees
        self.edgeThresholdScale = edgeThresholdScale
    }
}

public struct SelectionQuery: Sendable {
    public let triangleID: MeshTriangleID
    public let localPoint: SIMD3<Float>

    public init(triangleID: MeshTriangleID, localPoint: SIMD3<Float>) {
        self.triangleID = triangleID
        self.localPoint = localPoint
    }
}

public struct SelectedEdge: Equatable, Sendable {
    public let source: MeshSourceID
    public let edges: [MeshEdgeID]
    public let points: [SIMD3<Float>]
}

public struct SelectedSurface: Equatable, Sendable {
    public let source: MeshSourceID
    public let triangles: [MeshTriangleID]
}

public enum SelectionEntity: Equatable, Sendable {
    case edge(SelectedEdge)
    case surface(SelectedSurface)
}

public struct SelectionResolution: Equatable, Sendable {
    public let kind: SelectionKind
    public let entity: SelectionEntity?
    public let seedTriangle: MeshTriangleID?
    public let nearestFeatureEdgeDistance: Float?
    public let edgeThreshold: Float
    public let reason: String
    public let acceleration: SelectionAcceleration
}
