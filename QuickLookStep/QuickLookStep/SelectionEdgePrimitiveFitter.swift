import Foundation
import simd

extension EdgePrimitiveIndex {
    struct PlaneBasis {
        let origin: SIMD3<Float>
        let u: SIMD3<Float>
        let v: SIMD3<Float>
        let normal: SIMD3<Float>
    }

    struct ArcFit {
        let radius: Float
        let sweepAngle: Float
        let radialResidual: Float
        let planeResidual: Float
        let inlierRatio: Float
        let inlierSpan: ClosedRange<Int>
    }

    func arcFit(for points: [SIMD3<Float>], seedIndex: Int) -> ArcFit? {
        guard points.count >= 3,
              let basis = planeBasis(for: points)
        else {
            return nil
        }

        let projected = points.map { point -> SIMD2<Float> in
            let relative = point - basis.origin
            return SIMD2<Float>(simd_dot(relative, basis.u), simd_dot(relative, basis.v))
        }

        let inlierTolerance = max(maxExtent * 0.003, 0.05) * arcFitToleranceMultiplier
        let planeTolerance = max(maxExtent * 0.003, 0.08) * arcFitToleranceMultiplier

        guard let circle = bestCircleFit(
            from: projected,
            inlierTolerance: inlierTolerance,
            minInlierRatio: adjustedArcInlierRatio(),
            iterations: max(0, arcRansacIterations),
            minCoverage: minimumArcCoverage,
            minimumArcLength: minimumArcLength,
            seedCount: minimumArcSeedPointCount,
            seedIndex: seedIndex
        ) else {
            return nil
        }

        let radius = circle.radius
        guard radius.isFinite,
              radius > max(maxExtent * 0.002, 0.05),
              radius <= max(maxExtent * 4.0, 10.0)
        else {
            return nil
        }

        var maxPlaneResidual: Float = 0
        for point in points {
            maxPlaneResidual = max(maxPlaneResidual, abs(simd_dot(point - basis.origin, basis.normal)))
        }
        guard maxPlaneResidual <= planeTolerance else {
            return nil
        }

        let arcPoints = Array(projected[circle.inlierSpan])
        let sweep = arcSweepAngle(points: arcPoints, center: circle.center)
        guard sweep >= minimumArcSweep,
              circle.maxResidual <= max(inlierTolerance, 0.5)
        else {
            return nil
        }

        let inlierCount = circle.inlierSpan.upperBound - circle.inlierSpan.lowerBound + 1
        let inlierRatio = Float(inlierCount) / Float(points.count)
        guard inlierRatio >= minimumArcCoverage else {
            return nil
        }

        return ArcFit(
            radius: radius,
            sweepAngle: sweep,
            radialResidual: circle.maxResidual,
            planeResidual: maxPlaneResidual,
            inlierRatio: inlierRatio,
            inlierSpan: circle.inlierSpan
        )
    }

    func adjustedArcInlierRatio() -> Float {
        let loosen = max(0.0, (arcFitToleranceMultiplier - 1.0) * 0.025)
        return max(0.58, minimumArcInlierRatio - loosen)
    }

