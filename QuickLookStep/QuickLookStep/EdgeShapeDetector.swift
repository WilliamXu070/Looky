import AppKit
import Foundation
import SceneKit
import simd

enum EdgeShapeDetector {
    static func analyze(points rawPoints: [SIMD3<Float>]) -> EdgeShapeDetectionDownload {
        let points = dedupe(rawPoints)
        guard points.count >= 2 else {
            return EdgeShapeDetectionDownload(
                rawOrderShape: "unknown",
                detectedShape: "unknown",
                sequence: ["unknown"],
                segments: []
            )
        }

        let ordered = orderedClosedLoop(points)
        let rawLength = closedLength(points)
        let orderedLength = closedLength(ordered)
        let rawOrderShape = rawLength > orderedLength * 3 ? "fragmented" : "ordered"
        let segments = capsuleSegments(ordered) ?? extrudedSemicircleSegments(ordered) ?? fallbackSegments(ordered)
        let sequence = segments.map(\.kind)
        let detectedShape: String
        if sequence.count == 1 {
            detectedShape = sequence[0]
        } else {
            detectedShape = sequence.joined(separator: " -> ")
        }

        return EdgeShapeDetectionDownload(
            rawOrderShape: rawOrderShape,
            detectedShape: detectedShape,
            sequence: sequence,
            segments: segments
        )
    }

    static func selectedPrimitivePoints(
        points rawPoints: [SIMD3<Float>],
        nearest snappedPoint: SIMD3<Float>
    ) -> [SIMD3<Float>]? {
        guard let capsule = capsulePrimitiveGroups(rawPoints) ?? extrudedSemicirclePrimitiveGroups(rawPoints),
              capsule.map(\.kind) == ["line", "semicircle", "line", "semicircle"] else {
            return nil
        }

        let selected = capsule.min { lhs, rhs in
            lhs.distance(to: snappedPoint) < rhs.distance(to: snappedPoint)
        }
        guard let points = selected?.points, points.count >= 2 else {
            return nil
        }
        return points
    }

    private static func capsuleSegments(_ points: [SIMD3<Float>]) -> [EdgeShapeSegmentDownload]? {
        capsulePrimitiveGroups(points)?.map(\.download)
    }

    private static func extrudedSemicircleSegments(_ points: [SIMD3<Float>]) -> [EdgeShapeSegmentDownload]? {
        extrudedSemicirclePrimitiveGroups(points)?.map(\.download)
    }

    private struct PrimitiveGroup {
        let kind: String
        let points: [SIMD3<Float>]
        let download: EdgeShapeSegmentDownload

        func distance(to point: SIMD3<Float>) -> Float {
            guard points.count >= 2 else {
                return points.first.map { simd_distance($0, point) } ?? .greatestFiniteMagnitude
            }

            var best = Float.greatestFiniteMagnitude
            for pair in zip(points, points.dropFirst()) {
                best = min(best, distanceToSegment(point, pair.0, pair.1))
            }
            return best
        }
    }

    private struct CapsulePoint {
        let world: SIMD3<Float>
        let coord: SIMD2<Float>
    }

    private enum CoordinateAxis: CaseIterable {
        case x
        case y
        case z
    }

