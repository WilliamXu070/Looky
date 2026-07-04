import Foundation
import SceneKit
import simd

enum MeasurementUnit: String, Codable, CaseIterable, Identifiable {
    case model
    case millimeters = "mm"
    case inches = "in"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .model: return "u"
        case .millimeters: return "mm"
        case .inches: return "in"
        }
    }

    var areaLabel: String {
        switch self {
        case .model: return "u2"
        case .millimeters: return "mm2"
        case .inches: return "in2"
        }
    }

    static func resolved(from rawValue: String?) -> MeasurementUnit {
        rawValue.flatMap(MeasurementUnit.init(rawValue:)) ?? .model
    }

    func convertLength(_ value: Float, mmPerModelUnit: Double) -> Double {
        let modelValue = Double(value)
        switch self {
        case .model:
            return modelValue
        case .millimeters:
            return modelValue * mmPerModelUnit
        case .inches:
            return (modelValue * mmPerModelUnit) / 25.4
        }
    }

    func convertArea(_ value: Float, mmPerModelUnit: Double) -> Double {
        let modelValue = Double(value)
        switch self {
        case .model:
            return modelValue
        case .millimeters:
            return modelValue * mmPerModelUnit * mmPerModelUnit
        case .inches:
            let inchesPerModelUnit = mmPerModelUnit / 25.4
            return modelValue * inchesPerModelUnit * inchesPerModelUnit
        }
    }
}

struct SelectionMeasurementExpectation: Codable {
    let kind: String?
    let entityCount: Int?
    let unitMode: String?
    let minTotalLength: Float?
    let maxTotalLength: Float?
    let minMinimumDistance: Float?
    let maxMinimumDistance: Float?
    let minArea: Float?
    let maxArea: Float?
    let minPerimeter: Float?
    let maxPerimeter: Float?
}

struct SelectionMeasurementState: Codable, Equatable {
    static let empty = SelectionMeasurementState(
        kind: "empty",
        entities: [],
        summary: SelectionMeasurementSummary.empty
    )

    let kind: String
    let entities: [SelectionMeasurementEntity]
    let summary: SelectionMeasurementSummary

    var isEmpty: Bool {
        kind == "empty" || entities.isEmpty
    }

    static func singleEdge(_ entity: SelectionMeasurementEntity) -> SelectionMeasurementState {
        SelectionMeasurementState(
            kind: "edge",
            entities: [entity],
            summary: SelectionMeasurementCalculator.summary(forEdges: [entity])
        )
    }

    static func singleSurface(_ entity: SelectionMeasurementEntity) -> SelectionMeasurementState {
        SelectionMeasurementState(
            kind: "surface",
            entities: [entity],
            summary: SelectionMeasurementSummary(
                kind: "surface",
                entityCount: 1,
                label: entity.label,
                length: nil,
                totalLength: nil,
                area: entity.area,
                perimeter: entity.perimeter,
                radius: nil,
                minimumDistance: nil,
                maximumDistance: nil,
                centerToCenterDistance: nil,
                angleDegrees: nil,
                triangleCount: entity.triangleCount,
                pointCount: nil,
                shape: nil,
                surfaceType: entity.surfaceType,
                unitMode: nil,
                distanceDetail: nil
            )
        )
    }

    static func edges(_ entities: [SelectionMeasurementEntity]) -> SelectionMeasurementState {
        let uniqueEdges = SelectionMeasurementCalculator.uniqueEdges(entities)
        guard !uniqueEdges.isEmpty else {
            return .empty
        }
        return SelectionMeasurementState(
            kind: uniqueEdges.count == 1 ? "edge" : "multiEdge",
            entities: uniqueEdges,
            summary: SelectionMeasurementCalculator.summary(forEdges: uniqueEdges)
        )
    }
}

struct SelectionMeasurementEntity: Codable, Equatable, Identifiable {
    let id: String
    let kind: String
    let label: String
    let sourceIDs: [String]
    let length: Float?
    let radius: Float?
    let area: Float?
    let perimeter: Float?
    let triangleCount: Int?
    let pointCount: Int?
    let shape: String?
    let surfaceType: String?
    let points: [[Float]]

