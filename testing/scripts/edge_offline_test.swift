import Foundation
import simd

struct EdgeFitSettings {
    var arcToleranceMultiplier: Float = 3.0
    var minimumArcSweepDegrees: Float = 5.0
    var minimumArcCoverage: Float = 0.75
    var arcRansacIterations: Int = 96
    var minimumArcInlierRatio: Float = 0.72
    var arcInlierGapAllowance: Int = 1
}

struct EdgeChainResult {
    let edge: String
    let kind: String
    let pointCount: Int
    let length: Float
    let startIndex: Int
    let endIndex: Int
}

let requestedVertexCount = CommandLine.arguments.count > 1 ? max(12, Int(CommandLine.arguments[1]) ?? 100) : 100
let outputPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil

var deterministicSeed: UInt64 = 0x1234_5678_9ABC_DEF0

let samplePoints = generatePillProfile(totalVertices: requestedVertexCount)
let analyzer = EdgeChainAnalyzer(points: samplePoints, settings: EdgeFitSettings())
let results = analyzer.analyzeEdges()

let rawReport: [String: Any] = [
    "requestedVertices": requestedVertexCount,
    "actualVertices": samplePoints.count,
    "results": results.map { result in
        [
            "edge": result.edge,
            "kind": result.kind,
            "pointCount": result.pointCount,
            "length": result.length,
            "startIndex": result.startIndex,
            "endIndex": result.endIndex,
        ] as [String: Any]
    },
]

guard let encoded = try? JSONSerialization.data(withJSONObject: rawReport, options: [.prettyPrinted, .sortedKeys]) else {
    fputs("Failed to encode JSON\n", stderr)
    exit(1)
}

let outputString = String(data: encoded, encoding: .utf8) ?? "{}"

if let path = outputPath {
    try outputString.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
}

print(outputString)

// MARK: - Geometry generation

func generatePillProfile(totalVertices: Int) -> [SIMD3<Float>] {
    let arcSegments = max(16, Int(Float(totalVertices) * 0.28))
    let lineSegments = max(10, (totalVertices - 2 * arcSegments) / 2)
    let radius: Float = 20.0
    let halfLine: Float = 35.0

    var points: [SIMD3<Float>] = []

    func arcPoints(centerX: Float, start: Float, end: Float, count: Int, includeFirst: Bool = true) -> [SIMD3<Float>] {
        guard count >= 2 else { return [] }
        let span = end - start
        let iStart = includeFirst ? 0 : 1
        return Array(iStart..<count).map { idx in
            let t = Float(idx) / Float(count - 1)
            let angle = start + span * t
            return SIMD3<Float>(centerX + radius * cosf(angle), radius * sinf(angle), 0)
        }
    }

    func linePoints(from: SIMD3<Float>, to: SIMD3<Float>, segments: Int, includeStart: Bool = false) -> [SIMD3<Float>] {
        guard segments >= 2 else { return [] }
        let iStart = includeStart ? 0 : 1
        return Array(iStart..<segments).map { idx in
            let t = Float(idx) / Float(segments - 1)
            return from + (to - from) * t
        }
    }

    let leftArc = arcPoints(centerX: -halfLine, start: .pi / 2, end: -.pi / 2, count: arcSegments, includeFirst: true)
    points.append(contentsOf: leftArc)

    let leftBottom = leftArc.last ?? SIMD3<Float>(-halfLine, -radius, 0)
    let rightBottom = SIMD3<Float>(halfLine, -radius, 0)
    points.append(contentsOf: linePoints(from: leftBottom, to: rightBottom, segments: lineSegments, includeStart: false))

    let rightArc = arcPoints(centerX: halfLine, start: -.pi / 2, end: .pi / 2, count: arcSegments, includeFirst: true)
    if let first = rightArc.first {
        points.append(contentsOf: rightArc.filter { $0 != first })
    }

    let rightTop = rightArc.last ?? SIMD3<Float>(halfLine, radius, 0)
    let leftTop = SIMD3<Float>(-halfLine, radius, 0)
    points.append(contentsOf: linePoints(from: rightTop, to: leftTop, segments: lineSegments, includeStart: false))

    return dedupeConsecutive(points)
}

