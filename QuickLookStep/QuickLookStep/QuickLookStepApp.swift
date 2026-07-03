//
//  QuickLookStepApp.swift
//  QuickLookStep
//
//  Created by John Boiles on 7/14/25.
//

import SwiftUI
import AppKit

private struct LaunchSettings {
    let testingPlanPath: String?
    let testingOutputPath: String?
    let autoQuitAfterTesting: Bool
    let initialFilePath: String?
    let edgeProbeEnabled: Bool
    let edgeProbeOutputPath: String?
    let surfaceProbeEnabled: Bool
    let surfaceProbeOutputPath: String?
    let edgeSelectionMode: EdgeSelectionMode
    let edgeOnlyMode: Bool
}

private func parseEdgeSelectionMode(from value: String) -> EdgeSelectionMode {
    switch value.lowercased() {
    case "connected", "connected-edges", "component":
        return .connected
    default:
        return .fitted
    }
}

private func possibleSupportedPath(from value: String) -> String? {
    guard let url = URL(string: value) ?? URL(fileURLWithPath: value) as URL? else {
        return nil
    }
    guard SceneBuilder.canLoad(fileURL: url) else { return nil }
    return value
}

private func parseLaunchSettings(from arguments: [String]) -> LaunchSettings {
    var idx = 1
    var testPlanPath: String?
    var testOutputPath: String?
    var autoQuitAfterTesting = false
    var initialFilePath: String?
    var edgeProbeEnabled = false
    var edgeProbeOutputPath: String?
    var surfaceProbeEnabled = false
    var surfaceProbeOutputPath: String?
    var edgeSelectionMode: EdgeSelectionMode = .fitted
    var edgeOnlyMode = false

    while idx < arguments.count {
        let arg = arguments[idx]

        if arg.hasPrefix("--test-plan=") {
            testPlanPath = String(arg.dropFirst("--test-plan=".count))
        } else if arg == "--test-plan", idx + 1 < arguments.count {
            idx += 1
            testPlanPath = arguments[idx]
        } else if arg.hasPrefix("--test-output=") {
            testOutputPath = String(arg.dropFirst("--test-output=".count))
        } else if arg == "--test-output", idx + 1 < arguments.count {
            idx += 1
            testOutputPath = arguments[idx]
        } else if arg == "--auto-quit" || arg == "--auto-quit=1" {
            autoQuitAfterTesting = true
        } else if arg == "--edge-probe" || arg == "--edge-probe=1" {
            edgeProbeEnabled = true
        } else if arg == "--edge-probe=0" {
            edgeProbeEnabled = false
        } else if arg == "--surface-probe" || arg == "--surface-probe=1" {
            surfaceProbeEnabled = true
        } else if arg == "--surface-probe=0" {
            surfaceProbeEnabled = false
        } else if arg == "--edge-only" || arg == "--edge-only=1" {
            edgeOnlyMode = true
        } else if arg == "--edge-only=0" {
            edgeOnlyMode = false
        } else if arg.hasPrefix("--selection-mode=") {
            let rawMode = String(arg.dropFirst("--selection-mode=".count))
            edgeSelectionMode = parseEdgeSelectionMode(from: rawMode)
        } else if arg == "--selection-mode", idx + 1 < arguments.count {
            idx += 1
            edgeSelectionMode = parseEdgeSelectionMode(from: arguments[idx])
        } else if arg.hasPrefix("--edge-probe-output=") {
            edgeProbeOutputPath = String(arg.dropFirst("--edge-probe-output=".count))
        } else if arg == "--edge-probe-output", idx + 1 < arguments.count {
            idx += 1
            edgeProbeOutputPath = arguments[idx]
        } else if arg.hasPrefix("--surface-probe-output=") {
            surfaceProbeOutputPath = String(arg.dropFirst("--surface-probe-output=".count))
        } else if arg == "--surface-probe-output", idx + 1 < arguments.count {
            idx += 1
            surfaceProbeOutputPath = arguments[idx]
        } else if arg.hasPrefix("--sample="), let path = possibleSupportedPath(from: String(arg.dropFirst("--sample=".count))) {
            initialFilePath = path
        } else if arg == "--sample", idx + 1 < arguments.count {
            idx += 1
            initialFilePath = possibleSupportedPath(from: arguments[idx])
        } else if arg == "--open", idx + 1 < arguments.count {
            idx += 1
            initialFilePath = possibleSupportedPath(from: arguments[idx])
        } else if let path = possibleSupportedPath(from: arg), !arg.hasPrefix("-") {
            initialFilePath = path
        }

        idx += 1
    }

    return LaunchSettings(
        testingPlanPath: testPlanPath,
        testingOutputPath: testOutputPath,
        autoQuitAfterTesting: autoQuitAfterTesting,
        initialFilePath: initialFilePath,
        edgeProbeEnabled: edgeProbeEnabled,
        edgeProbeOutputPath: edgeProbeOutputPath,
        surfaceProbeEnabled: surfaceProbeEnabled,
        surfaceProbeOutputPath: surfaceProbeOutputPath,
        edgeSelectionMode: edgeSelectionMode,
        edgeOnlyMode: edgeOnlyMode
    )
}