    var simdPoints: [SIMD3<Float>] {
        points.compactMap { point in
            guard point.count >= 3 else { return nil }
            return SIMD3<Float>(point[0], point[1], point[2])
        }
    }
}

struct SelectionMeasurementSummary: Codable, Equatable {
    static let empty = SelectionMeasurementSummary(
        kind: "empty",
        entityCount: 0,
        label: "No selection",
        length: nil,
        totalLength: nil,
        area: nil,
        perimeter: nil,
        radius: nil,
        minimumDistance: nil,
        maximumDistance: nil,
        centerToCenterDistance: nil,
        angleDegrees: nil,
        triangleCount: nil,
        pointCount: nil,
        shape: nil,
        surfaceType: nil,
        unitMode: nil,
        distanceDetail: nil
    )

    let kind: String
    let entityCount: Int
    let label: String
    let length: Float?
    let totalLength: Float?
    let area: Float?
    let perimeter: Float?
    let radius: Float?
    let minimumDistance: Float?
    let maximumDistance: Float?
    let centerToCenterDistance: Float?
    let angleDegrees: Float?
    let triangleCount: Int?
    let pointCount: Int?
    let shape: String?
    let surfaceType: String?
    var unitMode: String?
    let distanceDetail: SelectionMeasurementDistanceDetail?

    func withUnitMode(_ unitMode: MeasurementUnit) -> SelectionMeasurementSummary {
        var copy = self
        copy.unitMode = unitMode.rawValue
        return copy
    }
}

struct SelectionSurfaceMeasurements {
    let area: Float
    let perimeter: Float
}

struct SelectionMeasurementDistanceDetail: Codable, Equatable {
    let firstEntityID: String
    let secondEntityID: String
    let firstLabel: String
    let secondLabel: String
    let minimumDistance: Float
    let minimumDelta: [Float]
    let minimumFirstPoint: [Float]
    let minimumSecondPoint: [Float]
    let maximumDistance: Float
    let maximumDelta: [Float]
    let maximumFirstPoint: [Float]
    let maximumSecondPoint: [Float]

    var minimumDeltaSIMD: SIMD3<Float>? {
        Self.simd3(minimumDelta)
    }

    var maximumDeltaSIMD: SIMD3<Float>? {
        Self.simd3(maximumDelta)
    }

    var minimumFirstPointSIMD: SIMD3<Float>? {
        Self.simd3(minimumFirstPoint)
    }

    var minimumSecondPointSIMD: SIMD3<Float>? {
        Self.simd3(minimumSecondPoint)
    }

    var maximumFirstPointSIMD: SIMD3<Float>? {
        Self.simd3(maximumFirstPoint)
    }

    var maximumSecondPointSIMD: SIMD3<Float>? {
        Self.simd3(maximumSecondPoint)
    }

    private static func simd3(_ values: [Float]) -> SIMD3<Float>? {
        guard values.count >= 3 else { return nil }
        return SIMD3<Float>(values[0], values[1], values[2])
    }
}

enum SelectionMeasurementCalculator {
    static func uniqueEdges(_ entities: [SelectionMeasurementEntity]) -> [SelectionMeasurementEntity] {
        var seen: Set<String> = []
        var result: [SelectionMeasurementEntity] = []
        for entity in entities where entity.kind == "edge" {
            if seen.insert(entity.id).inserted {
                result.append(entity)
            }
        }
        return result
    }