func dedupeConsecutive(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
    var result: [SIMD3<Float>] = []
    for point in points {
        if let last = result.last, simd_distance(last, point) < 0.000001 { continue }
        result.append(point)
    }
    return result
}

func nextRandomInt(_ upper: Int) -> Int {
    deterministicSeed = deterministicSeed &* 1_103_515_245 &+ 12_345
    return Int(deterministicSeed % UInt64(upper))
}

// MARK: - Analyzer

private struct EdgeKey: Hashable {
    let a: Int
    let b: Int

    init(_ first: Int, _ second: Int) {
        if first < second { a = first; b = second } else { a = second; b = first }
    }

    func otherVertex(from vertex: Int) -> Int? {
        if vertex == a { return b }
        if vertex == b { return a }
        return nil
    }
}

struct EdgeChainAnalyzer {
    private let points: [SIMD3<Float>]
    private let settings: EdgeFitSettings
    private let maxExtent: Float

    init(points: [SIMD3<Float>], settings: EdgeFitSettings) {
        self.points = points
        self.settings = settings
        self.maxExtent = Self.maxExtent(of: points)
    }

    func analyzeEdges() -> [EdgeChainResult] {
        let incident = featureEdgesByVertex()
        var chainByKey: [String: EdgeChainResult] = [:]
        var results: [EdgeChainResult] = []

        for index in 0..<points.count {
            let next = (index + 1) % points.count
            let seed = EdgeKey(index, next)
            let rawPath = rawFeaturePath(from: seed, incident: incident)

            let chain = edgeChain(from: seed, rawPath: rawPath)
            let recordKey = chainFingerprint(seed: seed, chain: chain)

            if chainByKey[recordKey] != nil { continue }

            chainByKey[recordKey] = chain
            results.append(chain)

            if chain.pointCount <= 2 {
                // keep deterministic order and continue; tiny/noise chains are kept for visibility
            }
        }

        return results
    }

    private func chainFingerprint(seed: EdgeKey, chain: EdgeChainResult) -> String {
        let from = chain.startIndex
        let to = chain.endIndex
        return "\(chain.kind)|\(from)-\(to)|\(chain.pointCount)"
    }

    private func featureEdgesByVertex() -> [Int: [EdgeKey]] {
        var result: [Int: [EdgeKey]] = [:]
        for i in 0..<points.count {
            let n = (i + 1) % points.count
            let key = EdgeKey(i, n)
            result[i, default: []].append(key)
            result[n, default: []].append(key)
        }
        return result
    }

    private func rawFeaturePath(from seedEdge: EdgeKey, incident: [Int: [EdgeKey]]) -> [Int] {
        var path = [seedEdge.a, seedEdge.b]
        var visited: Set<EdgeKey> = [seedEdge]

        extendPath(&path, currentVertex: seedEdge.b, previousEdge: seedEdge, incident: incident, visited: &visited, appendForward: true)
        extendPath(&path, currentVertex: seedEdge.a, previousEdge: seedEdge, incident: incident, visited: &visited, appendForward: false)
        return path
    }

    private func extendPath(
        _ path: inout [Int],
        currentVertex: Int,
        previousEdge: EdgeKey,
        incident: [Int: [EdgeKey]],
        visited: inout Set<EdgeKey>,
        appendForward: Bool
    ) {
        var cursor = currentVertex
        var prev = previousEdge

        while true {
            let candidates = (incident[cursor] ?? []).filter { $0 != prev && !visited.contains($0) }
            guard candidates.count == 1,
                  let candidate = candidates.first,
                  let next = candidate.otherVertex(from: cursor) else {
                break
            }

            visited.insert(candidate)
            if appendForward {
                path.append(next)
                if next == path.first { break }
            } else {
                path.insert(next, at: 0)
                if next == path.last { break }
            }
            prev = candidate
            cursor = next
        }
    }

