import AppKit
import Foundation

enum SelectionDebugCoordinateSpace: String, Codable {
    case normalizedViewport
    case viewport
}

struct SelectionDebugExpectation: Codable {
    let kind: String?
    let source: String?
    let sourceEntityID: String?
    let surfaceType: String?
    let curveType: String?
    let reasonCode: String?
    let maxProjectedEdgeDistancePoints: Float?
    let surfaceTriangleCount: Int?
    let minSurfaceTriangleCount: Int?
    let maxSurfaceTriangleCount: Int?
    let forbiddenLabels: [String]?
    let mustHaveRejectedAlternative: Bool?
}

struct SelectionDebugSelectAtRequest {
    let x: Double
    let y: Double
    let coordinateSpace: SelectionDebugCoordinateSpace
    let expectation: SelectionDebugExpectation?
    let modifiers: [String]?
}

struct SelectionDebugHoverAtRequest {
    let x: Double
    let y: Double
    let coordinateSpace: SelectionDebugCoordinateSpace
}

struct SelectionDebugSession: Codable {
    let schemaVersion: Int
    let producedAt: String
    let updatedAt: String
    let outputDirectory: String
    let eventCount: Int
    let events: [SelectionDebugEvent]
}

struct SelectionDebugEvent: Codable {
    var eventID: String
    let producedAt: String
    let modelHint: String
    let modelHash: String?
    let loaderMetadata: [String: String]?
    let camera: SelectionDebugCameraState
    let input: SelectionDebugInput
    let hitTest: SelectionDebugHitTest
    let resolver: SelectionDebugResolver
    let render: SelectionDebugRenderValidation
    var expectation: SelectionDebugExpectation?
    var expectedKind: String?
    var expectedSurfaceLabel: String?
    var note: String?
    var eventPath: String?
    var sessionPath: String?
    var beforeScreenshotPath: String?
    var afterScreenshotPath: String?

    var summary: SelectionDebugEventSummary {
        SelectionDebugEventSummary(
            eventID: eventID,
            kind: resolver.finalKind,
            selectedEntityID: resolver.selectedEntityID,
            reason: resolver.reason,
            surfaceTriangleCount: resolver.selectedSurfaceTriangleCount,
            edgeCandidateCount: resolver.edgeCandidateCount,
            nearestFeatureEdgeDistance: resolver.nearestFeatureEdgeDistance,
            nearestFeatureEdgeAcceleration: resolver.nearestFeatureEdgeAcceleration,
            eventPath: eventPath,
            beforeScreenshotPath: beforeScreenshotPath,
            afterScreenshotPath: afterScreenshotPath
        )
    }
}

struct SelectionDebugEventSummary: Codable {
    let eventID: String
    let kind: String
    let selectedEntityID: String?
    let reason: String
    let surfaceTriangleCount: Int
    let edgeCandidateCount: Int
    let nearestFeatureEdgeDistance: Float?
    let nearestFeatureEdgeAcceleration: String?
    let eventPath: String?
    let beforeScreenshotPath: String?
    let afterScreenshotPath: String?
}

struct SelectionDebugCameraState: Codable {
    let orientationDegrees: [Double]
    let position: [Double]
    let fieldOfView: Double
    let distanceFromOrigin: Double
}

struct SelectionDebugInput: Codable {
    let windowPoint: [Double]?
    let viewportPoint: [Double]
    let normalizedViewportPoint: [Double]
    let modifierFlags: [String]
    let selectionMode: String
    let edgeOnlyMode: Bool
}

struct SelectionDebugHitTest: Codable {
    let viewSize: [Float]
    let sceneNodeName: String?
    let hitLocalPoint: [Float]?
    let hitWorldPoint: [Float]?
    let hitLocalNormal: [Float]?
    let hitWorldNormal: [Float]?
    let seedTriangle: Int?
    let hitDistance: Float?
    let noHitReason: String?
}

struct SelectionDebugResolver: Codable {
    let finalKind: String
    let selectedEntityID: String?
    let source: String?
    let sourceEntityID: String?
    let surfaceType: String?
    let curveType: String?
    let fitRMS: Float?
    let fitMaximumResidual: Float?
    let projectedEdgeDistancePoints: Float?
    let candidateRank: Int?
    let rejectionCode: String?
    let selectedSurfaceTriangleCount: Int
    let selectedEdgePointCount: Int
    let seedTriangle: Int?
    let nearestFeatureEdgeDistance: Float?
    let nearestFeatureEdgeAcceleration: String?
    let surfacePromotionThreshold: Float?
    let edgeCandidateCount: Int
    let bestEdgeDistance: Float?
    let bestEdgeIsFeature: Bool?
    let bestEdgeCurrentPointIsEdge: Bool?
    let bestEdgeChainKind: String?
    let rejectedAlternatives: [SelectionDebugRejectedAlternative]
    let elapsedMs: Double
    let reason: String
}

