import XCTest
@testable import QuickLookCore

final class QuickLookCoreTests: XCTestCase {
    private let source = MeshSourceID(model: "fixture", node: "root", geometry: "mesh")

    func testFeatureEdgeBVHMatchesLinearDistance() {
        let segments = (0..<64).map { index in
            MeshSegment(
                id: MeshEdgeID(index * 2, index * 2 + 1),
                start: SIMD3<Float>(Float(index), 0, 0),
                end: SIMD3<Float>(Float(index), 1, 0)
            )
        }
        let point = SIMD3<Float>(17.25, 0.5, 2)
        let hit = FeatureEdgeBVH(segments: segments).nearest(to: point)
        let expected = segments.map { GeometryMath.distanceSquared(from: point, to: $0) }.min()!
        XCTAssertEqual(hit!.distance * hit!.distance, expected, accuracy: 1e-5)
    }

    func testSelectionChoosesEdgeThenSurface() {
        let mesh = MeshSnapshot(
            sourceID: source,
            vertices: [
                SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(1, 1, 0), SIMD3<Float>(0, 1, 0),
            ],
            triangleIndices: [SIMD3<Int32>(0, 1, 2), SIMD3<Int32>(0, 2, 3)]
        )
        let engine = SelectionEngine(mesh: mesh)
        XCTAssertEqual(
            engine.resolve(.init(triangleID: .init(0), localPoint: SIMD3<Float>(0.5, 0, 0))).kind,
            .edge
        )
        XCTAssertEqual(
            engine.resolve(.init(triangleID: .init(0), localPoint: SIMD3<Float>(0.5, 0.5, 0))).kind,
            .surface
        )
    }

    func testEdgeSelectionStopsAtSharpConnectedCorner() {
        let mesh = MeshSnapshot(
            sourceID: source,
            vertices: [
                SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(1, 1, 0), SIMD3<Float>(0, 1, 0),
            ],
            triangleIndices: [SIMD3<Int32>(0, 1, 2), SIMD3<Int32>(0, 2, 3)]
        )
        let engine = SelectionEngine(
            mesh: mesh,
            settings: SelectionSettings(edgeThresholdScale: 0.2)
        )
        let result = engine.resolve(
            SelectionQuery(triangleID: MeshTriangleID(0), localPoint: SIMD3<Float>(0.5, 0, 0))
        )

        guard case .edge(let edge) = result.entity else {
            return XCTFail("Expected edge selection")
        }
        XCTAssertEqual(edge.edges, [MeshEdgeID(0, 1)])
        XCTAssertEqual(edge.points.count, 2)
    }

    func testSurfaceMeasurements() {
        let mesh = MeshSnapshot(
            sourceID: source,
            vertices: [
                SIMD3<Float>(0, 0, 0), SIMD3<Float>(2, 0, 0),
                SIMD3<Float>(2, 1, 0), SIMD3<Float>(0, 1, 0),
            ],
            triangleIndices: [SIMD3<Int32>(0, 1, 2), SIMD3<Int32>(0, 2, 3)]
        )
        let value = MeasurementEngine.surface(mesh: mesh, triangles: [.init(0), .init(1)])
        XCTAssertEqual(value.area, 2, accuracy: 1e-6)
        XCTAssertEqual(value.perimeter, 6, accuracy: 1e-6)
    }

    func testMeasurementClassifiesParallelPerpendicularAndSkewLines() {
        let horizontal = MeasurementGeometry(
            kind: .line,
            points: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(10, 0, 0)]
        )
        let parallel = MeasurementGeometry(
            kind: .line,
            points: [SIMD3<Float>(0, 6.5, 0), SIMD3<Float>(10, 6.5, 0)]
        )
        let perpendicular = MeasurementGeometry(
            kind: .line,
            points: [SIMD3<Float>(5, -2, 0), SIMD3<Float>(5, 2, 0)]
        )
        let skew = MeasurementGeometry(
            kind: .line,
            points: [SIMD3<Float>(0, 2, 3), SIMD3<Float>(10, 7, 3)]
        )