    static func summary(forEdges entities: [SelectionMeasurementEntity]) -> SelectionMeasurementSummary {
        let edgeEntities = uniqueEdges(entities)
        guard !edgeEntities.isEmpty else {
            return .empty
        }

        let totalLength = edgeEntities.reduce(Float(0)) { partial, entity in
            partial + (entity.length ?? polylineLength(entity.simdPoints))
        }
        let pointCount = edgeEntities.reduce(0) { $0 + ($1.pointCount ?? $1.points.count) }
        let distanceDetail = edgeEntities.count >= 2 ? closestDistanceDetail(edgeEntities) : nil
        let minimumDistance = distanceDetail?.minimumDistance
        let maximumDistance = distanceDetail?.maximumDistance
        let centerDistance = edgeEntities.count >= 2 ? minimumCentroidDistance(edgeEntities.map(\.simdPoints)) : nil
        let angle = edgeEntities.count == 2 ? angleDegrees(edgeEntities[0].simdPoints, edgeEntities[1].simdPoints) : nil

        if edgeEntities.count == 1, let entity = edgeEntities.first {
            return SelectionMeasurementSummary(
                kind: "edge",
                entityCount: 1,
                label: entity.label,
                length: entity.length,
                totalLength: entity.length,
                area: nil,
                perimeter: nil,
                radius: entity.radius,
                minimumDistance: nil,
                maximumDistance: nil,
                centerToCenterDistance: nil,
                angleDegrees: nil,
                triangleCount: nil,
                pointCount: entity.pointCount,
                shape: entity.shape,
                surfaceType: nil,
                unitMode: nil,
                distanceDetail: nil
            )
        }

        return SelectionMeasurementSummary(
            kind: "multiEdge",
            entityCount: edgeEntities.count,
            label: "\(edgeEntities.count) Edges",
            length: nil,
            totalLength: totalLength,
            area: nil,
            perimeter: nil,
            radius: nil,
            minimumDistance: minimumDistance,
            maximumDistance: maximumDistance,
            centerToCenterDistance: centerDistance,
            angleDegrees: angle,
            triangleCount: nil,
            pointCount: pointCount,
            shape: nil,
            surfaceType: nil,
            unitMode: nil,
            distanceDetail: distanceDetail
        )
    }

    static func surfaceMeasurements(
        triangleIndices: [Int],
        selectionModel: SelectionModel,
        node: SCNNode
    ) -> SelectionSurfaceMeasurements {
        let selected = Set(triangleIndices)
        var area: Float = 0
        var edgeUseCounts: [SelectionEdgeKey: Int] = [:]

        for triangleIndex in triangleIndices {
            guard triangleIndex >= 0, triangleIndex < selectionModel.triangles.count else {
                continue
            }

            let triangle = selectionModel.triangles[triangleIndex]
            guard let a = worldVertex(triangle.vertexIndices[0], selectionModel: selectionModel, node: node),
                  let b = worldVertex(triangle.vertexIndices[1], selectionModel: selectionModel, node: node),
                  let c = worldVertex(triangle.vertexIndices[2], selectionModel: selectionModel, node: node)
            else {
                continue
            }
            area += simd_length(simd_cross(b - a, c - a)) * 0.5

            for edgeKey in triangle.edgeKeys {
                edgeUseCounts[edgeKey, default: 0] += 1
            }
        }

        var perimeter: Float = 0
        for (edgeKey, count) in edgeUseCounts where count == 1 {
            guard selected.contains(where: { triangleIndex in
                selectionModel.triangles.indices.contains(triangleIndex)
                    && selectionModel.triangles[triangleIndex].edgeKeys.contains(edgeKey)
            }),
            let a = worldVertex(edgeKey.a, selectionModel: selectionModel, node: node),
            let b = worldVertex(edgeKey.b, selectionModel: selectionModel, node: node)
            else {
                continue
            }
            perimeter += simd_distance(a, b)
        }

        return SelectionSurfaceMeasurements(area: area, perimeter: perimeter)
    }

    static func polylineLength(_ points: [SIMD3<Float>]) -> Float {
        zip(points, points.dropFirst()).reduce(Float(0)) { partial, pair in
            partial + simd_distance(pair.0, pair.1)
        }
    }

    static func minimumDistance(between polylines: [[SIMD3<Float>]]) -> Float? {
        minimumDistanceReport(between: polylines)?.distance
    }