    private static func capsulePrimitiveGroups(_ rawPoints: [SIMD3<Float>]) -> [PrimitiveGroup]? {
        let points = orderedClosedLoop(dedupe(rawPoints))
        guard points.count >= 12 else { return nil }

        let basis = planeBasis(for: points)
        let projected = project(points, onto: basis)
        let axes = pcaAxes(projected)
        let capsulePoints = zip(points, projected).map { pair -> CapsulePoint in
            let point = pair.1
            let relative = point - axes.centroid
            let coord = SIMD2<Float>(simd_dot(relative, axes.major), simd_dot(relative, axes.minor))
            return CapsulePoint(world: pair.0, coord: coord)
        }

        let sValues = capsulePoints.map(\.coord.x)
        let tValues = capsulePoints.map(\.coord.y)
        guard let minS = sValues.min(),
              let maxS = sValues.max(),
              let minT = tValues.min(),
              let maxT = tValues.max() else {
            return nil
        }

        let width = maxS - minS
        let height = maxT - minT
        guard height > 0.0001, width > height * 2.4 else {
            return nil
        }

        let radius = height / 2
        let centerT = (minT + maxT) / 2
        let leftCenterS = minS + radius
        let rightCenterS = maxS - radius

        var topPoints: [CapsulePoint] = []
        var bottomPoints: [CapsulePoint] = []
        var leftCapPoints: [CapsulePoint] = []
        var rightCapPoints: [CapsulePoint] = []

        for cp in capsulePoints {
            let s = cp.coord.x
            let t = cp.coord.y
            let yDistTop = abs(t - maxT)
            let yDistBottom = abs(t - minT)
            let xDistLeft = abs(s - leftCenterS)
            let xDistRight = abs(s - rightCenterS)

            let railScale = height
            let capScale = width * 1.5

            let scores: [(zone: String, score: Float)] = [
                ("top", yDistTop / railScale),
                ("bottom", yDistBottom / railScale),
                ("left", xDistLeft / capScale),
                ("right", xDistRight / capScale),
            ]
            guard let best = scores.min(by: { $0.score < $1.score }) else {
                continue
            }
            switch best.zone {
            case "top": topPoints.append(cp)
            case "bottom": bottomPoints.append(cp)
            case "left": leftCapPoints.append(cp)
            case "right": rightCapPoints.append(cp)
            default: break
            }
        }

        guard topPoints.count >= 2,
              bottomPoints.count >= 2,
              leftCapPoints.count >= 6,
              rightCapPoints.count >= 6 else {
            return nil
        }

        let topLine = lineGroup(points: topPoints, targetT: maxT, ascending: true)
        let right = capGroup(points: rightCapPoints, center: SIMD2<Float>(rightCenterS, centerT), radius: radius)
        let bottomLine = lineGroup(points: bottomPoints, targetT: minT, ascending: false)
        let left = capGroup(points: leftCapPoints, center: SIMD2<Float>(leftCenterS, centerT), radius: radius)

        guard right.kind == "semicircle", left.kind == "semicircle" else {
            return nil
        }

        let correctedRight = PrimitiveGroup(
            kind: right.kind,
            points: [topLine.points.last!] + right.points + [bottomLine.points.first!],
            download: right.download
        )
        let correctedLeft = PrimitiveGroup(
            kind: left.kind,
            points: [bottomLine.points.last!] + left.points + [topLine.points.first!],
            download: left.download
        )
        return [topLine, correctedRight, bottomLine, correctedLeft]
    }

    private static func extrudedSemicirclePrimitiveGroups(_ rawPoints: [SIMD3<Float>]) -> [PrimitiveGroup]? {
        let points = dedupe(rawPoints)
        guard points.count >= 12 else { return nil }

        for axis in CoordinateAxis.allCases {
            let values = points.map { coordinate($0, axis: axis) }
            guard let minValue = values.min(), let maxValue = values.max() else {
                continue
            }

            let range = maxValue - minValue
            guard range > 0.0001 else {
                continue
            }

            let levelTolerance = max(range * 0.02, 0.01)
            var lower: [SIMD3<Float>] = []
            var upper: [SIMD3<Float>] = []
            var middleCount = 0

            for point in points {
                let value = coordinate(point, axis: axis)
                if abs(value - minValue) <= levelTolerance {
                    lower.append(point)
                } else if abs(value - maxValue) <= levelTolerance {
                    upper.append(point)
                } else {
                    middleCount += 1
                }
            }

            guard middleCount == 0,
                  lower.count >= 6,
                  upper.count >= 6 else {
                continue
            }

            guard let lowerArc = semicircleRailGroup(points: lower, axis: axis),
                  let upperArc = semicircleRailGroup(points: upper, axis: axis) else {
                continue
            }

            let lowerStart = lowerArc.points.first ?? lower[0]
            let lowerEnd = lowerArc.points.last ?? lower[lower.count - 1]
            let upperStart = upperArc.points.first ?? upper[0]
            let upperEnd = upperArc.points.last ?? upper[upper.count - 1]

            let alignedDistance = simd_distance(lowerStart, upperStart) + simd_distance(lowerEnd, upperEnd)
            let crossedDistance = simd_distance(lowerStart, upperEnd) + simd_distance(lowerEnd, upperStart)
            let firstLine: PrimitiveGroup
            let secondLine: PrimitiveGroup
            let orderedUpperArc: PrimitiveGroup

            if alignedDistance <= crossedDistance {
                firstLine = connectorLineGroup(lowerStart, upperStart)
                secondLine = connectorLineGroup(upperEnd, lowerEnd)
                orderedUpperArc = upperArc
            } else {
                firstLine = connectorLineGroup(lowerStart, upperEnd)
                secondLine = connectorLineGroup(upperStart, lowerEnd)
                orderedUpperArc = PrimitiveGroup(
                    kind: upperArc.kind,
                    points: upperArc.points.reversed(),
                    download: upperArc.download
                )
            }

            return [firstLine, orderedUpperArc, secondLine, lowerArc]
        }

        return nil
    }

