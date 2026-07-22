import Foundation
import simd

public enum SelectionEntitySource: String, Codable, Sendable {
    case exactTopology = "exact-topology"
    case inferredGeometry = "inferred-geometry"
}

public enum SurfacePrimitiveKind: String, Codable, Sendable {
    case plane
    case cylinder
    case cone
    case sphere
    case torus
    case bSpline = "b-spline"
    case other
}

public enum CurvePrimitiveKind: String, Codable, Sendable {
    case line
    case circle
    case ellipse
    case bSpline = "b-spline"
    case other
}

public struct SurfaceDescriptor: Hashable, Codable, Sendable {
    public let kind: SurfacePrimitiveKind
    public let origin: SIMD3<Float>?
    public let axis: SIMD3<Float>?
    public let normal: SIMD3<Float>?
    public let radius: Float?
    public let secondaryRadius: Float?
    public let halfAngle: Float?
    public let fitRMS: Float?
    public let fitMaximumResidual: Float?

    public init(
        kind: SurfacePrimitiveKind,
        origin: SIMD3<Float>? = nil,
        axis: SIMD3<Float>? = nil,
        normal: SIMD3<Float>? = nil,
        radius: Float? = nil,
        secondaryRadius: Float? = nil,
        halfAngle: Float? = nil,
        fitRMS: Float? = nil,
        fitMaximumResidual: Float? = nil
    ) {
        self.kind = kind
        self.origin = origin
        self.axis = axis
        self.normal = normal
        self.radius = radius
        self.secondaryRadius = secondaryRadius
        self.halfAngle = halfAngle
        self.fitRMS = fitRMS
        self.fitMaximumResidual = fitMaximumResidual
    }
}

public struct CurveDescriptor: Hashable, Codable, Sendable {
    public let kind: CurvePrimitiveKind
    public let radius: Float?
    public let fitRMS: Float?
    public let fitMaximumResidual: Float?

    public init(
        kind: CurvePrimitiveKind,
        radius: Float? = nil,
        fitRMS: Float? = nil,
        fitMaximumResidual: Float? = nil
    ) {
        self.kind = kind
        self.radius = radius
        self.fitRMS = fitRMS
        self.fitMaximumResidual = fitMaximumResidual
    }
}

public struct SourceFaceHint: Hashable, Codable, Sendable {
    public let sourceID: String
    public let triangles: Set<MeshTriangleID>
    public let descriptor: SurfaceDescriptor

    public init(
        sourceID: String,
        triangles: Set<MeshTriangleID>,
        descriptor: SurfaceDescriptor = .init(kind: .other)
    ) {
        self.sourceID = sourceID
        self.triangles = triangles
        self.descriptor = descriptor
    }
}

public struct SourceEdgeHint: Hashable, Codable, Sendable {
    public let sourceID: String
    public let edges: Set<MeshEdgeID>
    public let points: [SIMD3<Float>]
    public let incidentFaceIDs: Set<String>
    public let descriptor: CurveDescriptor

    public init(
        sourceID: String,
        edges: Set<MeshEdgeID> = [],
        points: [SIMD3<Float>] = [],
        incidentFaceIDs: Set<String> = [],
        descriptor: CurveDescriptor = .init(kind: .other)
    ) {
        self.sourceID = sourceID
        self.edges = edges
        self.points = points
        self.incidentFaceIDs = incidentFaceIDs
        self.descriptor = descriptor
    }
}

public struct TopologyHints: Equatable, Codable, Sendable {
    public let faces: [SourceFaceHint]
    public let edges: [SourceEdgeHint]

    public init(faces: [SourceFaceHint] = [], edges: [SourceEdgeHint] = []) {
        self.faces = faces
        self.edges = edges
    }
}
