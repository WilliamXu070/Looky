import Foundation
import SceneKit

@MainActor
final class ViewerSession: ObservableObject {
    @Published var scene: SCNScene?
    @Published var loadError: String?
    @Published var modelPath = ""
    @Published var loaderMetadata: [String: String] = [:]
    @Published var latestDebugEvent: SelectionDebugEvent?
    @Published var measurementState: SelectionMeasurementState = .empty
    @Published var measurementPanelHidden = false

    func beginLoading(_ url: URL) {
        loadError = nil
        modelPath = url.path
        latestDebugEvent = nil
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
        scene = imported.scene
        return metadata
    }

    func failLoading(_ error: Error) {
        scene = nil
        loaderMetadata = [:]
        measurementState = .empty
        measurementPanelHidden = false
        loadError = error.localizedDescription
    }
}
