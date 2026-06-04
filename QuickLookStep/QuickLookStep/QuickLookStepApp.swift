//
//  QuickLookStepApp.swift
//  QuickLookStep
//
//  Created by John Boiles on 7/14/25.
//

import SwiftUI

@main
struct QuickLookStepApp: App {
    private func possibleSupportedPath(from value: String) -> String? {
        guard let url = URL(string: value) ?? URL(fileURLWithPath: value) as URL? else {
            return nil
        }
        guard SceneBuilder.canLoad(fileURL: url) else { return nil }
        return value
    }

    private struct LaunchSettings {
        let testingPlanPath: String?
        let testingOutputPath: String?
        let autoQuitAfterTesting: Bool
        let initialFilePath: String?
    }

    private func parseLaunchSettings(from arguments: [String]) -> LaunchSettings {
        var idx = 1
        var testPlanPath: String?
        var testOutputPath: String?
        var autoQuitAfterTesting = false
        var initialFilePath: String?

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
            initialFilePath: initialFilePath
        )
    }

    var body: some Scene {
        WindowGroup {
            let env = ProcessInfo.processInfo.environment
            let args = ProcessInfo.processInfo.arguments
            let cli = parseLaunchSettings(from: args)
            let testPlan = env["QLS_TEST_PLAN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let testOutput = env["QLS_TEST_OUTPUT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let testAutoQuit = env["QLS_TEST_AUTO_QUIT"]
            let testFile = env["QLS_TEST_FILE"]?.trimmingCharacters(in: .whitespacesAndNewlines)

            QuickLookStepHostView(
                testingPlanPath: (testPlan == "") ? nil : (testPlan ?? cli.testingPlanPath),
                testingOutputPath: (testOutput == "") ? nil : (testOutput ?? cli.testingOutputPath),
                autoQuitAfterTesting: (testAutoQuit == "1") || cli.autoQuitAfterTesting,
                initialFilePath: (testFile == "") ? nil : (testFile ?? cli.initialFilePath)
            )
        }
    }
}
