import Foundation
import QuickLookCore
import SceneKit
import simd

/// `model` remains decodable for old plans and preferences but is never exposed in the UI.
enum MeasurementUnit: String, Codable, CaseIterable, Identifiable {
    case model
    case millimeters = "mm"
    case inches = "in"

    static let visibleCases: [MeasurementUnit] = [.millimeters, .inches]

    var id: String { rawValue }
    var shortLabel: String { self == .inches ? "in" : "mm" }
    var areaLabel: String { self == .inches ? "in2" : "mm2" }

    static func resolved(from rawValue: String?) -> MeasurementUnit {
        guard let unit = rawValue.flatMap(MeasurementUnit.init(rawValue:)), unit != .model else {
            return .millimeters
        }
        return unit
    }

    func convertLength(_ value: Float, mmPerModelUnit: Double) -> Double {
        scaleContext(mmPerModelUnit).convertLength(value, to: coreUnit)
    }

    func convertArea(_ value: Float, mmPerModelUnit: Double) -> Double {
        scaleContext(mmPerModelUnit).convertArea(value, to: coreUnit)
    }

    private var coreUnit: MeasurementDisplayUnit { self == .inches ? .inches : .millimeters }

    private func scaleContext(_ millimetersPerSourceUnit: Double) -> MeasurementScaleContext {
        MeasurementScaleContext(
            sourceUnit: .unknown,
            millimetersPerSourceUnitOverride: millimetersPerSourceUnit
        )
    }
}

enum SelectionMeasurementKind: String, Codable, Sendable {
    case empty
    case point
    case edge
    case surface
    case multiEdge
    case multiSurface
    case mixed
}

typealias SelectionMeasurementEntityKind = SelectionKind

struct SelectionMeasurementExpectation: Codable {
    let kind: String?
    let entityCount: Int?
    let unitMode: String?
    let relation: String?
    let minTotalLength: Float?
    let maxTotalLength: Float?
    let minMinimumDistance: Float?
    let maxMinimumDistance: Float?
    let minArea: Float?
    let maxArea: Float?
    let minPerimeter: Float?
    let maxPerimeter: Float?
}

struct SelectionMeasurementState: Codable, Equatable, Sendable {
    static let empty = SelectionMeasurementState(
        kind: .empty,
        entities: [],
        summary: .empty
    )

    let kind: SelectionMeasurementKind
    let entities: [SelectionMeasurementEntity]
    let summary: SelectionMeasurementSummary

    var isEmpty: Bool { kind == .empty || entities.isEmpty }

    static func entities(
        _ entities: [SelectionMeasurementEntity],
        includeDistanceDetail: Bool = true
    ) -> SelectionMeasurementState {
        let unique = SelectionMeasurementCalculator.uniqueEntities(entities)
        guard !unique.isEmpty else { return .empty }

        let pointCount = unique.filter { $0.kind == .point }.count
        let edgeCount = unique.filter { $0.kind == .edge }.count
        let surfaceCount = unique.filter { $0.kind == .surface }.count
        let kind: SelectionMeasurementKind
        if unique.count == 1 {
            if pointCount == 1 {
                kind = .point
            } else {
                kind = edgeCount == 1 ? .edge : .surface
            }
        } else if edgeCount == unique.count {
            kind = .multiEdge
        } else if surfaceCount == unique.count {
            kind = .multiSurface
        } else {
            kind = .mixed
        }
        return SelectionMeasurementState(
            kind: kind,
            entities: unique,
            summary: SelectionMeasurementCalculator.summary(
                for: unique,
                kind: kind,
                includeDistanceDetail: includeDistanceDetail
            )
        )
    }

    static func updating(
        _ current: SelectionMeasurementState,
        with entity: SelectionMeasurementEntity,
        modifiers: [String],
        includeDistanceDetail: Bool = true
    ) -> SelectionMeasurementState {
        if modifiers.contains("command") {
            if current.entities.contains(where: { $0.id == entity.id }) {
                return entities(
                    current.entities.filter { $0.id != entity.id },
                    includeDistanceDetail: includeDistanceDetail
                )
            }
            return entities(current.entities + [entity], includeDistanceDetail: includeDistanceDetail)
        }
        if modifiers.contains("shift") {
            return entities(current.entities + [entity], includeDistanceDetail: includeDistanceDetail)
        }
        return entities([entity], includeDistanceDetail: includeDistanceDetail)
    }