struct SelectionDebugRejectedAlternative: Codable {
    let kind: String
    let reason: String
    let distance: Float?
    let threshold: Float?
    let triangleCount: Int
    let chainKind: String?
}

struct SelectionDebugRenderValidation: Codable {
    let selectedTriangleCount: Int
    let selectedEdgePointCount: Int
    let localBoundsMin: [Float]?
    let localBoundsMax: [Float]?
    let materialMode: String
    let readsDepth: Bool
    let writesDepth: Bool
    let clippingWarning: String?
}

struct SelectionDebugWriteResult {
    let event: SelectionDebugEvent
    let eventPath: String
    let sessionPath: String
    let latestPath: String
}

final class SelectionDebugSessionWriter {
    let outputDirectory: String

    init(outputDirectory: String) {
        self.outputDirectory = outputDirectory
    }

    func write(
        event inputEvent: SelectionDebugEvent,
        beforeImage: NSImage?,
        afterImage: NSImage?
    ) throws -> SelectionDebugWriteResult {
        let directory = URL(fileURLWithPath: outputDirectory)
        let screenshotsDirectory = directory.appendingPathComponent("screenshots")
        try FileManager.default.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true)

        var event = inputEvent
        if let beforeImage {
            let path = screenshotsDirectory.appendingPathComponent("\(event.eventID)-before.png").path
            try Self.writePNG(beforeImage, to: path)
            event.beforeScreenshotPath = path
        }
        if let afterImage {
            let path = screenshotsDirectory.appendingPathComponent("\(event.eventID)-after.png").path
            try Self.writePNG(afterImage, to: path)
            event.afterScreenshotPath = path
        }

        let eventPath = directory.appendingPathComponent("\(event.eventID).json").path
        let sessionPath = directory.appendingPathComponent("selection-debug-session.json").path
        let latestPath = directory.appendingPathComponent("selection-debug-latest.json").path
        event.eventPath = eventPath
        event.sessionPath = sessionPath

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(event).write(to: URL(fileURLWithPath: eventPath), options: .atomic)
        try encoder.encode(event).write(to: URL(fileURLWithPath: latestPath), options: .atomic)

        let now = ISO8601DateFormatter().string(from: Date())
        let existingEvents: [SelectionDebugEvent]
        let producedAt: String
        if let data = try? Data(contentsOf: URL(fileURLWithPath: sessionPath)),
           let previous = try? JSONDecoder().decode(SelectionDebugSession.self, from: data) {
            existingEvents = previous.events
            producedAt = previous.producedAt
        } else {
            existingEvents = []
            producedAt = now
        }

        let session = SelectionDebugSession(
            schemaVersion: 2,
            producedAt: producedAt,
            updatedAt: now,
            outputDirectory: outputDirectory,
            eventCount: existingEvents.count + 1,
            events: existingEvents + [event]
        )
        try encoder.encode(session).write(to: URL(fileURLWithPath: sessionPath), options: .atomic)

        return SelectionDebugWriteResult(
            event: event,
            eventPath: eventPath,
            sessionPath: sessionPath,
            latestPath: latestPath
        )
    }

    private static func writePNG(_ image: NSImage, to path: String) throws {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(
                domain: "SelectionDebugSessionWriter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not encode debug screenshot"]
            )
        }

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

func selectionDebugEventID() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let timestamp = formatter.string(from: Date())
        .replacingOccurrences(of: ":", with: "-")
        .replacingOccurrences(of: ".", with: "-")
    return "\(timestamp)-\(UUID().uuidString.prefix(8))"
}

func selectionDebugFileHash(path: String) -> String? {
    guard FileManager.default.fileExists(atPath: path),
          let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
        return nil
    }
    defer { try? handle.close() }

    var hash: UInt64 = 0xcbf29ce484222325
    let prime: UInt64 = 0x100000001b3
    while true {
        let data = try? handle.read(upToCount: 64 * 1024)
        guard let chunk = data, !chunk.isEmpty else {
            break
        }
        for byte in chunk {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
    }
    return String(format: "fnv1a64:%016llx", hash)
}
