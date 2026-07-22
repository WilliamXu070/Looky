import Foundation
import simd

public struct MeshSourceID: Hashable, Codable, Sendable {
    public let model: String
    public let node: String
    public let geometry: String

    public init(model: String, node: String, geometry: String) {
        self.model = model
        self.node = node
        self.geometry = geometry
    }
}

public struct MeshTriangleID: Hashable, Comparable, Codable, Sendable {
    public let rawValue: Int

    public init(_ rawValue: Int) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct MeshEdgeID: Hashable, Comparable, Codable, Sendable {
    public let a: Int
    public let b: Int

    public init(_ first: Int, _ second: Int) {
        a = min(first, second)
        b = max(first, second)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.a == rhs.a ? lhs.b < rhs.b : lhs.a < rhs.a
    }
}

public struct MeshTriangle: Equatable, Sendable {
    public let id: MeshTriangleID
    public let vertexIndices: SIMD3<Int32>
    public let normal: SIMD3<Float>

    public init(id: MeshTriangleID, vertexIndices: SIMD3<Int32>, normal: SIMD3<Float>) {
        self.id = id
        self.vertexIndices = vertexIndices
        self.normal = normal
    }

    public var indices: [Int] {
        [Int(vertexIndices.x), Int(vertexIndices.y), Int(vertexIndices.z)]
    }

    public var edges: [MeshEdgeID] {
        [
            MeshEdgeID(Int(vertexIndices.x), Int(vertexIndices.y)),
            MeshEdgeID(Int(vertexIndices.y), Int(vertexIndices.z)),
            MeshEdgeID(Int(vertexIndices.z), Int(vertexIndices.x)),
        ]
    }
}

public struct MeshSegment: Equatable, Sendable {
    public let id: MeshEdgeID
    public let start: SIMD3<Float>
    public let end: SIMD3<Float>

    public init(id: MeshEdgeID, start: SIMD3<Float>, end: SIMD3<Float>) {
        self.id = id
        self.start = start
        self.end = end
    }
}

public enum ModelUnit: String, Codable, Sendable {
    case unknown
    case millimeter
    case centimeter
    case meter
    case inch
    case foot
}

public struct ModelTransform: Equatable, Sendable {
    public let sourceToSceneScale: Float
    public let sourceCenter: SIMD3<Float>

    public init(sourceToSceneScale: Float = 1, sourceCenter: SIMD3<Float> = .zero) {
        self.sourceToSceneScale = sourceToSceneScale
        self.sourceCenter = sourceCenter
    }
}
