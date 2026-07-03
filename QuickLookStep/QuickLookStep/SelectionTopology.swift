import Foundation
import simd

struct SelectionTriangleID: Hashable, Comparable, RawRepresentable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static func < (lhs: SelectionTriangleID, rhs: SelectionTriangleID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct SelectionEdgeID: Hashable, Comparable, RawRepresentable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static func < (lhs: SelectionEdgeID, rhs: SelectionEdgeID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct SelectionSurfacePatchID: Hashable, Comparable, RawRepresentable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static func < (lhs: SelectionSurfacePatchID, rhs: SelectionSurfacePatchID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct SelectionEdgeLoopID: Hashable, Comparable, RawRepresentable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static func < (lhs: SelectionEdgeLoopID, rhs: SelectionEdgeLoopID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct SelectionEdgeKey: Hashable, Comparable {
    let a: Int
    let b: Int

    init(_ first: Int, _ second: Int) {
        if first < second {
            a = first
            b = second
        } else {
            a = second
            b = first
        }
    }

    static func < (lhs: SelectionEdgeKey, rhs: SelectionEdgeKey) -> Bool {
        if lhs.a != rhs.a { return lhs.a < rhs.a }
        return lhs.b < rhs.b
    }

    func otherVertex(from vertex: Int) -> Int? {
        if vertex == a { return b }
        if vertex == b { return a }
        return nil
    }
}

struct SelectionWeldedVertexKey: Hashable, Comparable {
    let x: Int64
    let y: Int64
    let z: Int64

    init(_ point: SIMD3<Float>, tolerance: Float) {
        let scale = max(tolerance, Float.ulpOfOne)
        x = Int64((point.x / scale).rounded())
        y = Int64((point.y / scale).rounded())
        z = Int64((point.z / scale).rounded())
    }

    static func < (lhs: SelectionWeldedVertexKey, rhs: SelectionWeldedVertexKey) -> Bool {
        if lhs.x != rhs.x { return lhs.x < rhs.x }
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        return lhs.z < rhs.z
    }
}

struct SelectionWeldedEdgeKey: Hashable, Comparable {
    let a: SelectionWeldedVertexKey
    let b: SelectionWeldedVertexKey

    init(_ first: SelectionWeldedVertexKey, _ second: SelectionWeldedVertexKey) {
        if second < first {
            a = second
            b = first
        } else {
            a = first
            b = second
        }
    }

    static func < (lhs: SelectionWeldedEdgeKey, rhs: SelectionWeldedEdgeKey) -> Bool {
        if lhs.a != rhs.a { return lhs.a < rhs.a }
        return lhs.b < rhs.b
    }
}

struct SelectionTriangle {
    let id: SelectionTriangleID
    let vertexIndices: [Int]
    let normal: SIMD3<Float>
    var edgeIDs: [SelectionEdgeID] = []
    var neighborTriangleIDs: [SelectionTriangleID] = []

    var edgeKeys: [SelectionEdgeKey] {
        [
            SelectionEdgeKey(vertexIndices[0], vertexIndices[1]),
            SelectionEdgeKey(vertexIndices[1], vertexIndices[2]),
            SelectionEdgeKey(vertexIndices[2], vertexIndices[0]),
        ]
    }

    func localEdges(in vertices: [SIMD3<Float>]) -> [(SIMD3<Float>, SIMD3<Float>)] {
        [
            (vertices[vertexIndices[0]], vertices[vertexIndices[1]]),
            (vertices[vertexIndices[1]], vertices[vertexIndices[2]]),
            (vertices[vertexIndices[2]], vertices[vertexIndices[0]]),
        ]
    }
}

struct SelectionEdge {
    let id: SelectionEdgeID
    let key: SelectionEdgeKey
    let weldedKey: SelectionWeldedEdgeKey
    var triangleIDs: [SelectionTriangleID] = []
    var displayNormal = SIMD3<Float>(0, 1, 0)
    var isFeatureEdge = false
    var isWeldedFeatureEdge = false

    var a: Int { key.a }
    var b: Int { key.b }
}

struct SelectionWeldedEdgeEntry {
    let triangleID: SelectionTriangleID
    let edgeID: SelectionEdgeID?
    let start: SIMD3<Float>
    let end: SIMD3<Float>
}

struct SelectionFeatureSegment {
    let start: SIMD3<Float>
    let end: SIMD3<Float>
}

struct SelectionDistanceResult {
    let distance: Float
    let acceleration: String
}

struct SelectionSurfacePatch {
    let id: SelectionSurfacePatchID
    let seedTriangleID: SelectionTriangleID
    let triangleIDs: [SelectionTriangleID]
    let isPlanar: Bool
}

struct SelectionEdgeLoop {
    let id: SelectionEdgeLoopID
    let seedEdgeID: SelectionEdgeID
    let edgeIDs: [SelectionEdgeID]
    let vertexPath: [Int]
    let isClosed: Bool
}

struct SelectionEdgeDistance {
    let edgeID: SelectionEdgeID
    let distance: Float
    let closestPoint: SIMD3<Float>
}

enum SelectionGeometryMath {
    static func triangleNormal(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> SIMD3<Float> {
        let normal = simd_cross(b - a, c - a)
        let length = simd_length(normal)
        guard length > 0 else {
            return SIMD3<Float>(0, 1, 0)
        }
        return normal / length
    }

    static func averageNormal(_ normals: [SIMD3<Float>]) -> SIMD3<Float> {
        let sum = normals.reduce(SIMD3<Float>(repeating: 0), +)
        let length = simd_length(sum)
        guard length > 0 else {
            return normals.first ?? SIMD3<Float>(0, 1, 0)
        }
        return sum / length
    }

    static func normalized(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(vector)
        guard length.isFinite, length > 0 else {
            return fallback
        }
        return vector / length
    }

    static func maxExtent(of vertices: [SIMD3<Float>]) -> Float {
        var minPoint = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var maxPoint = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)

        for vertex in vertices {
            minPoint = min(minPoint, vertex)
            maxPoint = max(maxPoint, vertex)
        }

        let size = maxPoint - minPoint
        return max(size.x, max(size.y, size.z))
    }

    static func closestPoint(onSegmentFrom start: SIMD3<Float>, to end: SIMD3<Float>, point: SIMD3<Float>) -> SIMD3<Float> {
        let segment = end - start
        let denominator = simd_dot(segment, segment)
        guard denominator > 0 else {
            return start
        }
        let t = max(0, min(1, simd_dot(point - start, segment) / denominator))
        return start + segment * t
    }

    static func pointTriangleDistanceSquared(
        _ point: SIMD3<Float>,
        _ a: SIMD3<Float>,
        _ b: SIMD3<Float>,
        _ c: SIMD3<Float>
    ) -> Float {
        let ab = b - a
        let ac = c - a
        let ap = point - a
        let d1 = simd_dot(ab, ap)
        let d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return simd_length_squared(ap) }

        let bp = point - b
        let d3 = simd_dot(ab, bp)
        let d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return simd_length_squared(bp) }

        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 {
            let v = d1 / (d1 - d3)
            return simd_length_squared(point - (a + v * ab))
        }

        let cp = point - c
        let d5 = simd_dot(ab, cp)
        let d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return simd_length_squared(cp) }

        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 {
            let w = d2 / (d2 - d6)
            return simd_length_squared(point - (a + w * ac))
        }

        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return simd_length_squared(point - (b + w * (c - b)))
        }

        let normal = triangleNormal(a, b, c)
        let signedDistance = simd_dot(point - a, normal)
        return signedDistance * signedDistance
    }
}