    private func edgeChain(from seedEdge: EdgeKey, rawPath: [Int]) -> EdgeChainResult {
        if let line = fittedLineSelection(in: rawPath, seedEdge: seedEdge) {
            return toResult(seedEdge, line: line, kind: "line")
        }

        if let arc = fittedArcSelection(in: rawPath, seedEdge: seedEdge) {
            return toResult(seedEdge, line: arc, kind: "arc")
        }

        if let spline = fittedSplineSelection(in: rawPath) {
            return toResult(seedEdge, line: spline, kind: "spline")
        }

        return EdgeChainResult(edge: edgeLabel(seedEdge), kind: "none", pointCount: 2, length: 0, startIndex: seedEdge.a, endIndex: seedEdge.b)
    }

    private func toResult(_ seedEdge: EdgeKey, line: [SIMD3<Float>], kind: String) -> EdgeChainResult {
        guard let first = line.first, let last = line.last else {
            return EdgeChainResult(edge: edgeLabel(seedEdge), kind: "none", pointCount: 0, length: 0, startIndex: seedEdge.a, endIndex: seedEdge.b)
        }

        let firstIndex = points.firstIndex(of: first) ?? seedEdge.a
        let lastIndex = points.firstIndex(of: last) ?? seedEdge.b
        return EdgeChainResult(
            edge: edgeLabel(seedEdge),
            kind: kind,
            pointCount: line.count,
            length: polylineLength(line),
            startIndex: min(firstIndex, lastIndex),
            endIndex: max(firstIndex, lastIndex)
        )
    }

    private func edgeLabel(_ key: EdgeKey) -> String {
        "\(key.a)-\(key.b)"
    }

    private var minimumLineLength: Float { max(maxExtent * 0.02, 2.0) }
    private var minimumArcLength: Float { max(maxExtent * 0.025, 2.5) }
    private var minimumArcSweep: Float { max(settings.minimumArcSweepDegrees, 1.0) * .pi / 180.0 }

    private func seedRange(in path: [Int], seedEdge: EdgeKey) -> ClosedRange<Int>? {
        guard path.count >= 2 else { return nil }
        for index in 0..<(path.count - 1) {
            if EdgeKey(path[index], path[index + 1]) == seedEdge {
                return index...(index + 1)
            }
        }
        return nil
    }

    private func fittedLineSelection(in rawPath: [Int], seedEdge: EdgeKey) -> [SIMD3<Float>]? {
        guard let range = seedRange(in: rawPath, seedEdge: seedEdge) else { return nil }
        let seedDirection = normalized(points[rawPath[range.upperBound]] - points[rawPath[range.lowerBound]], fallback: SIMD3<Float>(0, 1, 0))
        var rangeVar = range

        var grown = true
        while grown {
            grown = false
            if rangeVar.lowerBound > 0 {
                let candidate = Array(rawPath[(rangeVar.lowerBound - 1)...rangeVar.upperBound]).map { points[$0] }
                if isLineCandidate(points: candidate, seedDirection: seedDirection) {
                    rangeVar = (rangeVar.lowerBound - 1)...rangeVar.upperBound
                    grown = true
                }
            }
            if rangeVar.upperBound + 1 < rawPath.count {
                let candidate = Array(rawPath[rangeVar.lowerBound...(rangeVar.upperBound + 1)]).map { points[$0] }
                if isLineCandidate(points: candidate, seedDirection: seedDirection) {
                    rangeVar = rangeVar.lowerBound...(rangeVar.upperBound + 1)
                    grown = true
                }
            }
        }

        let pointsSelection = Array(rawPath[rangeVar]).map { points[$0] }
        guard pointsSelection.count >= 4,
              polylineLength(pointsSelection) >= minimumLineLength,
              isLineCandidate(points: pointsSelection, seedDirection: seedDirection)
        else { return nil }
        return pointsSelection
    }

    private var minimumArcSeedPointCount: Int { 5 }

