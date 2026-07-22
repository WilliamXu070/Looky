import Foundation

public struct SourceFaceHint: Hashable, Codable, Sendable {
    public let sourceID: String
    public let triangles: Set<MeshTriangleID>

    public init(sourceID: String, triangles: Set<MeshTriangleID>) {
        self.sourceID = sourceID
        self.triangles = triangles
    }
}

public struct SourceEdgeHint: Hashable, Codable, Sendable {
    public let sourceID: String
    public let edges: Set<MeshEdgeID>

    public init(sourceID: String, edges: Set<MeshEdgeID>) {
        self.sourceID = sourceID
        self.edges = edges
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
