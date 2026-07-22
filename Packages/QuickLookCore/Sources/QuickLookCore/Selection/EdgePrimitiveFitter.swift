import simd

public enum EdgePrimitive: Equatable, Sendable {
    case line(length: Float, direction: SIMD3<Float>)
    case arc(radius: Float, sweepRadians: Float)
    case polyline(length: Float)
}

public enum EdgePrimitiveFitter {
    public static func fit(points: [SIMD3<Float>], tolerance: Float) -> EdgePrimitive? {
        guard points.count >= 2 else { return nil }
        let length = GeometryMath.polylineLength(points)
        let direction = GeometryMath.normalized(points.last! - points.first!, fallback: .zero)
        let maximumLineError = points.map { point -> Float in
            let offset = point - points[0]
            return simd_length(offset - direction * simd_dot(offset, direction))
        }.max() ?? 0
        if maximumLineError <= tolerance {
            return .line(length: length, direction: direction)
        }

        guard points.count >= 3 else { return .polyline(length: length) }
        let middle = points[points.count / 2]
        if let circle = circleThrough(points[0], middle, points[points.count - 1]),
           points.allSatisfy({ abs(simd_distance($0, circle.center) - circle.radius) <= tolerance })
        {
            return .arc(radius: circle.radius, sweepRadians: min(2 * .pi, length / circle.radius))
        }
        return .polyline(length: length)
    }

    private static func circleThrough(
        _ a: SIMD3<Float>,
        _ b: SIMD3<Float>,
        _ c: SIMD3<Float>
    ) -> (center: SIMD3<Float>, radius: Float)? {
        let ab = b - a
        let ac = c - a
        let normal = simd_cross(ab, ac)
        let denominator = 2 * simd_length_squared(normal)
        guard denominator > 1e-12 else { return nil }
        let center = a + (
            simd_cross(normal, ab) * simd_length_squared(ac) +
            simd_cross(ac, normal) * simd_length_squared(ab)
        ) / denominator
        let radius = simd_distance(center, a)
        return radius.isFinite && radius > 0 ? (center, radius) : nil
    }
}
