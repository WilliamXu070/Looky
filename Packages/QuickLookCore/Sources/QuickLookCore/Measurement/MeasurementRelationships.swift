import simd

public enum MeasurementDisplayUnit: String, Codable, CaseIterable, Sendable {
    case millimeters = "mm"
    case inches = "in"
}

public struct MeasurementScaleContext: Equatable, Sendable {
    public let sourceUnit: ModelUnit
    public let millimetersPerSourceUnitOverride: Double?

    public init(
        sourceUnit: ModelUnit,
        millimetersPerSourceUnitOverride: Double? = nil
    ) {
        self.sourceUnit = sourceUnit
        self.millimetersPerSourceUnitOverride = millimetersPerSourceUnitOverride
    }

    public var isAssumed: Bool {
        sourceUnit == .unknown && millimetersPerSourceUnitOverride == nil
    }

    public var millimetersPerSourceUnit: Double {
        if let override = millimetersPerSourceUnitOverride,
           override.isFinite, override > 0 {
            return override
        }
        switch sourceUnit {
        case .unknown, .millimeter: return 1
        case .centimeter: return 10
        case .meter: return 1_000
        case .inch: return 25.4
        case .foot: return 304.8
        }
    }

    public func convertLength(_ value: Float, to unit: MeasurementDisplayUnit) -> Double {
        let millimeters = Double(value) * millimetersPerSourceUnit
        return unit == .millimeters ? millimeters : millimeters / 25.4
    }

    public func convertArea(_ value: Float, to unit: MeasurementDisplayUnit) -> Double {
        let scale = millimetersPerSourceUnit
        let squareMillimeters = Double(value) * scale * scale
        return unit == .millimeters ? squareMillimeters : squareMillimeters / (25.4 * 25.4)
    }
}

public enum MeasurementGeometryKind: String, Codable, Sendable {
    case point
    case line
    case arc
    case circle
    case plane
    case cylinder
    case other
}

public enum MeasurementRelation: String, Codable, Sendable {
    case parallel
    case perpendicular
    case angled
    case skew
    case intersecting
    case coincident
    case concentric
    case coaxial
    case general
}

public struct MeasurementGeometry: Equatable, Sendable {
    public let kind: MeasurementGeometryKind
    public let points: [SIMD3<Float>]
    /// Flattened triangle vertices. Every consecutive group of three is one triangle.
    public let triangleVertices: [SIMD3<Float>]
    public let origin: SIMD3<Float>?
    public let axis: SIMD3<Float>?
    public let normal: SIMD3<Float>?
    public let radius: Float?

    public init(
        kind: MeasurementGeometryKind,
        points: [SIMD3<Float>] = [],
        triangleVertices: [SIMD3<Float>] = [],
        origin: SIMD3<Float>? = nil,
        axis: SIMD3<Float>? = nil,
        normal: SIMD3<Float>? = nil,
        radius: Float? = nil
    ) {
        self.kind = kind
        self.points = points
        self.triangleVertices = triangleVertices
        self.origin = origin
        self.axis = axis
        self.normal = normal
        self.radius = radius
    }
}

public struct MeasurementPointPair: Equatable, Sendable {
    public let first: SIMD3<Float>
    public let second: SIMD3<Float>

    public var delta: SIMD3<Float> { second - first }
    public var distance: Float { simd_distance(first, second) }
}

public struct MeasurementPairResult: Equatable, Sendable {
    public let relation: MeasurementRelation
    public let angleDegrees: Float?
    public let minimum: MeasurementPointPair?
    public let maximum: MeasurementPointPair?
    public let centerDistance: Float?
    public let axisDistance: Float?
    public let radialGap: Float?
}

public extension MeasurementEngine {
    static func compare(
        _ first: MeasurementGeometry,
        _ second: MeasurementGeometry,
        angularToleranceDegrees: Float = 1
    ) -> MeasurementPairResult {
        let closest = closestPair(first, second)
        let farthest = farthestPair(first, second)
        let positionTolerance = max(combinedExtent(first, second) * 0.00001, 0.000001)
        let relation = relationship(
            first,
            second,
            minimumDistance: closest?.distance,
            positionTolerance: positionTolerance,
            angularToleranceDegrees: angularToleranceDegrees
        )
        let angle = relationshipAngle(first, second)
        let firstCenter = center(of: first)
        let secondCenter = center(of: second)
        let centerDistance: Float?
        if let firstCenter, let secondCenter {
            centerDistance = simd_distance(firstCenter, secondCenter)
        } else {
            centerDistance = nil
        }
        let axisDistance = axisSeparation(first, second)
        let radialGap: Float?
        if let firstRadius = first.radius, let secondRadius = second.radius {
            radialGap = abs(firstRadius - secondRadius)
        } else {
            radialGap = nil
        }

        return MeasurementPairResult(
            relation: relation,
            angleDegrees: angle,
            minimum: closest,
            maximum: farthest,
            centerDistance: centerDistance,
            axisDistance: axisDistance,
            radialGap: radialGap
        )
    }