    static func minimumDistanceReport(between polylines: [[SIMD3<Float>]]) -> (distance: Float, firstPoint: SIMD3<Float>, secondPoint: SIMD3<Float>)? {
        var best: (distance: Float, firstPoint: SIMD3<Float>, secondPoint: SIMD3<Float>)?
        for firstIndex in polylines.indices {
            let firstSegments = segments(in: polylines[firstIndex])
            guard !firstSegments.isEmpty else { continue }
            for secondIndex in polylines.indices where secondIndex > firstIndex {
                let secondSegments = segments(in: polylines[secondIndex])
                guard !secondSegments.isEmpty else { continue }
                for first in firstSegments {
                    for second in secondSegments {
                        let candidate = segmentSegmentDistanceReport(first.0, first.1, second.0, second.1)
                        if best == nil || candidate.distance < best!.distance {
                            best = candidate
                        }
                    }
                }
            }
        }

        return best
    }

    static func closestDistanceDetail(_ entities: [SelectionMeasurementEntity]) -> SelectionMeasurementDistanceDetail? {
        let edgeEntities = uniqueEdges(entities)
        var best: (
            distance: Float,
            first: SelectionMeasurementEntity,
            second: SelectionMeasurementEntity,
            firstPoint: SIMD3<Float>,
            secondPoint: SIMD3<Float>
        )?
        var farthest: (
            distance: Float,
            first: SelectionMeasurementEntity,
            second: SelectionMeasurementEntity,
            firstPoint: SIMD3<Float>,
            secondPoint: SIMD3<Float>
        )?

        for firstIndex in edgeEntities.indices {
            let first = edgeEntities[firstIndex]
            let firstSegments = segments(in: first.simdPoints)
            guard !firstSegments.isEmpty else { continue }

            for secondIndex in edgeEntities.indices where secondIndex > firstIndex {
                let second = edgeEntities[secondIndex]
                let secondSegments = segments(in: second.simdPoints)
                guard !secondSegments.isEmpty else { continue }

                for firstSegment in firstSegments {
                    for secondSegment in secondSegments {
                        let nearest = segmentSegmentDistanceReport(
                            firstSegment.0,
                            firstSegment.1,
                            secondSegment.0,
                            secondSegment.1
                        )
                        if best == nil || nearest.distance < best!.distance {
                            best = (nearest.distance, first, second, nearest.firstPoint, nearest.secondPoint)
                        }

                        let endpoints = [
                            (firstSegment.0, secondSegment.0),
                            (firstSegment.0, secondSegment.1),
                            (firstSegment.1, secondSegment.0),
                            (firstSegment.1, secondSegment.1),
                        ]
                        for endpointPair in endpoints {
                            let distance = simd_distance(endpointPair.0, endpointPair.1)
                            if farthest == nil || distance > farthest!.distance {
                                farthest = (distance, first, second, endpointPair.0, endpointPair.1)
                            }
                        }
                    }
                }
            }
        }

        guard let best else {
            return nil
        }
        let farthestPair = farthest ?? best
        let minimumDelta = best.secondPoint - best.firstPoint
        let maximumDelta = farthestPair.secondPoint - farthestPair.firstPoint

        return SelectionMeasurementDistanceDetail(
            firstEntityID: best.first.id,
            secondEntityID: best.second.id,
            firstLabel: best.first.label,
            secondLabel: best.second.label,
            minimumDistance: best.distance,
            minimumDelta: array(minimumDelta),
            minimumFirstPoint: array(best.firstPoint),
            minimumSecondPoint: array(best.secondPoint),
            maximumDistance: farthestPair.distance,
            maximumDelta: array(maximumDelta),
            maximumFirstPoint: array(farthestPair.firstPoint),
            maximumSecondPoint: array(farthestPair.secondPoint)
        )
    }

    static func minimumCentroidDistance(_ polylines: [[SIMD3<Float>]]) -> Float? {
        let centers = polylines.compactMap(centroid)
        guard centers.count >= 2 else {
            return nil
        }

        var best = Float.greatestFiniteMagnitude
        for first in centers.indices {
            for second in centers.indices where second > first {
                best = min(best, simd_distance(centers[first], centers[second]))
            }
        }
        return best.isFinite ? best : nil
    }