    private func fittedArcSelection(in rawPath: [Int], seedEdge: EdgeKey) -> [SIMD3<Float>]? {
        guard var range = seedRange(in: rawPath, seedEdge: seedEdge) else { return nil }
        var seedAnchor = 0
        var grown = true

        while grown {
            grown = false
            if range.lowerBound > 0 {
                let candidate = Array(rawPath[(range.lowerBound - 1)...range.upperBound]).map { points[$0] }
                let candidateAnchor = seedAnchor + 1
                if shouldGrowArc(with: candidate, seedIndex: candidateAnchor) {
                    range = (range.lowerBound - 1)...range.upperBound
                    seedAnchor = candidateAnchor
                    grown = true
                }
            }

            if range.upperBound + 1 < rawPath.count {
                let candidate = Array(rawPath[range.lowerBound...(range.upperBound + 1)]).map { points[$0] }
                if shouldGrowArc(with: candidate, seedIndex: seedAnchor) {
                    range = range.lowerBound...(range.upperBound + 1)
                    grown = true
                }
            }
        }

        let candidate = Array(rawPath[range]).map { points[$0] }
        let boundedSeed = min(max(seedAnchor, 0), max(candidate.count - 1, 0))
        guard let fit = arcFit(for: candidate, seedIndex: boundedSeed) else { return nil }
        let selected = Array(candidate[fit.inlierSpan])

        let length = polylineLength(selected)
        if length < minimumArcLength || fit.sweepAngle < minimumArcSweep { return nil }
        if isLineCandidate(points: selected, seedDirection: normalized(selected.last! - selected.first!, fallback: SIMD3<Float>(0, 1, 0)), toleranceScale: 0.012) {
            return nil
        }
        return selected
    }

    private func shouldGrowArc(with candidatePoints: [SIMD3<Float>], seedIndex: Int) -> Bool {
        if candidatePoints.count < 3 { return true }
        if candidatePoints.count < minimumArcSeedPointCount {
            return arcFit(for: candidatePoints, seedIndex: seedIndex) != nil
        }
        guard let fit = arcFit(for: candidatePoints, seedIndex: seedIndex) else { return false }
        if fit.sweepAngle < minimumArcSweep { return false }
        if fit.inlierRatio < settings.minimumArcCoverage { return false }
        return fit.sweepAngle >= minimumArcSweep * 0.66 && polylineLength(Array(candidatePoints[fit.inlierSpan])) >= minimumArcLength
    }

    private func fittedSplineSelection(in rawPath: [Int]) -> [SIMD3<Float>]? {
        let candidate = rawPath.map { points[$0] }
        let length = polylineLength(candidate)
        if length >= minimumLineLength && isPlanar(points: candidate) { return candidate }
        return nil
    }

    private struct PlaneBasis {
        let origin: SIMD3<Float>
        let u: SIMD3<Float>
        let v: SIMD3<Float>
        let normal: SIMD3<Float>
    }

    private struct ArcFit {
        let radius: Float
        let sweepAngle: Float
        let inlierRatio: Float
        let inlierSpan: ClosedRange<Int>
    }

    private func arcFit(for points: [SIMD3<Float>], seedIndex: Int) -> ArcFit? {
        guard points.count >= 3,
              let basis = planeBasis(for: points)
        else { return nil }

        let projected = points.map {
            let relative = $0 - basis.origin
            return SIMD2<Float>(simd_dot(relative, basis.u), simd_dot(relative, basis.v))
        }

        let inlierTolerance = max(maxExtent * 0.003, 0.05) * settings.arcToleranceMultiplier
        let planeTolerance = max(maxExtent * 0.003, 0.08) * settings.arcToleranceMultiplier

        guard let circle = bestCircleFit(from: projected, inlierTolerance: inlierTolerance, minInlierRatio: adjustedArcInlierRatio(), iterations: max(0, settings.arcRansacIterations)) else {
            return nil
        }

        guard circle.radius > max(maxExtent * 0.002, 0.05) && circle.radius <= max(maxExtent * 4.0, 10.0) else { return nil }

        var maxPlaneResidual: Float = 0
        for p in points {
            maxPlaneResidual = max(maxPlaneResidual, abs(simd_dot(p - basis.origin, basis.normal)))
        }
        guard maxPlaneResidual <= planeTolerance else { return nil }

        let arcPoints = Array(projected[circle.inlierSpan])
        let sweep = arcSweepAngle(points: arcPoints, center: circle.center)
        guard sweep >= minimumArcSweep && circle.maxResidual <= max(inlierTolerance, 0.5) else { return nil }

        let inlierCount = circle.inlierSpan.count
        let inlierRatio = Float(inlierCount) / Float(points.count)
        guard inlierRatio >= settings.minimumArcCoverage else { return nil }

        return ArcFit(radius: circle.radius, sweepAngle: sweep, inlierRatio: inlierRatio, inlierSpan: circle.inlierSpan)
    }

