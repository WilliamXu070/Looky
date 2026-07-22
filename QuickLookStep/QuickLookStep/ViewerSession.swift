import Foundation
import QuickLookCore
import SceneKit

@MainActor
final class ViewerSession: ObservableObject {
    @Published var scene: SCNScene?
    @Published var loadError: String?
    @Published var modelPath = ""
    @Published var loaderMetadata: [String: String] = [:]
    @Published var topologyHints: ImportedTopologyHints = .empty
    @Published var measurementSourceUnit: ModelUnit = .unknown
    @Published var latestDebugEvent: SelectionDebugEvent?
    @Published var measurementState: SelectionMeasurementState = .empty
    @Published var measurementPanelHidden = false

    func beginLoading(_ url: URL) {
        loadError = nil
        modelPath = url.path
        latestDebugEvent = nil
        topologyHints = .empty
        measurementSourceUnit = .unknown
        measurementState = .empty
        measurementPanelHidden = false
    }

    func completeLoading(_ imported: ImportedScene) -> [String: String] {
        var metadata = imported.diagnostics.flattenedMetadata
        metadata["sourceUnit"] = imported.sourceUnit.rawValue
        metadata["sourceToSceneScale"] = String(imported.sourceTransform.sourceToSceneScale)
        metadata["sourceCenter"] = [
            imported.sourceTransform.sourceCenter.x,
            imported.sourceTransform.sourceCenter.y,
            imported.sourceTransform.sourceCenter.z,
        ].map { String($0) }.joined(separator: ",")
        loaderMetadata = metadata
        topologyHints = imported.topologyHints
        measurementSourceUnit = imported.sourceUnit.coreMeasurementUnit
        scene = imported.scene
        return metadata
    }

    func failLoading(_ error: Error) {
        scene = nil
        loaderMetadata = [:]
        topologyHints = .empty
        measurementSourceUnit = .unknown
        measurementState = .empty
        measurementPanelHidden = false
        loadError = error.localizedDescription
    }
}

private extension ImportedModelUnit {
    var coreMeasurementUnit: ModelUnit {
        switch self {
        case .unknown: .unknown
        case .millimeter: .millimeter
        case .centimeter: .centimeter
        case .meter: .meter
        case .inch: .inch
        case .foot: .foot
        }
    }
}
