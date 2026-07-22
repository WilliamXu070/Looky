import SceneKit
import QuickLookCore

/// Owns canonical selection topology and the derived finite-primitive index.
final class SceneSelectionEngine {
    let selectionModel: SelectionModel
    let edgeTopology: EdgePrimitiveIndex
    let snapshot: MeshSnapshot

    init?(geometry: SCNGeometry, edgeSettings: EdgeFitSettings) {
        guard let snapshot = SelectionGeometryReader.snapshot(
            from: geometry,
            sourceID: MeshSourceID(model: "scene", node: "node", geometry: "geometry")
        ),
              let selectionModel = SelectionModel(snapshot: snapshot)
        else {
            return nil
        }
        self.snapshot = snapshot
        self.selectionModel = selectionModel
        self.edgeTopology = EdgePrimitiveIndex(selectionModel: selectionModel, settings: edgeSettings)
    }
}