    private func adjustedArcInlierRatio() -> Float {
        let loosen = max(0.0, (settings.arcToleranceMultiplier - 1.0) * 0.025)
        return max(0.58, settings.minimumArcInlierRatio - loosen)
    }

    private func bestCircleFit(
        from projected: [SIMD2<Float>],
        inlierTolerance: Float,
        minInlierRatio: Float,
        iterations: Int
    ) -> (center: SIMD2<Float>, radius: Float, inlierSpan: ClosedRange<Int>, maxResidual: Float)? {
        let minCoverage = max(settings.minimumArcCoverage, 0.55)

        if let deterministic = deterministicCircleFit(projected) {
            let count = Float(deterministic.inlierSpan.count)
            let ratio = count / Float(projected.count)
            let len = polylineLength2D(Array(projected[deterministic.inlierSpan]))
            if ratio >= minCoverage && len >= minimumArcLength {
                return (deterministic.center, deterministic.radius, deterministic.inlierSpan, deterministic.maxResidual)
            }
        }

        var best: (center: SIMD2<Float>, radius: Float, inlierSpan: ClosedRange<Int>, maxResidual: Float, score: Float)?

        if projected.count >= 6 && iterations > 0 {
            for _ in 0..<iterations {
                guard let sample = randomThreeIndices(count: projected.count) else { continue }
                guard let circle = circleFromThreePoints(projected[sample.0], projected[sample.1], projected[sample.2]) else { continue }

                let residuals = circleFitResiduals(projected, circle)
                let ratio = Float(residuals.inlierCount) / Float(projected.count)
                if residuals.inlierCount < 4 || ratio < minInlierRatio { continue }

                guard let span = inlierSpan(from: residuals.inliers, seed: sample.1, maxGap: settings.arcInlierGapAllowance) else { continue }
                if (span.upperBound - span.lowerBound + 1) < 3 { continue }

                let spanPoints = Array(projected[span])
                let spanRatio = Float(spanPoints.count) / Float(projected.count)
                if spanRatio < minCoverage { continue }
                let physical = polylineLength2D(spanPoints)
                if physical < minimumArcLength { continue }

                let score = ratio * 100.0 + min(1.0, physical / max(maxExtent, 1.0)) * 100.0 - residuals.maxResidual * 12.0

                if let current = best, score <= current.score { continue }
                best = (circle.center, circle.radius, span, residuals.maxResidual, score)
            }
        }

        if let b = best { return (b.center, b.radius, b.inlierSpan, b.maxResidual) }
        return nil
    }

    private func deterministicCircleFit(_ points: [SIMD2<Float>]) -> (center: SIMD2<Float>, radius: Float, inlierSpan: ClosedRange<Int>, maxResidual: Float)? {
        guard let circle = fittedCircle2D(points) else { return nil }
        let tolerance = max(maxExtent * 0.003, 0.05) * settings.arcToleranceMultiplier
        let residuals = circleFitResiduals(points, circle)
        if residuals.maxResidual > max(tolerance, 0.5) { return nil }
        let ratio = Float(residuals.inlierCount) / Float(points.count)
        if ratio < adjustedArcInlierRatio() * 0.85 { return nil }
        guard let span = inlierSpan(from: residuals.inliers, seed: (points.count - 1) / 2, maxGap: settings.arcInlierGapAllowance) else { return nil }
        return (circle.center, circle.radius, span, residuals.maxResidual)
    }

    private struct CircleFitResiduals {
        let inliers: [Bool]
        let inlierCount: Int
        let maxResidual: Float
    }

