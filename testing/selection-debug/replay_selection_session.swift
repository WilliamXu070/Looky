#!/usr/bin/env swift

import Foundation

struct SelectionDebugSession: Codable {
    let events: [SelectionDebugEvent]
}

struct SelectionDebugEvent: Codable {
    let eventID: String
    let modelHint: String
    let camera: SelectionDebugCameraState
    let input: SelectionDebugInput
    let resolver: SelectionDebugResolver
    let expectation: SelectionDebugExpectation?
    let expectedKind: String?
    let eventPath: String?
}

struct SelectionDebugCameraState: Codable {
    let orientationDegrees: [Double]
    let position: [Double]
    let fieldOfView: Double
}

struct SelectionDebugInput: Codable {
    let normalizedViewportPoint: [Double]
}

struct SelectionDebugResolver: Codable {
    let finalKind: String
    let selectedEntityID: String?
    let selectedSurfaceTriangleCount: Int
    let edgeCandidateCount: Int
    let rejectedAlternatives: [SelectionDebugRejectedAlternative]
}

struct SelectionDebugRejectedAlternative: Codable {
    let kind: String
}

struct SelectionDebugExpectation: Codable {
    let kind: String?
    let surfaceTriangleCount: Int?
    let minSurfaceTriangleCount: Int?
    let maxSurfaceTriangleCount: Int?
    let forbiddenLabels: [String]?
    let mustHaveRejectedAlternative: Bool?

    static func baseline(from event: SelectionDebugEvent) -> SelectionDebugExpectation {
        SelectionDebugExpectation(
            kind: event.expectedKind ?? event.resolver.finalKind,
            surfaceTriangleCount: event.resolver.finalKind == "surface" ? event.resolver.selectedSurfaceTriangleCount : nil,
            minSurfaceTriangleCount: nil,
            maxSurfaceTriangleCount: nil,
            forbiddenLabels: nil,
            mustHaveRejectedAlternative: nil
        )
    }
}

struct TestingPlan: Codable {
    let scenarios: [TestingScenario]
}

struct TestingScenario: Codable {
    let name: String
    let file: String
    let actions: [TestingAction]
}

struct TestingAction: Codable {
    let kind: String
    let durationMs: Double?
    let x: Double?
    let y: Double?
    let coordinateSpace: String?
    let expect: SelectionDebugExpectation?
    let orientationDegrees: [Double]?
    let cameraPosition: [Double]?
    let fieldOfView: Double?

    static func setCamera(_ camera: SelectionDebugCameraState) -> TestingAction {
        TestingAction(
            kind: "setCamera",
            durationMs: 40,
            x: nil,
            y: nil,
            coordinateSpace: nil,
            expect: nil,
            orientationDegrees: camera.orientationDegrees,
            cameraPosition: camera.position,
            fieldOfView: camera.fieldOfView
        )
    }

    static func selectAt(_ event: SelectionDebugEvent, expectation: SelectionDebugExpectation) -> TestingAction {
        TestingAction(
            kind: "selectAt",
            durationMs: 80,
            x: event.input.normalizedViewportPoint.first,
            y: event.input.normalizedViewportPoint.dropFirst().first,
            coordinateSpace: "normalizedViewport",
            expect: expectation,
            orientationDegrees: nil,
            cameraPosition: nil,
            fieldOfView: nil
        )
    }
}

struct TestingResults: Codable {
    let reports: [TestingRunReport]
}

struct TestingRunReport: Codable {
    let events: [TestingSample]
}

struct TestingSample: Codable {
    let action: String
    let selectionDebugSummary: SelectionDebugEventSummary?
}

struct SelectionDebugEventSummary: Codable {
    let eventID: String
    let kind: String
    let surfaceTriangleCount: Int
    let edgeCandidateCount: Int
    let eventPath: String?
}

struct ReplayEventReport: Codable {
    let eventID: String
    let sourceEventPath: String?
    let mode: String
    let actualKind: String
    let actualSurfaceTriangleCount: Int
    let expectation: SelectionDebugExpectation
    let passed: Bool
    let failures: [String]
}

