import Foundation
import simd

extension EdgePrimitiveIndex {
    func rawFeaturePath(from seedEdge: EdgeKey, incident: [Int: [EdgeKey]]) -> [Int] {
        var path = [seedEdge.a, seedEdge.b]
        var visitedEdges = Set<EdgeKey>([seedEdge])
        let continuityKind = edgeContinuityKind(seedEdge)

        extendRawFeaturePath(
            &path,
            currentVertex: seedEdge.b,
            previousEdge: seedEdge,
            continuityKind: continuityKind,
            incident: incident,
            visitedEdges: &visitedEdges,
            append: true
        )
        extendRawFeaturePath(
            &path,
            currentVertex: seedEdge.a,
            previousEdge: seedEdge,
            continuityKind: continuityKind,
            incident: incident,
            visitedEdges: &visitedEdges,
            append: false
        )

        return dedupedPath(from: path)
    }

    func extendRawFeaturePath(
        _ path: inout [Int],
        currentVertex: Int,
        previousEdge: EdgeKey,
        continuityKind: Int,
        incident: [Int: [EdgeKey]],
        visitedEdges: inout Set<EdgeKey>,
        append: Bool
    ) {
        var currentVertex = currentVertex
        var previousEdge = previousEdge

        while true {
            let candidates = (incident[currentVertex] ?? [])
                .filter { $0 != previousEdge && !visitedEdges.contains($0) }
                .filter { edgeContinuityKind($0) == continuityKind }

            guard candidates.count == 1,
                  let candidate = candidates.first,
                  let nextVertex = candidate.otherVertex(from: currentVertex)
            else {
                break
            }

            visitedEdges.insert(candidate)
            if append {
                path.append(nextVertex)
                if nextVertex == path.first {
                    break
                }
            } else {
                path.insert(nextVertex, at: 0)
                if nextVertex == path.last {
                    break
                }
            }

            previousEdge = candidate
            currentVertex = nextVertex
        }
    }

    func rawVertexPath(from seedEdge: EdgeKey) -> [Int] {
        let incident = featureEdgesByVertex()
        var path = rawFeaturePath(from: seedEdge, incident: incident)
        guard path.count >= 2 else {
            return path
        }

        if path.first != path.last {
            if path.first! > path.last! {
                path.reverse()
            }
        } else {
            let interiorCount = path.count - 1
            guard interiorCount >= 2 else {
                return path
            }
            var minVertex = path[0]
            var minIndex = 0
            for i in 0..<interiorCount {
                if path[i] < minVertex {
                    minVertex = path[i]
                    minIndex = i
                }
            }
            if minIndex > 0 {
                var rotated = Array(path[minIndex..<interiorCount])
                rotated.append(contentsOf: path[0..<minIndex])
                rotated.append(path[minIndex])
                path = rotated
            }
        }

        return path
    }

    func fittedLineSelection(in rawPath: [Int], seedEdge: EdgeKey) -> EdgeChain? {
        guard var range = seedRange(in: rawPath, seedEdge: seedEdge) else {
            return nil
        }

        let seedDirection = Self.normalized(
            vertices[rawPath[range.upperBound]] - vertices[rawPath[range.lowerBound]],
            fallback: SIMD3<Float>(0, 1, 0)
        )

        let incidentFeatureEdges = featureEdgesByVertex()
        let directionDot = cosf(lineDeviationDegrees * .pi / 180.0)

        var grew = true
        while grew {
            grew = false

            if range.lowerBound > 0 {
                let newVertex = rawPath[range.lowerBound - 1]
                let incidentDirectionsAgree = (incidentFeatureEdges[newVertex] ?? []).allSatisfy { edgeKey in
                    guard let edge = edges[edgeKey] else { return true }
                    let other = edge.a == newVertex ? edge.b : edge.a
                    let direction = Self.normalized(vertices[other] - vertices[newVertex], fallback: SIMD3<Float>(0, 1, 0))
                    return abs(simd_dot(direction, seedDirection)) >= directionDot
                }
                if incidentDirectionsAgree {
                    let candidate = Array(rawPath[(range.lowerBound - 1)...range.upperBound]).map { vertices[$0] }
                    if isLineCandidate(points: candidate, seedDirection: seedDirection) {
                        range = (range.lowerBound - 1)...range.upperBound
                        grew = true
                    }
                }
            }

            if range.upperBound + 1 < rawPath.count {
                let newVertex = rawPath[range.upperBound + 1]
                let incidentDirectionsAgree = (incidentFeatureEdges[newVertex] ?? []).allSatisfy { edgeKey in
                    guard let edge = edges[edgeKey] else { return true }
                    let other = edge.a == newVertex ? edge.b : edge.a
                    let direction = Self.normalized(vertices[other] - vertices[newVertex], fallback: SIMD3<Float>(0, 1, 0))
                    return abs(simd_dot(direction, seedDirection)) >= directionDot
                }
                if incidentDirectionsAgree {
                    let candidate = Array(rawPath[range.lowerBound...(range.upperBound + 1)]).map { vertices[$0] }
                    if isLineCandidate(points: candidate, seedDirection: seedDirection) {
                        range = range.lowerBound...(range.upperBound + 1)
                        grew = true
                    }
                }
            }
        }

        let points = Array(rawPath[range]).map { vertices[$0] }
        let length = polylineLength(points)
        guard length >= minimumLineLength,
              isLineCandidate(points: points, seedDirection: seedDirection)
        else {
            return nil
        }

        let kind = String(format: "line length=%.2f min=%.2f", length, minimumLineLength)
        return EdgeChain(points: points, kind: kind)
    }

