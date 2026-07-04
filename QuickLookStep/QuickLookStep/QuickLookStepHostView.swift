import AppKit
import Foundation
import Metal
import Quartz
import SceneKit
import SwiftUI
import UniformTypeIdentifiers

/// Root UI used inside the demo host macOS app. Drop a supported 3D file to view it.
struct QuickLookStepHostView: View {
    let testingPlanPath: String?
    let testingOutputPath: String?
    let autoQuitAfterTesting: Bool
    let initialFilePath: String?
    let edgeProbeEnabled: Bool
    let edgeProbeOutputPath: String?
    let surfaceProbeEnabled: Bool
    let surfaceProbeOutputPath: String?
    let selectionDebugEnabled: Bool
    let selectionDebugOutputPath: String?
    let selectionDebugHUDEnabled: Bool
    let edgeSelectionMode: EdgeSelectionMode
    let edgeOnlyMode: Bool

    @State private var scene: SCNScene? = nil
    @State private var loadError: String? = nil
    @State private var isTargeted: Bool = false
    @State private var didRunAutomatedTests = false
    @State private var hasManualLoad = false
    @State private var automatedTestingTask: Task<Void, Never>? = nil
    @State private var currentModelPathForProbe: String = ""
    @State private var currentLoaderMetadataForProbe: [String: String] = [:]
    @State private var latestSelectionDebugEvent: SelectionDebugEvent? = nil
    @State private var latestMeasurementState: SelectionMeasurementState = .empty
    @State private var measurementPanelHidden = false
    @AppStorage("quicklook.measurement.unit") private var measurementUnitRaw = MeasurementUnit.model.rawValue
    @AppStorage("quicklook.measurement.mmPerModelUnit") private var mmPerModelUnit = 1.0

    init(
        testingPlanPath: String? = nil,
        testingOutputPath: String? = nil,
        autoQuitAfterTesting: Bool = false,
        initialFilePath: String? = nil,
        edgeProbeEnabled: Bool = false,
        edgeProbeOutputPath: String? = nil,
        surfaceProbeEnabled: Bool = false,
        surfaceProbeOutputPath: String? = nil,
        selectionDebugEnabled: Bool = false,
        selectionDebugOutputPath: String? = nil,
        selectionDebugHUDEnabled: Bool = false,
        edgeSelectionMode: EdgeSelectionMode = .fitted,
        edgeOnlyMode: Bool = false
    ) {
        self.testingPlanPath = testingPlanPath
        self.testingOutputPath = testingOutputPath
        self.autoQuitAfterTesting = autoQuitAfterTesting
        self.initialFilePath = initialFilePath
        self.edgeProbeEnabled = edgeProbeEnabled
        self.edgeProbeOutputPath = edgeProbeOutputPath
        self.surfaceProbeEnabled = surfaceProbeEnabled
        self.surfaceProbeOutputPath = surfaceProbeOutputPath
        self.selectionDebugEnabled = selectionDebugEnabled
        self.selectionDebugOutputPath = selectionDebugOutputPath
        self.selectionDebugHUDEnabled = selectionDebugHUDEnabled
        self.edgeSelectionMode = edgeSelectionMode
        self.edgeOnlyMode = edgeOnlyMode
    }

    private var measurementUnitBinding: Binding<MeasurementUnit> {
        Binding(
            get: {
                MeasurementUnit.resolved(from: measurementUnitRaw)
            },
            set: { nextUnit in
                measurementUnitRaw = nextUnit.rawValue
            }
        )
    }

    private var currentMeasurementUnit: MeasurementUnit {
        MeasurementUnit.resolved(from: measurementUnitRaw)
    }

