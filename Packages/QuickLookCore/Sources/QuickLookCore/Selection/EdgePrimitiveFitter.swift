import simd

public enum EdgePrimitive: Equatable, Sendable {
    case line(length: Float, direction: SIMD3<Float>)
    case arc(radius: Float, sweepRadians: Float)
    case polyline(length: Float)
}

public enum EdgePrimitiveFitter {
    public struct FittedCircle: Equatable, Sendable {
        public let center: SIMD3<Float>
        public let normal: SIMD3<Float>
        public let radius: Float

        public init(center: SIMD3<Float>, normal: SIMD3<Float>, radius: Float) {
            self.center = center
            self.normal = normal
            self.radius = radius
        }
    }

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

    /// Fits a stable 3D circle for semantic curve-center points without changing the
    /// edge classifier's existing line/arc decision path.
    public static func fittedCircle(
        points: [SIMD3<Float>],
        tolerance: Float
    ) -> FittedCircle? {
        let tolerance = max(tolerance, 1e-7)
        var unique: [SIMD3<Float>] = []
        unique.reserveCapacity(points.count)
        for point in points where !unique.contains(where: { simd_distance($0, point) <= tolerance }) {
            unique.append(point)
        }
        guard unique.count >= 3, let first = unique.first else { return nil }

        guard let second = unique.max(by: {
            simd_distance_squared(first, $0) < simd_distance_squared(first, $1)
        }), simd_distance(first, second) > tolerance else {
            return nil
        }
        let axis = GeometryMath.normalized(second - first, fallback: .zero)
        guard let third = unique.max(by: {
            distanceSquaredFromLine($0, origin: first, direction: axis)
                < distanceSquaredFromLine($1, origin: first, direction: axis)
        }), distanceSquaredFromLine(third, origin: first, direction: axis) > tolerance * tolerance,
              let circle = circleThrough(first, second, third) else {
            return nil
        }

        let normal = GeometryMath.normalized(
            simd_cross(second - first, third - first),
            fallback: .zero
        )
        guard simd_length_squared(normal) > 0 else { return nil }
        for point in unique {
            let planeError = abs(simd_dot(point - first, normal))
            let radialError = abs(simd_distance(point, circle.center) - circle.radius)
            guard planeError <= tolerance, radialError <= tolerance else { return nil }
        }
        return FittedCircle(center: circle.center, normal: normal, radius: circle.radius)
    }

    private static func distanceSquaredFromLine(
        _ point: SIMD3<Float>,
        origin: SIMD3<Float>,
        direction: SIMD3<Float>
    ) -> Float {
        let offset = point - origin
        let rejection = offset - direction * simd_dot(offset, direction)
        return simd_length_squared(rejection)
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