    func bestCircleFit(
        from projected: [SIMD2<Float>],
        inlierTolerance: Float,
        minInlierRatio: Float,
        iterations: Int,
        minCoverage: Float,
        minimumArcLength: Float,
        seedCount: Int,
        seedIndex: Int
    ) -> (center: SIMD2<Float>, radius: Float, inlierSpan: ClosedRange<Int>, maxResidual: Float)? {
        var best: (center: SIMD2<Float>, radius: Float, inlierSpan: ClosedRange<Int>, maxResidual: Float, score: Float)?

        let clampedSeed = min(max(seedIndex, 0), max(projected.count - 1, 0))

        if let deterministic = deterministicCircleFit(projected, seedIndex: clampedSeed) {
            let minCount = min(seedCount, projected.count)
            if deterministic.inlierSpan.count >= minCount {
                let spanPoints = Array(projected[deterministic.inlierSpan])
                let spanLength = polylineLength2D(spanPoints)
                if spanLength >= minimumArcLength {
                    let score = Float(deterministic.inlierSpan.upperBound - deterministic.inlierSpan.lowerBound + 1)
                    best = (
                        deterministic.center,
                        deterministic.radius,
                        deterministic.inlierSpan,
                        deterministic.maxResidual,
                        score
                    )
                }
            }

            let candidateSpanLength = Float(deterministic.inlierSpan.upperBound - deterministic.inlierSpan.lowerBound + 1)
            let candidateRatio = candidateSpanLength / Float(projected.count)
            if candidateRatio < minCoverage {
                best = nil
            }
        }

        if projected.count >= 6 && iterations > 0 {
            for iteration in 0..<iterations {
                guard let sample = deterministicThreeIndices(
                    count: projected.count,
                    iteration: iteration,
                    seed: clampedSeed
                ) else {
                    continue
                }

                guard let circle = circleFromThreePoints(
                    projected[sample.0],
                    projected[sample.1],
                    projected[sample.2]
                ) else {
                    continue
                }

                let residuals = circleFitResiduals(projected, circle)
                let inlierRatio = Float(residuals.inlierCount) / Float(projected.count)
                if residuals.inlierCount < 4 || inlierRatio < minInlierRatio {
                    continue
                }

                guard let span = inlierSpan(
                    from: residuals.inliers,
                    seed: clampedSeed,
                    maxGap: arcInlierGapAllowance
                ) else {
                    continue
                }

                guard span.count >= max(seedCount, 3) else {
                    continue
                }

                let spanLength = Float(span.upperBound - span.lowerBound + 1)
                let spanRatio = spanLength / Float(projected.count)
                if spanRatio < minCoverage {
                    continue
                }

                let spanPoints = Array(projected[span])
                if polylineLength2D(spanPoints) < minimumArcLength {
                    continue
                }

                let physicalSpanLength = polylineLength2D(spanPoints)
                let score = inlierRatio * 100.0
                    + min(1.0, physicalSpanLength / max(maxExtent, 1.0)) * 100.0
                    - residuals.maxResidual * 12.0
                if let current = best, score <= current.score {
                    continue
                }

                best = (
                    circle.center,
                    circle.radius,
                    span,
                    residuals.maxResidual,
                    score
                )
            }
        }

        return best.map { (center: $0.center, radius: $0.radius, inlierSpan: $0.inlierSpan, maxResidual: $0.maxResidual) }
    }

    func deterministicCircleFit(
        _ projected: [SIMD2<Float>],
        seedIndex: Int
    ) -> (center: SIMD2<Float>, radius: Float, inlierSpan: ClosedRange<Int>, maxResidual: Float)? {
        guard let circle = fittedCircle2D(projected) else {
            return nil
        }

        let inlierTolerance = max(maxExtent * 0.003, 0.05) * arcFitToleranceMultiplier
        let residuals = circleFitResiduals(projected, circle)
        if residuals.maxResidual > max(inlierTolerance, 0.5) {
            return nil
        }

        let inlierRatio = Float(residuals.inlierCount) / Float(projected.count)
        guard inlierRatio >= adjustedArcInlierRatio() * 0.85 else {
            return nil
        }

        guard let span = inlierSpan(
            from: residuals.inliers,
            seed: seedIndex,
            maxGap: arcInlierGapAllowance
        ) else {
            return nil
        }

        return (circle.center, circle.radius, span, residuals.maxResidual)
    }

    struct CircleFitResiduals {
        let inliers: [Bool]
        let inlierCount: Int
        let maxResidual: Float
        let maxConsecutiveSeed: Int?
    }

    func circleFitResiduals(_ projected: [SIMD2<Float>], _ circle: (center: SIMD2<Float>, radius: Float)) -> CircleFitResiduals {
        let tolerance = max(maxExtent * 0.003, 0.05) * arcFitToleranceMultiplier
        var inliers = [Bool](repeating: false, count: projected.count)
        var maxResidual: Float = 0
        var inlierCount = 0

        for index in projected.indices {
            let residual = abs(simd_distance(projected[index], circle.center) - circle.radius)
            if residual <= tolerance {
                inliers[index] = true
                inlierCount += 1
            }
            maxResidual = max(maxResidual, residual)
        }

        return CircleFitResiduals(
            inliers: inliers,
            inlierCount: inlierCount,
            maxResidual: maxResidual,
            maxConsecutiveSeed: longestInlierSeed(inliers)
        )
    }

    func inlierSpan(from inliers: [Bool], seed: Int, maxGap: Int) -> ClosedRange<Int>? {
        guard !inliers.isEmpty else {
            return nil
        }

        let start = min(max(seed, 0), inliers.count - 1)
        if !inliers[start], let restored = closestInlierIndex(inliers, from: start) {
            return inlierSpan(from: inliers, seed: restored, maxGap: maxGap)
        }

        var left = start
        var right = start

        var gaps = 0
        while left > 0 {
            if inliers[left - 1] {
                left -= 1
                continue
            }
            if gaps < maxGap {
                gaps += 1
                left -= 1
                continue
            }
            break
        }

        gaps = 0
        while right + 1 < inliers.count {
            if inliers[right + 1] {
                right += 1
                continue
            }
            if gaps < maxGap {
                gaps += 1
                right += 1
                continue
            }
            break
        }

        if right <= left {
            return nil
        }
        return left...right
    }

