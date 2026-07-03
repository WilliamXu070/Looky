import Foundation
import SceneKit

struct TestingPlan: Codable {
    let scenarios: [TestingScenario]

    static func load(from url: URL) throws -> TestingPlan {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(TestingPlan.self, from: data)
    }
}

struct TestingScenario: Codable {
    let name: String
    let file: String
    let actions: [TestingAction]
}

struct TestingAction: Codable {
    /// Action to apply to the active camera.
    /// - rotateX/rotateY/rotateZ: delta in degrees
    /// - zoom: delta FOV in degrees
    /// - wait: wait duration in milliseconds
    /// - selectSurface: test-only surface overlay selection on the loaded scene
    /// - selectAt: click the same selection path used by mouse input
    /// - setCamera: restore an exact camera pose for replay
    let kind: TestingActionKind
    let value: Double?
    let durationMs: Double?
    let x: Double?
    let y: Double?
    let coordinateSpace: SelectionDebugCoordinateSpace?
    let expect: SelectionDebugExpectation?
    let orientationDegrees: [Double]?
    let cameraPosition: [Double]?
    let fieldOfView: Double?

    init(
        kind: TestingActionKind,
        value: Double? = nil,
        durationMs: Double? = nil,
        x: Double? = nil,
        y: Double? = nil,
        coordinateSpace: SelectionDebugCoordinateSpace? = nil,
        expect: SelectionDebugExpectation? = nil,
        orientationDegrees: [Double]? = nil,
        cameraPosition: [Double]? = nil,
        fieldOfView: Double? = nil
    ) {
        self.kind = kind
        self.value = value
        self.durationMs = durationMs
        self.x = x
        self.y = y
        self.coordinateSpace = coordinateSpace
        self.expect = expect
        self.orientationDegrees = orientationDegrees
        self.cameraPosition = cameraPosition
        self.fieldOfView = fieldOfView
    }
}

enum TestingActionKind: String, Codable {
    case rotateX
    case rotateY
    case rotateZ
    case zoom
    case wait
    case selectSurface
    case selectAt
    case setCamera
}

struct TestingRunReport: Codable {
    let scenario: String
    let file: String
    let loaderMethod: String?
    let loaderMetadata: [String: String]?
    let loadTimeMs: Double
    let loadSnapshotPath: String?
    let events: [TestingSample]
    let finishedAt: Date
}

struct TestingSample: Codable {
    let scenario: String
    let file: String
    let actionIndex: Int
    let action: String
    let phase: String
    let elapsedMs: Double
    let requestedValue: Double?
    let requestedDurationMs: Double?
    let orientationDegrees: [Double]
    let cameraPosition: [Double]
    let fieldOfView: Double
    let distanceFromOrigin: Double
    let snapshotPath: String?
    let actionDurationMs: Double?
    let selectionDebugEventPath: String?
    let selectionDebugSummary: SelectionDebugEventSummary?
    let selectionDebugExpectationFailures: [String]?
}

extension SCNNode {
    func cameraOrientationDegrees() -> [Double] {
        let eulers = eulerAngles
        return [
            Double(eulers.x * 180.0 / .pi),
            Double(eulers.y * 180.0 / .pi),
            Double(eulers.z * 180.0 / .pi),
        ]
    }

    func positionArray() -> [Double] {
        let p = position
        return [Double(p.x), Double(p.y), Double(p.z)]
    }

    func distanceFromOrigin() -> Double {
        let p = position
        return Double(sqrt((p.x * p.x) + (p.y * p.y) + (p.z * p.z)))
    }
}

struct TestingResults: Codable {
    let planPath: String
    let startedAt: Date
    let durationMs: Double
    let reports: [TestingRunReport]
}