    func fittedArcSelection(in rawPath: [Int], seedEdge: EdgeKey) -> EdgeChain? {
        guard var range = seedRange(in: rawPath, seedEdge: seedEdge) else {
            return nil
        }
        var seedAnchor = 0

        var grew = true
        while grew {
            grew = false

            if range.lowerBound > 0 {
                let candidatePoints = Array(rawPath[(range.lowerBound - 1)...range.upperBound]).map { vertices[$0] }
                let candidateSeedAnchor = seedAnchor + 1
                if shouldGrowArc(with: candidatePoints, seedIndex: candidateSeedAnchor) {
                    range = (range.lowerBound - 1)...range.upperBound
                    seedAnchor = candidateSeedAnchor
                    grew = true
                }
            }

            if range.upperBound + 1 < rawPath.count {
                let candidatePoints = Array(rawPath[range.lowerBound...(range.upperBound + 1)]).map { vertices[$0] }
                if shouldGrowArc(with: candidatePoints, seedIndex: seedAnchor) {
                    range = range.lowerBound...(range.upperBound + 1)
                    grew = true
                }
            }
        }

        let points = Array(rawPath[range]).map { vertices[$0] }
        let boundedSeedAnchor = min(max(seedAnchor, 0), max(points.count - 1, 0))
        guard let fit = arcFit(for: points, seedIndex: boundedSeedAnchor) else {
            return nil
        }

        let selectedRange = fit.inlierSpan
        let selectedPoints = Array(points[selectedRange])
        let length = polylineLength(selectedPoints)
        guard length >= minimumArcLength,
              fit.sweepAngle >= minimumArcSweep
        else {
            return nil
        }

        if isLineCandidate(
            points: selectedPoints,
            seedDirection: Self.normalized(selectedPoints.last! - selectedPoints.first!, fallback: SIMD3<Float>(0, 1, 0)),
            toleranceScale: 0.012
        ) {
            return nil
        }

        let kind = String(
            format: "arc length=%.2f min=%.2f radius=%.2f sweep=%.1fdeg",
            length,
            minimumArcLength,
            fit.radius,
            fit.sweepAngle * 180.0 / .pi
        )
        return EdgeChain(points: selectedPoints, kind: kind)
    }

    func shouldGrowArc(with candidatePoints: [SIMD3<Float>], seedIndex: Int) -> Bool {
        if candidatePoints.count < 3 {
            return true
        }

        if candidatePoints.count < minimumArcSeedPointCount {
            return arcFit(for: candidatePoints, seedIndex: seedIndex) != nil
        }

        guard let fit = arcFit(for: candidatePoints, seedIndex: seedIndex) else {
            return false
        }

        if fit.sweepAngle < minimumArcSweep {
            return false
        }

        if fit.inlierRatio < minimumArcCoverage {
            return false
        }

        return fit.sweepAngle >= minimumArcSweep * 0.66
            && polylineLength(Array(candidatePoints[fit.inlierSpan])) >= minimumArcLength
    }

    func fittedSplineSelection(in rawPath: [Int]) -> EdgeChain? {
        let points = rawPath.map { vertices[$0] }
        let length = polylineLength(points)
        guard length >= minimumLineLength,
              isPlanar(points: points)
        else {
            return nil
        }

        let kind = String(format: "spline length=%.2f min=%.2f", length, minimumLineLength)
        return EdgeChain(points: points, kind: kind)
    }

    func dedupedPath(from path: [Int]) -> [Int] {
        path.reduce(into: [Int]()) { partial, vertex in
            if partial.last != vertex {
                partial.append(vertex)
            }
        }
    }

    func seedRange(in path: [Int], seedEdge: EdgeKey) -> ClosedRange<Int>? {
        guard path.count >= 2 else {
            return nil
        }

        for index in 0..<(path.count - 1) {
            let edge = EdgeKey(path[index], path[index + 1])
            if edge == seedEdge {
                return index...(index + 1)
            }
        }
        return nil
    }

    func isLineCandidate(points: [SIMD3<Float>], seedDirection: SIMD3<Float>, toleranceScale: Float = 0.0015) -> Bool {
        guard points.count >= 2, let first = points.first else {
            return false
        }

        let directionDot = cosf(lineDeviationDegrees * .pi / 180.0)
        let distanceTolerance = max(maxExtent * toleranceScale, 0.05)
        let seedDirection = Self.normalized(seedDirection, fallback: SIMD3<Float>(0, 1, 0))

        var previousDirection: SIMD3<Float>?
        for pair in zip(points, points.dropFirst()) {
            let segment = pair.1 - pair.0
            let length = simd_length(segment)
            guard length > max(maxExtent * 0.00001, 0.0001) else {
                continue
            }

            let segmentDirection = segment / length
            if abs(simd_dot(segmentDirection, seedDirection)) < directionDot {
                return false
            }
            if let prev = previousDirection,
               abs(simd_dot(segmentDirection, prev)) < directionDot {
                return false
            }
            previousDirection = segmentDirection
        }

        for point in points {
            let projectedLength = simd_dot(point - first, seedDirection)
            let projected = first + seedDirection * projectedLength
            if simd_distance(point, projected) > distanceTolerance {
                return false
            }
        }

        return true
    }
}
