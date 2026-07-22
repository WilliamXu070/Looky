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

    func testPrimitiveFittingIsDeterministic() {
        let points = (0...20).map { index in SIMD3<Float>(Float(index) * 0.1, 0, 0) }
        let first = EdgePrimitiveFitter.fit(points: points, tolerance: 1e-5)
        for _ in 0..<100 {
            XCTAssertEqual(EdgePrimitiveFitter.fit(points: points, tolerance: 1e-5), first)
        }
    }
}