struct ReplayReport: Codable {
    let sessionPath: String
    let generatedPlanPath: String
    let replayRunOutputPath: String?
    let passed: Int
    let failed: Int
    let events: [ReplayEventReport]
}

func usage() -> Never {
    fputs("usage: swift testing/selection-debug/replay_selection_session.swift <session.json> <output.json> [--no-run]\n", stderr)
    exit(2)
}

let args = CommandLine.arguments
guard args.count >= 3 else { usage() }
let sessionPath = args[1]
let outputPath = args[2]
let noRun = args.contains("--no-run")

let sessionURL = URL(fileURLWithPath: sessionPath)
let outputURL = URL(fileURLWithPath: outputPath)
let outputDirectory = outputURL.deletingLastPathComponent()
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

guard FileManager.default.fileExists(atPath: sessionURL.path) else {
    fputs("selection debug session not found: \(sessionURL.path)\n", stderr)
    exit(1)
}

let decoder = JSONDecoder()
let session = try decoder.decode(
    SelectionDebugSession.self,
    from: Data(contentsOf: sessionURL)
)

let planURL = outputDirectory
    .appendingPathComponent(outputURL.deletingPathExtension().lastPathComponent + "-plan.json")
let runOutputURL = outputDirectory
    .appendingPathComponent(outputURL.deletingPathExtension().lastPathComponent + "-run.json")