    private static func relationship(
        _ first: MeasurementGeometry,
        _ second: MeasurementGeometry,
        minimumDistance: Float?,
        positionTolerance: Float,
        angularToleranceDegrees: Float
    ) -> MeasurementRelation {
        if let planeRelation = relationshipToPlane(
            first,
            second,
            minimumDistance: minimumDistance,
            positionTolerance: positionTolerance,
            angularToleranceDegrees: angularToleranceDegrees
        ) {
            return planeRelation
        }

        if isCircular(first.kind), isCircular(second.kind),
           let firstFrame = circleFrame(first), let secondFrame = circleFrame(second) {
            let axisAngle = unorientedAngleDegrees(firstFrame.normal, secondFrame.normal)
            let delta = secondFrame.center - firstFrame.center
            let axialOffset = abs(simd_dot(delta, firstFrame.normal))
            let lateralOffset = simd_length(delta - firstFrame.normal * simd_dot(delta, firstFrame.normal))
            if axisAngle <= angularToleranceDegrees {
                if lateralOffset <= positionTolerance && axialOffset <= positionTolerance {
                    return .concentric
                }
                if lateralOffset <= positionTolerance {
                    return .coaxial
                }
                return .parallel
            }
            return (minimumDistance ?? .greatestFiniteMagnitude) <= positionTolerance
                ? .intersecting
                : .angled
        }

        guard let firstDirection = relationDirection(first),
              let secondDirection = relationDirection(second) else {
            return (minimumDistance ?? .greatestFiniteMagnitude) <= positionTolerance
                ? .intersecting
                : .general
        }

        let angle = unorientedAngleDegrees(firstDirection, secondDirection)
        let minimum = minimumDistance ?? .greatestFiniteMagnitude
        if angle <= angularToleranceDegrees {
            if minimum <= positionTolerance {
                return .coincident
            }
            if first.kind == .cylinder && second.kind == .cylinder,
               (axisSeparation(first, second) ?? .greatestFiniteMagnitude) <= positionTolerance {
                return .coaxial
            }
            return .parallel
        }
        if abs(angle - 90) <= angularToleranceDegrees {
            return .perpendicular
        }
        if minimum <= positionTolerance {
            return .intersecting
        }

        if first.kind == .line && second.kind == .line,
           let firstPoint = first.points.first,
           let secondPoint = second.points.first {
            let cross = simd_cross(firstDirection, secondDirection)
            let crossLength = simd_length(cross)
            if crossLength > 0,
               abs(simd_dot(secondPoint - firstPoint, cross / crossLength)) > positionTolerance {
                return .skew
            }
        }
        return .angled
    }

    private static func relationshipToPlane(
        _ first: MeasurementGeometry,
        _ second: MeasurementGeometry,
        minimumDistance: Float?,
        positionTolerance: Float,
        angularToleranceDegrees: Float
    ) -> MeasurementRelation? {
        let directed: MeasurementGeometry
        let plane: MeasurementGeometry
        if first.kind == .plane, second.kind == .line || second.kind == .cylinder {
            directed = second
            plane = first
        } else if second.kind == .plane, first.kind == .line || first.kind == .cylinder {
            directed = first
            plane = second
        } else {
            return nil
        }
        guard let direction = relationDirection(directed),
              let normal = relationDirection(plane) else {
            return .general
        }
        let angleToPlane = 90 - unorientedAngleDegrees(direction, normal)
        if angleToPlane <= angularToleranceDegrees {
            return (minimumDistance ?? .greatestFiniteMagnitude) <= positionTolerance
                ? .coincident
                : .parallel
        }
        if abs(angleToPlane - 90) <= angularToleranceDegrees {
            return .perpendicular
        }
        return (minimumDistance ?? .greatestFiniteMagnitude) <= positionTolerance
            ? .intersecting
            : .angled
    }