    private func circleFitResiduals(_ points: [SIMD2<Float>], _ circle: (center: SIMD2<Float>, radius: Float)) -> CircleFitResiduals {
        let tolerance = max(maxExtent * 0.003, 0.05) * settings.arcToleranceMultiplier
        var inliers = [Bool](repeating: false, count: points.count)
        var maxResidual: Float = 0
        var inlierCount = 0

        for (index, p) in points.enumerated() {
            let residual = abs(simd_distance(p, circle.center) - circle.radius)
            if residual <= tolerance {
                inliers[index] = true
                inlierCount += 1
            }
            maxResidual = max(maxResidual, residual)
        }

        return CircleFitResiduals(inliers: inliers, inlierCount: inlierCount, maxResidual: maxResidual)
    }

    private func inlierSpan(from inliers: [Bool], seed: Int, maxGap: Int) -> ClosedRange<Int>? {
        guard !inliers.isEmpty else { return nil }
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

        return right <= left ? nil : left...right
    }

    private func closestInlierIndex(_ inliers: [Bool], from seed: Int) -> Int? {
        for offset in 0..<inliers.count {
            let lower = seed - offset
            if lower >= 0, inliers[lower] { return lower }
            let upper = seed + offset
            if upper < inliers.count, inliers[upper] { return upper }
        }
        return nil
    }

    private func randomThreeIndices(count: Int) -> (Int, Int, Int)? {
        guard count >= 3 else { return nil }
        func next(_ max: Int) -> Int {
            return nextRandomInt(max)
        }

        let first = next(count)
        var second = next(count)
        while second == first { second = next(count) }
        var third = next(count)
        while third == first || third == second { third = next(count) }
        return (first, second, third)
    }

    private func circleFromThreePoints(_ first: SIMD2<Float>, _ second: SIMD2<Float>, _ third: SIMD2<Float>) -> (center: SIMD2<Float>, radius: Float)? {
        let d = 2 * (first.x * (second.y - third.y) + second.x * (third.y - first.y) + third.x * (first.y - second.y))
        guard abs(d) > 0.000001 else { return nil }
        let a2 = simd_dot(first, first)
        let b2 = simd_dot(second, second)
        let c2 = simd_dot(third, third)
        let ux = (a2 * (second.y - third.y) + b2 * (third.y - first.y) + c2 * (first.y - second.y)) / d
        let uy = (a2 * (third.x - second.x) + b2 * (first.x - third.x) + c2 * (second.x - first.x)) / d
        let center = SIMD2<Float>(ux, uy)
        let radius = simd_distance(center, first)
        if radius <= 0.0001 { return nil }
        return (center, radius)
    }

    private func fittedCircle2D(_ points: [SIMD2<Float>]) -> (center: SIMD2<Float>, radius: Float)? {
        var xx: Float = 0
        var xy: Float = 0
        var x: Float = 0
        var yy: Float = 0
        var y: Float = 0
        var xr: Float = 0
        var yr: Float = 0
        var r: Float = 0

        for p in points {
            let rs = p.x * p.x + p.y * p.y
            xx += p.x * p.x
            xy += p.x * p.y
            x += p.x
            yy += p.y * p.y
            y += p.y
            xr += p.x * rs
            yr += p.y * rs
            r += rs
        }

        let matrix: [[Float]] = [
            [xx, xy, x],
            [xy, yy, y],
            [x, y, Float(points.count)],
        ]

        guard let solution = solve3x3(matrix: matrix, vector: [-xr, -yr, -r]) else { return nil }
        let center = SIMD2<Float>(-solution.x * 0.5, -solution.y * 0.5)
        let radiusSq = simd_length_squared(center) - solution.z
        if radiusSq <= 0 { return nil }
        return (center, sqrt(radiusSq))
    }

    private func solve3x3(matrix: [[Float]], vector: [Float]) -> SIMD3<Float>? {
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
            if abs(rows[pivot][column]) <= 0.000001 { return nil }
            if pivot != column { rows.swapAt(pivot, column) }

            let factor = rows[column][column]
            for i in column...3 { rows[column][i] /= factor }
            for row in 0..<3 where row != column {
                let f = rows[row][column]
                for i in column...3 { rows[row][i] -= f * rows[column][i] }
            }
        }