    private static func fallbackSegments(_ points: [SIMD3<Float>]) -> [EdgeShapeSegmentDownload] {
        let line = lineFit(points)
        let extent = max(line.length, 0.0001)
        if line.maxResidual <= max(extent * 0.02, 0.75) {
            return [
                EdgeShapeSegmentDownload(
                    kind: "line",
                    pointCount: points.count,
                    length: line.length,
                    lineMaxResidual: line.maxResidual,
                    circleRadius: nil,
                    circleMaxResidual: nil,
                    coverageDegrees: nil
                )
            ]
        }

        guard points.count >= 6 else {
            return polygonLineSegments(points)
        }

        let basis = planeBasis(for: points)
        let circle = circleFit(project(points, onto: basis))
        if circle.maxResidual > max(circle.radius * 0.08, extent * 0.03, 0.75) {
            return polygonLineSegments(points)
        }

        let kind: String
        if circle.coverageDegrees >= 140 && circle.coverageDegrees <= 225 {
            kind = "semicircle"
        } else if circle.coverageDegrees > 325 {
            kind = "circle"
        } else if circle.coverageDegrees >= 25 {
            kind = "arc"
        } else {
            kind = "fragmented"
        }

        return [
            EdgeShapeSegmentDownload(
                kind: kind,
                pointCount: points.count,
                length: openLength(points),
                lineMaxResidual: nil,
                circleRadius: circle.radius,
                circleMaxResidual: circle.maxResidual,
                coverageDegrees: circle.coverageDegrees
            )
        ]
    }

    private static func polygonLineSegments(_ points: [SIMD3<Float>]) -> [EdgeShapeSegmentDownload] {
        guard points.count >= 2 else { return [] }

        var segments: [EdgeShapeSegmentDownload] = []
        segments.reserveCapacity(points.count)
        for index in 0..<points.count {
            let nextIndex = (index + 1) % points.count
            let start = points[index]
            let end = points[nextIndex]
            let length = simd_distance(start, end)
            guard length > 0.000001 else {
                continue
            }
            segments.append(
                EdgeShapeSegmentDownload(
                    kind: "line-segment",
                    pointCount: 2,
                    length: length,
                    lineMaxResidual: 0,
                    circleRadius: nil,
                    circleMaxResidual: nil,
                    coverageDegrees: nil
                )
            )
        }
        return segments
    }

    private static func lineGroup(
        points: [CapsulePoint],
        targetT: Float,
        ascending: Bool
    ) -> PrimitiveGroup {
        let sorted = points.sorted {
            ascending ? $0.coord.x < $1.coord.x : $0.coord.x > $1.coord.x
        }
        let coords = sorted.map(\.coord)
        let length = max(0, (coords.map(\.x).max() ?? 0) - (coords.map(\.x).min() ?? 0))
        let residual = coords.map { abs($0.y - targetT) }.max() ?? 0
        let download = EdgeShapeSegmentDownload(
            kind: "line",
            pointCount: points.count,
            length: length,
            lineMaxResidual: residual,
            circleRadius: nil,
            circleMaxResidual: nil,
            coverageDegrees: nil
        )
        return PrimitiveGroup(kind: "line", points: sorted.map(\.world), download: download)
    }

