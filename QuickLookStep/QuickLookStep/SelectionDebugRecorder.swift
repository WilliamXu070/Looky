import AppKit
import Foundation

final class SelectionDebugRecorder {
    static let shared = SelectionDebugRecorder()

    private let queue = DispatchQueue(label: "com.quicklookstep.selection-debug-recorder", qos: .utility)

    private init() {}

    func preparedEvent(
        _ input: SelectionDebugEvent,
        outputDirectory: String,
        hasBeforeImage: Bool,
        hasAfterImage: Bool
    ) -> SelectionDebugEvent {
        var event = input
        let directory = URL(fileURLWithPath: outputDirectory)
        let screenshots = directory.appendingPathComponent("screenshots")
        event.eventPath = directory.appendingPathComponent("\(event.eventID).json").path
        event.sessionPath = directory.appendingPathComponent("selection-debug-session.json").path
        if hasBeforeImage {
            event.beforeScreenshotPath = screenshots.appendingPathComponent("\(event.eventID)-before.png").path
        }
        if hasAfterImage {
            event.afterScreenshotPath = screenshots.appendingPathComponent("\(event.eventID)-after.png").path
        }
        return event
    }

    func record(
        event: SelectionDebugEvent,
        beforeImage: NSImage?,
        afterImage: NSImage?,
        outputDirectory: String
    ) {
        queue.async {
            do {
                let result = try SelectionDebugSessionWriter(outputDirectory: outputDirectory).write(
                    event: event,
                    beforeImage: beforeImage,
                    afterImage: afterImage
                )
                NSLog(
                    "Selection debug event saved: %@ kind=%@ reason=%@",
                    result.eventPath,
                    result.event.resolver.finalKind,
                    result.event.resolver.reason
                )
            } catch {
                NSLog("Failed writing selection debug event to %@: %@", outputDirectory, error.localizedDescription)
            }
        }
    }
}
