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

    @State private var scene: SCNScene? = nil
    @State private var loadError: String? = nil
    @State private var isTargeted: Bool = false
    @State private var didRunAutomatedTests = false
    @State private var hasManualLoad = false
    @State private var automatedTestingTask: Task<Void, Never>? = nil

    init(
        testingPlanPath: String? = nil,
        testingOutputPath: String? = nil,
        autoQuitAfterTesting: Bool = false,
        initialFilePath: String? = nil
    ) {
        self.testingPlanPath = testingPlanPath
        self.testingOutputPath = testingOutputPath
        self.autoQuitAfterTesting = autoQuitAfterTesting
        self.initialFilePath = initialFilePath
    }

    var body: some View {
        ZStack {
            if let scene {
                SceneKitView(scene: scene)
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
        }
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
                scene: scene
            ))

            for (index, action) in scenario.actions.enumerated() {
                let actionStart = CFAbsoluteTimeGetCurrent()
                try Task.checkCancellation()
                if hasManualLoad { return }

                if action.kind == .wait {
                    if let waitMs = action.durationMs {
                        try await Task.sleep(nanoseconds: UInt64(waitMs * 1_000_000))
                    } else {
                        try await Task.sleep(nanoseconds: UInt64(16 * 1_000_000))
                    }
                } else {
                    applyTestingAction(action, to: scene)
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
    private func applyTestingAction(_ action: TestingAction, to scene: SCNScene) {
        guard let cameraNode = scene.rootNode.childNode(withName: "camera", recursively: true),
              let camera = cameraNode.camera,
              let value = action.value
        else {
            return
        }

        switch action.kind {
        case .rotateX:
            cameraNode.eulerAngles.x += CGFloat(value * .pi / 180.0)
        case .rotateY:
            cameraNode.eulerAngles.y += CGFloat(value * .pi / 180.0)
        case .rotateZ:
            cameraNode.eulerAngles.z += CGFloat(value * .pi / 180.0)
        case .zoom:
            let target = max(5.0, min(120.0, Double(camera.fieldOfView) + value))
            camera.fieldOfView = CGFloat(target)
        case .wait:
            break
        }
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
                actionDurationMs: actionDurationMs
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
            actionDurationMs: actionDurationMs
        )
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
            let loadResult = try SceneBuilder.sceneWithTrace(for: url)
            scene = loadResult.scene
            return ((CFAbsoluteTimeGetCurrent() - start) * 1000, loadResult.method, loadResult.metadata)
        } catch {
            scene = nil
            loadError = error.localizedDescription
            print("Failed to load model:", error.localizedDescription)
            return (0, "failed:\(error.localizedDescription)", [:])
        }
    }
}