    func closestInlierIndex(_ inliers: [Bool], from seed: Int) -> Int? {
        for offset in 0..<inliers.count {
            let lower = seed - offset
            if lower >= 0, inliers[lower] {
                return lower
            }

            let upper = seed + offset
            if upper < inliers.count, inliers[upper] {
                return upper
            }
        }
        return nil
    }

    func longestInlierSeed(_ inliers: [Bool]) -> Int? {
        var bestSpan = 0
        var bestSeed: Int?
        var currentStart: Int?
        var currentSpan = 0

        for index in inliers.indices {
            if inliers[index] {
                if currentStart == nil {
                    currentStart = index
                }
                currentSpan += 1
            } else if currentStart != nil {
                if currentSpan > bestSpan {
                    bestSpan = currentSpan
                    bestSeed = currentStart! + currentSpan / 2
                }
                currentStart = nil
                currentSpan = 0
            }
        }

        if let start = currentStart, currentSpan > bestSpan {
            bestSeed = start + currentSpan / 2
        }
        return bestSeed
    }

    func deterministicThreeIndices(
        count: Int,
        iteration: Int,
        seed: Int
    ) -> (Int, Int, Int)? {
        guard count >= 3 else {
            return nil
        }

        // Stable coprime strides cover the path without process-global randomness.
        let first = (seed + iteration * 17) % count
        var second = (seed + iteration * 31 + max(1, count / 3)) % count
        if second == first { second = (second + 1) % count }
        var third = (seed + iteration * 47 + max(2, (count * 2) / 3)) % count
        while third == first || third == second { third = (third + 1) % count }
        return (first, second, third)
    }

    func circleFromThreePoints(
        _ first: SIMD2<Float>,
        _ second: SIMD2<Float>,
        _ third: SIMD2<Float>
    ) -> (center: SIMD2<Float>, radius: Float)? {
        let d = 2 * (first.x * (second.y - third.y) + second.x * (third.y - first.y) + third.x * (first.y - second.y))
        guard abs(d) > 0.000001 else {
            return nil
        }

        let a2 = simd_dot(first, first)
        let b2 = simd_dot(second, second)
        let c2 = simd_dot(third, third)
        let ux = (a2 * (second.y - third.y) + b2 * (third.y - first.y) + c2 * (first.y - second.y)) / d
        let uy = (a2 * (third.x - second.x) + b2 * (first.x - third.x) + c2 * (second.x - first.x)) / d
        let center = SIMD2<Float>(ux, uy)
        let radius = simd_distance(center, first)
        guard radius > 0.0001 else {
            return nil
        }
        return (center, radius)
    }

    func planeBasis(for points: [SIMD3<Float>]) -> PlaneBasis? {
        guard points.count >= 3, let origin = points.first else {
            return nil
        }

        var bestNormal = SIMD3<Float>(repeating: 0)
        var bestLength: Float = 0

        for i in 1..<(points.count - 1) {
            for j in (i + 1)..<points.count {
                let candidate = simd_cross(points[i] - origin, points[j] - origin)
                let length = simd_length(candidate)
                if length > bestLength {
                    bestLength = length
                    bestNormal = candidate
                }
            }
        }

        guard bestLength > max(maxExtent * 0.00001, 0.0001) else {
            return nil
        }

        let normal = bestNormal / bestLength
        guard let axisPoint = points.dropFirst().first(where: { simd_distance($0, origin) > max(maxExtent * 0.00001, 0.0001) }) else {
            return nil
        }

        let u = Self.normalized(axisPoint - origin, fallback: SIMD3<Float>(1, 0, 0))
        let v = Self.normalized(simd_cross(normal, u), fallback: SIMD3<Float>(0, 1, 0))
        return PlaneBasis(origin: origin, u: u, v: v, normal: normal)
    }

    func fittedCircle2D(_ points: [SIMD2<Float>]) -> (center: SIMD2<Float>, radius: Float)? {
        var xx: Float = 0
        var xy: Float = 0
        var x: Float = 0
        var yy: Float = 0
        var y: Float = 0
        var xr: Float = 0
        var yr: Float = 0
        var r: Float = 0

        for point in points {
            let radiusSquared = point.x * point.x + point.y * point.y
            xx += point.x * point.x
            xy += point.x * point.y
            x += point.x
            yy += point.y * point.y
            y += point.y
            xr += point.x * radiusSquared
            yr += point.y * radiusSquared
            r += radiusSquared
        }

        let matrix: [[Float]] = [
            [xx, xy, x],
            [xy, yy, y],
            [x, y, Float(points.count)],
        ]
        let vector = [-xr, -yr, -r]
        guard let solution = solve3x3(matrix, vector) else {
            return nil
        }

        let center = SIMD2<Float>(-solution.x * 0.5, -solution.y * 0.5)
        let radiusSquared = simd_length_squared(center) - solution.z
        guard radiusSquared > 0 else {
            return nil
        }

        return (center, sqrtf(radiusSquared))
    }

