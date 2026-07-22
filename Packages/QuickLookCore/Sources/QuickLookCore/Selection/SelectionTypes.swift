import Foundation
import simd

public enum SelectionKind: String, Codable, Sendable {
    case point
    case edge
    case surface
    case none
}

public enum SelectionAcceleration: String, Codable, Sendable {
    case cpuBVH = "cpu-bvh"
    case metal
    case unavailable
}

public struct SelectionEntityID: Hashable, Comparable, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum SelectionRejectionCode: String, Codable, Sendable {
    case invalidHit = "invalid-hit"
    case unsupportedSurface = "unsupported-surface"
    case ambiguousEdge = "ambiguous-edge"
    case occluded
    case outsideEdgeAperture = "outside-edge-aperture"
    case selectionIndexPending = "selection-index-pending"
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
    public let id: SelectionEntityID
    public let source: MeshSourceID
    public let entitySource: SelectionEntitySource
    public let descriptor: CurveDescriptor
    public let edges: [MeshEdgeID]
    public let points: [SIMD3<Float>]
    public let incidentFaceIDs: Set<String>

    public init(
        source: MeshSourceID,
        edges: [MeshEdgeID],
        points: [SIMD3<Float>],
        id: SelectionEntityID? = nil,
        entitySource: SelectionEntitySource = .inferredGeometry,
        descriptor: CurveDescriptor = .init(kind: .other),
        incidentFaceIDs: Set<String> = []
    ) {
        self.id = id ?? SelectionEntityID(
            "\(source.model):\(source.node):\(source.geometry):edge:\(edges.first?.a ?? -1)-\(edges.first?.b ?? -1)"
        )
        self.source = source
        self.entitySource = entitySource
        self.descriptor = descriptor
        self.edges = edges
        self.points = points
        self.incidentFaceIDs = incidentFaceIDs
    }
}

public struct SelectedSurface: Equatable, Sendable {
    public let id: SelectionEntityID
    public let source: MeshSourceID
    public let entitySource: SelectionEntitySource
    public let descriptor: SurfaceDescriptor
    public let triangles: [MeshTriangleID]

    public init(
        source: MeshSourceID,
        triangles: [MeshTriangleID],
        id: SelectionEntityID? = nil,
        entitySource: SelectionEntitySource = .inferredGeometry,
        descriptor: SurfaceDescriptor = .init(kind: .other)
    ) {
        self.id = id ?? SelectionEntityID(
            "\(source.model):\(source.node):\(source.geometry):surface:\(triangles.first?.rawValue ?? -1)"
        )
        self.source = source
        self.entitySource = entitySource
        self.descriptor = descriptor
        self.triangles = triangles
    }
}

public enum PointSelectionKind: String, Codable, Sendable {
    case vertex
    case curveCenter = "curve-center"
}

public struct SelectedPoint: Equatable, Sendable {
    public let id: SelectionEntityID
    public let source: MeshSourceID
    public let entitySource: SelectionEntitySource
    public let kind: PointSelectionKind
    public let position: SIMD3<Float>
    public let parentEntityIDs: Set<SelectionEntityID>
    public let incidentFaceIDs: Set<String>

    public init(
        id: SelectionEntityID,
        source: MeshSourceID,
        entitySource: SelectionEntitySource,
        kind: PointSelectionKind,
        position: SIMD3<Float>,
        parentEntityIDs: Set<SelectionEntityID> = [],
        incidentFaceIDs: Set<String> = []
    ) {
        self.id = id
        self.source = source
        self.entitySource = entitySource
        self.kind = kind
        self.position = position
        self.parentEntityIDs = parentEntityIDs
        self.incidentFaceIDs = incidentFaceIDs
    }
}

public enum SelectionEntity: Equatable, Sendable {
    case point(SelectedPoint)
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
    public let rejectionCode: SelectionRejectionCode?
    public let acceleration: SelectionAcceleration

    public init(
        kind: SelectionKind,
        entity: SelectionEntity?,
        seedTriangle: MeshTriangleID?,
        nearestFeatureEdgeDistance: Float?,
        edgeThreshold: Float,
        reason: String,
        rejectionCode: SelectionRejectionCode? = nil,
        acceleration: SelectionAcceleration
    ) {
        self.kind = kind
        self.entity = entity
        self.seedTriangle = seedTriangle
        self.nearestFeatureEdgeDistance = nearestFeatureEdgeDistance
        self.edgeThreshold = edgeThreshold
        self.reason = reason
        self.rejectionCode = rejectionCode
        self.acceleration = acceleration
    }
}