    func removing(
        entityID: String,
        includeDistanceDetail: Bool = true
    ) -> SelectionMeasurementState {
        Self.entities(
            entities.filter { $0.id != entityID },
            includeDistanceDetail: includeDistanceDetail
        )
    }
}

struct SelectionMeasurementEntity: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: SelectionMeasurementEntityKind
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
    let displayPoints: [[Float]]?
    let sourcePoints: [[Float]]?
    let sourceTriangleVertices: [[Float]]?
    let origin: [Float]?
    let axis: [Float]?
    let normal: [Float]?

    init(
        id: String,
        kind: SelectionMeasurementEntityKind,
        label: String,
        sourceIDs: [String],
        length: Float?,
        radius: Float?,
        area: Float?,
        perimeter: Float?,
        triangleCount: Int?,
        pointCount: Int?,
        shape: String?,
        surfaceType: String?,
        points: [[Float]],
        displayPoints: [[Float]]?,
        sourcePoints: [[Float]]?,
        sourceTriangleVertices: [[Float]]? = nil,
        origin: [Float]? = nil,
        axis: [Float]? = nil,
        normal: [Float]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.sourceIDs = sourceIDs
        self.length = length
        self.radius = radius
        self.area = area
        self.perimeter = perimeter
        self.triangleCount = triangleCount
        self.pointCount = pointCount
        self.shape = shape
        self.surfaceType = surfaceType
        self.points = points
        self.displayPoints = displayPoints
        self.sourcePoints = sourcePoints
        self.sourceTriangleVertices = sourceTriangleVertices
        self.origin = origin
        self.axis = axis
        self.normal = normal
    }

    var simdPoints: [SIMD3<Float>] { Self.simd3Array(points) }
    var simdDisplayPoints: [SIMD3<Float>] { Self.simd3Array(displayPoints ?? points) }
    var simdSourcePoints: [SIMD3<Float>] { Self.simd3Array(sourcePoints ?? points) }
    var simdSourceTriangleVertices: [SIMD3<Float>] { Self.simd3Array(sourceTriangleVertices ?? []) }

    var geometryKind: MeasurementGeometryKind {
        if kind == .point { return .point }
        let value = (kind == .edge ? shape : surfaceType)?.lowercased() ?? ""
        if value.contains("circle") { return .circle }
        if value.contains("arc") || value.contains("semicircle") { return .arc }
        if value.contains("line") { return .line }
        if value.contains("plane") || value.contains("planar") { return .plane }
        if value.contains("cylinder") || value.contains("cylindrical") { return .cylinder }
        return .other
    }

    var coreGeometry: MeasurementGeometry {
        MeasurementGeometry(
            kind: geometryKind,
            points: simdSourcePoints,
            triangleVertices: simdSourceTriangleVertices,
            origin: Self.simd3(origin),
            axis: Self.simd3(axis),
            normal: Self.simd3(normal),
            radius: radius
        )
    }

    private static func simd3Array(_ values: [[Float]]) -> [SIMD3<Float>] {
        values.compactMap(simd3)
    }

    private static func simd3(_ values: [Float]?) -> SIMD3<Float>? {
        guard let values, values.count >= 3 else { return nil }
        return SIMD3<Float>(values[0], values[1], values[2])
    }
}

struct SelectionMeasurementSummary: Codable, Equatable, Sendable {
    static let empty = SelectionMeasurementSummary(
        kind: .empty,
        entityCount: 0,
        label: "No selection"
    )

    let kind: SelectionMeasurementKind
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
    let axisDistance: Float?
    let radialGap: Float?
    let angleDegrees: Float?
    let triangleCount: Int?
    let pointCount: Int?
    let shape: String?
    let surfaceType: String?
    let relation: String?
    var unitMode: String?
    let distanceDetail: SelectionMeasurementDistanceDetail?