    func solve3x3(_ matrix: [[Float]], _ vector: [Float]) -> SIMD3<Float>? {
        var rows = [
            [matrix[0][0], matrix[0][1], matrix[0][2], vector[0]],
            [matrix[1][0], matrix[1][1], matrix[1][2], vector[1]],
            [matrix[2][0], matrix[2][1], matrix[2][2], vector[2]],
        ]

        for column in 0..<3 {
            var pivot = column
            for row in column..<3 where abs(rows[row][column]) > abs(rows[pivot][column]) {
                pivot = row
            }

            guard abs(rows[pivot][column]) > 0.000001 else {
                return nil
            }

            if pivot != column {
                rows.swapAt(pivot, column)
            }

            let divisor = rows[column][column]
            for index in column...3 {
                rows[column][index] /= divisor
            }

            for row in 0..<3 where row != column {
                let factor = rows[row][column]
                for index in column...3 {
                    rows[row][index] -= factor * rows[column][index]
                }
            }
        }

        return SIMD3<Float>(rows[0][3], rows[1][3], rows[2][3])
    }

    func arcSweepAngle(points: [SIMD2<Float>], center: SIMD2<Float>) -> Float {
        guard points.count >= 2 else {
            return 0
        }

        let angles = points.map { atan2f($0.y - center.y, $0.x - center.x) }
        var sweep: Float = 0
        for pair in zip(angles, angles.dropFirst()) {
            var delta = pair.1 - pair.0
            while delta > .pi {
                delta -= 2.0 * .pi
            }
            while delta < -.pi {
                delta += 2.0 * .pi
            }
            sweep += abs(delta)
        }
        return sweep
    }

    func polylineLength(_ points: [SIMD3<Float>]) -> Float {
        zip(points, points.dropFirst()).reduce(Float(0)) { partial, pair in
            partial + simd_distance(pair.0, pair.1)
        }
    }

    func polylineLength2D(_ points: [SIMD2<Float>]) -> Float {
        zip(points, points.dropFirst()).reduce(Float(0)) { partial, pair in
            partial + simd_length(pair.1 - pair.0)
        }
    }

    func edgeContinuityKind(_ edgeKey: EdgeKey) -> Int {
        guard let edge = edges[edgeKey] else {
            return 0
        }
        return edge.triangleIndices.count == 1 ? 1 : 2
    }

    func featureEdgesByVertex() -> [Int: [EdgeKey]] {
        var result: [Int: [EdgeKey]] = [:]
        for (edgeKey, edge) in edges where edge.isFeatureEdge {
            result[edge.a, default: []].append(edgeKey)
            result[edge.b, default: []].append(edgeKey)
        }
        return result
    }

    func isStraight(points: [SIMD3<Float>], toleranceScale: Float = 0.006) -> Bool {
        guard points.count >= 2,
              let first = points.first,
              let last = points.last
        else {
            return false
        }

        let direction = Self.normalized(last - first, fallback: SIMD3<Float>(0, 1, 0))
        let tolerance = max(maxExtent * toleranceScale, 0.12)
        for point in points {
            let projectedLength = simd_dot(point - first, direction)
            let projected = first + direction * projectedLength
            if simd_distance(point, projected) > tolerance {
                return false
            }
        }
        return true
    }

    func isPlanar(points: [SIMD3<Float>]) -> Bool {
        guard points.count >= 3, let origin = points.first else {
            return true
        }

        let tolerance = max(maxExtent * 0.01, 0.18)
        var planeNormal: SIMD3<Float>?

        for i in 1..<(points.count - 1) {
            let candidate = simd_cross(points[i] - origin, points[i + 1] - origin)
            if simd_length(candidate) > tolerance {
                planeNormal = Self.normalized(candidate, fallback: SIMD3<Float>(0, 1, 0))
                break
            }
        }

        guard let planeNormal else {
            return true
        }

        for point in points {
            let distance = abs(simd_dot(point - origin, planeNormal))
            if distance > tolerance {
                return false
            }
        }
        return true
    }

    static func normalized(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(vector)
        guard length.isFinite, length > 0 else {
            return fallback
        }
        return vector / length
    }

}