let scenarioEvents = session.events.enumerated().map { index, event -> TestingScenario in
    let expectation = event.expectation ?? .baseline(from: event)
    return TestingScenario(
        name: "selection-debug-\(index)-\(event.eventID)",
        file: event.modelHint,
        actions: [
            .setCamera(event.camera),
            .selectAt(event, expectation: expectation),
        ]
    )
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(TestingPlan(scenarios: scenarioEvents)).write(to: planURL, options: .atomic)

func compare(
    eventID: String,
    sourceEventPath: String?,
    mode: String,
    actualKind: String,
    actualSurfaceTriangleCount: Int,
    actualRejectedCount: Int,
    actualEntity: String?,
    expectation: SelectionDebugExpectation
) -> ReplayEventReport {
    var failures: [String] = []

    if let kind = expectation.kind, actualKind != kind {
        failures.append("kind expected \(kind), got \(actualKind)")
    }
    if let surfaceTriangleCount = expectation.surfaceTriangleCount,
       actualSurfaceTriangleCount != surfaceTriangleCount {
        failures.append("surfaceTriangleCount expected \(surfaceTriangleCount), got \(actualSurfaceTriangleCount)")
    }
    if let minSurfaceTriangleCount = expectation.minSurfaceTriangleCount,
       actualSurfaceTriangleCount < minSurfaceTriangleCount {
        failures.append("surfaceTriangleCount expected >= \(minSurfaceTriangleCount), got \(actualSurfaceTriangleCount)")
    }
    if let maxSurfaceTriangleCount = expectation.maxSurfaceTriangleCount,
       actualSurfaceTriangleCount > maxSurfaceTriangleCount {
        failures.append("surfaceTriangleCount expected <= \(maxSurfaceTriangleCount), got \(actualSurfaceTriangleCount)")
    }
    if expectation.mustHaveRejectedAlternative == true, actualRejectedCount == 0 {
        failures.append("expected at least one rejected alternative")
    }
    if let forbiddenLabels = expectation.forbiddenLabels, !forbiddenLabels.isEmpty {
        let haystack = [actualKind, actualEntity ?? ""].joined(separator: " ")
        for label in forbiddenLabels where haystack.contains(label) {
            failures.append("forbidden label matched: \(label)")
        }
    }

    return ReplayEventReport(
        eventID: eventID,
        sourceEventPath: sourceEventPath,
        mode: mode,
        actualKind: actualKind,
        actualSurfaceTriangleCount: actualSurfaceTriangleCount,
        expectation: expectation,
        passed: failures.isEmpty,
        failures: failures
    )
}

var eventReports: [ReplayEventReport]
var replayRunOutputPath: String?

let runTestingPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("testing/scripts/run-testing.sh")
let appBinaryPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("build/Build/Products/Debug/QuickLookStep.app/Contents/MacOS/QuickLookStep")

if !noRun,
   FileManager.default.isExecutableFile(atPath: runTestingPath.path),
   FileManager.default.isExecutableFile(atPath: appBinaryPath.path) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [runTestingPath.path, planURL.path, runOutputURL.path]
    var environment = ProcessInfo.processInfo.environment
    environment["QLS_FORCE_DIRECT_LAUNCH"] = environment["QLS_FORCE_DIRECT_LAUNCH"] ?? "1"
    environment["QLS_SELECTION_DEBUG"] = "1"
    environment["QLS_SELECTION_DEBUG_OUTPUT"] = outputDirectory
        .appendingPathComponent("selection-debug-replay-events")
        .path
    process.environment = environment
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "SelectionDebugReplay",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "run-testing.sh failed with status \(process.terminationStatus)"]
        )
    }
    replayRunOutputPath = runOutputURL.path

    let runResults = try decoder.decode(
        TestingResults.self,
        from: Data(contentsOf: runOutputURL)
    )
    let actualSummaries = runResults.reports
        .flatMap(\.events)
        .filter { $0.action == "selectAt" }
        .compactMap(\.selectionDebugSummary)

    eventReports = zip(session.events, actualSummaries).map { event, summary in
        let replayEvent = summary.eventPath.flatMap { path -> SelectionDebugEvent? in
            try? decoder.decode(
                SelectionDebugEvent.self,
                from: Data(contentsOf: URL(fileURLWithPath: path))
            )
        }
        return compare(
            eventID: event.eventID,
            sourceEventPath: event.eventPath,
            mode: "live-replay",
            actualKind: summary.kind,
            actualSurfaceTriangleCount: summary.surfaceTriangleCount,
            actualRejectedCount: replayEvent?.resolver.rejectedAlternatives.count ?? 0,
            actualEntity: replayEvent?.resolver.selectedEntityID,
            expectation: event.expectation ?? .baseline(from: event)
        )
    }

    if actualSummaries.count != session.events.count {
        let missing = session.events.dropFirst(actualSummaries.count).map { event in
            ReplayEventReport(
                eventID: event.eventID,
                sourceEventPath: event.eventPath,
                mode: "live-replay",
                actualKind: "missing",
                actualSurfaceTriangleCount: 0,
                expectation: event.expectation ?? .baseline(from: event),
                passed: false,
                failures: ["missing selectAt replay summary"]
            )
        }
        eventReports.append(contentsOf: missing)
    }
} else {
    eventReports = session.events.map { event in
        compare(
            eventID: event.eventID,
            sourceEventPath: event.eventPath,
            mode: noRun ? "captured-session-only" : "captured-session-only-app-not-built",
            actualKind: event.resolver.finalKind,
            actualSurfaceTriangleCount: event.resolver.selectedSurfaceTriangleCount,
            actualRejectedCount: event.resolver.rejectedAlternatives.count,
            actualEntity: event.resolver.selectedEntityID,
            expectation: event.expectation ?? .baseline(from: event)
        )
    }
}

let passed = eventReports.filter(\.passed).count
let failed = eventReports.count - passed
let report = ReplayReport(
    sessionPath: sessionURL.path,
    generatedPlanPath: planURL.path,
    replayRunOutputPath: replayRunOutputPath,
    passed: passed,
    failed: failed,
    events: eventReports
)
try encoder.encode(report).write(to: outputURL, options: .atomic)
print("Wrote replay report: \(outputURL.path)")
print("Wrote generated plan: \(planURL.path)")
if let replayRunOutputPath {
    print("Wrote replay run output: \(replayRunOutputPath)")
}
if failed > 0 {
    exit(1)
}