    private static func semicircleRailGroup(
        points: [SIMD3<Float>],
        axis: CoordinateAxis
    ) -> PrimitiveGroup? {
        let railPoints = points.map { point in
            CapsulePoint(world: point, coord: project(point, excluding: axis))
        }
        let coords = railPoints.map(\.coord)
        let fit = circleFit(coords)
        let residualLimit = max(fit.radius * 0.08, 0.05)
        guard fit.radius > 0.0001,
              fit.maxResidual <= residualLimit,
              fit.coverageDegrees >= 140,
              fit.coverageDegrees <= 220 else {
            return nil
        }

        let center = circleCenter(coords)
        let sorted = orderedByAngle(railPoints, center: center)
        let download = EdgeShapeSegmentDownload(
            kind: "semicircle",
            pointCount: sorted.count,
            length: fit.radius * fit.coverageDegrees * .pi / 180,
            lineMaxResidual: nil,
            circleRadius: fit.radius,
            circleMaxResidual: fit.maxResidual,
            coverageDegrees: fit.coverageDegrees
        )
        return PrimitiveGroup(kind: "semicircle", points: sorted.map(\.world), download: download)
    }

    private static func connectorLineGroup(_ start: SIMD3<Float>, _ end: SIMD3<Float>) -> PrimitiveGroup {
        let length = simd_distance(start, end)
        let download = EdgeShapeSegmentDownload(
            kind: "line",
            pointCount: 2,
            length: length,
            lineMaxResidual: 0,
            circleRadius: nil,
            circleMaxResidual: nil,
            coverageDegrees: nil
        )
        return PrimitiveGroup(kind: "line", points: [start, end], download: download)
    }

    private static func capGroup(
        points: [CapsulePoint],
        center: SIMD2<Float>,
        radius: Float
    ) -> PrimitiveGroup {
        let sorted = orderedByAngle(points, center: center)
        let coords = sorted.map(\.coord)
        let residual = coords.map { abs(simd_distance($0, center) - radius) }.max() ?? 0
        let coverage = angularCoverageDegrees(coords, center: center)
        let kind = coverage >= 140 && coverage <= 220 ? "semicircle" : "arc"
        let download = EdgeShapeSegmentDownload(
            kind: kind,
            pointCount: points.count,
            length: radius * coverage * .pi / 180,
            lineMaxResidual: nil,
            circleRadius: radius,
            circleMaxResidual: residual,
            coverageDegrees: coverage
        )
        return PrimitiveGroup(kind: kind, points: sorted.map(\.world), download: download)
    }

    private static func orderedByAngle(_ points: [CapsulePoint], center: SIMD2<Float>) -> [CapsulePoint] {
        let sorted = points.sorted {
            atan2f($0.coord.y - center.y, $0.coord.x - center.x)
                < atan2f($1.coord.y - center.y, $1.coord.x - center.x)
        }
        guard sorted.count >= 3 else { return sorted }

        let angles = sorted.map { atan2f($0.coord.y - center.y, $0.coord.x - center.x) }
        var splitIndex = 0
        var maxGap: Float = -1
        for index in 0..<angles.count {
            let nextIndex = (index + 1) % angles.count
            let nextAngle = nextIndex == 0 ? angles[0] + (2 * .pi) : angles[nextIndex]
            let gap = nextAngle - angles[index]
            if gap > maxGap {
                maxGap = gap
                splitIndex = nextIndex
            }
        }

        return Array(sorted[splitIndex...]) + Array(sorted[..<splitIndex])
    }

    private struct LineFit {
        let length: Float
        let maxResidual: Float
    }

    private struct CircleFit {
        let radius: Float
        let maxResidual: Float
        let coverageDegrees: Float
    }

    private struct PlaneBasis {
        let origin: SIMD3<Float>
        let u: SIMD3<Float>
        let v: SIMD3<Float>
    }