    init(
        kind: SelectionMeasurementKind,
        entityCount: Int,
        label: String,
        length: Float? = nil,
        totalLength: Float? = nil,
        area: Float? = nil,
        perimeter: Float? = nil,
        radius: Float? = nil,
        minimumDistance: Float? = nil,
        maximumDistance: Float? = nil,
        centerToCenterDistance: Float? = nil,
        axisDistance: Float? = nil,
        radialGap: Float? = nil,
        angleDegrees: Float? = nil,
        triangleCount: Int? = nil,
        pointCount: Int? = nil,
        shape: String? = nil,
        surfaceType: String? = nil,
        relation: String? = nil,
        unitMode: String? = nil,
        distanceDetail: SelectionMeasurementDistanceDetail? = nil
    ) {
        self.kind = kind
        self.entityCount = entityCount
        self.label = label
        self.length = length
        self.totalLength = totalLength
        self.area = area
        self.perimeter = perimeter
        self.radius = radius
        self.minimumDistance = minimumDistance
        self.maximumDistance = maximumDistance
        self.centerToCenterDistance = centerToCenterDistance
        self.axisDistance = axisDistance
        self.radialGap = radialGap
        self.angleDegrees = angleDegrees
        self.triangleCount = triangleCount
        self.pointCount = pointCount
        self.shape = shape
        self.surfaceType = surfaceType
        self.relation = relation
        self.unitMode = unitMode
        self.distanceDetail = distanceDetail
    }

    func withUnitMode(_ unitMode: MeasurementUnit) -> SelectionMeasurementSummary {
        var copy = self
        copy.unitMode = MeasurementUnit.resolved(from: unitMode.rawValue).rawValue
        return copy
    }

    func convertedForTesting(
        unit: MeasurementUnit,
        millimetersPerSourceUnit: Double
    ) -> SelectionMeasurementSummary {
        let resolvedUnit = MeasurementUnit.resolved(from: unit.rawValue)
        func convertedLength(_ value: Float?) -> Float? {
            value.map { Float(resolvedUnit.convertLength($0, mmPerModelUnit: millimetersPerSourceUnit)) }
        }
        func areaValue(_ value: Float?) -> Float? {
            value.map { Float(resolvedUnit.convertArea($0, mmPerModelUnit: millimetersPerSourceUnit)) }
        }
        return SelectionMeasurementSummary(
            kind: kind,
            entityCount: entityCount,
            label: label,
            length: convertedLength(length),
            totalLength: convertedLength(totalLength),
            area: areaValue(area),
            perimeter: convertedLength(perimeter),
            radius: convertedLength(radius),
            minimumDistance: convertedLength(minimumDistance),
            maximumDistance: convertedLength(maximumDistance),
            centerToCenterDistance: convertedLength(centerToCenterDistance),
            axisDistance: convertedLength(axisDistance),
            radialGap: convertedLength(radialGap),
            angleDegrees: angleDegrees,
            triangleCount: triangleCount,
            pointCount: pointCount,
            shape: shape,
            surfaceType: surfaceType,
            relation: relation,
            unitMode: resolvedUnit.rawValue,
            distanceDetail: distanceDetail?.converted(
                unit: resolvedUnit,
                millimetersPerSourceUnit: millimetersPerSourceUnit
            )
        )
    }
}

typealias SelectionSurfaceMeasurements = (
    area: Float,
    perimeter: Float,
    sourceTriangleVertices: [SIMD3<Float>]
)

struct SelectionMeasurementDistanceDetail: Codable, Equatable, Sendable {
    let firstEntityID: String
    let secondEntityID: String
    let firstLabel: String
    let secondLabel: String
    let firstGeometryKind: String?
    let secondGeometryKind: String?
    let relation: String?
    let angleDegrees: Float?
    let minimumDistance: Float
    let minimumDelta: [Float]
    let minimumFirstPoint: [Float]
    let minimumSecondPoint: [Float]
    let maximumDistance: Float
    let maximumDelta: [Float]
    let maximumFirstPoint: [Float]
    let maximumSecondPoint: [Float]
    let centerDistance: Float?
    let axisDistance: Float?
    let radialGap: Float?

    var minimumDeltaSIMD: SIMD3<Float>? { Self.simd3(minimumDelta) }
    var maximumDeltaSIMD: SIMD3<Float>? { Self.simd3(maximumDelta) }
    var minimumFirstPointSIMD: SIMD3<Float>? { Self.simd3(minimumFirstPoint) }
    var minimumSecondPointSIMD: SIMD3<Float>? { Self.simd3(minimumSecondPoint) }
    var maximumFirstPointSIMD: SIMD3<Float>? { Self.simd3(maximumFirstPoint) }
    var maximumSecondPointSIMD: SIMD3<Float>? { Self.simd3(maximumSecondPoint) }