    private static func relationshipAngle(
        _ first: MeasurementGeometry,
        _ second: MeasurementGeometry
    ) -> Float? {
        guard let firstDirection = relationDirection(first),
              let secondDirection = relationDirection(second) else {
            return nil
        }

        if first.kind == .line, second.kind == .plane {
            return 90 - unorientedAngleDegrees(firstDirection, secondDirection)
        }
        if first.kind == .plane, second.kind == .line {
            return 90 - unorientedAngleDegrees(firstDirection, secondDirection)
        }
        if first.kind == .cylinder, second.kind == .plane {
            return 90 - unorientedAngleDegrees(firstDirection, secondDirection)
        }
        if first.kind == .plane, second.kind == .cylinder {
            return 90 - unorientedAngleDegrees(firstDirection, secondDirection)
        }
        return unorientedAngleDegrees(firstDirection, secondDirection)
    }

    private static func relationDirection(_ geometry: MeasurementGeometry) -> SIMD3<Float>? {
        switch geometry.kind {
        case .point:
            return nil
        case .line:
            return principalDirection(geometry.points)
        case .arc, .circle:
            return circleFrame(geometry)?.normal
        case .plane:
            return normalizedOptional(geometry.normal) ?? triangleNormal(geometry.triangleVertices)
        case .cylinder:
            return normalizedOptional(geometry.axis)
        case .other:
            return nil
        }
    }

    private static func center(of geometry: MeasurementGeometry) -> SIMD3<Float>? {
        if let origin = geometry.origin { return origin }
        if isCircular(geometry.kind), let frame = circleFrame(geometry) { return frame.center }
        let support = supportPoints(geometry)
        guard !support.isEmpty else { return nil }
        return support.reduce(.zero, +) / Float(support.count)
    }

    private static func circleFrame(
        _ geometry: MeasurementGeometry
    ) -> (center: SIMD3<Float>, normal: SIMD3<Float>)? {
        if let origin = geometry.origin,
           let normal = normalizedOptional(geometry.normal ?? geometry.axis) {
            return (origin, normal)
        }
        guard geometry.points.count >= 3 else { return nil }
        let first = geometry.points[0]
        for middleIndex in 1..<(geometry.points.count - 1) {
            for finalIndex in (middleIndex + 1)..<geometry.points.count {
                let middle = geometry.points[middleIndex]
                let final = geometry.points[finalIndex]
                let ab = middle - first
                let ac = final - first
                let cross = simd_cross(ab, ac)
                let denominator = 2 * simd_length_squared(cross)
                guard denominator > 0.000000000001 else { continue }
                let center = first + (
                    simd_cross(cross, ab) * simd_length_squared(ac)
                    + simd_cross(ac, cross) * simd_length_squared(ab)
                ) / denominator
                return (center, simd_normalize(cross))
            }
        }
        return nil
    }

    private static func axisSeparation(
        _ first: MeasurementGeometry,
        _ second: MeasurementGeometry
    ) -> Float? {
        guard let firstAxis = axisLine(first), let secondAxis = axisLine(second) else { return nil }
        return infiniteLineDistance(
            firstAxis.origin,
            firstAxis.direction,
            secondAxis.origin,
            secondAxis.direction
        )
    }