    private struct PCAAxes {
        let centroid: SIMD2<Float>
        let major: SIMD2<Float>
        let minor: SIMD2<Float>
    }

    private static func orderedClosedLoop(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        let basis = planeBasis(for: points)
        let projected = project(points, onto: basis)
        let centroid = projected.reduce(SIMD2<Float>(0, 0), +) / Float(max(projected.count, 1))
        return zip(points, projected)
            .sorted {
                atan2f($0.1.y - centroid.y, $0.1.x - centroid.x)
                    < atan2f($1.1.y - centroid.y, $1.1.x - centroid.x)
            }
            .map(\.0)
    }

    private static func pcaAxes(_ points: [SIMD2<Float>]) -> PCAAxes {
        let centroid = points.reduce(SIMD2<Float>(0, 0), +) / Float(max(points.count, 1))
        var xx: Float = 0
        var xy: Float = 0
        var yy: Float = 0
        for point in points {
            let centered = point - centroid
            xx += centered.x * centered.x
            xy += centered.x * centered.y
            yy += centered.y * centered.y
        }

        let angle = 0.5 * atan2f(2 * xy, xx - yy)
        let major = normalized(SIMD2<Float>(cosf(angle), sinf(angle)), fallback: SIMD2<Float>(1, 0))
        return PCAAxes(centroid: centroid, major: major, minor: SIMD2<Float>(-major.y, major.x))
    }

    private static func planeBasis(for points: [SIMD3<Float>]) -> PlaneBasis {
        let origin = points.first ?? SIMD3<Float>(0, 0, 0)
        let farthest = points.max(by: { simd_distance(origin, $0) < simd_distance(origin, $1) }) ?? origin
        let u = normalized(farthest - origin, fallback: SIMD3<Float>(1, 0, 0))
        let offAxis = points.max(by: { distanceToLine($0, origin, u) < distanceToLine($1, origin, u) }) ?? origin
        let normal = normalized(simd_cross(u, offAxis - origin), fallback: SIMD3<Float>(0, 1, 0))
        let v = normalized(simd_cross(normal, u), fallback: SIMD3<Float>(0, 0, 1))
        return PlaneBasis(origin: origin, u: u, v: v)
    }

    private static func project(_ points: [SIMD3<Float>], onto basis: PlaneBasis) -> [SIMD2<Float>] {
        points.map { point in
            let relative = point - basis.origin
            return SIMD2<Float>(simd_dot(relative, basis.u), simd_dot(relative, basis.v))
        }
    }

    private static func lineFit(_ points: [SIMD3<Float>]) -> LineFit {
        guard points.count >= 2 else {
            return LineFit(length: 0, maxResidual: 0)
        }

        var start = points[0]
        var end = points[1]
        var length = simd_distance(start, end)
        for first in points {
            for second in points {
                let distance = simd_distance(first, second)
                if distance > length {
                    start = first
                    end = second
                    length = distance
                }
            }
        }

        let direction = normalized(end - start, fallback: SIMD3<Float>(1, 0, 0))
        return LineFit(
            length: length,
            maxResidual: points.map { distanceToLine($0, start, direction) }.max() ?? 0
        )
    }

    private static func circleFit(_ points: [SIMD2<Float>]) -> CircleFit {
        guard points.count >= 3 else {
            return CircleFit(radius: 0, maxResidual: 0, coverageDegrees: 0)
        }

        var ata = simd_float3x3()
        var atb = SIMD3<Float>(repeating: 0)
        for point in points {
            let row = SIMD3<Float>(2 * point.x, 2 * point.y, 1)
            ata += simd_float3x3(
                SIMD3<Float>(row.x * row.x, row.x * row.y, row.x * row.z),
                SIMD3<Float>(row.y * row.x, row.y * row.y, row.y * row.z),
                SIMD3<Float>(row.z * row.x, row.z * row.y, row.z * row.z)
            )
            atb += row * (point.x * point.x + point.y * point.y)
        }

        let solution = ata.inverse * atb
        let center = SIMD2<Float>(solution.x, solution.y)
        let radius = sqrt(max(0.0001, solution.z + simd_dot(center, center)))
        let residuals = points.map { abs(simd_distance($0, center) - radius) }
        return CircleFit(
            radius: radius,
            maxResidual: residuals.max() ?? 0,
            coverageDegrees: angularCoverageDegrees(points, center: center)
        )
    }