    func converted(
        unit: MeasurementUnit,
        millimetersPerSourceUnit: Double
    ) -> SelectionMeasurementDistanceDetail {
        func value(_ input: Float) -> Float {
            Float(unit.convertLength(input, mmPerModelUnit: millimetersPerSourceUnit))
        }
        func values(_ input: [Float]) -> [Float] { input.map(value) }
        return SelectionMeasurementDistanceDetail(
            firstEntityID: firstEntityID,
            secondEntityID: secondEntityID,
            firstLabel: firstLabel,
            secondLabel: secondLabel,
            firstGeometryKind: firstGeometryKind,
            secondGeometryKind: secondGeometryKind,
            relation: relation,
            angleDegrees: angleDegrees,
            minimumDistance: value(minimumDistance),
            minimumDelta: values(minimumDelta),
            minimumFirstPoint: values(minimumFirstPoint),
            minimumSecondPoint: values(minimumSecondPoint),
            maximumDistance: value(maximumDistance),
            maximumDelta: values(maximumDelta),
            maximumFirstPoint: values(maximumFirstPoint),
            maximumSecondPoint: values(maximumSecondPoint),
            centerDistance: centerDistance.map(value),
            axisDistance: axisDistance.map(value),
            radialGap: radialGap.map(value)
        )
    }

    private static func simd3(_ values: [Float]) -> SIMD3<Float>? {
        guard values.count >= 3 else { return nil }
        return SIMD3<Float>(values[0], values[1], values[2])
    }
}

enum SelectionMeasurementCalculator {
    static func uniqueEntities(
        _ entities: [SelectionMeasurementEntity]
    ) -> [SelectionMeasurementEntity] {
        var seen: Set<String> = []
        return entities.filter { seen.insert($0.id).inserted }
    }

    static func summary(
        for entities: [SelectionMeasurementEntity],
        kind: SelectionMeasurementKind,
        includeDistanceDetail: Bool = true
    ) -> SelectionMeasurementSummary {
        guard !entities.isEmpty else { return .empty }
        let edges = entities.filter { $0.kind == .edge }
        let surfaces = entities.filter { $0.kind == .surface }
        let totalLength = edges.isEmpty ? nil : edges.reduce(Float(0)) {
            $0 + ($1.length ?? polylineLength($1.simdSourcePoints))
        }
        let totalArea = surfaces.isEmpty ? nil : surfaces.reduce(Float(0)) { $0 + ($1.area ?? 0) }
        let totalPerimeter = surfaces.isEmpty ? nil : surfaces.reduce(Float(0)) { $0 + ($1.perimeter ?? 0) }
        let pointCount = edges.isEmpty ? nil : edges.reduce(0) { $0 + ($1.pointCount ?? $1.simdSourcePoints.count) }
        let triangleCount = surfaces.isEmpty ? nil : surfaces.reduce(0) { $0 + ($1.triangleCount ?? 0) }
        let detail = includeDistanceDetail && entities.count >= 2
            ? closestDistanceDetail(entities)
            : nil
        let single = entities.count == 1 ? entities[0] : nil

        return SelectionMeasurementSummary(
            kind: kind,
            entityCount: entities.count,
            label: single?.label ?? "\(entities.count) selected",
            length: single?.length,
            totalLength: totalLength,
            area: single?.area ?? totalArea,
            perimeter: single?.perimeter ?? totalPerimeter,
            radius: single?.radius,
            minimumDistance: detail?.minimumDistance,
            maximumDistance: detail?.maximumDistance,
            centerToCenterDistance: detail?.centerDistance,
            axisDistance: detail?.axisDistance,
            radialGap: detail?.radialGap,
            angleDegrees: detail?.angleDegrees,
            triangleCount: single?.triangleCount ?? triangleCount,
            pointCount: single?.pointCount ?? pointCount,
            shape: single?.shape,
            surfaceType: single?.surfaceType,
            relation: entities.count == 2 ? detail?.relation : nil,
            distanceDetail: detail
        )
    }