    static func angleDegrees(_ first: [SIMD3<Float>], _ second: [SIMD3<Float>]) -> Float? {
        guard let firstDirection = principalDirection(first),
              let secondDirection = principalDirection(second)
        else {
            return nil
        }
        let dot = min(max(abs(simd_dot(firstDirection, secondDirection)), -1), 1)
        return acosf(dot) * 180 / .pi
    }

    private static func worldVertex(
        _ index: Int,
        selectionModel: SelectionModel,
        node: SCNNode
    ) -> SIMD3<Float>? {
        guard index >= 0, index < selectionModel.vertices.count else {
            return nil
        }
        let vertex = selectionModel.vertices[index]
        let converted = node.convertPosition(SCNVector3(CGFloat(vertex.x), CGFloat(vertex.y), CGFloat(vertex.z)), to: nil)
        return SIMD3<Float>(Float(converted.x), Float(converted.y), Float(converted.z))
    }

    private static func segments(in points: [SIMD3<Float>]) -> [(SIMD3<Float>, SIMD3<Float>)] {
        zip(points, points.dropFirst()).compactMap { pair in
            simd_distance(pair.0, pair.1) > 0.000001 ? pair : nil
        }
    }

    private static func array(_ point: SIMD3<Float>) -> [Float] {
        [point.x, point.y, point.z]
    }

    private static func centroid(_ points: [SIMD3<Float>]) -> SIMD3<Float>? {
        guard !points.isEmpty else {
            return nil
        }
        return points.reduce(SIMD3<Float>(repeating: 0), +) / Float(points.count)
    }

    private static func principalDirection(_ points: [SIMD3<Float>]) -> SIMD3<Float>? {
        let validSegments = segments(in: points)
        guard let longest = validSegments.max(by: {
            simd_length_squared($0.1 - $0.0) < simd_length_squared($1.1 - $1.0)
        }) else {
            return nil
        }
        let vector = longest.1 - longest.0
        let length = simd_length(vector)
        guard length.isFinite, length > 0.000001 else {
            return nil
        }
        return vector / length
    }

    private static func segmentSegmentDistance(
        _ p1: SIMD3<Float>,
        _ q1: SIMD3<Float>,
        _ p2: SIMD3<Float>,
        _ q2: SIMD3<Float>
    ) -> Float {
        segmentSegmentDistanceReport(p1, q1, p2, q2).distance
    }

    private static func segmentSegmentDistanceReport(
        _ p1: SIMD3<Float>,
        _ q1: SIMD3<Float>,
        _ p2: SIMD3<Float>,
        _ q2: SIMD3<Float>
    ) -> (distance: Float, firstPoint: SIMD3<Float>, secondPoint: SIMD3<Float>) {
        let d1 = q1 - p1
        let d2 = q2 - p2
        let r = p1 - p2
        let a = simd_dot(d1, d1)
        let e = simd_dot(d2, d2)
        let f = simd_dot(d2, r)
        let epsilon: Float = 0.000001

        if a <= epsilon, e <= epsilon {
            return (simd_distance(p1, p2), p1, p2)
        }
        if a <= epsilon {
            let t = min(max(f / e, 0), 1)
            let closestSecond = p2 + d2 * t
            return (simd_distance(p1, closestSecond), p1, closestSecond)
        }
        if e <= epsilon {
            let s = min(max(-simd_dot(d1, r) / a, 0), 1)
            let closestFirst = p1 + d1 * s
            return (simd_distance(closestFirst, p2), closestFirst, p2)
        }

        let b = simd_dot(d1, d2)
        let c = simd_dot(d1, r)
        let denominator = a * e - b * b
        var s: Float = 0
        if denominator != 0 {
            s = min(max((b * f - c * e) / denominator, 0), 1)
        }

        let tNominal = b * s + f
        let t: Float
        if tNominal < 0 {
            t = 0
            s = min(max(-c / a, 0), 1)
        } else if tNominal > e {
            t = 1
            s = min(max((b - c) / a, 0), 1)
        } else {
            t = tNominal / e
        }

        let closestFirst = p1 + d1 * s
        let closestSecond = p2 + d2 * t
        return (simd_distance(closestFirst, closestSecond), closestFirst, closestSecond)
    }
}