    private static func circleCenter(_ points: [SIMD2<Float>]) -> SIMD2<Float> {
        guard points.count >= 3 else {
            return SIMD2<Float>(0, 0)
        }

        var ata = simd_float3x3()
        var atb = SIMD3<Float>(repeating: 0)
        for point in points {
            let row = SIMD3<Float>(2 * point.x, 2 * point.y, 1)
            ata += simd_float3x3(
                SIMD3<Float>(row.x * row.x, row.x * row.y, row.x * row.z),
                SIMD3<Float>(row.y * row.x, row.y * row.y, row.y * row.z),
                SIMD3<Float>(row.z * row.x, row.z * row.y, row.z * row.z)
            )
            atb += row * (point.x * point.x + point.y * point.y)
        }

        let solution = ata.inverse * atb
        return SIMD2<Float>(solution.x, solution.y)
    }

    private static func angularCoverageDegrees(_ points: [SIMD2<Float>], center: SIMD2<Float>) -> Float {
        let twoPi = Float.pi * 2
        let angles = points.map { atan2f($0.y - center.y, $0.x - center.x) }.sorted()
        guard angles.count >= 2 else { return 0 }

        var maxGap: Float = 0
        for pair in zip(angles, angles.dropFirst()) {
            maxGap = max(maxGap, pair.1 - pair.0)
        }
        maxGap = max(maxGap, (angles[0] + twoPi) - angles[angles.count - 1])
        return (twoPi - maxGap) * 180 / .pi
    }

    private static func openLength(_ points: [SIMD3<Float>]) -> Float {
        zip(points, points.dropFirst()).map(simd_distance).reduce(0, +)
    }

    private static func closedLength(_ points: [SIMD3<Float>]) -> Float {
        guard points.count >= 2 else { return 0 }
        return openLength(points) + simd_distance(points[0], points[points.count - 1])
    }

    private static func distanceToLine(_ point: SIMD3<Float>, _ linePoint: SIMD3<Float>, _ direction: SIMD3<Float>) -> Float {
        simd_length(simd_cross(point - linePoint, direction))
    }

    private static func distanceToSegment(_ point: SIMD3<Float>, _ start: SIMD3<Float>, _ end: SIMD3<Float>) -> Float {
        let segment = end - start
        let lengthSquared = simd_dot(segment, segment)
        guard lengthSquared > 0.000001 else {
            return simd_distance(point, start)
        }
        let t = min(1, max(0, simd_dot(point - start, segment) / lengthSquared))
        return simd_distance(point, start + segment * t)
    }

    private static func coordinate(_ point: SIMD3<Float>, axis: CoordinateAxis) -> Float {
        switch axis {
        case .x:
            return point.x
        case .y:
            return point.y
        case .z:
            return point.z
        }
    }

    private static func project(_ point: SIMD3<Float>, excluding axis: CoordinateAxis) -> SIMD2<Float> {
        switch axis {
        case .x:
            return SIMD2<Float>(point.y, point.z)
        case .y:
            return SIMD2<Float>(point.x, point.z)
        case .z:
            return SIMD2<Float>(point.x, point.y)
        }
    }

    private static func normalized(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(vector)
        guard length.isFinite, length > 0.000001 else { return fallback }
        return vector / length
    }

    private static func normalized(_ vector: SIMD2<Float>, fallback: SIMD2<Float>) -> SIMD2<Float> {
        let length = simd_length(vector)
        guard length.isFinite, length > 0.000001 else { return fallback }
        return vector / length
    }

    private static func dedupe(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        var result: [SIMD3<Float>] = []
        for point in points {
            if !result.contains(where: { simd_distance($0, point) < 0.00001 }) {
                result.append(point)
            }
        }
        return result
    }
}
