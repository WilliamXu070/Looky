import simd

public struct FeatureEdgeHit: Equatable, Sendable {
    public let segment: MeshSegment
    public let point: SIMD3<Float>
    public let distance: Float
}

public struct FeatureEdgeBVH: Sendable {
    private struct Bounds: Sendable {
        var minimum: SIMD3<Float>
        var maximum: SIMD3<Float>

        init(segment: MeshSegment) {
            minimum = simd_min(segment.start, segment.end)
            maximum = simd_max(segment.start, segment.end)
        }

        mutating func include(_ other: Bounds) {
            minimum = simd_min(minimum, other.minimum)
            maximum = simd_max(maximum, other.maximum)
        }

        func distanceSquared(to point: SIMD3<Float>) -> Float {
            let closest = simd_min(simd_max(point, minimum), maximum)
            return simd_length_squared(point - closest)
        }
    }

    private indirect enum Node: Sendable {
        case leaf(Bounds, [MeshSegment])
        case branch(Bounds, Node, Node)

        var bounds: Bounds {
            switch self {
            case .leaf(let bounds, _), .branch(let bounds, _, _): bounds
            }
        }
    }

    private let root: Node?

    public init(segments: [MeshSegment], leafSize: Int = 8) {
        root = Self.build(segments, leafSize: max(2, leafSize))
    }

    public func nearest(to point: SIMD3<Float>) -> FeatureEdgeHit? {
        guard let root else { return nil }
        var best: FeatureEdgeHit?
        Self.query(root, point: point, best: &best)
        return best
    }

    private static func build(_ segments: [MeshSegment], leafSize: Int) -> Node? {
        guard let first = segments.first else { return nil }
        var bounds = Bounds(segment: first)
        for segment in segments.dropFirst() {
            bounds.include(Bounds(segment: segment))
        }
        guard segments.count > leafSize else { return .leaf(bounds, segments) }

        let extent = bounds.maximum - bounds.minimum
        let axis = extent.x >= extent.y && extent.x >= extent.z ? 0 : (extent.y >= extent.z ? 1 : 2)
        let sorted = segments.sorted {
            (($0.start[axis] + $0.end[axis]) * 0.5) < (($1.start[axis] + $1.end[axis]) * 0.5)
        }
        let midpoint = sorted.count / 2
        guard
            let left = build(Array(sorted[..<midpoint]), leafSize: leafSize),
            let right = build(Array(sorted[midpoint...]), leafSize: leafSize)
        else {
            return .leaf(bounds, segments)
        }
        return .branch(bounds, left, right)
    }

    private static func query(_ node: Node, point: SIMD3<Float>, best: inout FeatureEdgeHit?) {
        let bestSquared = best.map { $0.distance * $0.distance } ?? .greatestFiniteMagnitude
        guard node.bounds.distanceSquared(to: point) <= bestSquared else { return }

        switch node {
        case .leaf(_, let segments):
            for segment in segments {
                let closest = GeometryMath.closestPoint(on: segment, to: point)
                let distance = simd_distance(point, closest)
                if distance < (best?.distance ?? .greatestFiniteMagnitude) {
                    best = FeatureEdgeHit(segment: segment, point: closest, distance: distance)
                }
            }
        case .branch(_, let left, let right):
            let leftDistance = left.bounds.distanceSquared(to: point)
            let rightDistance = right.bounds.distanceSquared(to: point)
            if leftDistance <= rightDistance {
                query(left, point: point, best: &best)
                query(right, point: point, best: &best)
            } else {
                query(right, point: point, best: &best)
                query(left, point: point, best: &best)
            }
        }
    }
}