    private static func axisLine(
        _ geometry: MeasurementGeometry
    ) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        if geometry.kind == .cylinder,
           let origin = geometry.origin,
           let direction = normalizedOptional(geometry.axis) {
            return (origin, direction)
        }
        if isCircular(geometry.kind), let frame = circleFrame(geometry) {
            return (frame.center, frame.normal)
        }
        return nil
    }

    private static func closestPair(
        _ first: MeasurementGeometry,
        _ second: MeasurementGeometry
    ) -> MeasurementPointPair? {
        let firstSegments = segments(first.points)
        let secondSegments = segments(second.points)
        let firstTriangles = triangles(first.triangleVertices)
        let secondTriangles = triangles(second.triangleVertices)
        var best: MeasurementPointPair?

        func consider(_ candidate: MeasurementPointPair) {
            if best == nil || candidate.distance < best!.distance {
                best = candidate
            }
        }

        for a in firstSegments {
            for b in secondSegments {
                consider(segmentSegmentPair(a.0, a.1, b.0, b.1))
            }
            for triangle in secondTriangles {
                consider(segmentTrianglePair(a.0, a.1, triangle))
            }
        }
        for triangle in firstTriangles {
            for b in secondSegments {
                let reversed = segmentTrianglePair(b.0, b.1, triangle)
                consider(MeasurementPointPair(first: reversed.second, second: reversed.first))
            }
            for other in secondTriangles {
                for edge in triangleEdges(triangle) {
                    consider(segmentTrianglePair(edge.0, edge.1, other))
                }
                for edge in triangleEdges(other) {
                    let reversed = segmentTrianglePair(edge.0, edge.1, triangle)
                    consider(MeasurementPointPair(first: reversed.second, second: reversed.first))
                }
            }
        }

        if best == nil {
            for a in sampledSupportPoints(first) {
                for b in sampledSupportPoints(second) {
                    consider(MeasurementPointPair(first: a, second: b))
                }
            }
        }
        return best
    }

    private static func farthestPair(
        _ first: MeasurementGeometry,
        _ second: MeasurementGeometry
    ) -> MeasurementPointPair? {
        var farthest: MeasurementPointPair?
        for a in sampledSupportPoints(first) {
            for b in sampledSupportPoints(second) {
                let candidate = MeasurementPointPair(first: a, second: b)
                if farthest == nil || candidate.distance > farthest!.distance {
                    farthest = candidate
                }
            }
        }
        return farthest
    }

    private static func segmentTrianglePair(
        _ start: SIMD3<Float>,
        _ end: SIMD3<Float>,
        _ triangle: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
    ) -> MeasurementPointPair {
        if let intersection = segmentTriangleIntersection(start, end, triangle) {
            return MeasurementPointPair(first: intersection, second: intersection)
        }

        var best = MeasurementPointPair(
            first: start,
            second: closestPointOnTriangle(start, triangle)
        )
        let endCandidate = MeasurementPointPair(
            first: end,
            second: closestPointOnTriangle(end, triangle)
        )
        if endCandidate.distance < best.distance { best = endCandidate }
        for edge in triangleEdges(triangle) {
            let candidate = segmentSegmentPair(start, end, edge.0, edge.1)
            if candidate.distance < best.distance { best = candidate }
        }
        return best
    }

    private static func segmentTriangleIntersection(
        _ start: SIMD3<Float>,
        _ end: SIMD3<Float>,
        _ triangle: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
    ) -> SIMD3<Float>? {
        let direction = end - start
        let edge1 = triangle.1 - triangle.0
        let edge2 = triangle.2 - triangle.0
        let h = simd_cross(direction, edge2)
        let determinant = simd_dot(edge1, h)
        guard abs(determinant) > 0.0000001 else { return nil }
        let inverse = 1 / determinant
        let s = start - triangle.0
        let u = inverse * simd_dot(s, h)
        guard u >= 0, u <= 1 else { return nil }
        let q = simd_cross(s, edge1)
        let v = inverse * simd_dot(direction, q)
        guard v >= 0, u + v <= 1 else { return nil }
        let t = inverse * simd_dot(edge2, q)
        guard t >= 0, t <= 1 else { return nil }
        return start + direction * t
    }

    private static func closestPointOnTriangle(
        _ point: SIMD3<Float>,
        _ triangle: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
    ) -> SIMD3<Float> {
        let a = triangle.0
        let b = triangle.1
        let c = triangle.2
        let ab = b - a
        let ac = c - a
        let ap = point - a
        let d1 = simd_dot(ab, ap)
        let d2 = simd_dot(ac, ap)
        if d1 <= 0, d2 <= 0 { return a }

        let bp = point - b
        let d3 = simd_dot(ab, bp)
        let d4 = simd_dot(ac, bp)
        if d3 >= 0, d4 <= d3 { return b }

        let vc = d1 * d4 - d3 * d2
        if vc <= 0, d1 >= 0, d3 <= 0 {
            return a + ab * (d1 / (d1 - d3))
        }

        let cp = point - c
        let d5 = simd_dot(ab, cp)
        let d6 = simd_dot(ac, cp)
        if d6 >= 0, d5 <= d6 { return c }

        let vb = d5 * d2 - d1 * d6
        if vb <= 0, d2 >= 0, d6 <= 0 {
            return a + ac * (d2 / (d2 - d6))
        }

        let va = d3 * d6 - d5 * d4
        if va <= 0, d4 - d3 >= 0, d5 - d6 >= 0 {
            return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
        }

        let denominator = 1 / (va + vb + vc)
        return a + ab * (vb * denominator) + ac * (vc * denominator)
    }

    private static func segmentSegmentPair(
        _ p1: SIMD3<Float>,
        _ q1: SIMD3<Float>,
        _ p2: SIMD3<Float>,
        _ q2: SIMD3<Float>
    ) -> MeasurementPointPair {
        let d1 = q1 - p1
        let d2 = q2 - p2
        let r = p1 - p2
        let a = simd_dot(d1, d1)
        let e = simd_dot(d2, d2)
        let f = simd_dot(d2, r)
        let epsilon: Float = 0.000001
        if a <= epsilon, e <= epsilon {
            return MeasurementPointPair(first: p1, second: p2)
        }
        if a <= epsilon {
            let t = min(max(f / e, 0), 1)
            return MeasurementPointPair(first: p1, second: p2 + d2 * t)
        }
        if e <= epsilon {
            let s = min(max(-simd_dot(d1, r) / a, 0), 1)
            return MeasurementPointPair(first: p1 + d1 * s, second: p2)
        }

        let b = simd_dot(d1, d2)
        let c = simd_dot(d1, r)
        let denominator = a * e - b * b
        var s: Float = denominator == 0 ? 0 : min(max((b * f - c * e) / denominator, 0), 1)
        let nominalT = b * s + f
        let t: Float
        if nominalT < 0 {
            t = 0
            s = min(max(-c / a, 0), 1)
        } else if nominalT > e {
            t = 1
            s = min(max((b - c) / a, 0), 1)
        } else {
            t = nominalT / e
        }
        return MeasurementPointPair(first: p1 + d1 * s, second: p2 + d2 * t)
    }

    private static func infiniteLineDistance(
        _ firstOrigin: SIMD3<Float>,
        _ firstDirection: SIMD3<Float>,
        _ secondOrigin: SIMD3<Float>,
        _ secondDirection: SIMD3<Float>
    ) -> Float {
        let cross = simd_cross(firstDirection, secondDirection)
        let crossLength = simd_length(cross)
        if crossLength <= 0.000001 {
            return simd_length(simd_cross(secondOrigin - firstOrigin, firstDirection))
        }
        return abs(simd_dot(secondOrigin - firstOrigin, cross / crossLength))
    }

    private static func principalDirection(_ points: [SIMD3<Float>]) -> SIMD3<Float>? {
        guard let segment = segments(points).max(by: {
            simd_length_squared($0.1 - $0.0) < simd_length_squared($1.1 - $1.0)
        }) else { return nil }
        return normalizedOptional(segment.1 - segment.0)
    }

    private static func triangleNormal(_ vertices: [SIMD3<Float>]) -> SIMD3<Float>? {
        guard vertices.count >= 3 else { return nil }
        return normalizedOptional(simd_cross(vertices[1] - vertices[0], vertices[2] - vertices[0]))
    }

    private static func normalizedOptional(_ value: SIMD3<Float>?) -> SIMD3<Float>? {
        guard let value else { return nil }
        let length = simd_length(value)
        return length.isFinite && length > 0.000001 ? value / length : nil
    }

    private static func unorientedAngleDegrees(
        _ first: SIMD3<Float>,
        _ second: SIMD3<Float>
    ) -> Float {
        let dot = min(max(abs(simd_dot(first, second)), 0), 1)
        return acos(dot) * 180 / .pi
    }

    private static func combinedExtent(
        _ first: MeasurementGeometry,
        _ second: MeasurementGeometry
    ) -> Float {
        GeometryMath.maxExtent(of: supportPoints(first) + supportPoints(second))
    }

    private static func supportPoints(_ geometry: MeasurementGeometry) -> [SIMD3<Float>] {
        geometry.points + geometry.triangleVertices
    }

    private static func sampledSupportPoints(
        _ geometry: MeasurementGeometry,
        maximumCount: Int = 256
    ) -> [SIMD3<Float>] {
        let points = supportPoints(geometry)
        guard points.count > maximumCount else { return points }
        let stride = max(1, points.count / maximumCount)
        var sampled = Swift.stride(from: 0, to: points.count, by: stride).map { points[$0] }
        if let last = points.last, sampled.last != last { sampled.append(last) }
        return sampled
    }

    private static func segments(
        _ points: [SIMD3<Float>]
    ) -> [(SIMD3<Float>, SIMD3<Float>)] {
        zip(points, points.dropFirst()).compactMap {
            simd_distance($0.0, $0.1) > 0.000001 ? ($0.0, $0.1) : nil
        }
    }

    private static func triangles(
        _ points: [SIMD3<Float>],
        maximumCount: Int = 128
    ) -> [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] {
        let triangleCount = points.count / 3
        guard triangleCount > 0 else { return [] }
        let triangleStride = max(1, (triangleCount + maximumCount - 1) / maximumCount)
        return stride(from: 0, to: triangleCount, by: triangleStride).map { triangleIndex in
            let index = triangleIndex * 3
            return (points[index], points[index + 1], points[index + 2])
        }
    }

    private static func triangleEdges(
        _ triangle: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
    ) -> [(SIMD3<Float>, SIMD3<Float>)] {
        [(triangle.0, triangle.1), (triangle.1, triangle.2), (triangle.2, triangle.0)]
    }

    private static func isCircular(_ kind: MeasurementGeometryKind) -> Bool {
        kind == .arc || kind == .circle
    }
}