        let parallelResult = MeasurementEngine.compare(horizontal, parallel)
        XCTAssertEqual(parallelResult.relation, .parallel)
        XCTAssertEqual(parallelResult.minimum?.distance ?? -1, 6.5, accuracy: 1e-5)
        XCTAssertEqual(parallelResult.angleDegrees ?? -1, 0, accuracy: 1e-5)

        let perpendicularResult = MeasurementEngine.compare(horizontal, perpendicular)
        XCTAssertEqual(perpendicularResult.relation, .perpendicular)
        XCTAssertEqual(perpendicularResult.minimum?.distance ?? -1, 0, accuracy: 1e-5)
        XCTAssertEqual(perpendicularResult.angleDegrees ?? -1, 90, accuracy: 1e-5)

        XCTAssertEqual(MeasurementEngine.compare(horizontal, skew).relation, .skew)
    }

    func testMeasurementClassifiesCircleAndCylinderRelationships() {
        let firstCircle = MeasurementGeometry(
            kind: .circle,
            origin: .zero,
            axis: SIMD3<Float>(0, 0, 1),
            radius: 2
        )
        let concentricCircle = MeasurementGeometry(
            kind: .circle,
            origin: .zero,
            axis: SIMD3<Float>(0, 0, 1),
            radius: 1
        )
        let coaxialCylinder = MeasurementGeometry(
            kind: .cylinder,
            origin: SIMD3<Float>(0, 0, 4),
            axis: SIMD3<Float>(0, 0, 1),
            radius: 3
        )
        let firstCylinder = MeasurementGeometry(
            kind: .cylinder,
            origin: .zero,
            axis: SIMD3<Float>(0, 0, 1),
            radius: 2
        )

        let circles = MeasurementEngine.compare(firstCircle, concentricCircle)
        XCTAssertEqual(circles.relation, .concentric)
        XCTAssertEqual(circles.radialGap ?? -1, 1, accuracy: 1e-6)

        let cylinders = MeasurementEngine.compare(firstCylinder, coaxialCylinder)
        XCTAssertEqual(cylinders.relation, .coaxial)
        XCTAssertEqual(cylinders.axisDistance ?? -1, 0, accuracy: 1e-6)
    }

    func testMeasurementClassifiesLinePlaneAndPlanePlaneRelationships() {
        let planeTriangles: [SIMD3<Float>] = [
            SIMD3<Float>(-2, -2, 0), SIMD3<Float>(2, -2, 0), SIMD3<Float>(2, 2, 0),
            SIMD3<Float>(-2, -2, 0), SIMD3<Float>(2, 2, 0), SIMD3<Float>(-2, 2, 0),
        ]
        let plane = MeasurementGeometry(
            kind: .plane,
            triangleVertices: planeTriangles,
            origin: .zero,
            normal: SIMD3<Float>(0, 0, 1)
        )
        let parallelLine = MeasurementGeometry(
            kind: .line,
            points: [SIMD3<Float>(-1, 0, 2), SIMD3<Float>(1, 0, 2)]
        )
        let perpendicularLine = MeasurementGeometry(
            kind: .line,
            points: [SIMD3<Float>(0, 0, -1), SIMD3<Float>(0, 0, 1)]
        )
        let verticalPlane = MeasurementGeometry(
            kind: .plane,
            triangleVertices: [
                SIMD3<Float>(0, -2, -2), SIMD3<Float>(0, 2, -2), SIMD3<Float>(0, 2, 2),
            ],
            origin: .zero,
            normal: SIMD3<Float>(1, 0, 0)
        )

        XCTAssertEqual(MeasurementEngine.compare(parallelLine, plane).relation, .parallel)
        XCTAssertEqual(MeasurementEngine.compare(perpendicularLine, plane).relation, .perpendicular)
        XCTAssertEqual(MeasurementEngine.compare(plane, verticalPlane).relation, .perpendicular)
    }

    func testMeasurementScaleUsesKnownAndAssumedSourceUnits() {
        let centimeters = MeasurementScaleContext(sourceUnit: .centimeter)
        XCTAssertFalse(centimeters.isAssumed)
        XCTAssertEqual(centimeters.convertLength(2, to: .millimeters), 20, accuracy: 1e-9)
        XCTAssertEqual(centimeters.convertArea(4, to: .millimeters), 400, accuracy: 1e-9)

        let assumed = MeasurementScaleContext(sourceUnit: .unknown)
        XCTAssertTrue(assumed.isAssumed)
        XCTAssertEqual(assumed.convertLength(25.4, to: .inches), 1, accuracy: 1e-6)

        let calibrated = MeasurementScaleContext(
            sourceUnit: .unknown,
            millimetersPerSourceUnitOverride: 2
        )
        XCTAssertFalse(calibrated.isAssumed)
        XCTAssertEqual(calibrated.convertLength(4, to: .millimeters), 8, accuracy: 1e-9)
    }

    func testPrimitiveFittingIsDeterministic() {
        let points = (0...20).map { index in SIMD3<Float>(Float(index) * 0.1, 0, 0) }
        let first = EdgePrimitiveFitter.fit(points: points, tolerance: 1e-5)
        for _ in 0..<100 {
            XCTAssertEqual(EdgePrimitiveFitter.fit(points: points, tolerance: 1e-5), first)
        }
    }

    func testExactTopologyPreservesSemanticFaceAndEdgeIdentity() {
        let faceID = "step:7:2:face:129"
        let edgeID = "step:7:2:edge:63"
        let mesh = MeshSnapshot(
            sourceID: source,
            vertices: [
                SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0, 1, 0),
            ],
            triangleIndices: [SIMD3<Int32>(0, 1, 2)],
            topologyHints: TopologyHints(
                faces: [
                    SourceFaceHint(
                        sourceID: faceID,
                        triangles: [.init(0)],
                        descriptor: SurfaceDescriptor(
                            kind: .cylinder,
                            origin: .zero,
                            axis: SIMD3<Float>(0, 0, 1),
                            radius: 0.25
                        )
                    ),
                ],
                edges: [
                    SourceEdgeHint(
                        sourceID: edgeID,
                        points: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0)],
                        incidentFaceIDs: [faceID],
                        descriptor: CurveDescriptor(kind: .circle, radius: 0.25)
                    ),
                ]
            )
        )
        let engine = SelectionEngine(mesh: mesh)
        let resolution = engine.resolve(
            SelectionQuery(triangleID: .init(0), localPoint: SIMD3<Float>(0.3, 0.3, 0))
        )

        guard case .surface(let surface) = resolution.entity else {
            return XCTFail("Expected exact surface")
        }
        XCTAssertEqual(surface.entitySource, .exactTopology)
        XCTAssertEqual(surface.descriptor.kind, .cylinder)
        XCTAssertTrue(surface.id.rawValue.hasSuffix(faceID))
        XCTAssertEqual(engine.exactEdges.count, 1)
        XCTAssertEqual(engine.exactEdges[0].entitySource, .exactTopology)
        XCTAssertEqual(engine.exactEdges[0].descriptor.kind, .circle)
        XCTAssertTrue(engine.exactEdges[0].id.rawValue.hasSuffix(edgeID))
        for _ in 0..<100 {
            XCTAssertEqual(
                engine.resolve(
                    SelectionQuery(triangleID: .init(0), localPoint: SIMD3<Float>(0.3, 0.3, 0))
                ),
                resolution
            )
        }
    }

    func testSelectionPointsDeduplicateVerticesAndAddClosedCurveCenter() {
        let faceID = "step:fixture:face:1"
        let circlePoints: [SIMD3<Float>] = [
            SIMD3<Float>(6, 5, 0),
            SIMD3<Float>(5, 6, 0),
            SIMD3<Float>(4, 5, 0),
            SIMD3<Float>(5, 4, 0),
            SIMD3<Float>(6, 5, 0),
        ]
        let mesh = MeshSnapshot(
            sourceID: source,
            vertices: [
                SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(1, 1, 0), SIMD3<Float>(0, 1, 0),
            ],
            triangleIndices: [SIMD3<Int32>(0, 1, 2), SIMD3<Int32>(0, 2, 3)],
            topologyHints: TopologyHints(
                faces: [SourceFaceHint(sourceID: faceID, triangles: [.init(0), .init(1)])],
                edges: [
                    SourceEdgeHint(
                        sourceID: "step:fixture:edge:1",
                        points: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0)],
                        incidentFaceIDs: [faceID],
                        descriptor: CurveDescriptor(kind: .line)
                    ),
                    SourceEdgeHint(
                        sourceID: "step:fixture:edge:2",
                        points: [SIMD3<Float>(1, 0, 0), SIMD3<Float>(1, 1, 0)],
                        incidentFaceIDs: [faceID],
                        descriptor: CurveDescriptor(kind: .line)
                    ),
                    SourceEdgeHint(
                        sourceID: "step:fixture:edge:3",
                        points: circlePoints,
                        incidentFaceIDs: [faceID],
                        descriptor: CurveDescriptor(kind: .circle)
                    ),
                ]
            )
        )

        let engine = SelectionEngine(mesh: mesh)
        let vertices = engine.points.filter { $0.kind == .vertex }
        let centers = engine.points.filter { $0.kind == .curveCenter }

        XCTAssertEqual(vertices.count, 3)
        XCTAssertEqual(vertices.filter { squaredDistance($0.position, SIMD3<Float>(1, 0, 0)) < 1e-12 }.count, 1)
        XCTAssertEqual(centers.count, 1)
        XCTAssertEqual(centers[0].position.x, 5, accuracy: 1e-5)
        XCTAssertEqual(centers[0].position.y, 5, accuracy: 1e-5)
        XCTAssertTrue(centers[0].id.rawValue.hasSuffix("edge:3:point:center"))
        XCTAssertEqual(engine.points(incidentTo: engine.surface(at: .init(0))).count, 4)

        for _ in 0..<20 {
            XCTAssertEqual(SelectionEngine(mesh: mesh).points, engine.points)
        }
    }

    func testInferredSelectionPointsExposeCornersButNotTessellationVertices() {
        let mesh = MeshSnapshot(
            sourceID: source,
            vertices: [
                SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(1, 1, 0), SIMD3<Float>(0, 1, 0),
                SIMD3<Float>(0.5, 0.5, 0),
            ],
            triangleIndices: [
                SIMD3<Int32>(0, 1, 4), SIMD3<Int32>(1, 2, 4),
                SIMD3<Int32>(2, 3, 4), SIMD3<Int32>(3, 0, 4),
            ]
        )
        let points = SelectionEngine(mesh: mesh).points

        XCTAssertEqual(points.count, 4)
        XCTAssertFalse(points.contains { squaredDistance($0.position, SIMD3<Float>(0.5, 0.5, 0)) < 1e-12 })
    }

    func testSmoothSphereIsRejectedInsteadOfBecomingGenericSurface() {
        let mesh = makeSphere(latitudeSegments: 12, longitudeSegments: 24)
        let engine = SelectionEngine(mesh: mesh)
        let result = engine.resolve(
            SelectionQuery(
                triangleID: .init(mesh.triangles.count / 2),
                localPoint: mesh.vertices[mesh.triangles[mesh.triangles.count / 2].indices[0]]
            )
        )

        XCTAssertEqual(result.kind, .none)
        XCTAssertEqual(result.rejectionCode, .unsupportedSurface)
    }

    func testConeIsRejectedInsteadOfBeingMisclassifiedAsCylinder() {
        let mesh = makeCone(segmentCount: 32)
        let engine = SelectionEngine(mesh: mesh)
        let triangle = mesh.triangles[8]
        let centroid = triangle.indices.reduce(SIMD3<Float>.zero) { $0 + mesh.vertices[$1] } / 3
        let result = engine.resolve(SelectionQuery(triangleID: triangle.id, localPoint: centroid))

        XCTAssertEqual(result.kind, .none)
        XCTAssertEqual(result.rejectionCode, .unsupportedSurface)
    }

    func testDisconnectedCoplanarSupportsRemainSeparate() {
        let mesh = MeshSnapshot(
            sourceID: source,
            vertices: [
                SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(1, 1, 0), SIMD3<Float>(0, 1, 0),
                SIMD3<Float>(3, 0, 0), SIMD3<Float>(4, 0, 0),
                SIMD3<Float>(4, 1, 0), SIMD3<Float>(3, 1, 0),
            ],
            triangleIndices: [
                SIMD3<Int32>(0, 1, 2), SIMD3<Int32>(0, 2, 3),
                SIMD3<Int32>(4, 5, 6), SIMD3<Int32>(4, 6, 7),
            ]
        )
        let engine = SelectionEngine(mesh: mesh)
        let first = engine.surface(at: .init(0))
        let second = engine.surface(at: .init(2))

        XCTAssertEqual(first?.triangles, [.init(0), .init(1)])
        XCTAssertEqual(second?.triangles, [.init(2), .init(3)])
        XCTAssertNotEqual(first?.id, second?.id)
    }

    func testWavyChainIsNotClassifiedAsLineOrArc() {
        let points = (0...20).map { index -> SIMD3<Float> in
            let x = Float(index) * 0.1
            return SIMD3<Float>(x, sin(x * 7) * 0.2, 0)
        }
        guard case .polyline = EdgePrimitiveFitter.fit(points: points, tolerance: 0.001) else {
            return XCTFail("Expected ambiguous wavy chain to remain a polyline")
        }
    }

    private func makeSphere(latitudeSegments: Int, longitudeSegments: Int) -> MeshSnapshot {
        var vertices: [SIMD3<Float>] = []
        for latitude in 0...latitudeSegments {
            let phi = Float(latitude) * .pi / Float(latitudeSegments)
            for longitude in 0..<longitudeSegments {
                let theta = Float(longitude) * 2 * .pi / Float(longitudeSegments)
                vertices.append(
                    SIMD3<Float>(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
                )
            }
        }

        var triangles: [SIMD3<Int32>] = []
        for latitude in 0..<latitudeSegments {
            for longitude in 0..<longitudeSegments {
                let nextLongitude = (longitude + 1) % longitudeSegments
                let current = latitude * longitudeSegments + longitude
                let next = latitude * longitudeSegments + nextLongitude
                let lower = (latitude + 1) * longitudeSegments + longitude
                let lowerNext = (latitude + 1) * longitudeSegments + nextLongitude
                if latitude > 0 {
                    triangles.append(SIMD3<Int32>(Int32(current), Int32(lower), Int32(next)))
                }
                if latitude + 1 < latitudeSegments {
                    triangles.append(SIMD3<Int32>(Int32(next), Int32(lower), Int32(lowerNext)))
                }
            }
        }
        return MeshSnapshot(sourceID: source, vertices: vertices, triangleIndices: triangles)
    }

    private func squaredDistance(_ first: SIMD3<Float>, _ second: SIMD3<Float>) -> Float {
        let delta = first - second
        return delta.x * delta.x + delta.y * delta.y + delta.z * delta.z
    }

    private func makeCone(segmentCount: Int) -> MeshSnapshot {
        var vertices = [SIMD3<Float>(0, 1, 0)]
        for index in 0..<segmentCount {
            let angle = Float(index) * 2 * .pi / Float(segmentCount)
            vertices.append(SIMD3<Float>(cos(angle), -1, sin(angle)))
        }
        var triangles: [SIMD3<Int32>] = []
        for index in 0..<segmentCount {
            let current = Int32(index + 1)
            let next = Int32(((index + 1) % segmentCount) + 1)
            triangles.append(SIMD3<Int32>(0, current, next))
        }
        return MeshSnapshot(sourceID: source, vertices: vertices, triangleIndices: triangles)
    }
}