private func resolveLaunchSettings() -> LaunchSettings {
    let env = ProcessInfo.processInfo.environment
    let args = ProcessInfo.processInfo.arguments
    let cli = parseLaunchSettings(from: args)
    let testPlan = env["QLS_TEST_PLAN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let testOutput = env["QLS_TEST_OUTPUT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let testAutoQuit = env["QLS_TEST_AUTO_QUIT"]
    let testFile = env["QLS_TEST_FILE"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let edgeProbe = env["QLS_EDGE_PROBE"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let edgeProbeOutput = env["QLS_EDGE_PROBE_OUTPUT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let surfaceProbe = env["QLS_SURFACE_PROBE"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let surfaceProbeOutput = env["QLS_SURFACE_PROBE_OUTPUT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let envSelectionMode = env["QLS_EDGE_SELECTION_MODE"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let edgeSelectionMode = parseEdgeSelectionMode(from: envSelectionMode ?? "fitted")
    let envEdgeOnly = env["QLS_EDGE_ONLY"]?.trimmingCharacters(in: .whitespacesAndNewlines)

    return LaunchSettings(
        testingPlanPath: (testPlan == "") ? nil : (testPlan ?? cli.testingPlanPath),
        testingOutputPath: (testOutput == "") ? nil : (testOutput ?? cli.testingOutputPath),
        autoQuitAfterTesting: (testAutoQuit == "1") || cli.autoQuitAfterTesting,
        initialFilePath: (testFile == "") ? nil : (testFile ?? cli.initialFilePath),
        edgeProbeEnabled: (edgeProbe == "1") || cli.edgeProbeEnabled,
        edgeProbeOutputPath: (edgeProbeOutput == "") ? nil : (edgeProbeOutput ?? cli.edgeProbeOutputPath),
        surfaceProbeEnabled: (surfaceProbe == "1") || cli.surfaceProbeEnabled,
        surfaceProbeOutputPath: (surfaceProbeOutput == "") ? nil : (surfaceProbeOutput ?? cli.surfaceProbeOutputPath),
        edgeSelectionMode: envSelectionMode == nil ? cli.edgeSelectionMode : edgeSelectionMode,
        edgeOnlyMode: (envEdgeOnly == "1") || cli.edgeOnlyMode
    )
}

private func appendQuickLookStepLifecycleEvent(_ event: String) {
    let path = URL(fileURLWithPath: "/tmp/quicklookstep-lifecycle.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(event)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path.path),
               let handle = try? FileHandle(forWritingTo: path) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                _ = try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: path)
            }
        }
}

private func windowStateDescription(_ window: NSWindow?) -> String {
    guard let window else {
        return "window=nil"
    }
    return "visible=\(window.isVisible) key=\(window.isKeyWindow) main=\(window.isMainWindow) miniaturized=\(window.isMiniaturized) frame=\(NSStringFromRect(window.frame))"
}

@main
struct QuickLookStepApp: App {
    @NSApplicationDelegateAdaptor(QuickLookAppDelegate.self) private var appDelegate

    init() {
        appendQuickLookStepLifecycleEvent("app-init")
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

private final class QuickLookAppDelegate: NSObject, NSApplicationDelegate {
    private let defaultWindowSize = NSSize(width: 1200, height: 800)
    private let minimumWindowSize = NSSize(width: 900, height: 600)
    private var hostWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        appendQuickLookStepLifecycleEvent("app-delegate-did-finish")
        NSLog("QuickLookStep app launched - windowed mode activated")

        guard hostWindow == nil else {
            return
        }

        DispatchQueue.main.async {
            self.createAndShowWindow()
        }
    }

    private func createAndShowWindow() {
        guard hostWindow == nil else {
            return
        }

        let settings = resolveLaunchSettings()
        let hostView = QuickLookStepHostView(
            testingPlanPath: settings.testingPlanPath,
            testingOutputPath: settings.testingOutputPath,
            autoQuitAfterTesting: settings.autoQuitAfterTesting,
            initialFilePath: settings.initialFilePath,
            edgeProbeEnabled: settings.edgeProbeEnabled,
            edgeProbeOutputPath: settings.edgeProbeOutputPath,
            surfaceProbeEnabled: settings.surfaceProbeEnabled,
            surfaceProbeOutputPath: settings.surfaceProbeOutputPath,
            edgeSelectionMode: settings.edgeSelectionMode,
            edgeOnlyMode: settings.edgeOnlyMode
        )
        let hostController = NSHostingController(rootView: hostView)

        let style: NSWindow.StyleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable
        ]
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultWindowSize),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        hostController.view.frame = NSRect(origin: .zero, size: defaultWindowSize)
        window.contentViewController = hostController
        window.title = "QuickLookStep"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed, .fullScreenPrimary]
        window.minSize = minimumWindowSize
        window.contentMinSize = minimumWindowSize
        window.setContentSize(defaultWindowSize)
        window.center()
        hostWindow = window
        bringHostWindowToFront(reason: "create")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.bringHostWindowToFront(reason: "post-create")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.bringHostWindowToFront(reason: "post-launch")
        }
    }

    private func bringHostWindowToFront(reason: String) {
        guard let hostWindow else {
            appendQuickLookStepLifecycleEvent("bring-front-\(reason) window=nil")
            return
        }

        if hostWindow.isMiniaturized {
            hostWindow.deminiaturize(nil)
        }

        restoreHostWindowSizeIfNeeded(hostWindow)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApplication.shared.activate(ignoringOtherApps: true)
        hostWindow.makeKeyAndOrderFront(nil)
        hostWindow.orderFrontRegardless()
        appendQuickLookStepLifecycleEvent("bring-front-\(reason) \(windowStateDescription(hostWindow))")
    }

    private func restoreHostWindowSizeIfNeeded(_ window: NSWindow) {
        guard window.frame.width < minimumWindowSize.width || window.frame.height < minimumWindowSize.height else {
            return
        }

        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
        let origin = NSPoint(
            x: visibleFrame.midX - defaultWindowSize.width / 2,
            y: visibleFrame.midY - defaultWindowSize.height / 2
        )
        window.setFrame(NSRect(origin: origin, size: defaultWindowSize), display: true)
    }
}
