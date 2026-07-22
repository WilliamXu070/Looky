import simd

public enum GeometryMath {
    public static func normalized(
        _ vector: SIMD3<Float>,
        fallback: SIMD3<Float> = SIMD3<Float>(0, 1, 0)
    ) -> SIMD3<Float> {
        let length = simd_length(vector)
        return length > 0 && length.isFinite ? vector / length : fallback
    }

    public static func triangleNormal(
        _ a: SIMD3<Float>,
        _ b: SIMD3<Float>,
        _ c: SIMD3<Float>
    ) -> SIMD3<Float> {
        normalized(simd_cross(b - a, c - a))
    }

    public static func triangleArea(
        _ a: SIMD3<Float>,
        _ b: SIMD3<Float>,
        _ c: SIMD3<Float>
    ) -> Float {
        simd_length(simd_cross(b - a, c - a)) * 0.5
    }

    public static func closestPoint(
        on segment: MeshSegment,
        to point: SIMD3<Float>
    ) -> SIMD3<Float> {
        let delta = segment.end - segment.start
        let denominator = simd_length_squared(delta)
        guard denominator > 0 else { return segment.start }
        let t = min(1, max(0, simd_dot(point - segment.start, delta) / denominator))
        return segment.start + delta * t
    }

    public static func distanceSquared(
        from point: SIMD3<Float>,
        to segment: MeshSegment
    ) -> Float {
        simd_length_squared(point - closestPoint(on: segment, to: point))
    }

    public static func polylineLength(_ points: [SIMD3<Float>]) -> Float {
        guard points.count > 1 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
    }

    public static func maxExtent(of vertices: [SIMD3<Float>]) -> Float {
        guard var minimum = vertices.first else { return 0 }
        var maximum = minimum
        for vertex in vertices.dropFirst() {
            minimum = simd_min(minimum, vertex)
            maximum = simd_max(maximum, vertex)
        }
        let size = maximum - minimum
        return max(size.x, max(size.y, size.z))
    }
}