    static func surfaceMeasurements(
        triangleIndices: [Int],
        selectionModel: SelectionModel,
        node: SCNNode,
        scene: SCNScene?
    ) -> SelectionSurfaceMeasurements {
        var remappedVertices: [SIMD3<Float>] = []
        var sourceToRemapped: [Int: Int] = [:]
        var remappedTriangles: [SIMD3<Int32>] = []

        for triangleIndex in triangleIndices where selectionModel.triangles.indices.contains(triangleIndex) {
            let sourceTriangle = selectionModel.triangles[triangleIndex]
            var mapped: [Int32] = []
            for sourceIndex in sourceTriangle.vertexIndices {
                if let existing = sourceToRemapped[sourceIndex] {
                    mapped.append(Int32(existing))
                    continue
                }
                guard let sourcePoint = sourceVertex(
                    sourceIndex,
                    selectionModel: selectionModel,
                    node: node,
                    scene: scene
                ) else {
                    mapped.removeAll()
                    break
                }
                let next = remappedVertices.count
                remappedVertices.append(sourcePoint)
                sourceToRemapped[sourceIndex] = next
                mapped.append(Int32(next))
            }
            if mapped.count == 3 {
                remappedTriangles.append(SIMD3<Int32>(mapped[0], mapped[1], mapped[2]))
            }
        }

        let mesh = MeshSnapshot(
            sourceID: MeshSourceID(model: "measurement", node: "selected", geometry: "surface"),
            vertices: remappedVertices,
            triangleIndices: remappedTriangles
        )
        let measurement = MeasurementEngine.surface(mesh: mesh, triangles: mesh.triangles.map(\.id))
        let triangleVertices = remappedTriangles.flatMap { triangle in
            [
                remappedVertices[Int(triangle.x)],
                remappedVertices[Int(triangle.y)],
                remappedVertices[Int(triangle.z)],
            ]
        }
        return SelectionSurfaceMeasurements(
            area: measurement.area,
            perimeter: measurement.perimeter,
            sourceTriangleVertices: triangleVertices
        )
    }

    static func polylineLength(_ points: [SIMD3<Float>]) -> Float {
        MeasurementEngine.edgeLength(points: points)
    }

    static func closestDistanceDetail(
        _ entities: [SelectionMeasurementEntity]
    ) -> SelectionMeasurementDistanceDetail? {
        var selected: (
            first: SelectionMeasurementEntity,
            second: SelectionMeasurementEntity,
            result: MeasurementPairResult
        )?

        for firstIndex in entities.indices {
            for secondIndex in entities.indices where secondIndex > firstIndex {
                let result = MeasurementEngine.compare(
                    entities[firstIndex].coreGeometry,
                    entities[secondIndex].coreGeometry
                )
                guard result.minimum != nil else { continue }
                if selected == nil || result.minimum!.distance < selected!.result.minimum!.distance {
                    selected = (entities[firstIndex], entities[secondIndex], result)
                }
            }
        }

        guard let selected, let minimum = selected.result.minimum else { return nil }
        let maximum = selected.result.maximum ?? minimum
        return SelectionMeasurementDistanceDetail(
            firstEntityID: selected.first.id,
            secondEntityID: selected.second.id,
            firstLabel: selected.first.label,
            secondLabel: selected.second.label,
            firstGeometryKind: selected.first.geometryKind.rawValue,
            secondGeometryKind: selected.second.geometryKind.rawValue,
            relation: selected.result.relation.rawValue,
            angleDegrees: selected.result.angleDegrees,
            minimumDistance: minimum.distance,
            minimumDelta: array(minimum.delta),
            minimumFirstPoint: array(minimum.first),
            minimumSecondPoint: array(minimum.second),
            maximumDistance: maximum.distance,
            maximumDelta: array(maximum.delta),
            maximumFirstPoint: array(maximum.first),
            maximumSecondPoint: array(maximum.second),
            centerDistance: selected.result.centerDistance,
            axisDistance: selected.result.axisDistance,
            radialGap: selected.result.radialGap
        )
    }

    private static func sourceVertex(
        _ index: Int,
        selectionModel: SelectionModel,
        node: SCNNode,
        scene: SCNScene?
    ) -> SIMD3<Float>? {
        guard selectionModel.vertices.indices.contains(index) else { return nil }
        let vertex = selectionModel.vertices[index]
        let world = node.convertPosition(
            SCNVector3(CGFloat(vertex.x), CGFloat(vertex.y), CGFloat(vertex.z)),
            to: nil
        )
        let scenePoint = SIMD3<Float>(Float(world.x), Float(world.y), Float(world.z))
        return scene.map { SceneComposer.sourcePoint(fromScenePoint: scenePoint, in: $0) } ?? scenePoint
    }

    private static func array(_ point: SIMD3<Float>) -> [Float] {
        [point.x, point.y, point.z]
    }
}