    var body: some View {
        ZStack {
            if let scene {
                SceneKitView(
                    scene: scene,
                    edgeFitSettings: .init(),
                    edgeProbeMode: edgeProbeEnabled,
                    edgeSelectionMode: edgeSelectionMode,
                    edgeProbeOutputDirectory: edgeProbeOutputPath ?? "/tmp/quicklook-edge-probe",
                    surfaceProbeMode: surfaceProbeEnabled,
                    surfaceProbeOutputDirectory: surfaceProbeOutputPath ?? "/tmp/quicklook-surface-probe",
                    edgeProbeModelHint: currentModelPathForProbe,
                    edgeOnlyMode: edgeOnlyMode,
                    selectionDebugMode: selectionDebugEnabled || selectionDebugHUDEnabled,
                    selectionDebugOutputDirectory: selectionDebugOutputPath ?? "/tmp/quicklook-selection-debug",
                    loaderMetadata: currentLoaderMetadataForProbe,
                    onSelectionDebugEvent: { event in
                        latestSelectionDebugEvent = event
                    },
                    onMeasurementStateChanged: { state in
                        latestMeasurementState = state
                        measurementPanelHidden = false
                    },
                    manualSelectionEnabled: testingPlanPath == nil || hasManualLoad
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Drop a supported 3D file")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            if let loadError {
                VStack {
                    Spacer()
                    Text(loadError)
                        .foregroundStyle(.blue)
                        .padding()
                }
            }

            if selectionDebugHUDEnabled {
                selectionDebugHUD
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }

            if !latestMeasurementState.isEmpty, !measurementPanelHidden {
                SelectionMeasurementPanel(
                    state: latestMeasurementState,
                    unit: measurementUnitBinding,
                    mmPerModelUnit: $mmPerModelUnit,
                    onClose: {
                        measurementPanelHidden = true
                    }
                )
                .padding(.top, 18)
                .padding(.trailing, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onDrop(of: [UTType.fileURL, UTType.url, UTType.item], isTargeted: $isTargeted) { providers in
            var collected: [URL] = []
            let group = DispatchGroup()

            func load(_ provider: NSItemProvider, uti: String) {
                group.enter()
                provider.loadItem(forTypeIdentifier: uti, options: nil) { item, _ in
                    defer { group.leave() }
                    if let url = item as? URL {
                        collected.append(url)
                    } else if let path = item as? String {
                        collected.append(URL(fileURLWithPath: path))
                    }
                }
            }

            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    load(provider, uti: UTType.fileURL.identifier)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    load(provider, uti: UTType.url.identifier)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.item.identifier) {
                    load(provider, uti: UTType.item.identifier)
                }
            }

            group.notify(queue: .main) {
                if let first = collected.first {
                    handleManualLoad(first)
                }
            }

            return true
        }
        .background(isTargeted ? Color.accentColor.opacity(0.2) : Color.clear)
        .onOpenURL { url in
            guard url.isFileURL else { return }
            handleManualLoad(url)
        }
        .onAppear {
            runInitialLoadIfNeeded()
            runAutomatedTestsIfNeeded()
        }
        .onDisappear {
            automatedTestingTask?.cancel()
            automatedTestingTask = nil
        }
    }

    @ViewBuilder
    private var selectionDebugHUD: some View {
        if let event = latestSelectionDebugEvent {
            VStack(alignment: .leading, spacing: 4) {
                Text("Selection Debug")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Text("\(event.resolver.finalKind): \(event.resolver.reason)")
                    .lineLimit(2)
                Text("tris \(event.resolver.selectedSurfaceTriangleCount)  edges \(event.resolver.edgeCandidateCount)")
                Text(
                    "seed \(event.resolver.seedTriangle.map(String.init) ?? "-")  near \(formatDebugFloat(event.resolver.nearestFeatureEdgeDistance)) / \(formatDebugFloat(event.resolver.surfacePromotionThreshold))"
                )
                Text("accel \(event.resolver.nearestFeatureEdgeAcceleration ?? "-")")
                Text(
                    "vp \(formatDebugDouble(event.input.normalizedViewportPoint.first)) \(formatDebugDouble(event.input.normalizedViewportPoint.dropFirst().first))  \(event.eventID)"
                )
                if let warning = event.render.clippingWarning {
                    Text(warning)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(.white)
            .padding(10)
            .background(Color.black.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 520, alignment: .leading)
        } else {
            Text("Selection Debug: no clicks yet")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.white)
                .padding(10)
                .background(Color.black.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func runInitialLoadIfNeeded() {
        if let initialFilePath,
           let testFileURL = resolveTestFilePath(initialFilePath) {
            hasManualLoad = true
            didRunAutomatedTests = true
            _ = loadFile(testFileURL)
            return
        }

        if let initialFilePath {
            loadError = "Could not resolve sample file: \(initialFilePath)"
        }
    }

    private func runAutomatedTestsIfNeeded() {
        guard !didRunAutomatedTests, let testingPlanPath, !hasManualLoad else { return }
        didRunAutomatedTests = true

        automatedTestingTask = Task { @MainActor in
            do {
                let plan = try TestingPlan.load(from: URL(fileURLWithPath: testingPlanPath))
                try await runAutomatedTest(plan: plan)
            } catch {
                loadError = "Testing plan failed: \(error.localizedDescription)"
                NSLog("Testing plan failed: %@", error.localizedDescription)
            }
        }
    }

    @MainActor
    private func runAutomatedTest(plan: TestingPlan) async throws {
        let runStart = CFAbsoluteTimeGetCurrent()
        var reports: [TestingRunReport] = []
        let outputDirectory = defaultTestingOutputURL().deletingLastPathComponent()
        let screenshotsDirectory = outputDirectory.appendingPathComponent("screenshots")
        if !FileManager.default.fileExists(atPath: screenshotsDirectory.path) {
            try FileManager.default.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true)
        }

        for scenario in plan.scenarios {
            try Task.checkCancellation()
            if hasManualLoad { return }

            guard let fileURL = resolveTestFilePath(scenario.file) else {
                NSLog("Skipping scenario %@: cannot resolve file %@", scenario.name, scenario.file)
                continue
            }
            NSLog("Automated load scenario=%@ file=%@ ext=%@", scenario.name, fileURL.path, fileURL.pathExtension)

            let (loadElapsedMs, loadMethod, loadMetadata) = loadFile(fileURL)
            let sceneLoadSnapshotPath = snapshotPath(
                for: scenario,
                action: "load",
                actionIndex: -1,
                phase: "load"
            )
            try? await Task.sleep(nanoseconds: 16_000_000)

            guard let scene else {
                NSLog("Could not load scene for %@", scenario.file)
                continue
            }
            let capturedLoadSnapshot = saveSnapshot(scene, for: sceneLoadSnapshotPath)

            var events: [TestingSample] = []
            events.append(cameraSnapshot(
                for: scenario,
                action: "load",
                actionIndex: -1,
                phase: "after-load",
                start: CFAbsoluteTimeGetCurrent(),
                requestedValue: nil,
                requestedDurationMs: nil,
                snapshotPath: capturedLoadSnapshot,
                actionDurationMs: loadElapsedMs,
                selectionDebugEvent: nil,
                selectionDebugExpectationFailures: nil,
                measurementExpectationFailures: nil,
                scene: scene
            ))
            try await Task.sleep(nanoseconds: 120_000_000)

            for (index, action) in scenario.actions.enumerated() {
                let actionStart = CFAbsoluteTimeGetCurrent()
                try Task.checkCancellation()
                if hasManualLoad { return }

                let selectionEvent: SelectionDebugEvent?
                if action.kind == .wait {
                    if let waitMs = action.durationMs {
                        try await Task.sleep(nanoseconds: UInt64(waitMs * 1_000_000))
                    } else {
                        try await Task.sleep(nanoseconds: UInt64(16 * 1_000_000))
                    }
                    selectionEvent = nil
                } else {
                    selectionEvent = applyTestingAction(action, to: scene)
                    if let delayMs = action.durationMs {
                        try await Task.sleep(nanoseconds: UInt64(delayMs * 1_000_000))
                    }
                }

                let snapshotTarget = snapshotPath(
                    for: scenario,
                    action: action.kind.rawValue,
                    actionIndex: index,
                    phase: "post-action"
                )
                let capturedSnapshot = saveSnapshot(scene, for: snapshotTarget)

                let actionElapsedMs = (CFAbsoluteTimeGetCurrent() - actionStart) * 1000
                let expectationFailures = selectionExpectationFailures(
                    event: selectionEvent,
                    expectation: action.expect
                )
                if !expectationFailures.isEmpty {
                    NSLog(
                        "Testing selection expectation failed action=%ld failures=%@",
                        index,
                        expectationFailures.joined(separator: "; ")
                    )
                }
                let measurementSummary = measurementSummaryForTesting()
                let measurementFailures = measurementExpectationFailures(
                    summary: measurementSummary,
                    expectation: action.measurementExpect
                )
                if !measurementFailures.isEmpty {
                    NSLog(
                        "Testing measurement expectation failed action=%ld failures=%@",
                        index,
                        measurementFailures.joined(separator: "; ")
                    )
                }

                events.append(cameraSnapshot(
                    for: scenario,
                    action: action.kind.rawValue,
                    actionIndex: index,
                    phase: "post-action",
                    start: runStart,
                    requestedValue: action.value,
                    requestedDurationMs: action.durationMs,
                    snapshotPath: capturedSnapshot,
                    actionDurationMs: actionElapsedMs,
                    selectionDebugEvent: selectionEvent,
                    selectionDebugExpectationFailures: expectationFailures.isEmpty ? nil : expectationFailures,
                    measurementExpectationFailures: measurementFailures.isEmpty ? nil : measurementFailures,
                    scene: scene
                ))
            }

            reports.append(TestingRunReport(
                scenario: scenario.name,
                file: scenario.file,
                loaderMethod: loadMethod,
                loaderMetadata: loadMetadata,
                loadTimeMs: loadElapsedMs,
                loadSnapshotPath: capturedLoadSnapshot,
                events: events,
                finishedAt: Date()
            ))
        }

        if hasManualLoad || Task.isCancelled { return }

        let totalElapsedMs = (CFAbsoluteTimeGetCurrent() - runStart) * 1000
        let results = TestingResults(
            planPath: testingPlanPath ?? "",
            startedAt: Date(timeIntervalSinceNow: -totalElapsedMs / 1000),
            durationMs: totalElapsedMs,
            reports: reports
        )

        let outputPath = testingOutputPath ?? "testing/results/quicklookstep-test-run.json"
        try writeTestingResults(results, to: outputPath)

        if autoQuitAfterTesting {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func handleManualLoad(_ url: URL) {
        guard SceneBuilder.canLoad(fileURL: url) else {
            loadError = "Unsupported file type: \(url.lastPathComponent)"
            return
        }

        NSLog("Manual model load requested: %@", url.path)
        automatedTestingTask?.cancel()
        hasManualLoad = true
        didRunAutomatedTests = true
        _ = loadFile(url)
    }

    private func resolveTestFilePath(_ path: String) -> URL? {
        if path.hasPrefix("/") {
            let resolved = URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: resolved.path) ? resolved : nil
        }

        if let testingPlanPath {
            let planDirectory = URL(fileURLWithPath: testingPlanPath).deletingLastPathComponent()
            let planRelative = planDirectory.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: planRelative.path) {
                return planRelative
            }
        }

        let base = FileManager.default.currentDirectoryPath
        let candidate = URL(fileURLWithPath: base).appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private func writeTestingResults(_ results: TestingResults, to path: String) throws {
        let outputURL = URL(fileURLWithPath: path)
        let outputDir = outputURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: outputDir.path) {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(results)
        try data.write(to: outputURL, options: .atomic)
        NSLog("Testing report written: %@", outputURL.path)
    }

    @MainActor
    private func applyTestingAction(_ action: TestingAction, to scene: SCNScene) -> SelectionDebugEvent? {
        guard let cameraNode = scene.rootNode.childNode(withName: "camera", recursively: true),
              let camera = cameraNode.camera
        else {
            return nil
        }

        switch action.kind {
        case .rotateX:
            guard let value = action.value else { return nil }
            cameraNode.eulerAngles.x += CGFloat(value * .pi / 180.0)
        case .rotateY:
            guard let value = action.value else { return nil }
            cameraNode.eulerAngles.y += CGFloat(value * .pi / 180.0)
        case .rotateZ:
            guard let value = action.value else { return nil }
            cameraNode.eulerAngles.z += CGFloat(value * .pi / 180.0)
        case .zoom:
            guard let value = action.value else { return nil }
            let target = max(5.0, min(120.0, Double(camera.fieldOfView) + value))
            camera.fieldOfView = CGFloat(target)
        case .selectSurface:
            let result = applyAutomatedSurfaceSelectionOverlay(to: scene)
            NSLog(
                "Testing selectSurface overlay applied=%@ triangles=%ld node=%@",
                result.applied ? "YES" : "NO",
                result.triangleCount,
                result.nodeName ?? "none"
            )
        case .selectAt:
            guard let x = action.x,
                  let y = action.y else {
                NSLog("Testing selectAt skipped: missing x/y")
                return nil
            }
            let request = SelectionDebugSelectAtRequest(
                x: x,
                y: y,
                coordinateSpace: action.coordinateSpace ?? .normalizedViewport,
                expectation: action.expect,
                modifiers: action.modifiers
            )
            let event = SelectionDebugActionDispatcher.shared.performSelectAt?(request)
            NSLog(
                "Testing selectAt x=%.4f y=%.4f space=%@ modifiers=%@ result=%@ path=%@",
                x,
                y,
                request.coordinateSpace.rawValue,
                (action.modifiers ?? []).joined(separator: ","),
                event?.resolver.finalKind ?? "none",
                event?.eventPath ?? "none"
            )
            return event
        case .setCamera:
            if let orientationDegrees = action.orientationDegrees,
               orientationDegrees.count >= 3 {
                cameraNode.eulerAngles = SCNVector3(
                    CGFloat(orientationDegrees[0] * .pi / 180.0),
                    CGFloat(orientationDegrees[1] * .pi / 180.0),
                    CGFloat(orientationDegrees[2] * .pi / 180.0)
                )
            }
            if let position = action.cameraPosition,
               position.count >= 3 {
                cameraNode.position = SCNVector3(
                    CGFloat(position[0]),
                    CGFloat(position[1]),
                    CGFloat(position[2])
                )
            }
            if let fieldOfView = action.fieldOfView {
                camera.fieldOfView = CGFloat(max(5.0, min(120.0, fieldOfView)))
            }
        case .setMeasurementUnit:
            if let unit = action.unit,
               MeasurementUnit(rawValue: unit) != nil {
                measurementUnitRaw = unit
            }
            if let scale = action.mmPerModelUnit,
               scale.isFinite,
               scale > 0 {
                mmPerModelUnit = scale
            }
        case .wait:
            break
        }
        return nil
    }

    @MainActor
    private func cameraSnapshot(
        for scenario: TestingScenario,
        action: String,
        actionIndex: Int,
        phase: String,
        start: CFAbsoluteTime,
        requestedValue: Double?,
        requestedDurationMs: Double?,
        snapshotPath: String?,
        actionDurationMs: Double? = nil,
        selectionDebugEvent: SelectionDebugEvent?,
        selectionDebugExpectationFailures: [String]?,
        measurementExpectationFailures: [String]?,
        scene: SCNScene
    ) -> TestingSample {
        guard
            let cameraNode = scene.rootNode.childNode(withName: "camera", recursively: true),
            let camera = cameraNode.camera
        else {
            return TestingSample(
                scenario: scenario.name,
                file: scenario.file,
                actionIndex: actionIndex,
                action: action,
                phase: phase,
                elapsedMs: (CFAbsoluteTimeGetCurrent() - start) * 1000,
                requestedValue: requestedValue,
                requestedDurationMs: requestedDurationMs,
                orientationDegrees: [0, 0, 0],
                cameraPosition: [0, 0, 0],
                fieldOfView: 0,
                distanceFromOrigin: 0,
                snapshotPath: snapshotPath,
                actionDurationMs: actionDurationMs,
                selectionDebugEventPath: selectionDebugEvent?.eventPath,
                selectionDebugSummary: selectionDebugEvent?.summary,
                selectionDebugExpectationFailures: selectionDebugExpectationFailures,
                measurementSummary: measurementSummaryForTesting(),
                measurementExpectationFailures: measurementExpectationFailures
            )
        }

        return TestingSample(
            scenario: scenario.name,
            file: scenario.file,
            actionIndex: actionIndex,
            action: action,
            phase: phase,
            elapsedMs: (CFAbsoluteTimeGetCurrent() - start) * 1000,
            requestedValue: requestedValue,
            requestedDurationMs: requestedDurationMs,
            orientationDegrees: cameraNode.cameraOrientationDegrees(),
            cameraPosition: cameraNode.positionArray(),
            fieldOfView: Double(camera.fieldOfView),
            distanceFromOrigin: cameraNode.distanceFromOrigin(),
            snapshotPath: snapshotPath,
            actionDurationMs: actionDurationMs,
            selectionDebugEventPath: selectionDebugEvent?.eventPath,
            selectionDebugSummary: selectionDebugEvent?.summary,
            selectionDebugExpectationFailures: selectionDebugExpectationFailures,
            measurementSummary: measurementSummaryForTesting(),
            measurementExpectationFailures: measurementExpectationFailures
        )
    }

    private func selectionExpectationFailures(
        event: SelectionDebugEvent?,
        expectation: SelectionDebugExpectation?
    ) -> [String] {
        guard let expectation else {
            return []
        }
        guard let event else {
            return ["expected selection event but no event was produced"]
        }

        var failures: [String] = []
        if let kind = expectation.kind,
           event.resolver.finalKind != kind {
            failures.append("kind expected \(kind), got \(event.resolver.finalKind)")
        }
        if let count = expectation.surfaceTriangleCount,
           event.resolver.selectedSurfaceTriangleCount != count {
            failures.append("surfaceTriangleCount expected \(count), got \(event.resolver.selectedSurfaceTriangleCount)")
        }
        if let minCount = expectation.minSurfaceTriangleCount,
           event.resolver.selectedSurfaceTriangleCount < minCount {
            failures.append("surfaceTriangleCount expected >= \(minCount), got \(event.resolver.selectedSurfaceTriangleCount)")
        }
        if let maxCount = expectation.maxSurfaceTriangleCount,
           event.resolver.selectedSurfaceTriangleCount > maxCount {
            failures.append("surfaceTriangleCount expected <= \(maxCount), got \(event.resolver.selectedSurfaceTriangleCount)")
        }
        if expectation.mustHaveRejectedAlternative == true,
           event.resolver.rejectedAlternatives.isEmpty {
            failures.append("expected at least one rejected alternative")
        }
        if let forbiddenLabels = expectation.forbiddenLabels,
           !forbiddenLabels.isEmpty {
            let haystack = [
                event.resolver.finalKind,
                event.resolver.selectedEntityID ?? "",
                event.resolver.reason,
            ].joined(separator: " ")
            for label in forbiddenLabels where haystack.contains(label) {
                failures.append("forbidden label matched: \(label)")
            }
        }

        return failures
    }

    private func measurementSummaryForTesting() -> SelectionMeasurementSummary {
        latestMeasurementState.summary.withUnitMode(currentMeasurementUnit)
    }

    private func measurementExpectationFailures(
        summary: SelectionMeasurementSummary,
        expectation: SelectionMeasurementExpectation?
    ) -> [String] {
        guard let expectation else {
            return []
        }

        var failures: [String] = []
        if let kind = expectation.kind,
           summary.kind != kind {
            failures.append("measurement kind expected \(kind), got \(summary.kind)")
        }
        if let entityCount = expectation.entityCount,
           summary.entityCount != entityCount {
            failures.append("measurement entityCount expected \(entityCount), got \(summary.entityCount)")
        }
        if let unitMode = expectation.unitMode,
           summary.unitMode != unitMode {
            failures.append("measurement unitMode expected \(unitMode), got \(summary.unitMode ?? "nil")")
        }

        let totalLength = summary.totalLength ?? summary.length
        if let minTotalLength = expectation.minTotalLength,
           (totalLength ?? -Float.greatestFiniteMagnitude) < minTotalLength {
            failures.append("measurement totalLength expected >= \(minTotalLength), got \(formatFailureFloat(totalLength))")
        }
        if let maxTotalLength = expectation.maxTotalLength,
           (totalLength ?? Float.greatestFiniteMagnitude) > maxTotalLength {
            failures.append("measurement totalLength expected <= \(maxTotalLength), got \(formatFailureFloat(totalLength))")
        }
        if let minMinimumDistance = expectation.minMinimumDistance,
           (summary.minimumDistance ?? -Float.greatestFiniteMagnitude) < minMinimumDistance {
            failures.append("measurement minimumDistance expected >= \(minMinimumDistance), got \(formatFailureFloat(summary.minimumDistance))")
        }
        if let maxMinimumDistance = expectation.maxMinimumDistance,
           (summary.minimumDistance ?? Float.greatestFiniteMagnitude) > maxMinimumDistance {
            failures.append("measurement minimumDistance expected <= \(maxMinimumDistance), got \(formatFailureFloat(summary.minimumDistance))")
        }
        if let minArea = expectation.minArea,
           (summary.area ?? -Float.greatestFiniteMagnitude) < minArea {
            failures.append("measurement area expected >= \(minArea), got \(formatFailureFloat(summary.area))")
        }
        if let maxArea = expectation.maxArea,
           (summary.area ?? Float.greatestFiniteMagnitude) > maxArea {
            failures.append("measurement area expected <= \(maxArea), got \(formatFailureFloat(summary.area))")
        }
        if let minPerimeter = expectation.minPerimeter,
           (summary.perimeter ?? -Float.greatestFiniteMagnitude) < minPerimeter {
            failures.append("measurement perimeter expected >= \(minPerimeter), got \(formatFailureFloat(summary.perimeter))")
        }
        if let maxPerimeter = expectation.maxPerimeter,
           (summary.perimeter ?? Float.greatestFiniteMagnitude) > maxPerimeter {
            failures.append("measurement perimeter expected <= \(maxPerimeter), got \(formatFailureFloat(summary.perimeter))")
        }

        return failures
    }

    private func formatFailureFloat(_ value: Float?) -> String {
        guard let value, value.isFinite else {
            return "nil"
        }
        return String(format: "%.4f", value)
    }

    private func snapshotPath(for scenario: TestingScenario, action: String, actionIndex: Int, phase: String) -> String {
        let outputDirectory = defaultTestingOutputURL().deletingLastPathComponent()
        let scenarioDirectory = outputDirectory
            .appendingPathComponent("screenshots")
            .appendingPathComponent(sanitizedFilenameComponent(scenario.name))
        return scenarioDirectory
            .appendingPathComponent(
                "\(sanitizedFilenameComponent(scenario.file))--\(phase)--\(actionIndex)--\(action).png"
            )
            .path
    }

    private func defaultTestingOutputURL() -> URL {
        let path = testingOutputPath ?? "testing/results/quicklookstep-test.json"
        return URL(fileURLWithPath: path)
    }

    private func saveSnapshot(
        _ scene: SCNScene,
        for path: String,
        imageSize: CGSize = CGSize(width: 1024, height: 768)
    ) -> String? {
        guard let device = MTLCreateSystemDefaultDevice() else {
            NSLog("Could not create MTL device for snapshot capture")
            return nil
        }

        let snapshotURL = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: snapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: true)

        let start = CFAbsoluteTimeGetCurrent()
        let image = renderer.snapshot(
            atTime: 0,
            with: imageSize,
            antialiasingMode: .multisampling4X
        )
        if image.size.width == 0 || image.size.height == 0 {
            NSLog("Scene snapshot has empty size for %@", path)
            return nil
        }
        let snapshotMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        NSLog("Saved scene snapshot in %.2f ms to %@", snapshotMs, snapshotURL.path)

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            NSLog("Could not convert snapshot to PNG: %@", snapshotURL.path)
            return nil
        }

        do {
            try png.write(to: snapshotURL)
            return snapshotURL.path
        } catch {
            NSLog("Failed writing snapshot %@: %@", snapshotURL.path, error.localizedDescription)
            return nil
        }
    }

    private func sanitizedFilenameComponent(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*:|\"<>").union(.newlines)
        return value
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .replacingOccurrences(of: " ", with: "_")
            .prefix(140)
            .description
    }

    private func formatDebugFloat(_ value: Float?) -> String {
        guard let value, value.isFinite else { return "-" }
        return String(format: "%.4f", value)
    }

    private func formatDebugDouble(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "-" }
        return String(format: "%.3f", value)
    }

    // MARK: - Loading & snapshot
    @discardableResult
    private func loadFile(_ url: URL) -> (Double, String, [String: String]) {
        loadError = nil

        let needsSecurity = url.startAccessingSecurityScopedResource()
        defer {
            if needsSecurity { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let start = CFAbsoluteTimeGetCurrent()
            print("Loading file at", url.path)
            currentModelPathForProbe = url.path
            latestSelectionDebugEvent = nil
            latestMeasurementState = .empty
            measurementPanelHidden = false
            let loadResult = try SceneBuilder.sceneWithTrace(for: url)
            currentLoaderMetadataForProbe = loadResult.metadata
            scene = loadResult.scene
            return ((CFAbsoluteTimeGetCurrent() - start) * 1000, loadResult.method, loadResult.metadata)
        } catch {
            scene = nil
            currentLoaderMetadataForProbe = [:]
            latestMeasurementState = .empty
            measurementPanelHidden = false
            loadError = error.localizedDescription
            print("Failed to load model:", error.localizedDescription)
            return (0, "failed:\(error.localizedDescription)", [:])
        }
    }
}