        return SIMD3<Float>(rows[0][3], rows[1][3], rows[2][3])
    }

    private func arcSweepAngle(points: [SIMD2<Float>], center: SIMD2<Float>) -> Float {
        guard points.count >= 2 else { return 0 }
        let angles = points.map { atan2f($0.y - center.y, $0.x - center.x) }
        var sweep: Float = 0
        for pair in zip(angles, angles.dropFirst()) {
            var delta = pair.1 - pair.0
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            sweep += abs(delta)
        }
        return sweep
    }

    private func planeBasis(for points: [SIMD3<Float>]) -> PlaneBasis? {
        guard points.count >= 3, let origin = points.first else { return nil }
        var bestNormal = SIMD3<Float>(repeating: 0)
        var bestLength: Float = 0

        for i in 1..<(points.count - 1) {
            for j in (i + 1)..<points.count {
                let candidate = simd_cross(points[i] - origin, points[j] - origin)
                let len = simd_length(candidate)
                if len > bestLength {
                    bestLength = len
                    bestNormal = candidate
                }
            }
        }

        guard bestLength > max(maxExtent * 0.00001, 0.0001) else { return nil }
        let normal = bestNormal / bestLength
        guard let axisPoint = points.dropFirst().first(where: { simd_distance($0, origin) > max(maxExtent * 0.00001, 0.0001) }) else { return nil }
        let u = normalized(axisPoint - origin, fallback: SIMD3<Float>(1, 0, 0))
        let v = normalized(simd_cross(normal, u), fallback: SIMD3<Float>(0, 1, 0))
        return PlaneBasis(origin: origin, u: u, v: v, normal: normal)
    }

    private func isPlanar(points: [SIMD3<Float>]) -> Bool {
        guard points.count >= 3, let origin = points.first else { return true }
        var normal: SIMD3<Float>?
        let tolerance = max(maxExtent * 0.01, 0.18)
        for i in 1..<(points.count - 1) {
            let candidate = simd_cross(points[i] - origin, points[i + 1] - origin)
            if simd_length(candidate) > tolerance {
                normal = normalized(candidate, fallback: SIMD3<Float>(0, 1, 0))
                break
            }
        }
        guard let planeNormal = normal else { return true }
        for p in points where abs(simd_dot(p - origin, planeNormal)) > tolerance {
            return false
        }
        return true
    }

    private func isLineCandidate(points: [SIMD3<Float>], seedDirection: SIMD3<Float>, toleranceScale: Float = 0.0015) -> Bool {
        guard points.count >= 2, let first = points.first else { return false }
        let direction = normalized(seedDirection, fallback: SIMD3<Float>(0, 1, 0))
        let tolerance = max(maxExtent * toleranceScale, 0.05)
        let directionDot = cosf(0.3 * .pi / 180.0)

        for pair in zip(points, points.dropFirst()) {
            let segment = pair.1 - pair.0
            let len = simd_length(segment)
            if len < max(maxExtent * 0.00001, 0.0001) { continue }
            let segmentDir = segment / len
            if abs(simd_dot(segmentDir, direction)) < directionDot { return false }
        }

        for p in points {
            let projection = simd_dot(p - first, direction)
            let projectedPoint = first + direction * projection
            if simd_distance(p, projectedPoint) > tolerance { return false }
        }

        return true
    }

    private func polylineLength(_ points: [SIMD3<Float>]) -> Float {
        zip(points, points.dropFirst()).reduce(0) { total, pair in
            total + simd_distance(pair.0, pair.1)
        }
    }

    private func polylineLength2D(_ points: [SIMD2<Float>]) -> Float {
        zip(points, points.dropFirst()).reduce(0) { total, pair in
            total + simd_distance(pair.0, pair.1)
        }
    }

    private static func maxExtent(of points: [SIMD3<Float>]) -> Float {
        var minPoint = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var maxPoint = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        for p in points {
            minPoint = min(minPoint, p)
            maxPoint = max(maxPoint, p)
        }
        let span = maxPoint - minPoint
        return max(span.x, max(span.y, span.z))
    }
}

private func normalized(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
    let len = simd_length(vector)
    guard len.isFinite, len > 0 else { return fallback }
    return vector / len
}
