import SceneKit
import QuickLookCore

/// Owns canonical selection topology and the derived finite-primitive index.
final class SceneSelectionEngine {
    let selectionModel: SelectionModel
    let edgeTopology: EdgePrimitiveIndex
    let snapshot: MeshSnapshot
    let semanticEngine: QuickLookCore.SelectionEngine

    init?(
        geometry: SCNGeometry,
        edgeSettings: EdgeFitSettings,
        modelIdentifier: String,
        topologyHints: ImportedTopologyHints
    ) {
        let sourceID = MeshSourceID(
            model: modelIdentifier.isEmpty ? "scene" : modelIdentifier,
            node: "model-root",
            geometry: "primary"
        )
        let coreHints = Self.coreTopologyHints(from: topologyHints)
        guard let snapshot = SelectionGeometryReader.snapshot(
            from: geometry,
            sourceID: sourceID,
            topologyHints: coreHints
        ),
              let selectionModel = SelectionModel(snapshot: snapshot)
        else {
            return nil
        }
        self.snapshot = snapshot
        self.selectionModel = selectionModel
        self.edgeTopology = EdgePrimitiveIndex(selectionModel: selectionModel, settings: edgeSettings)
        self.semanticEngine = QuickLookCore.SelectionEngine(mesh: snapshot)
    }

    private static func coreTopologyHints(from hints: ImportedTopologyHints) -> TopologyHints? {
        guard !hints.faces.isEmpty || !hints.edges.isEmpty else { return nil }
        return TopologyHints(
            faces: hints.faces.map { face in
                SourceFaceHint(
                    sourceID: face.sourceID,
                    triangles: Set(face.triangleIndices.map(MeshTriangleID.init)),
                    descriptor: SurfaceDescriptor(
                        kind: surfaceKind(face.descriptor.kind),
                        origin: face.descriptor.origin,
                        axis: face.descriptor.axis,
                        normal: face.descriptor.normal,
                        radius: face.descriptor.radius,
                        secondaryRadius: face.descriptor.secondaryRadius,
                        halfAngle: face.descriptor.halfAngle
                    )
                )
            },
            edges: hints.edges.map { edge in
                SourceEdgeHint(
                    sourceID: edge.sourceID,
                    points: edge.points,
                    incidentFaceIDs: Set(edge.incidentFaceIDs),
                    descriptor: CurveDescriptor(kind: curveKind(edge.descriptor.kind))
                )
            }
        )
    }

    private static func surfaceKind(_ kind: ImportedSurfaceKind) -> SurfacePrimitiveKind {
        switch kind {
        case .plane: .plane
        case .cylinder: .cylinder
        case .cone: .cone
        case .sphere: .sphere
        case .torus: .torus
        case .bSpline: .bSpline
        case .other: .other
        }
    }

    private static func curveKind(_ kind: ImportedCurveKind) -> CurvePrimitiveKind {
        switch kind {
        case .line: .line
        case .circle: .circle
        case .ellipse: .ellipse
        case .bSpline: .bSpline
        case .other: .other
        }
    }
}
