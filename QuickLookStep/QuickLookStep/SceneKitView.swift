import AppKit
import Foundation
import SwiftUI
import SceneKit
import Metal
import simd

enum EdgeSelectionMode: String {
    case fitted
    case connected
}

struct EdgeFitSettings: Equatable {
    var arcToleranceMultiplier: Float = 3.0
    var minimumArcSweepDegrees: Float = 5.0
    var minimumArcCoverage: Float = 0.75
    var arcRansacIterations: Int = 96
    var minimumArcInlierRatio: Float = 0.72
    var arcInlierGapAllowance: Int = 1
    var minimumLineLengthScale: Float = 0.02
    var minimumArcLengthScale: Float = 0.025
    var lineDeviationDegrees: Float = 0
}

/// A simple SwiftUI wrapper around `SCNView` so we can embed SceneKit or Model I/O
/// content inside a SwiftUI hierarchy.
struct SceneKitView: NSViewRepresentable {
    /// The scene to show.  When this changes, the view updates.
    var scene: SCNScene?
    var edgeFitSettings: EdgeFitSettings = .init()
    var edgeProbeMode: Bool = false
    var edgeSelectionMode: EdgeSelectionMode = .fitted
    var edgeProbeOutputDirectory: String = "/tmp/quicklook-edge-probe"
    var surfaceProbeMode: Bool = false
    var surfaceProbeOutputDirectory: String = "/tmp/quicklook-surface-probe"
    var edgeProbeModelHint: String = ""
    var edgeDownloadOutputDirectory: String = "/tmp/quicklook-edge-download"
    var onSelectionResult: ((EdgeSelectionDownload?) -> Void)?
    var edgeOnlyMode: Bool = false
    var selectionDebugMode: Bool = false
    var selectionDebugOutputDirectory: String = "/tmp/quicklook-selection-debug"
    var loaderMetadata: [String: String] = [:]
    var onSelectionDebugEvent: ((SelectionDebugEvent) -> Void)?
    var onMeasurementStateChanged: ((SelectionMeasurementState) -> Void)?
    var manualSelectionEnabled: Bool = true

    func makeNSView(context: Context) -> SCNView {
        let scnView = DebugSelectableSCNView()
        NSLog("SceneKitView initialized with edgeSelectionMode=%@", edgeSelectionMode.rawValue)
        scnView.edgeFitSettings = edgeFitSettings
        scnView.edgeProbeMode = edgeProbeMode
        scnView.edgeSelectionMode = edgeSelectionMode
        scnView.edgeProbeOutputDirectory = edgeProbeOutputDirectory
        scnView.surfaceProbeMode = surfaceProbeMode
        scnView.surfaceProbeOutputDirectory = surfaceProbeOutputDirectory
        scnView.edgeProbeModelHint = edgeProbeModelHint
        scnView.edgeDownloadOutputDirectory = edgeDownloadOutputDirectory
        scnView.onSelectionResult = onSelectionResult
        scnView.edgeOnlyMode = edgeOnlyMode
        scnView.selectionDebugMode = selectionDebugMode
        scnView.selectionDebugOutputDirectory = selectionDebugOutputDirectory
        scnView.loaderMetadata = loaderMetadata
        scnView.onSelectionDebugEvent = onSelectionDebugEvent
        scnView.onMeasurementStateChanged = onMeasurementStateChanged
        scnView.manualSelectionEnabled = manualSelectionEnabled
        SelectionDebugActionDispatcher.shared.performSelectAt = { [weak scnView] request in
            scnView?.performDebugSelectAt(request)
        }
        scnView.allowsCameraControl = true
        scnView.autoresizingMask = [.width, .height]
        scnView.backgroundColor = .clear
        scnView.preferredFramesPerSecond = 60
        scnView.antialiasingMode = .multisampling4X
        scnView.autoenablesDefaultLighting = false // we set lighting in the scene builder
        scnView.delegate = scnView
        scnView.isPlaying = true
        return scnView
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        let sceneChanged: Bool
        switch (nsView.scene, scene) {
        case let (current?, next?):
            sceneChanged = current !== next
        case (nil, nil):
            sceneChanged = false
        default:
            sceneChanged = true
        }

        if sceneChanged {
            nsView.scene = scene
            nsView.pointOfView = scene?.rootNode.childNode(withName: "camera", recursively: true)
        }
        if let selectableView = nsView as? DebugSelectableSCNView {
            if sceneChanged {
                selectableView.invalidateSelectionCaches()
            }
            selectableView.edgeFitSettings = edgeFitSettings
            selectableView.edgeProbeMode = edgeProbeMode
            selectableView.edgeSelectionMode = edgeSelectionMode
            selectableView.edgeProbeOutputDirectory = edgeProbeOutputDirectory
            selectableView.surfaceProbeMode = surfaceProbeMode
            selectableView.surfaceProbeOutputDirectory = surfaceProbeOutputDirectory
            selectableView.edgeProbeModelHint = edgeProbeModelHint
            selectableView.edgeDownloadOutputDirectory = edgeDownloadOutputDirectory
            selectableView.onSelectionResult = onSelectionResult
            selectableView.edgeOnlyMode = edgeOnlyMode
            selectableView.selectionDebugMode = selectionDebugMode
            selectableView.selectionDebugOutputDirectory = selectionDebugOutputDirectory
            selectableView.loaderMetadata = loaderMetadata
            selectableView.onSelectionDebugEvent = onSelectionDebugEvent
            selectableView.onMeasurementStateChanged = onMeasurementStateChanged
            selectableView.manualSelectionEnabled = manualSelectionEnabled
            SelectionDebugActionDispatcher.shared.performSelectAt = { [weak selectableView] request in
                selectableView?.performDebugSelectAt(request)
            }
        }
    }
}

private final class DebugSelectableSCNView: SCNView, SCNSceneRendererDelegate {
    private let selectionRootName = "__selection_debug_overlay"
    private let highlightStrokePixelRadius: CGFloat = 2.2
    private let highlightEndpointPixelRadius: CGFloat = 5.0
    private let edgeSelectionRadiusViewportFraction: Float = 0.0016
    private let edgeSelectionRadiusWorldMin: Float = 0.0005
    private let edgeSelectionRadiusWorldMax: Float = 0.45
    private var screenStableHighlightNodes: [ScreenStableHighlightNode] = []
    var edgeFitSettings = EdgeFitSettings()
    var edgeProbeMode = false
    var edgeSelectionMode: EdgeSelectionMode = .fitted
    var edgeProbeOutputDirectory = "/tmp/quicklook-edge-probe"
    var surfaceProbeMode = false
    var surfaceProbeOutputDirectory = "/tmp/quicklook-surface-probe"
    var edgeProbeModelHint = ""
    var edgeDownloadOutputDirectory = "/tmp/quicklook-edge-download"
    var onSelectionResult: ((EdgeSelectionDownload?) -> Void)?
    var edgeOnlyMode = false
    var selectionDebugMode = false
    var selectionDebugOutputDirectory = "/tmp/quicklook-selection-debug"
    var loaderMetadata: [String: String] = [:]
    var onSelectionDebugEvent: ((SelectionDebugEvent) -> Void)?
    var onMeasurementStateChanged: ((SelectionMeasurementState) -> Void)?
    var manualSelectionEnabled = true
    private var surfaceGeometryRestores: [(node: SCNNode, geometry: SCNGeometry)] = []
    private var activeSurfaceHighlight: (node: SCNNode, triangleIndices: [Int])?
    private var measurementState: SelectionMeasurementState = .empty
    private var selectionModelCache: [ObjectIdentifier: SelectionModel] = [:]
    private var meshTopologyCache: [ObjectIdentifier: MeshTopology] = [:]
    private var cachedMeshSettings = EdgeFitSettings()
    private var mouseDownPoint: CGPoint?
    private var mouseDraggedPastSelectionThreshold = false
    private let cameraDragSelectionThreshold: CGFloat = 4
    private let metalFeatureDistanceThreshold = SelectionMetalAccelerator.minimumSegmentThreshold
    private var selectionMetalAccelerator: SelectionMetalAccelerator? = SelectionMetalAccelerator()
    private var loggedSelectionAccelerationModes: Set<String> = []

    private struct ScreenStableHighlightNode {
        let node: SCNNode
        let anchor: SIMD3<Float>
        let pixelRadius: CGFloat
        let scaleMode: HighlightScaleMode
    }

    private enum HighlightScaleMode {
        case radial
        case uniform
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        mouseDraggedPastSelectionThreshold = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let mouseDownPoint {
            let point = convert(event.locationInWindow, from: nil)
            let distance = hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y)
            if distance > cameraDragSelectionThreshold {
                mouseDraggedPastSelectionThreshold = true
            }
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let releaseDistance = mouseDownPoint.map {
            hypot(point.x - $0.x, point.y - $0.y)
        } ?? 0

        guard manualSelectionEnabled else {
            super.mouseUp(with: event)
            mouseDownPoint = nil
            mouseDraggedPastSelectionThreshold = false
            return
        }

        guard mouseDraggedPastSelectionThreshold == false,
              releaseDistance <= cameraDragSelectionThreshold else {
            super.mouseUp(with: event)
            mouseDownPoint = nil
            mouseDraggedPastSelectionThreshold = false
            return
        }

        _ = drawDebugSelection(at: point, event: event)
        super.mouseUp(with: event)
        mouseDownPoint = nil
        mouseDraggedPastSelectionThreshold = false
    }

    func performDebugSelectAt(_ request: SelectionDebugSelectAtRequest) -> SelectionDebugEvent? {
        guard bounds.width > 1, bounds.height > 1 else {
            return nil
        }

        if let sceneCamera = scene?.rootNode.childNode(withName: "camera", recursively: true) {
            pointOfView = sceneCamera
        }

        let point: CGPoint
        switch request.coordinateSpace {
        case .normalizedViewport:
            point = CGPoint(
                x: CGFloat(request.x) * bounds.width,
                y: CGFloat(request.y) * bounds.height
            )
        case .viewport:
            point = CGPoint(x: CGFloat(request.x), y: CGFloat(request.y))
        }

        return drawDebugSelection(
            at: point,
            event: nil,
            expectation: request.expectation,
            forceDebugEvent: true,
            modifierFlagsOverride: request.modifiers
        )
    }

    func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
        updateScreenStableHighlights()
    }

    func invalidateSelectionCaches() {
        selectionModelCache.removeAll()
        meshTopologyCache.removeAll()
        cachedMeshSettings = edgeFitSettings
        activeSurfaceHighlight = nil
        measurementState = .empty
    }

    private func selectionModel(for geometry: SCNGeometry) -> SelectionModel? {
        let key = ObjectIdentifier(geometry)
        if let cached = selectionModelCache[key] {
            return cached
        }
        guard let model = SelectionModel(geometry: geometry) else {
            return nil
        }
        selectionModelCache[key] = model
        return model
    }

    private func meshTopology(for geometry: SCNGeometry) -> MeshTopology? {
        if cachedMeshSettings != edgeFitSettings {
            meshTopologyCache.removeAll()
            cachedMeshSettings = edgeFitSettings
        }

        let key = ObjectIdentifier(geometry)
        if let cached = meshTopologyCache[key] {
            return cached
        }
        guard let mesh = MeshTopology(geometry: geometry, settings: edgeFitSettings) else {
            return nil
        }
        meshTopologyCache[key] = mesh
        return mesh
    }

    @discardableResult
    private func drawDebugSelection(
        at point: CGPoint,
        event: NSEvent? = nil,
        expectation: SelectionDebugExpectation? = nil,
        forceDebugEvent: Bool = false,
        modifierFlagsOverride: [String]? = nil
    ) -> SelectionDebugEvent? {
        let selectionStart = CFAbsoluteTimeGetCurrent()
        let shouldWriteDebugEvent = selectionDebugMode || forceDebugEvent
        let beforeImage = shouldWriteDebugEvent ? snapshot() : nil
        guard let scene else {
            return nil
        }
        let modifierNames = selectionModifierNames(event: event, override: modifierFlagsOverride)

        // Start every input transaction from a clean state so previous surface overlays
        // do not affect the next click's ray-cast or candidate topology.
        clearDebugSelection(from: scene)

        guard let selectionResult = resolveSelection(at: point) else {
            if surfaceProbeMode {
                writeSurfaceProbeRecord(
                    makeSurfaceProbeRecord(
                        at: point,
                        event: event,
                        modifierFlagsOverride: modifierFlagsOverride,
                        resolvedSelection: nil
                    )
                )
            }
            updateMeasurementStateForNoSelection(modifiers: modifierNames, scene: scene)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - selectionStart) * 1000
            let pendingDebugEvent = makeSelectionDebugEventIfNeeded(
                at: point,
                event: event,
                resolvedSelection: nil,
                elapsedMs: elapsedMs,
                expectation: expectation,
                forceDebugEvent: forceDebugEvent,
                modifierFlagsOverride: modifierFlagsOverride
            )
            let debugEvent = writeSelectionDebugEvent(pendingDebugEvent, beforeImage: beforeImage)
            NSLog("Selection ignored: no nearby downloadable edge or surface elapsedMs=%.2f", elapsedMs)
            return debugEvent
        }

        if surfaceProbeMode {
            writeSurfaceProbeRecord(
                makeSurfaceProbeRecord(
                    at: point,
                    event: event,
                    modifierFlagsOverride: modifierFlagsOverride,
                    resolvedSelection: selectionResult
                )
            )
        }

        let resolvedElapsedMs = (CFAbsoluteTimeGetCurrent() - selectionStart) * 1000
        let pendingDebugEvent = makeSelectionDebugEventIfNeeded(
            at: point,
            event: event,
            resolvedSelection: selectionResult,
            elapsedMs: resolvedElapsedMs,
            expectation: expectation,
            forceDebugEvent: forceDebugEvent,
            modifierFlagsOverride: modifierFlagsOverride
        )

        switch selectionResult {
        case .surface(let hit, let surfaceSelection):
            let measurementEntity = makeSurfaceMeasurementEntity(
                hit: hit,
                surfaceSelection: surfaceSelection
            )
            let didDraw = drawSurfaceSelection(
                hit: hit,
                surfaceSelection: surfaceSelection,
                scene: scene,
                selectionStart: selectionStart
            )
            if didDraw, let measurementEntity {
                setMeasurementState(.singleSurface(measurementEntity))
            } else if didDraw == false {
                activeSurfaceHighlight = nil
                setMeasurementState(.empty)
            }
        case .edge(let hit, let resolved):
            let didDraw = drawEdgeSelection(
                hit: hit,
                resolved: resolved,
                scene: scene,
                selectionStart: selectionStart
            )
            if didDraw {
                updateMeasurementStateForEdge(
                    resolved,
                    hit: hit,
                    modifiers: modifierNames,
                    scene: scene
                )
            } else {
                activeSurfaceHighlight = nil
                setMeasurementState(.empty)
            }
        }

        return writeSelectionDebugEvent(pendingDebugEvent, beforeImage: beforeImage)
    }

    private func drawEdgeSelection(
        hit: SCNHitTestResult,
        resolved: EdgeSelectionCandidate,
        scene: SCNScene,
        selectionStart: CFAbsoluteTime
    ) -> Bool {
        let edgeSnap = resolved.edgeSnap
        let chainWorldPoints = resolved.chainWorldPoints
        let chainKind = resolved.chainKind

        let chainLength = polylineLength(chainWorldPoints)
        guard canDownloadSelection(mode: edgeSelectionMode, candidate: resolved) else {
            NSLog(
                "Selection not downloadable after retry: mode=%@ chainKind=%@ candidate=(%ld,%ld) length=%.4f points=%ld",
                edgeSelectionMode.rawValue,
                chainKind,
                edgeSnap.selectedEdge.a,
                edgeSnap.selectedEdge.b,
                chainLength,
                chainWorldPoints.count
            )
            return false
        }

        // Clear and rebuild overlay only once we have a valid, downloadable edge candidate.
        clearDebugSelection(from: scene)

        let overlayRoot = SCNNode()
        overlayRoot.name = selectionRootName
        scene.rootNode.addChildNode(overlayRoot)

        guard let geometry = hit.node.geometry,
              let mesh = meshTopology(for: geometry) else {
            return false
        }

        let snappedWorldPosition = simdVector(hit.node.convertPosition(scnVector(edgeSnap.position), to: nil))

        NSLog(
            "Selection snapped to edge: distance=%.4f currentPointIsEdge=%@ visitedTriangles=%ld chain=%@ points=%ld",
            edgeSnap.distance,
            edgeSnap.currentPointIsEdge ? "YES" : "NO",
            edgeSnap.visitedTriangleCount,
            chainKind,
            chainWorldPoints.count
        )

        let snappedWorldPoint = snappedWorldPosition
        let hitWorldPoint = simdVector(hit.worldCoordinates)
        let shapeDetection = EdgeShapeDetector.analyze(points: chainWorldPoints)
        let highlightPoints = EdgeShapeDetector.selectedPrimitivePoints(
            points: chainWorldPoints,
            nearest: snappedWorldPoint
        )
        NSLog(
            "Selection shape detection: raw=%@ detected=%@ sequence=%@ highlightPoints=%ld",
            shapeDetection.rawOrderShape,
            shapeDetection.detectedShape,
            shapeDetection.sequence.joined(separator: " -> "),
            highlightPoints?.count ?? 0
        )

        if edgeSelectionMode == .connected {
            let selectedEdgeIsFeature = mesh.edges[edgeSnap.selectedEdge]?.isFeatureEdge ?? false
            let localHit = simdVector(hit.localCoordinates)
            let componentSeed = selectedEdgeIsFeature
                ? edgeSnap.selectedEdge
                : (mesh.nearestFeatureEdge(to: localHit) ?? edgeSnap.selectedEdge)
            let componentEdges = mesh.connectedFeatureEdgeComponent(startingFrom: componentSeed)
            let componentSource = (componentSeed == edgeSnap.selectedEdge) ? "seed" : "nearest-feature"

            NSLog(
                "Selection mode=%@ selectedEdge=(%ld,%ld) feature=%@ componentSeed=(%ld,%ld) seedReason=%@ componentEdges=%ld",
                edgeSelectionMode.rawValue,
                edgeSnap.selectedEdge.a,
                edgeSnap.selectedEdge.b,
                selectedEdgeIsFeature ? "YES" : "NO",
                componentSeed.a,
                componentSeed.b,
                componentSource,
                componentEdges.count
            )

            if let highlightPoints {
                overlayRoot.addChildNode(makeEdgeChainNode(points: highlightPoints))
            } else if shapeDetection.sequence.allSatisfy({ $0 == "line-segment" }),
                      let selectedEdgeNode = makeSelectedEdgeNode(
                        edge: edgeSnap.selectedEdge,
                        using: hit.node,
                        meshVertices: mesh.vertices
                      ) {
                overlayRoot.addChildNode(selectedEdgeNode)
            } else {
                let segments = mesh.connectedFeatureSegments(componentEdges: componentEdges) ?? []
                if let componentNode = makeConnectedComponentNode(segments: segments, using: hit.node, meshVertices: mesh.vertices) {
                    overlayRoot.addChildNode(componentNode)
                } else {
                    overlayRoot.addChildNode(makeEdgeChainNode(points: chainWorldPoints))
                }
            }
        } else {
            if let selectedEdgeNode = makeSelectedEdgeNode(
                edge: edgeSnap.selectedEdge,
                using: hit.node,
                meshVertices: mesh.vertices
            ) {
                overlayRoot.addChildNode(selectedEdgeNode)
            } else {
                overlayRoot.addChildNode(makeEdgeChainNode(points: chainWorldPoints))
            }
        }
        updateScreenStableHighlights()

        let downloadRecord = EdgeSelectionDownload(
            producedAt: ISO8601DateFormatter().string(from: Date()),
            detectionVersion: "2026-06-07-fix",
            selectedEdge: [edgeSnap.selectedEdge.a, edgeSnap.selectedEdge.b],
            chainKind: chainKind,
            chainPoints: chainWorldPoints.map { $0.asArray() },
            shapeDetection: shapeDetection,
            hitWorldPoint: hitWorldPoint.asArray(),
            snappedPoint: edgeSnap.position.asArray(),
            snappedWorldPoint: snappedWorldPoint.asArray(),
            snapDistance: edgeSnap.distance,
            isExactEdge: edgeSnap.currentPointIsEdge,
            selectedTriangle: edgeSnap.selectedTriangle,
            visitedTriangles: edgeSnap.visitedTriangleCount
        )

        onSelectionResult?(downloadRecord)
        writeEdgeDownloadRecord(
            at: edgeDownloadOutputDirectory,
            chainPoints: chainWorldPoints,
            edgeSnap: edgeSnap,
            chainKind: chainKind,
            hitWorldPoint: hitWorldPoint,
            snappedWorldPoint: snappedWorldPoint
        )

        if edgeProbeMode,
           let outputRecord = makeEdgeProbeRecord(
            using: mesh,
            hit: hit,
            edgeSnap: edgeSnap
           ) {
            writeEdgeProbeRecord(outputRecord)
        }

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - selectionStart) * 1000
        NSLog("Selection completed elapsedMs=%.2f", elapsedMs)
        return true
    }

    private func drawSurfaceSelection(
        hit: SCNHitTestResult,
        surfaceSelection: SurfaceSelectionCandidate,
        scene: SCNScene,
        selectionStart: CFAbsoluteTime
    ) -> Bool {
        clearDebugSelection(from: scene)

        guard let geometry = hit.node.geometry,
              let selectionModel = selectionModel(for: geometry),
              let selectedGeometry = makeSurfaceSelectionGeometry(
                triangleIndices: surfaceSelection.triangleIndices,
                selectionModel: selectionModel,
                baseMaterial: geometry.materials.first
        ) else {
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - selectionStart) * 1000
            NSLog("Surface selection failed to build overlay elapsedMs=%.2f", elapsedMs)
            return false
        }

        rememberSurfaceGeometry(for: hit.node, geometry: geometry)
        activeSurfaceHighlight = (node: hit.node, triangleIndices: surfaceSelection.triangleIndices)
        hit.node.geometry = selectedGeometry

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - selectionStart) * 1000
        NSLog(
            "Surface selected: seedTriangle=%ld triangles=%ld nearestFeatureEdge=%.4f threshold=%.4f elapsedMs=%.2f",
            surfaceSelection.seedTriangle,
            surfaceSelection.triangleIndices.count,
            surfaceSelection.nearestFeatureEdgeDistance,
            surfaceSelection.edgePromotionThreshold,
            elapsedMs
        )
        return true
    }

    private func setMeasurementState(_ state: SelectionMeasurementState) {
        measurementState = state
        onMeasurementStateChanged?(state)
    }

    private func updateMeasurementStateForNoSelection(modifiers: [String], scene: SCNScene) {
        if preservesSelection(modifiers: modifiers), !measurementState.isEmpty {
            redrawMeasurementHighlight(for: measurementState, scene: scene)
            onMeasurementStateChanged?(measurementState)
            return
        }

        activeSurfaceHighlight = nil
        setMeasurementState(.empty)
    }

    private func updateMeasurementStateForEdge(
        _ resolved: EdgeSelectionCandidate,
        hit: SCNHitTestResult,
        modifiers: [String],
        scene: SCNScene
    ) {
        let entity = makeEdgeMeasurementEntity(resolved, hit: hit)
        let isCommand = modifiers.contains("command")
        let isShift = modifiers.contains("shift")

        var nextEdges: [SelectionMeasurementEntity]
        if isCommand {
            let currentEdges = measurementState.entities.filter { $0.kind == "edge" }
            if currentEdges.contains(where: { $0.id == entity.id }) {
                nextEdges = currentEdges.filter { $0.id != entity.id }
            } else {
                nextEdges = currentEdges + [entity]
            }
        } else if isShift {
            nextEdges = measurementState.entities.filter { $0.kind == "edge" } + [entity]
        } else {
            nextEdges = [entity]
        }

        activeSurfaceHighlight = nil
        let nextState = SelectionMeasurementState.edges(nextEdges)
        setMeasurementState(nextState)
        redrawMeasurementHighlight(for: nextState, scene: scene)
    }

    private func preservesSelection(modifiers: [String]) -> Bool {
        modifiers.contains("shift") || modifiers.contains("command")
    }

    private func redrawMeasurementHighlight(for state: SelectionMeasurementState, scene: SCNScene) {
        clearDebugSelection(from: scene)

        switch state.kind {
        case "edge", "multiEdge":
            activeSurfaceHighlight = nil
            let edgeEntities = state.entities.filter { $0.kind == "edge" && $0.simdPoints.count >= 2 }
            guard !edgeEntities.isEmpty else {
                return
            }

            let overlayRoot = SCNNode()
            overlayRoot.name = selectionRootName
            scene.rootNode.addChildNode(overlayRoot)

            for entity in edgeEntities {
                overlayRoot.addChildNode(makeEdgeChainNode(points: entity.simdPoints))
            }
            updateScreenStableHighlights()

        case "surface":
            redrawActiveSurfaceHighlight()

        default:
            activeSurfaceHighlight = nil
        }
    }

    private func redrawActiveSurfaceHighlight() {
        guard let activeSurfaceHighlight,
              let geometry = activeSurfaceHighlight.node.geometry,
              let selectionModel = selectionModel(for: geometry),
              let selectedGeometry = makeSurfaceSelectionGeometry(
                triangleIndices: activeSurfaceHighlight.triangleIndices,
                selectionModel: selectionModel,
                baseMaterial: geometry.materials.first
              ) else {
            return
        }

        rememberSurfaceGeometry(for: activeSurfaceHighlight.node, geometry: geometry)
        activeSurfaceHighlight.node.geometry = selectedGeometry
    }

    private func makeEdgeMeasurementEntity(
        _ resolved: EdgeSelectionCandidate,
        hit: SCNHitTestResult
    ) -> SelectionMeasurementEntity {
        let edge = resolved.edgeSnap.selectedEdge
        let points = userFacingEdgePoints(for: resolved, hit: hit)
        let shapeDetection = EdgeShapeDetector.analyze(points: points)
        let shapeLabel = shapeDetection.detectedShape == "unknown" ? "Edge" : shapeDetection.detectedShape
        let radius = shapeDetection.segments.compactMap(\.circleRadius).first

        return SelectionMeasurementEntity(
            id: "edge:\(edge.a)-\(edge.b)",
            kind: "edge",
            label: shapeLabel,
            sourceIDs: [
                "edge:\(edge.a)-\(edge.b)",
                "triangle:\(resolved.edgeSnap.selectedTriangle)",
            ],
            length: SelectionMeasurementCalculator.polylineLength(points),
            radius: radius,
            area: nil,
            perimeter: nil,
            triangleCount: nil,
            pointCount: points.count,
            shape: shapeDetection.detectedShape,
            surfaceType: nil,
            points: points.map { $0.asArray() }
        )
    }

    private func userFacingEdgePoints(
        for resolved: EdgeSelectionCandidate,
        hit: SCNHitTestResult
    ) -> [SIMD3<Float>] {
        if edgeSelectionMode == .connected {
            return resolved.chainWorldPoints
        }

        guard let geometry = hit.node.geometry,
              let mesh = meshTopology(for: geometry),
              let points = selectedEdgeWorldPoints(
                edge: resolved.edgeSnap.selectedEdge,
                using: hit.node,
                meshVertices: mesh.vertices
              ) else {
            return resolved.chainWorldPoints
        }
        return points
    }

    private func makeSurfaceMeasurementEntity(
        hit: SCNHitTestResult,
        surfaceSelection: SurfaceSelectionCandidate
    ) -> SelectionMeasurementEntity? {
        guard let geometry = hit.node.geometry,
              let selectionModel = selectionModel(for: geometry) else {
            return nil
        }

        let seedTriangleID = SelectionTriangleID(rawValue: surfaceSelection.seedTriangle)
        let patchID = selectionModel.surfacePatchID(forTriangle: seedTriangleID)
        let patch = patchID.flatMap { selectionModel.surfacePatch($0) }
        let measurements = SelectionMeasurementCalculator.surfaceMeasurements(
            triangleIndices: surfaceSelection.triangleIndices,
            selectionModel: selectionModel,
            node: hit.node
        )
        let entityID = patchID.map { "surfacePatch:\($0.rawValue)" } ?? "surfaceSeed:\(surfaceSelection.seedTriangle)"
        let surfaceType = patch?.isPlanar == true ? "Planar" : "Curved"

        return SelectionMeasurementEntity(
            id: entityID,
            kind: "surface",
            label: patchID.map { "Surface \($0.rawValue)" } ?? "Surface",
            sourceIDs: [entityID, "seedTriangle:\(surfaceSelection.seedTriangle)"],
            length: nil,
            radius: nil,
            area: measurements.area,
            perimeter: measurements.perimeter,
            triangleCount: surfaceSelection.triangleIndices.count,
            pointCount: nil,
            shape: nil,
            surfaceType: surfaceType,
            points: []
        )
    }

    private func makeSelectionDebugEventIfNeeded(
        at point: CGPoint,
        event: NSEvent?,
        resolvedSelection: ResolvedSelection?,
        elapsedMs: Double,
        expectation: SelectionDebugExpectation?,
        forceDebugEvent: Bool,
        modifierFlagsOverride: [String]?
    ) -> SelectionDebugEvent? {
        guard selectionDebugMode || forceDebugEvent else {
            return nil
        }

        return makeSelectionDebugEvent(
            at: point,
            event: event,
            resolvedSelection: resolvedSelection,
            elapsedMs: elapsedMs,
            expectation: expectation,
            modifierFlagsOverride: modifierFlagsOverride
        )
    }

    private func writeSelectionDebugEvent(
        _ event: SelectionDebugEvent?,
        beforeImage: NSImage?
    ) -> SelectionDebugEvent? {
        guard let event else {
            return nil
        }

        let afterImage = snapshot()
        do {
            let result = try SelectionDebugSessionWriter(
                outputDirectory: selectionDebugOutputDirectory
            ).write(
                event: event,
                beforeImage: beforeImage,
                afterImage: afterImage
            )
            onSelectionDebugEvent?(result.event)
            NSLog(
                "Selection debug event saved: %@ kind=%@ reason=%@",
                result.eventPath,
                result.event.resolver.finalKind,
                result.event.resolver.reason
            )
            return result.event
        } catch {
            NSLog(
                "Failed writing selection debug event to %@: %@",
                selectionDebugOutputDirectory,
                error.localizedDescription
            )
            onSelectionDebugEvent?(event)
            return event
        }
    }

    private func makeSelectionDebugEvent(
        at point: CGPoint,
        event: NSEvent?,
        resolvedSelection: ResolvedSelection?,
        elapsedMs: Double,
        expectation: SelectionDebugExpectation?,
        modifierFlagsOverride: [String]?
    ) -> SelectionDebugEvent {
        let probe = makeSurfaceProbeRecord(
            at: point,
            event: event,
            modifierFlagsOverride: modifierFlagsOverride,
            resolvedSelection: resolvedSelection
        )
        let selectedEdgePointCount: Int
        let selectedSurfaceTriangleCount: Int
        let selectedEntityID: String?
        let seedTriangle: Int?

        switch resolvedSelection {
        case .surface(let hit, let surfaceSelection):
            selectedEdgePointCount = 0
            selectedSurfaceTriangleCount = surfaceSelection.triangleIndices.count
            seedTriangle = surfaceSelection.seedTriangle
            if let geometry = hit.node.geometry,
               let selectionModel = selectionModel(for: geometry),
               let patchID = selectionModel.surfacePatchID(forTriangle: SelectionTriangleID(rawValue: surfaceSelection.seedTriangle)) {
                selectedEntityID = "surfacePatch:\(patchID.rawValue)"
            } else {
                selectedEntityID = "surfaceSeed:\(surfaceSelection.seedTriangle)"
            }
        case .edge(_, let edgeSelection):
            selectedEdgePointCount = edgeSelection.chainWorldPoints.count
            selectedSurfaceTriangleCount = 0
            seedTriangle = edgeSelection.edgeSnap.selectedTriangle
            selectedEntityID = "edge:\(edgeSelection.edgeSnap.selectedEdge.a)-\(edgeSelection.edgeSnap.selectedEdge.b)"
        case nil:
            selectedEdgePointCount = 0
            selectedSurfaceTriangleCount = 0
            seedTriangle = probe.seedTriangle
            selectedEntityID = nil
        }

        let finalKind = probe.resolvedKind
        let reason = selectionDebugReason(
            finalKind: finalKind,
            selectedSurfaceTriangleCount: selectedSurfaceTriangleCount,
            selectedEdgePointCount: selectedEdgePointCount,
            probe: probe
        )
        let render = selectionDebugRenderValidation(for: resolvedSelection)
        let modelHint = edgeProbeModelHint.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeModelHint = modelHint.isEmpty ? "unknown-model" : modelHint

        return SelectionDebugEvent(
            eventID: selectionDebugEventID(),
            producedAt: ISO8601DateFormatter().string(from: Date()),
            modelHint: safeModelHint,
            modelHash: selectionDebugFileHash(path: safeModelHint),
            loaderMetadata: loaderMetadata.isEmpty ? nil : loaderMetadata,
            camera: selectionDebugCameraState(),
            input: SelectionDebugInput(
                windowPoint: event.map { [Double($0.locationInWindow.x), Double($0.locationInWindow.y)] },
                viewportPoint: [Double(point.x), Double(point.y)],
                normalizedViewportPoint: normalizedViewportPoint(point),
                modifierFlags: probe.modifierFlags,
                selectionMode: edgeSelectionMode.rawValue,
                edgeOnlyMode: edgeOnlyMode
            ),
            hitTest: SelectionDebugHitTest(
                viewSize: [Float(bounds.width), Float(bounds.height)],
                sceneNodeName: probe.sceneNodeName,
                hitLocalPoint: probe.hitLocalPoint,
                hitWorldPoint: probe.hitWorldPoint,
                hitLocalNormal: probe.hitLocalNormal,
                hitWorldNormal: probe.hitWorldNormal,
                seedTriangle: probe.seedTriangle,
                hitDistance: hitDistanceFromCamera(hitWorldPoint: probe.hitWorldPoint),
                noHitReason: probe.sceneNodeName == nil ? probe.note : nil
            ),
            resolver: SelectionDebugResolver(
                finalKind: finalKind,
                selectedEntityID: selectedEntityID,
                selectedSurfaceTriangleCount: selectedSurfaceTriangleCount,
                selectedEdgePointCount: selectedEdgePointCount,
                seedTriangle: seedTriangle,
                nearestFeatureEdgeDistance: probe.nearestFeatureEdgeDistance,
                nearestFeatureEdgeAcceleration: probe.nearestFeatureEdgeAcceleration,
                surfacePromotionThreshold: probe.surfacePromotionThreshold,
                edgeCandidateCount: probe.edgeCandidateCount,
                bestEdgeDistance: probe.bestEdgeDistance,
                bestEdgeIsFeature: probe.bestEdgeIsFeature,
                bestEdgeCurrentPointIsEdge: probe.bestEdgeCurrentPointIsEdge,
                bestEdgeChainKind: probe.bestEdgeChainKind,
                rejectedAlternatives: selectionDebugRejectedAlternatives(finalKind: finalKind, probe: probe),
                elapsedMs: elapsedMs,
                reason: reason
            ),
            render: render,
            expectation: expectation,
            expectedKind: expectation?.kind,
            expectedSurfaceLabel: nil,
            note: nil,
            eventPath: nil,
            sessionPath: nil,
            beforeScreenshotPath: nil,
            afterScreenshotPath: nil
        )
    }

    private func selectionDebugReason(
        finalKind: String,
        selectedSurfaceTriangleCount: Int,
        selectedEdgePointCount: Int,
        probe: SurfaceProbeRecord
    ) -> String {
        switch finalKind {
        case "surface":
            return "surface selected: \(selectedSurfaceTriangleCount) triangles"
        case "edge":
            if probe.surfaceTriangleCount > 0,
               let nearest = probe.nearestFeatureEdgeDistance,
               let threshold = probe.surfacePromotionThreshold,
               nearest <= threshold {
                return "edge selected: surface rejected inside edge threshold"
            }
            return "edge selected: \(selectedEdgePointCount) points"
        default:
            if probe.sceneNodeName == nil {
                return "none: no non-overlay hit"
            }
            if probe.surfaceTriangleCount == 0, probe.edgeCandidateCount == 0 {
                return "none: no surface or edge candidates"
            }
            return "none: no downloadable edge or promotable surface"
        }
    }

    private func selectionDebugRejectedAlternatives(
        finalKind: String,
        probe: SurfaceProbeRecord
    ) -> [SelectionDebugRejectedAlternative] {
        var alternatives: [SelectionDebugRejectedAlternative] = []
        if finalKind == "edge", probe.surfaceTriangleCount > 0 {
            let reason: String
            if let nearest = probe.nearestFeatureEdgeDistance,
               let threshold = probe.surfacePromotionThreshold,
               nearest <= threshold {
                reason = "surface rejected: inside edge threshold"
            } else {
                reason = "surface rejected: accepted edge candidate took priority"
            }
            alternatives.append(
                SelectionDebugRejectedAlternative(
                    kind: "surface",
                    reason: reason,
                    distance: probe.nearestFeatureEdgeDistance,
                    threshold: probe.surfacePromotionThreshold,
                    triangleCount: probe.surfaceTriangleCount,
                    chainKind: nil
                )
            )
        }

        if finalKind == "surface", probe.bestEdgeDistance != nil || probe.edgeCandidateCount > 0 {
            alternatives.append(
                SelectionDebugRejectedAlternative(
                    kind: "edge",
                    reason: "edge rejected: surface promotion won",
                    distance: probe.bestEdgeDistance,
                    threshold: probe.surfacePromotionThreshold,
                    triangleCount: 0,
                    chainKind: probe.bestEdgeChainKind
                )
            )
        }

        if finalKind == "none" {
            if probe.surfaceTriangleCount > 0 {
                alternatives.append(
                    SelectionDebugRejectedAlternative(
                        kind: "surface",
                        reason: "surface rejected: resolver did not promote candidate",
                        distance: probe.nearestFeatureEdgeDistance,
                        threshold: probe.surfacePromotionThreshold,
                        triangleCount: probe.surfaceTriangleCount,
                        chainKind: nil
                    )
                )
            }
            if probe.edgeCandidateCount > 0 {
                alternatives.append(
                    SelectionDebugRejectedAlternative(
                        kind: "edge",
                        reason: "edge rejected: no downloadable chain",
                        distance: probe.bestEdgeDistance,
                        threshold: nil,
                        triangleCount: 0,
                        chainKind: probe.bestEdgeChainKind
                    )
                )
            }
        }

        return alternatives
    }

    private func selectionDebugRenderValidation(
        for resolvedSelection: ResolvedSelection?
    ) -> SelectionDebugRenderValidation {
        switch resolvedSelection {
        case .surface(let hit, let surfaceSelection):
            guard let geometry = hit.node.geometry,
                  let selectionModel = selectionModel(for: geometry) else {
                return SelectionDebugRenderValidation(
                    selectedTriangleCount: surfaceSelection.triangleIndices.count,
                    selectedEdgePointCount: 0,
                    localBoundsMin: nil,
                    localBoundsMax: nil,
                    materialMode: "replacement-two-material-geometry",
                    readsDepth: true,
                    writesDepth: true,
                    clippingWarning: "selected surface model unavailable for finite bounds"
                )
            }
            let bounds = selectedSurfaceBounds(
                triangleIndices: surfaceSelection.triangleIndices,
                selectionModel: selectionModel
            )
            let disconnected = selectedSurfaceDisconnected(
                surfaceSelection,
                selectionModel: selectionModel
            )
            let warning: String?
            if bounds == nil {
                warning = "selected surface has no finite bounds"
            } else if disconnected {
                warning = "selected surface triangles disconnected from seed"
            } else {
                warning = nil
            }
            return SelectionDebugRenderValidation(
                selectedTriangleCount: surfaceSelection.triangleIndices.count,
                selectedEdgePointCount: 0,
                localBoundsMin: bounds?.min.asArray(),
                localBoundsMax: bounds?.max.asArray(),
                materialMode: "replacement-two-material-geometry",
                readsDepth: true,
                writesDepth: true,
                clippingWarning: warning
            )
        case .edge(_, let edgeSelection):
            let bounds = selectedPointBounds(edgeSelection.chainWorldPoints)
            return SelectionDebugRenderValidation(
                selectedTriangleCount: 0,
                selectedEdgePointCount: edgeSelection.chainWorldPoints.count,
                localBoundsMin: bounds?.min.asArray(),
                localBoundsMax: bounds?.max.asArray(),
                materialMode: "selection-overlay-edge-chain",
                readsDepth: true,
                writesDepth: false,
                clippingWarning: edgeSelection.chainWorldPoints.count < 2 ? "selected edge has fewer than two points" : nil
            )
        case nil:
            return SelectionDebugRenderValidation(
                selectedTriangleCount: 0,
                selectedEdgePointCount: 0,
                localBoundsMin: nil,
                localBoundsMax: nil,
                materialMode: "none",
                readsDepth: false,
                writesDepth: false,
                clippingWarning: nil
            )
        }
    }

    private func selectedSurfaceBounds(
        triangleIndices: [Int],
        selectionModel: SelectionModel
    ) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(triangleIndices.count * 3)
        for triangleIndex in triangleIndices {
            guard triangleIndex >= 0, triangleIndex < selectionModel.triangles.count else {
                continue
            }
            for vertexIndex in selectionModel.triangles[triangleIndex].vertexIndices {
                guard vertexIndex >= 0, vertexIndex < selectionModel.vertices.count else {
                    continue
                }
                points.append(selectionModel.vertices[vertexIndex])
            }
        }
        return selectedPointBounds(points)
    }

    private func selectedPointBounds(
        _ points: [SIMD3<Float>]
    ) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard var minPoint = points.first else {
            return nil
        }
        var maxPoint = minPoint
        for point in points.dropFirst() {
            minPoint = SIMD3<Float>(
                min(minPoint.x, point.x),
                min(minPoint.y, point.y),
                min(minPoint.z, point.z)
            )
            maxPoint = SIMD3<Float>(
                max(maxPoint.x, point.x),
                max(maxPoint.y, point.y),
                max(maxPoint.z, point.z)
            )
        }
        return (minPoint, maxPoint)
    }

    private func selectedSurfaceDisconnected(
        _ surfaceSelection: SurfaceSelectionCandidate,
        selectionModel: SelectionModel
    ) -> Bool {
        let selected = Set(surfaceSelection.triangleIndices)
        guard selected.contains(surfaceSelection.seedTriangle) else {
            return true
        }

        var visited: Set<Int> = [surfaceSelection.seedTriangle]
        var queue = [surfaceSelection.seedTriangle]
        var cursor = 0
        while cursor < queue.count {
            let triangleIndex = queue[cursor]
            cursor += 1
            guard triangleIndex >= 0, triangleIndex < selectionModel.triangles.count else {
                continue
            }
            for neighbor in selectionModel.triangles[triangleIndex].neighborTriangleIDs {
                let raw = neighbor.rawValue
                if selected.contains(raw), visited.insert(raw).inserted {
                    queue.append(raw)
                }
            }
        }
        return visited.count != selected.count
    }

    private func selectionDebugCameraState() -> SelectionDebugCameraState {
        guard let cameraNode = pointOfView,
              let camera = cameraNode.camera else {
            return SelectionDebugCameraState(
                orientationDegrees: [0, 0, 0],
                position: [0, 0, 0],
                fieldOfView: 0,
                distanceFromOrigin: 0
            )
        }

        return SelectionDebugCameraState(
            orientationDegrees: cameraNode.cameraOrientationDegrees(),
            position: cameraNode.positionArray(),
            fieldOfView: Double(camera.fieldOfView),
            distanceFromOrigin: cameraNode.distanceFromOrigin()
        )
    }

    private func normalizedViewportPoint(_ point: CGPoint) -> [Double] {
        let width = max(Double(bounds.width), 1.0)
        let height = max(Double(bounds.height), 1.0)
        return [
            min(max(Double(point.x) / width, 0), 1),
            min(max(Double(point.y) / height, 0), 1),
        ]
    }

    private func hitDistanceFromCamera(hitWorldPoint: [Float]?) -> Float? {
        guard let hitWorldPoint,
              hitWorldPoint.count >= 3,
              let cameraNode = pointOfView else {
            return nil
        }
        let hit = SIMD3<Float>(hitWorldPoint[0], hitWorldPoint[1], hitWorldPoint[2])
        return simd_distance(cameraNode.simdWorldPosition, hit)
    }

    private func clearDebugSelection(from scene: SCNScene) {
        restoreSurfaceGeometries()
        screenStableHighlightNodes.removeAll()
        scene.rootNode
            .childNode(withName: selectionRootName, recursively: false)?
            .removeFromParentNode()
    }

    private func rememberSurfaceGeometry(for node: SCNNode, geometry: SCNGeometry) {
        guard !surfaceGeometryRestores.contains(where: { $0.node === node }) else {
            return
        }
        surfaceGeometryRestores.append((node: node, geometry: geometry))
    }

    private func restoreSurfaceGeometries() {
        for restore in surfaceGeometryRestores {
            restore.node.geometry = restore.geometry
        }
        surfaceGeometryRestores.removeAll()
    }

    private func edgeSelectionWorldRadius(for hit: SCNHitTestResult) -> Float {
        guard let cameraNode = pointOfView,
              let camera = cameraNode.camera else {
            return 0.25
        }

        let cameraWorldPosition = cameraNode.simdWorldPosition
        let hitWorldPoint = simdVector(hit.worldCoordinates)
        let distanceToCamera = max(simd_distance(cameraWorldPosition, hitWorldPoint), 0.001)

        let radius: Float
        if camera.usesOrthographicProjection {
            radius = Float(camera.orthographicScale) * 2 * edgeSelectionRadiusViewportFraction
        } else {
            let fieldOfViewRadians = Float(camera.fieldOfView) * .pi / 180
            let visibleHeight = 2 * distanceToCamera * tanf(fieldOfViewRadians / 2)
            radius = visibleHeight * edgeSelectionRadiusViewportFraction
        }

        return max(edgeSelectionRadiusWorldMin, min(edgeSelectionRadiusWorldMax, radius))
    }

    private func localRayThroughScreenPoint(_ point: CGPoint, in node: SCNNode) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        let near = unprojectPoint(SCNVector3(point.x, point.y, 0))
        let far = unprojectPoint(SCNVector3(point.x, point.y, 1))

        let worldNear = simdVector(near)
        let worldFar = simdVector(far)
        let worldDirection = worldFar - worldNear
        let worldDirectionLength = simd_length(worldDirection)
        guard worldDirectionLength.isFinite && worldDirectionLength > 0 else {
            return nil
        }

        let normalizedWorldDirection = worldDirection / worldDirectionLength
        let localOrigin = simdVector(node.convertPosition(scnVector(worldNear), from: nil))
        let localDirection = qlsNormalized(
            simdVector(node.convertVector(scnVector(normalizedWorldDirection), from: nil)),
            fallback: SIMD3<Float>(0, 0, -1)
        )
        let localDirectionLength = simd_length(localDirection)
        guard localDirectionLength.isFinite && localDirectionLength > 0 else {
            return nil
        }

        return (origin: localOrigin, direction: localDirection)
    }

    private func distanceFromRayToSegment(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        segmentStart: SIMD3<Float>,
        segmentEnd: SIMD3<Float>
    ) -> Float {
        let d = direction
        let v = segmentEnd - segmentStart
        let w = segmentStart - origin

        let a = simd_dot(d, d)
        let b = simd_dot(d, v)
        let c = simd_dot(v, v)
        let d1 = simd_dot(d, w)
        let e = simd_dot(v, w)
        let denominator = a * c - b * b

        let stableDenominator = abs(denominator) > 0.000001 ? denominator : 0.000001
        var sc = (b * e - c * d1) / stableDenominator
        var tc = (a * e - b * d1) / stableDenominator

        if tc < 0 {
            tc = 0
            sc = max(-d1 / max(a, 0.000001), 0)
        } else if tc > 1 {
            tc = 1
            sc = max((b + d1) / max(a, 0.000001), 0)
        }

        if sc < 0 {
            sc = 0
            tc = c > 0 ? e / c : 0
            tc = max(min(tc, 1), 0)
        }

        let closestOnRay = origin + d * sc
        let closestOnSegment = segmentStart + v * tc
        return simd_distance(closestOnRay, closestOnSegment)
    }

    private func resolveSelection(at point: CGPoint) -> ResolvedSelection? {
        let samplingOffsets: [CGPoint] = [
            .init(x: 0, y: 0),
            .init(x: 1, y: 0),
            .init(x: -1, y: 0),
            .init(x: 0, y: 1),
            .init(x: 0, y: -1),
            .init(x: 1.5, y: 1.5),
            .init(x: -1.5, y: 1.5),
            .init(x: 1.5, y: -1.5),
            .init(x: -1.5, y: -1.5),
            .init(x: 2, y: 0),
            .init(x: -2, y: 0),
            .init(x: 0, y: 2),
            .init(x: 0, y: -2),
            .init(x: 2.5, y: 2.5),
            .init(x: -2.5, y: 2.5),
            .init(x: 2.5, y: -2.5),
            .init(x: -2.5, y: -2.5),
            .init(x: 3, y: 0),
            .init(x: -3, y: 0),
            .init(x: 0, y: 3),
            .init(x: 0, y: -3),
            .init(x: 3, y: 3),
            .init(x: -3, y: 3),
            .init(x: 3, y: -3),
            .init(x: -3, y: -3),
        ]

        var bestFallback: (hit: SCNHitTestResult, selection: EdgeSelectionCandidate, score: Float, nearestFeatureEdgeDistance: Float)?
        var bestSurfaceFallback: (hit: SCNHitTestResult, selection: SurfaceSelectionCandidate)?

        for (attempt, offset) in samplingOffsets.enumerated() {
            let attemptPoint = CGPoint(x: point.x + offset.x, y: point.y + offset.y)
            let hits = hitTest(attemptPoint, options: [
                .searchMode: SCNHitTestSearchMode.closest.rawValue,
                .ignoreHiddenNodes: true,
                .backFaceCulling: false,
            ])

            guard let hit = hits.first(where: { !isSelectionOverlay($0.node) }) else {
                continue
            }

            guard let geometry = hit.node.geometry,
                  let mesh = meshTopology(for: geometry),
                  let selectionModel = selectionModel(for: geometry) else {
                continue
            }

            let edgeSelectionRadius = edgeSelectionWorldRadius(for: hit)
            let localRay = localRayThroughScreenPoint(attemptPoint, in: hit.node)
            let localHit = simdVector(hit.localCoordinates)
            let nearestFeatureEdge = nearestFeatureEdgeDistance(in: selectionModel, to: localHit)
            let nearestFeatureEdgeDistance = nearestFeatureEdge.distance
            let surfaceCandidate = resolveSurfaceSelection(for: hit, in: selectionModel)
            if let surfaceCandidate,
               bestSurfaceFallback == nil ||
                surfaceCandidate.triangleIndices.count > bestSurfaceFallback!.selection.triangleIndices.count {
                bestSurfaceFallback = (hit, surfaceCandidate)
            }

            let candidates = nearestEdgeCandidates(for: hit, in: mesh)
            let featureCandidates = candidates.filter { $0.isFeatureEdge }
            let useConnectedFeaturePath = edgeSelectionMode == .connected
                && nearestFeatureEdgeDistance <= (surfaceCandidate?.edgePromotionThreshold ?? Float.greatestFiniteMagnitude)

            let candidatesForSelection = useConnectedFeaturePath ? featureCandidates : candidates

            if !edgeOnlyMode,
               useConnectedFeaturePath == false,
               let surfaceCandidate,
               nearestFeatureEdgeDistance > surfaceCandidate.edgePromotionThreshold {
                guard let seedTriangle = selectionModel.closestTriangleID(to: localHit)?.rawValue else {
                    continue
                }
                NSLog(
                    "Selection attempt routed to surface (no nearby feature candidates) at attempt=%d/%ld offset=(%.1f,%.1f) nearestFeatureEdge=%.4f threshold=%.4f seed=%ld",
                    attempt + 1,
                    samplingOffsets.count,
                    offset.x,
                    offset.y,
                    nearestFeatureEdgeDistance,
                    surfaceCandidate.edgePromotionThreshold,
                    seedTriangle
                )
                return .surface(hit: hit, selection: surfaceCandidate)
            }

            guard let selected = resolveBestDownloadSelection(
                from: candidatesForSelection,
                mesh: mesh,
                hit: hit,
                node: hit.node,
                edgeRadius: edgeSelectionRadius,
                rayOrigin: localRay?.origin,
                rayDirection: localRay?.direction
            ) else {
                continue
            }

            if !edgeOnlyMode,
               let surfaceCandidate,
               shouldPromoteSurfaceOver(
                selected: selected,
                nearestFeatureEdgeDistance: nearestFeatureEdgeDistance,
                surfaceCandidate: surfaceCandidate
               ) {
                NSLog(
                    "Selection attempt routed to surface at attempt=%d/%ld offset=(%.1f,%.1f) edgeDistance=%.4f surfaceDistThreshold=%.4f",
                    attempt + 1,
                    samplingOffsets.count,
                    offset.x,
                    offset.y,
                    selected.edgeSnap.distance,
                    surfaceCandidate.edgePromotionThreshold
                )
                return .surface(hit: hit, selection: surfaceCandidate)
            }

            let chainLength = polylineLength(selected.chainWorldPoints)
            let candidateScore = Float(selected.chainWorldPoints.count) * 64.0 + chainLength
            if canDownloadSelection(mode: edgeSelectionMode, candidate: selected) {
                NSLog(
                    "Selection retry accepted at attempt=%d/%ld offset=(%.1f,%.1f) chain=%@ length=%.4f points=%ld edgeRadius=%.4f",
                    attempt + 1,
                    samplingOffsets.count,
                    offset.x,
                    offset.y,
                    selected.chainKind,
                    chainLength,
                    selected.chainWorldPoints.count,
                    edgeSelectionRadius
                )
                return .edge(hit: hit, selection: selected)
            } else {
                NSLog(
                    "Selection retry rejected candidate at attempt=%d/%ld offset=(%.1f,%.1f) chain=%@ length=%.4f points=%ld edgeRadius=%.4f",
                    attempt + 1,
                    samplingOffsets.count,
                    offset.x,
                    offset.y,
                    selected.chainKind,
                    chainLength,
                    selected.chainWorldPoints.count,
                    edgeSelectionRadius
                )
            }

            if bestFallback == nil || candidateScore > bestFallback!.score {
                bestFallback = (hit, selected, candidateScore, nearestFeatureEdgeDistance)
            }
        }
        if let fallback = bestFallback {
            if !edgeOnlyMode,
               let fallbackSurface = bestSurfaceFallback,
               shouldPromoteSurfaceOver(
                selected: fallback.selection,
                nearestFeatureEdgeDistance: fallback.nearestFeatureEdgeDistance,
                surfaceCandidate: fallbackSurface.selection
               ) {
                NSLog(
                    "Selection retry exhausted; promoting nearest fallback to surface triangles=%ld nearestFeatureEdge=%.4f threshold=%.4f",
                    fallbackSurface.selection.triangleIndices.count,
                    fallbackSurface.selection.nearestFeatureEdgeDistance,
                    fallbackSurface.selection.edgePromotionThreshold
                )
                return .surface(hit: fallbackSurface.hit, selection: fallbackSurface.selection)
            }

            if !canDownloadSelection(mode: edgeSelectionMode, candidate: fallback.selection) {
                if !edgeOnlyMode,
                   let fallbackSurface = bestSurfaceFallback {
                    NSLog(
                        "Selection retry exhausted; best fallback edge not downloadable. Using surface fallback triangles=%ld nearestFeatureEdge=%.4f threshold=%.4f",
                        fallbackSurface.selection.triangleIndices.count,
                        fallbackSurface.selection.nearestFeatureEdgeDistance,
                        fallbackSurface.selection.edgePromotionThreshold
                    )
                    return .surface(hit: fallbackSurface.hit, selection: fallbackSurface.selection)
                }
                NSLog("Selection retry exhausted; best fallback edge not downloadable and no surface candidate available.")
                return nil
            }

            NSLog(
                "Selection retry exhausted; using nearest retry candidate chain=%@ points=%ld length=%.4f",
                fallback.selection.chainKind,
                fallback.selection.chainWorldPoints.count,
                polylineLength(fallback.selection.chainWorldPoints)
            )
            return .edge(hit: fallback.hit, selection: fallback.selection)
        }

        if !edgeOnlyMode,
           let fallbackSurface = bestSurfaceFallback {
            NSLog(
                "Selection retry exhausted; using surface fallback triangles=%ld nearestFeatureEdge=%.4f threshold=%.4f",
                fallbackSurface.selection.triangleIndices.count,
                fallbackSurface.selection.nearestFeatureEdgeDistance,
                fallbackSurface.selection.edgePromotionThreshold
            )
            return .surface(hit: fallbackSurface.hit, selection: fallbackSurface.selection)
        }

        return nil
    }

    private func resolveSurfaceSelection(
        for hit: SCNHitTestResult,
        in selectionModel: SelectionModel
    ) -> SurfaceSelectionCandidate? {
        let hitLocal = simdVector(hit.localCoordinates)
        guard let seedTriangle = selectionModel.closestTriangleID(to: hitLocal) else {
            return nil
        }

        let threshold = localSurfaceSelectionDistanceThreshold(for: selectionModel)
        let nearestFeatureEdge = nearestFeatureEdgeDistance(in: selectionModel, to: hitLocal)
        let nearestFeatureEdgeDistance = nearestFeatureEdge.distance
        guard nearestFeatureEdgeDistance > threshold else {
            return nil
        }

        let surfaceTriangles = selectionModel.surfacePatch(forTriangle: seedTriangle)?.triangleIDs.map(\.rawValue) ?? []
        guard !surfaceTriangles.isEmpty else {
            return nil
        }

        return SurfaceSelectionCandidate(
            seedTriangle: seedTriangle.rawValue,
            triangleIndices: surfaceTriangles,
            nearestFeatureEdgeDistance: nearestFeatureEdgeDistance,
            nearestFeatureEdgeAcceleration: nearestFeatureEdge.acceleration,
            edgePromotionThreshold: threshold
        )
    }

    private func nearestFeatureEdgeDistance(
        in selectionModel: SelectionModel,
        to point: SIMD3<Float>
    ) -> SelectionDistanceResult {
        let result = selectionModel.nearestFeatureEdgeDistanceGPUAccelerated(
            to: point,
            accelerator: selectionMetalAccelerator,
            minimumSegmentCount: metalFeatureDistanceThreshold
        )

        if loggedSelectionAccelerationModes.insert(result.acceleration).inserted {
            NSLog(
                "Selection nearest-feature acceleration=%@ featureSegments=%ld metalThreshold=%ld metalDisabled=%@",
                result.acceleration,
                selectionModel.featureEdgeSegments.count,
                metalFeatureDistanceThreshold,
                SelectionMetalAccelerator.disabledByEnvironment ? "YES" : "NO"
            )
        }

        return result
    }

    private func makeEdgeChainNode(points: [SIMD3<Float>]) -> SCNNode {
        let root = SCNNode()
        root.name = "selection-edge-chain"
        guard points.count >= 2 else {
            return root
        }

        for index in 0..<(points.count - 1) {
            let start = points[index]
            let end = points[index + 1]
            root.addChildNode(makeEdgeSegmentNode(from: start, to: end))
        }

        if let first = points.first,
           let last = points.last,
           simd_distance(first, last) > 0.001 {
            root.addChildNode(makeEndpointNode(at: first))
            root.addChildNode(makeEndpointNode(at: last))
        }

        return root
    }

    private func makeSelectedEdgeNode(
        edge: EdgeKey,
        using node: SCNNode,
        meshVertices: [SIMD3<Float>]
    ) -> SCNNode? {
        guard let points = selectedEdgeWorldPoints(edge: edge, using: node, meshVertices: meshVertices) else {
            return nil
        }
        return makeEdgeChainNode(points: points)
    }

    private func selectedEdgeWorldPoints(
        edge: EdgeKey,
        using node: SCNNode,
        meshVertices: [SIMD3<Float>]
    ) -> [SIMD3<Float>]? {
        guard edge.a >= 0, edge.b >= 0,
              edge.a < meshVertices.count, edge.b < meshVertices.count else {
            return nil
        }

        let localStart = meshVertices[edge.a]
        let localEnd = meshVertices[edge.b]
        let worldStart = simdVector(node.convertPosition(scnVector(localStart), to: nil))
        let worldEnd = simdVector(node.convertPosition(scnVector(localEnd), to: nil))
        return [worldStart, worldEnd]
    }

    private func makeConnectedComponentNode(
        segments: [[Int]],
        using node: SCNNode,
        meshVertices: [SIMD3<Float>]
    ) -> SCNNode? {
        let validSegments = segments.compactMap { pair -> (SIMD3<Float>, SIMD3<Float>)? in
            guard pair.count == 2 else { return nil }
            guard pair[0] >= 0, pair[1] >= 0,
                  pair[0] < meshVertices.count, pair[1] < meshVertices.count else {
                return nil
            }

            let localStart = meshVertices[pair[0]]
            let localEnd = meshVertices[pair[1]]
            let worldStart = simdVector(node.convertPosition(scnVector(localStart), to: nil))
            let worldEnd = simdVector(node.convertPosition(scnVector(localEnd), to: nil))
            return (worldStart, worldEnd)
        }

        guard !validSegments.isEmpty else {
            return nil
        }

        let root = SCNNode()
        root.name = "selection-edge-component"
        for segment in validSegments {
            root.addChildNode(makeEdgeSegmentNode(from: segment.0, to: segment.1))
        }
        return root
    }

    private func makeSurfaceSelectionNode(
        triangleIndices: [Int],
        using node: SCNNode,
        mesh: MeshTopology,
        cameraNode: SCNNode?
    ) -> SCNNode? {
        guard !triangleIndices.isEmpty else {
            return nil
        }

        var vertices: [SCNVector3] = []
        var indices: [UInt32] = []
        vertices.reserveCapacity(triangleIndices.count * 3)
        indices.reserveCapacity(triangleIndices.count * 3)

        for triangleIndex in triangleIndices {
            guard triangleIndex >= 0, triangleIndex < mesh.triangles.count else {
                continue
            }

            let triangle = mesh.triangles[triangleIndex]
            let localCentroid = mesh.triangleCentroid(triangle)
            let worldCentroid = simdVector(node.convertPosition(scnVector(localCentroid), to: nil))
            let liftDirection = cameraNode.map {
                normalized($0.simdWorldPosition - worldCentroid, fallback: SIMD3<Float>(0, 1, 0))
            } ?? normalized(
                simdVector(node.convertVector(scnVector(triangle.normal), to: nil)),
                fallback: SIMD3<Float>(0, 1, 0)
            )
            let lift = max(mesh.maxExtent * 0.00045, 0.05)

            for vertexIndex in triangle.indices {
                guard vertexIndex >= 0, vertexIndex < mesh.vertices.count else {
                    continue
                }

                let localPoint = mesh.vertices[vertexIndex]
                let worldPoint = simdVector(node.convertPosition(scnVector(localPoint), to: nil)) + liftDirection * lift
                vertices.append(scnVector(worldPoint))
                indices.append(UInt32(vertices.count - 1))
            }
        }

        guard vertices.count >= 3, indices.count >= 3 else {
            return nil
        }

        let source = SCNGeometrySource(vertices: vertices)
        let element = SCNGeometryElement(
            data: indices.withUnsafeBytes { Data($0) },
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.materials = [surfaceSelectionMaterial()]

        let surfaceNode = SCNNode(geometry: geometry)
        surfaceNode.name = "selection-surface"
        surfaceNode.renderingOrder = 18
        return surfaceNode
    }

    private func makeEdgeSegmentNode(from start: SIMD3<Float>, to end: SIMD3<Float>) -> SCNNode {
        let vector = end - start
        let length = simd_length(vector)
        guard length > 0 else {
            return SCNNode()
        }

        let cylinder = SCNCylinder(radius: 0.55, height: CGFloat(length))
        cylinder.radialSegmentCount = 12
        cylinder.radius = 1
        cylinder.materials = [selectionMaterial(alpha: 0.78)]

        let node = SCNNode(geometry: cylinder)
        node.name = "selection-edge-segment"
        node.simdPosition = (start + end) * 0.5
        node.simdOrientation = simd_quatf(
            from: SIMD3<Float>(0, 1, 0),
            to: normalized(vector, fallback: SIMD3<Float>(0, 1, 0))
        )
        node.renderingOrder = 20
        screenStableHighlightNodes.append(
            ScreenStableHighlightNode(
                node: node,
                anchor: node.simdPosition,
                pixelRadius: highlightStrokePixelRadius,
                scaleMode: .radial
            )
        )
        return node
    }

    private func makeEndpointNode(at position: SIMD3<Float>) -> SCNNode {
        let sphere = SCNSphere(radius: 1)
        sphere.segmentCount = 20
        sphere.materials = [selectionMaterial(alpha: 0.82)]

        let node = SCNNode(geometry: sphere)
        node.name = "selection-edge-endpoint"
        node.simdPosition = position
        node.renderingOrder = 21
        screenStableHighlightNodes.append(
            ScreenStableHighlightNode(
                node: node,
                anchor: position,
                pixelRadius: highlightEndpointPixelRadius,
                scaleMode: .uniform
            )
        )
        return node
    }

    private func updateScreenStableHighlights() {
        guard !screenStableHighlightNodes.isEmpty else {
            return
        }

        for highlight in screenStableHighlightNodes {
            let radius = worldRadius(forPixelRadius: highlight.pixelRadius, at: highlight.anchor)
            switch highlight.scaleMode {
            case .radial:
                highlight.node.simdScale = SIMD3<Float>(radius, 1, radius)
            case .uniform:
                highlight.node.simdScale = SIMD3<Float>(repeating: radius)
            }
        }
    }

    private func worldRadius(forPixelRadius pixelRadius: CGFloat, at anchor: SIMD3<Float>) -> Float {
        guard bounds.height > 1,
              let cameraNode = pointOfView,
              let camera = cameraNode.camera else {
            return 0.35
        }

        let viewportHeight = Float(bounds.height)
        let pixelRadius = Float(pixelRadius)
        if camera.usesOrthographicProjection {
            let unitsPerPixel = Float(camera.orthographicScale) / viewportHeight
            return max(unitsPerPixel * pixelRadius, 0.01)
        }

        let cameraPosition = cameraNode.simdWorldPosition
        let distance = max(simd_distance(cameraPosition, anchor), 0.01)
        let fieldOfViewRadians = Float(camera.fieldOfView) * .pi / 180
        let visibleHeight = 2 * distance * tanf(fieldOfViewRadians / 2)
        let unitsPerPixel = visibleHeight / viewportHeight
        return max(unitsPerPixel * pixelRadius, 0.01)
    }

    private func selectionMaterial(alpha: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        let color = NSColor(calibratedRed: 1.0, green: 0.58, blue: 0.08, alpha: alpha)
        material.diffuse.contents = color
        material.emission.contents = color.withAlphaComponent(min(alpha + 0.08, 1))
        material.transparency = alpha
        material.blendMode = .alpha
        material.isDoubleSided = true
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        return material
    }

    private func isSelectionOverlay(_ node: SCNNode) -> Bool {
        var current: SCNNode? = node
        while let node = current {
            if node.name == selectionRootName {
                return true
            }
            current = node.parent
        }
        return false
    }

    private func makeEdgeProbeRecord(
        using mesh: MeshTopology,
        hit: SCNHitTestResult,
        edgeSnap: EdgeSnap
    ) -> ProbeRecord? {
        let localHitPoint = simdVector(hit.localCoordinates)
        let worldHitPoint = simdVector(hit.node.convertPosition(scnVector(localHitPoint), to: nil))
        let localNormal = normalized(simdVector(hit.localNormal), fallback: SIMD3<Float>(0, 1, 0))
        let worldNormal = simdVector(hit.node.convertVector(scnVector(localNormal), to: nil))
        let component = mesh.connectedFeatureEdgeComponent(startingFrom: edgeSnap.selectedEdge)
        let connectedVertices = mesh.connectedFeatureVertices(componentEdges: component) ?? []
        let connectedSegments = mesh.connectedFeatureSegments(componentEdges: component) ?? []
        let surroundingTriangles = mesh.surroundingTriangles(for: component, maxTriangles: 250) ?? []

        let output = ProbeRecord(
            producedAt: ISO8601DateFormatter().string(from: Date()),
            modelHint: sanitizeFileHint(edgeProbeModelHint),
            sceneNodeName: hit.node.name ?? "model",
            chainKind: edgeSnap.chainKind,
            selectedTriangle: edgeSnap.selectedTriangle,
            selectedEdge: [edgeSnap.selectedEdge.a, edgeSnap.selectedEdge.b],
            hitLocalPoint: localHitPoint.asArray(),
            hitWorldPoint: worldHitPoint.asArray(),
            hitWorldNormal: worldNormal.asArray(),
            snappedPoint: edgeSnap.position.asArray(),
            snapDistance: edgeSnap.distance,
            isExactEdge: edgeSnap.currentPointIsEdge,
            visitedTriangles: edgeSnap.visitedTriangleCount,
            connectedFeatureVertices: connectedVertices,
            connectedFeatureSegments: connectedSegments,
            surroundingTriangles: surroundingTriangles
        )

        NSLog(
            "Edge probe captured: model=%@ vertices=%ld segments=%ld triangles=%ld rejected=%@",
            output.modelHint,
            output.connectedFeatureVertices.count,
            output.connectedFeatureSegments.count,
            output.surroundingTriangles.count,
            output.connectedFeatureVertices.isEmpty && output.connectedFeatureSegments.isEmpty ? "YES" : "NO"
        )
        return output
    }

    private func writeEdgeProbeRecord(_ record: ProbeRecord) {
        let directoryURL = URL(fileURLWithPath: edgeProbeOutputDirectory)
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let safeModel = sanitizeFileHint(record.modelHint)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )

            let outputURL = directoryURL.appendingPathComponent(
                "\(safeModel)-edge-probe-\(timestamp).json"
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let payload = try encoder.encode(record)
            try payload.write(to: outputURL, options: .atomic)
            NSLog("Edge probe saved: %@", outputURL.path)
        } catch {
            NSLog("Failed writing edge probe to %@: %@", edgeProbeOutputDirectory, error.localizedDescription)
        }
    }

    private func makeSurfaceProbeRecord(
        at point: CGPoint,
        event: NSEvent?,
        modifierFlagsOverride: [String]? = nil,
        resolvedSelection: ResolvedSelection?
    ) -> SurfaceProbeRecord {
        let resolvedKind: String
        switch resolvedSelection {
        case .surface:
            resolvedKind = "surface"
        case .edge:
            resolvedKind = "edge"
        case nil:
            resolvedKind = "none"
        }

        let hits = hitTest(point, options: [
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .ignoreHiddenNodes: true,
            .backFaceCulling: false,
        ])

        guard let hit = hits.first(where: { !isSelectionOverlay($0.node) }),
              let geometry = hit.node.geometry,
              let selectionModel = selectionModel(for: geometry)
        else {
            return SurfaceProbeRecord(
                producedAt: ISO8601DateFormatter().string(from: Date()),
                modelHint: sanitizeFileHint(edgeProbeModelHint),
                viewSize: [Float(bounds.width), Float(bounds.height)],
                viewportPoint: [Float(point.x), Float(point.y)],
                modifierFlags: selectionModifierNames(event: event, override: modifierFlagsOverride),
                resolvedKind: resolvedKind,
                sceneNodeName: nil,
                hitLocalPoint: nil,
                hitWorldPoint: nil,
                hitLocalNormal: nil,
                hitWorldNormal: nil,
                seedTriangle: nil,
                surfacePromoted: false,
                surfaceTriangleCount: 0,
                nearestFeatureEdgeDistance: nil,
                nearestFeatureEdgeAcceleration: nil,
                surfacePromotionThreshold: nil,
                edgeCandidateCount: 0,
                bestEdgeDistance: nil,
                bestEdgeIsFeature: nil,
                bestEdgeCurrentPointIsEdge: nil,
                bestEdgeChainKind: nil,
                note: "No non-overlay geometry hit at viewport point."
            )
        }

        let hitLocal = simdVector(hit.localCoordinates)
        let hitWorld = simdVector(hit.worldCoordinates)
        let localNormal = normalized(simdVector(hit.localNormal), fallback: SIMD3<Float>(0, 1, 0))
        let worldNormal = normalized(
            simdVector(hit.node.convertVector(scnVector(localNormal), to: nil)),
            fallback: SIMD3<Float>(0, 1, 0)
        )
        let seedTriangle = selectionModel.closestTriangleID(to: hitLocal)?.rawValue
        let surfaceCandidate = resolveSurfaceSelection(for: hit, in: selectionModel)
        let nearestFeatureEdge = surfaceCandidate.map {
            SelectionDistanceResult(
                distance: $0.nearestFeatureEdgeDistance,
                acceleration: $0.nearestFeatureEdgeAcceleration
            )
        } ?? nearestFeatureEdgeDistance(in: selectionModel, to: hitLocal)
        let mesh = meshTopology(for: geometry)
        let edgeCandidates = mesh.map { nearestEdgeCandidates(for: hit, in: $0) } ?? []
        let edgeSelectionRadius = edgeSelectionWorldRadius(for: hit)
        let localRay = localRayThroughScreenPoint(point, in: hit.node)
        let bestEdge = mesh.flatMap {
            resolveBestDownloadSelection(
                from: edgeCandidates,
                mesh: $0,
                hit: hit,
                node: hit.node,
                edgeRadius: edgeSelectionRadius,
                rayOrigin: localRay?.origin,
                rayDirection: localRay?.direction
            )
        }
        let note: String
        if resolvedKind == "edge", surfaceCandidate != nil {
            note = "Surface candidate existed, but final resolver chose edge. This is the edge-priority/auto-aim failure case."
        } else if resolvedKind == "surface" {
            note = "Final resolver chose surface."
        } else if surfaceCandidate == nil {
            note = "Surface candidate did not promote, usually because click was within edge threshold."
        } else {
            note = "Probe captured resolver state."
        }

        let bestEdgeSnap = bestEdge?.edgeSnap
        return SurfaceProbeRecord(
            producedAt: ISO8601DateFormatter().string(from: Date()),
            modelHint: sanitizeFileHint(edgeProbeModelHint),
            viewSize: [Float(bounds.width), Float(bounds.height)],
            viewportPoint: [Float(point.x), Float(point.y)],
            modifierFlags: selectionModifierNames(event: event, override: modifierFlagsOverride),
            resolvedKind: resolvedKind,
            sceneNodeName: hit.node.name,
            hitLocalPoint: hitLocal.asArray(),
            hitWorldPoint: hitWorld.asArray(),
            hitLocalNormal: localNormal.asArray(),
            hitWorldNormal: worldNormal.asArray(),
            seedTriangle: seedTriangle,
            surfacePromoted: surfaceCandidate != nil,
            surfaceTriangleCount: surfaceCandidate?.triangleIndices.count ?? 0,
            nearestFeatureEdgeDistance: nearestFeatureEdge.distance,
            nearestFeatureEdgeAcceleration: nearestFeatureEdge.acceleration,
            surfacePromotionThreshold: localSurfaceSelectionDistanceThreshold(for: selectionModel),
            edgeCandidateCount: edgeCandidates.count,
            bestEdgeDistance: bestEdgeSnap?.distance,
            bestEdgeIsFeature: bestEdgeSnap?.isFeatureEdge,
            bestEdgeCurrentPointIsEdge: bestEdgeSnap?.currentPointIsEdge,
            bestEdgeChainKind: bestEdge?.chainKind,
            note: note
        )
    }

    private func writeSurfaceProbeRecord(_ record: SurfaceProbeRecord) {
        let directoryURL = URL(fileURLWithPath: surfaceProbeOutputDirectory)
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let safeModel = sanitizeFileHint(record.modelHint)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )

            let outputURL = directoryURL.appendingPathComponent(
                "\(safeModel)-surface-probe-\(timestamp).json"
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let payload = try encoder.encode(record)
            try payload.write(to: outputURL, options: .atomic)
            NSLog(
                "Surface probe saved: %@ resolved=%@ surfacePromoted=%@ surfaceTriangles=%ld edgeCandidates=%ld",
                outputURL.path,
                record.resolvedKind,
                record.surfacePromoted ? "YES" : "NO",
                record.surfaceTriangleCount,
                record.edgeCandidateCount
            )
        } catch {
            NSLog("Failed writing surface probe to %@: %@", surfaceProbeOutputDirectory, error.localizedDescription)
        }
    }

    private func modifierFlagNames(_ flags: NSEvent.ModifierFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.shift) { names.append("shift") }
        if flags.contains(.control) { names.append("control") }
        if flags.contains(.option) { names.append("option") }
        if flags.contains(.command) { names.append("command") }
        if flags.contains(.capsLock) { names.append("capsLock") }
        return names
    }

    private func selectionModifierNames(event: NSEvent?, override: [String]?) -> [String] {
        if let override {
            return normalizedModifierNames(override)
        }
        return modifierFlagNames(event?.modifierFlags ?? [])
    }

    private func normalizedModifierNames(_ names: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []

        for rawName in names {
            let normalized: String
            switch rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "cmd", "command", "meta":
                normalized = "command"
            case "shift":
                normalized = "shift"
            case "ctrl", "control":
                normalized = "control"
            case "alt", "option":
                normalized = "option"
            case "caps", "capslock", "caps_lock":
                normalized = "capsLock"
            default:
                continue
            }

            if seen.insert(normalized).inserted {
                result.append(normalized)
            }
        }

        return result
    }

    private func canDownloadSelection(mode: EdgeSelectionMode, candidate: EdgeSelectionCandidate) -> Bool {
        if candidate.chainWorldPoints.count < 2 {
            return false
        }
        let chainLength = polylineLength(candidate.chainWorldPoints)
        if chainLength < 0.0001 {
            return false
        }

        return true
    }

    private func writeEdgeDownloadRecord(
        at directory: String,
        chainPoints: [SIMD3<Float>],
        edgeSnap: EdgeSnap,
        chainKind: String,
        hitWorldPoint: SIMD3<Float>,
        snappedWorldPoint: SIMD3<Float>
    ) {
        guard canDownloadSelection(mode: edgeSelectionMode, candidate: EdgeSelectionCandidate(
            edgeSnap: edgeSnap,
            chainWorldPoints: chainPoints,
            chainKind: chainKind
        )) else {
        return
        }

        let payload = EdgeSelectionDownload(
            producedAt: ISO8601DateFormatter().string(from: Date()),
            detectionVersion: "2026-06-07-fix",
            selectedEdge: [edgeSnap.selectedEdge.a, edgeSnap.selectedEdge.b],
            chainKind: chainKind,
            chainPoints: chainPoints.map { [$0.x, $0.y, $0.z] },
            shapeDetection: EdgeShapeDetector.analyze(points: chainPoints),
            hitWorldPoint: [hitWorldPoint.x, hitWorldPoint.y, hitWorldPoint.z],
            snappedPoint: [edgeSnap.position.x, edgeSnap.position.y, edgeSnap.position.z],
            snappedWorldPoint: [snappedWorldPoint.x, snappedWorldPoint.y, snappedWorldPoint.z],
            snapDistance: edgeSnap.distance,
            isExactEdge: edgeSnap.currentPointIsEdge,
            selectedTriangle: edgeSnap.selectedTriangle,
            visitedTriangles: edgeSnap.visitedTriangleCount
        )

        let directoryURL = URL(fileURLWithPath: directory)
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let filename = "edge-download-\(timestamp).json"

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )

            let outputURL = directoryURL.appendingPathComponent(filename)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: outputURL, options: .atomic)
            NSLog("Edge download saved: %@", outputURL.path)
        } catch {
            NSLog("Failed writing edge download to %@: %@", directory, error.localizedDescription)
        }
    }

    private func resolveBestDownloadSelection(
        from candidates: [EdgeSnap],
        mesh: MeshTopology,
        hit: SCNHitTestResult,
        node: SCNNode,
        edgeRadius: Float?,
        rayOrigin: SIMD3<Float>?,
        rayDirection: SIMD3<Float>?
    ) -> EdgeSelectionCandidate? {
        guard !candidates.isEmpty else {
            return nil
        }

        let localHit = simdVector(hit.localCoordinates)
        let gatedCandidates = candidates.filter { candidate in
            guard let edgeRadius,
                  edgeRadius > 0,
                  let rayOrigin,
                  let rayDirection,
                  mesh.edges[candidate.selectedEdge] != nil else {
                return true
            }

            guard candidate.selectedEdge.a >= 0, candidate.selectedEdge.b >= 0,
                  candidate.selectedEdge.a < mesh.vertices.count,
                  candidate.selectedEdge.b < mesh.vertices.count else {
                return false
            }

            let edgeStart = mesh.vertices[candidate.selectedEdge.a]
            let edgeEnd = mesh.vertices[candidate.selectedEdge.b]
            let rayDistance = distanceFromRayToSegment(
                origin: rayOrigin,
                direction: rayDirection,
                segmentStart: edgeStart,
                segmentEnd: edgeEnd
            )
            return rayDistance <= edgeRadius
        }

        guard !gatedCandidates.isEmpty else {
            return nil
        }

        let sortedCandidates = gatedCandidates.sorted { first, second in
            if edgeSelectionMode == .connected {
                if first.isFeatureEdge != second.isFeatureEdge {
                    return first.isFeatureEdge && !second.isFeatureEdge
                }
            }
            if first.currentPointIsEdge != second.currentPointIsEdge {
                return first.currentPointIsEdge && !second.currentPointIsEdge
            }
            return first.distance < second.distance
        }

        for candidate in sortedCandidates {
            guard let selected = resolvedChain(for: candidate, mesh: mesh, hit: localHit, node: node) else {
                continue
            }
            guard isDownloadable(
                selection: selected,
                mesh: mesh,
                relaxation: 1.0,
                mode: edgeSelectionMode
            ) else {
                continue
            }

            NSLog(
                "Selection accepted local edge=(%ld,%ld) distance=%.4f chainKind=%@ points=%ld",
                selected.edgeSnap.selectedEdge.a,
                selected.edgeSnap.selectedEdge.b,
                selected.edgeSnap.distance,
                selected.chainKind,
                selected.chainWorldPoints.count
            )
            return selected
        }

        return nil
    }

    private func resolveBestDownloadSelection(
        from candidates: [EdgeSnap],
        mesh: MeshTopology,
        hit: SCNHitTestResult,
        node: SCNNode
    ) -> EdgeSelectionCandidate? {
        resolveBestDownloadSelection(
            from: candidates,
            mesh: mesh,
            hit: hit,
            node: node,
            edgeRadius: nil,
            rayOrigin: nil,
            rayDirection: nil
        )
    }

    private func resolvedChain(
        for candidate: EdgeSnap,
        mesh: MeshTopology,
        hit: SIMD3<Float>,
        node: SCNNode
    ) -> EdgeSelectionCandidate? {
        if edgeSelectionMode == .connected {
            let selectedEdgeIsFeature = mesh.edges[candidate.selectedEdge]?.isFeatureEdge ?? false
            let componentSeed = selectedEdgeIsFeature
                ? candidate.selectedEdge
                : (mesh.nearestFeatureEdge(to: hit, maxDistance: localSelectionDistanceThreshold(for: mesh)) ?? candidate.selectedEdge)
            guard mesh.edges[componentSeed]?.isFeatureEdge == true else {
                return nil
            }

            let orderedVertices = mesh.rawVertexPath(from: componentSeed)
            if orderedVertices.count >= 2 {
                let chainPoints = orderedVertices.map { mesh.vertices[$0] }
                let worldPoints = chainPoints.map {
                    simdVector(node.convertPosition(scnVector($0), to: nil))
                }
                return EdgeSelectionCandidate(
                    edgeSnap: candidate,
                    chainWorldPoints: worldPoints,
                    chainKind: "connected edges"
                )
            }

            let worldPoints = candidate.chainPoints.map {
                simdVector(node.convertPosition(scnVector($0), to: nil))
            }
            return EdgeSelectionCandidate(edgeSnap: candidate, chainWorldPoints: worldPoints, chainKind: candidate.chainKind)
        }

        let worldPoints = candidate.chainPoints.map {
            simdVector(node.convertPosition(scnVector($0), to: nil))
        }

        let chainKind = candidate.chainKind
        return EdgeSelectionCandidate(edgeSnap: candidate, chainWorldPoints: worldPoints, chainKind: chainKind)
    }

    private func isDownloadable(
        selection: EdgeSelectionCandidate,
        mesh: MeshTopology,
        relaxation: Float,
        mode: EdgeSelectionMode
    ) -> Bool {
        let minimumPoints = max(2, Int(1.0 / max(relaxation, 0.05)))
        if selection.chainWorldPoints.count < minimumPoints {
            return false
        }

        let chainLength = polylineLength(selection.chainWorldPoints)
        let minimumLengthFloor: Float = (mode == .connected) ? 0.005 : 0.02
        let minLength = max(mesh.maxExtent * 0.0015 * relaxation, minimumLengthFloor)
        if chainLength < minLength {
            return false
        }

        return true
    }

    private func polylineLength(_ points: [SIMD3<Float>]) -> Float {
        zip(points, points.dropFirst()).reduce(Float(0)) { partial, pair in
            partial + simd_distance(pair.0, pair.1)
        }
    }

    private func nearestEdgeCandidates(for hit: SCNHitTestResult, in mesh: MeshTopology) -> [EdgeSnap] {
        let hitLocal = simdVector(hit.localCoordinates)
        guard let startTriangle = mesh.closestTriangleIndex(to: hitLocal) else {
            return []
        }

        let edgeThreshold = localSelectionDistanceThreshold(for: mesh)
        let maxVisitedTriangles = min(mesh.triangles.count, 48)
        var queue = [startTriangle]
        var cursor = 0
        var visited = Set<Int>([startTriangle])
        var candidates: [EdgeSnap] = []
        var candidateMap: [EdgeKey: Float] = [:]

        while cursor < queue.count, visited.count <= maxVisitedTriangles {
            let triangleIndex = queue[cursor]
            cursor += 1
            let triangle = mesh.triangles[triangleIndex]

            for edgeKey in triangle.edgeKeys {
                guard let edge = mesh.edges[edgeKey] else {
                    continue
                }
                let snapPoint = closestPoint(onSegmentFrom: mesh.vertices[edge.a], to: mesh.vertices[edge.b], point: hitLocal)
                let distance = simd_distance(hitLocal, snapPoint)
                guard distance <= edgeThreshold else {
                    continue
                }
                if let previousDistance = candidateMap[edgeKey], previousDistance <= distance {
                    continue
                }
                candidateMap[edgeKey] = distance
                let edgeChain = mesh.edgeChain(from: edgeKey)
                let chainPoints = edgeChain?.points ?? [mesh.vertices[edge.a], mesh.vertices[edge.b]]
                let fallbackLength = simd_distance(mesh.vertices[edge.a], mesh.vertices[edge.b])
                let chainKind = edgeChain?.kind
                    ?? String(format: "snap-only length=%.2f below-selection-min", fallbackLength)

                let edgeSnap = EdgeSnap(
                    position: snapPoint,
                    normal: edge.displayNormal,
                    distance: distance,
                    selectedTriangle: triangleIndex,
                    selectedEdge: edgeKey,
                    currentPointIsEdge: distance <= edgeThreshold,
                    isFeatureEdge: edge.isFeatureEdge,
                    visitedTriangleCount: visited.count,
                    chainPoints: chainPoints,
                    chainKind: chainKind
                )

                candidates.append(edgeSnap)
            }

            for neighbor in triangle.neighborTriangleIndices where visited.count < maxVisitedTriangles {
                if visited.insert(neighbor).inserted {
                    queue.append(neighbor)
                }
            }
        }

        NSLog(
            "Selection candidates localTriangles=%ld candidates=%ld threshold=%.4f",
            visited.count,
            candidates.count,
            edgeThreshold
        )

        let sorted = candidates.sorted { first, second in
            if edgeSelectionMode == .connected {
                if first.isFeatureEdge != second.isFeatureEdge {
                    return first.isFeatureEdge && !second.isFeatureEdge
                }
            }
            if first.currentPointIsEdge != second.currentPointIsEdge {
                return first.currentPointIsEdge && !second.currentPointIsEdge
            }
            return first.distance < second.distance
        }

        return sorted
    }

    private func localSelectionDistanceThreshold(for mesh: MeshTopology) -> Float {
        max(mesh.maxExtent * 0.03, 0.0005)
    }

    private func localSurfaceSelectionDistanceThreshold(for mesh: MeshTopology) -> Float {
        max(mesh.maxExtent * 0.00008, 0.001)
    }

    private func localSurfaceSelectionDistanceThreshold(for selectionModel: SelectionModel) -> Float {
        max(selectionModel.maxExtent * 0.00008, 0.001)
    }

    private func shouldPromoteSurfaceOver(
        selected: EdgeSelectionCandidate?,
        nearestFeatureEdgeDistance: Float?,
        surfaceCandidate: SurfaceSelectionCandidate?,
    ) -> Bool {
        guard let selected,
              let surfaceCandidate else {
            return false
        }
        guard let nearestFeatureEdgeDistance else {
            return false
        }

        if selected.edgeSnap.isFeatureEdge {
            return false
        }

        return nearestFeatureEdgeDistance > surfaceCandidate.edgePromotionThreshold
    }

    private func sanitizeFileHint(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "unknown-model"
        }
        return trimmed.replacingOccurrences(of: "/", with: "_")
    }

    private func nearestEdgeSnap(for hit: SCNHitTestResult, in mesh: MeshTopology) -> EdgeSnap? {
        let hitLocal = simdVector(hit.localCoordinates)
        guard let startTriangle = mesh.closestTriangleIndex(to: hitLocal) else {
            return nil
        }

        var queue = [startTriangle]
        var cursor = 0
        var visited = Set<Int>([startTriangle])
        var best: EdgeSnap?
        let edgeThreshold = max(mesh.maxExtent * 0.018, 0.35)

        while cursor < queue.count {
            let triangleIndex = queue[cursor]
            cursor += 1
            let triangle = mesh.triangles[triangleIndex]

            for edgeKey in triangle.edgeKeys {
                guard let edge = mesh.edges[edgeKey], edge.isFeatureEdge else {
                    continue
                }

                let snapPoint = closestPoint(onSegmentFrom: mesh.vertices[edge.a], to: mesh.vertices[edge.b], point: hitLocal)
                let distance = simd_distance(hitLocal, snapPoint)
                let edgeChain = mesh.edgeChain(from: edgeKey)
                let fallbackLength = simd_distance(mesh.vertices[edge.a], mesh.vertices[edge.b])
                let edgeSnap = EdgeSnap(
                    position: snapPoint,
                    normal: edge.displayNormal,
                    distance: distance,
                    selectedTriangle: triangleIndex,
                    selectedEdge: edgeKey,
                    currentPointIsEdge: distance <= edgeThreshold,
                    isFeatureEdge: edge.isFeatureEdge,
                    visitedTriangleCount: visited.count,
                    chainPoints: edgeChain?.points ?? [mesh.vertices[edge.a], mesh.vertices[edge.b]],
                    chainKind: edgeChain?.kind ?? String(format: "snap-only length=%.2f below-selection-min", fallbackLength)
                )

                if best == nil || distance < best!.distance {
                    best = edgeSnap
                }
            }

            if best == nil {
                for edgeKey in triangle.edgeKeys {
                    guard let edge = mesh.edges[edgeKey] else {
                        continue
                    }

                    let snapPoint = closestPoint(onSegmentFrom: mesh.vertices[edge.a], to: mesh.vertices[edge.b], point: hitLocal)
                    let distance = simd_distance(hitLocal, snapPoint)
                    let edgeChain = mesh.edgeChain(from: edgeKey)
                    let fallbackLength = simd_distance(mesh.vertices[edge.a], mesh.vertices[edge.b])
                    let edgeSnap = EdgeSnap(
                        position: snapPoint,
                        normal: edge.displayNormal,
                        distance: distance,
                        selectedTriangle: triangleIndex,
                        selectedEdge: edgeKey,
                        currentPointIsEdge: distance <= edgeThreshold,
                        isFeatureEdge: edge.isFeatureEdge,
                        visitedTriangleCount: visited.count,
                        chainPoints: edgeChain?.points ?? [mesh.vertices[edge.a], mesh.vertices[edge.b]],
                        chainKind: edgeChain?.kind ?? String(format: "snap-only length=%.2f below-selection-min", fallbackLength)
                    )

                    if best == nil || distance < best!.distance {
                        best = edgeSnap
                    }
                }
            }

            for neighbor in triangle.neighborTriangleIndices {
                guard !visited.contains(neighbor) else {
                    continue
                }
                visited.insert(neighbor)
                queue.append(neighbor)
            }
        }

        return best.map {
            EdgeSnap(
                position: $0.position,
                normal: $0.normal,
                distance: $0.distance,
                selectedTriangle: $0.selectedTriangle,
                selectedEdge: $0.selectedEdge,
                currentPointIsEdge: $0.currentPointIsEdge,
                isFeatureEdge: $0.isFeatureEdge,
                visitedTriangleCount: visited.count,
                chainPoints: $0.chainPoints,
                chainKind: $0.chainKind
            )
        }
    }

    private func closestPoint(onSegmentFrom a: SIMD3<Float>, to b: SIMD3<Float>, point: SIMD3<Float>) -> SIMD3<Float> {
        let ab = b - a
        let denominator = simd_dot(ab, ab)
        guard denominator > 0 else {
            return a
        }
        let t = max(0, min(1, simd_dot(point - a, ab) / denominator))
        return a + ab * t
    }

    private func simdVector(_ vector: SCNVector3) -> SIMD3<Float> {
        SIMD3<Float>(Float(vector.x), Float(vector.y), Float(vector.z))
    }

    private func scnVector(_ vector: SIMD3<Float>) -> SCNVector3 {
        SCNVector3(CGFloat(vector.x), CGFloat(vector.y), CGFloat(vector.z))
    }

    private func normalized(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(vector)
        guard length.isFinite, length > 0 else {
            return fallback
        }
        return vector / length
    }
}

private struct EdgeSnap {
    let position: SIMD3<Float>
    let normal: SIMD3<Float>
    let distance: Float
    let selectedTriangle: Int
    let selectedEdge: EdgeKey
    let currentPointIsEdge: Bool
    let isFeatureEdge: Bool
    let visitedTriangleCount: Int
    let chainPoints: [SIMD3<Float>]
    let chainKind: String
}

private struct EdgeSelectionCandidate {
    let edgeSnap: EdgeSnap
    let chainWorldPoints: [SIMD3<Float>]
    let chainKind: String
}

private struct SurfaceProbeRecord: Codable {
    let producedAt: String
    let modelHint: String
    let viewSize: [Float]
    let viewportPoint: [Float]
    let modifierFlags: [String]
    let resolvedKind: String
    let sceneNodeName: String?
    let hitLocalPoint: [Float]?
    let hitWorldPoint: [Float]?
    let hitLocalNormal: [Float]?
    let hitWorldNormal: [Float]?
    let seedTriangle: Int?
    let surfacePromoted: Bool
    let surfaceTriangleCount: Int
    let nearestFeatureEdgeDistance: Float?
    let nearestFeatureEdgeAcceleration: String?
    let surfacePromotionThreshold: Float?
    let edgeCandidateCount: Int
    let bestEdgeDistance: Float?
    let bestEdgeIsFeature: Bool?
    let bestEdgeCurrentPointIsEdge: Bool?
    let bestEdgeChainKind: String?
    let note: String
}

struct SurfaceOverlayTestResult {
    let applied: Bool
    let triangleCount: Int
    let nodeName: String?
}

@discardableResult
func applyAutomatedSurfaceSelectionOverlay(to scene: SCNScene) -> SurfaceOverlayTestResult {
    let selectionRootName = "__selection_debug_overlay"
    scene.rootNode
        .childNode(withName: selectionRootName, recursively: false)?
        .removeFromParentNode()

    guard let cameraNode = scene.rootNode.childNode(withName: "camera", recursively: true) else {
        return SurfaceOverlayTestResult(applied: false, triangleCount: 0, nodeName: nil)
    }

    if let hit = frontmostSurfaceSeed(from: scene, cameraNode: cameraNode) {
        let triangleID = SelectionTriangleID(rawValue: hit.triangleIndex)
        let component = hit.selectionModel.surfacePatch(forTriangle: triangleID)?.triangleIDs.map(\.rawValue) ?? []
        if !component.isEmpty,
           let selectedGeometry = makeSurfaceSelectionGeometry(
            triangleIndices: component,
            selectionModel: hit.selectionModel,
            baseMaterial: hit.node.geometry?.materials.first
           ) {
            hit.node.geometry = selectedGeometry
            return SurfaceOverlayTestResult(
                applied: true,
                triangleCount: component.count,
                nodeName: hit.node.name
            )
        }
    }

    var best: (node: SCNNode, selectionModel: SelectionModel, triangles: [Int], score: Float)?

    scene.rootNode.enumerateChildNodes { node, _ in
        guard node.name != selectionRootName,
              let geometry = node.geometry,
              let selectionModel = SelectionModel(geometry: geometry) else {
            return
        }

        var visited: Set<Int> = []
        for triangle in selectionModel.triangles where !visited.contains(triangle.id.rawValue) {
            let component = selectionModel.surfacePatch(forTriangle: triangle.id)?.triangleIDs.map(\.rawValue) ?? []
            guard !component.isEmpty else {
                continue
            }
            visited.formUnion(component)

            let score = surfaceOverlayScore(
                component,
                using: node,
                selectionModel: selectionModel,
                cameraNode: cameraNode
            )
            if score > (best?.score ?? -Float.greatestFiniteMagnitude) {
                best = (node, selectionModel, component, score)
            }
        }
    }

    guard let best,
          let selectedGeometry = makeSurfaceSelectionGeometry(
            triangleIndices: best.triangles,
            selectionModel: best.selectionModel,
            baseMaterial: best.node.geometry?.materials.first
          ) else {
        return SurfaceOverlayTestResult(applied: false, triangleCount: 0, nodeName: nil)
    }

    best.node.geometry = selectedGeometry
    return SurfaceOverlayTestResult(
        applied: true,
        triangleCount: best.triangles.count,
        nodeName: best.node.name
    )
}

private func frontmostSurfaceSeed(
    from scene: SCNScene,
    cameraNode: SCNNode
) -> (node: SCNNode, selectionModel: SelectionModel, triangleIndex: Int)? {
    let origin = cameraNode.simdWorldPosition
    var direction = qlsNormalized(cameraNode.simdWorldFront, fallback: SIMD3<Float>(0, 0, -1))
    if !direction.x.isFinite || !direction.y.isFinite || !direction.z.isFinite {
        direction = qlsNormalized(-origin, fallback: SIMD3<Float>(0, 0, -1))
    }

    var best: (node: SCNNode, selectionModel: SelectionModel, triangleIndex: Int, distance: Float)?

    scene.rootNode.enumerateChildNodes { node, _ in
        guard let geometry = node.geometry,
              let selectionModel = SelectionModel(geometry: geometry) else {
            return
        }

        for triangle in selectionModel.triangles {
            let points = triangle.vertexIndices.compactMap { index -> SIMD3<Float>? in
                guard index >= 0, index < selectionModel.vertices.count else {
                    return nil
                }
                return qlsSIMD(node.convertPosition(qlsSCN(selectionModel.vertices[index]), to: nil))
            }
            guard points.count == 3,
                  let distance = rayTriangleDistance(
                    origin: origin,
                    direction: direction,
                    a: points[0],
                    b: points[1],
                    c: points[2]
                  ) else {
                continue
            }

            if distance < (best?.distance ?? Float.greatestFiniteMagnitude) {
                best = (node, selectionModel, triangle.id.rawValue, distance)
            }
        }
    }

    guard let best else {
        return nil
    }
    return (best.node, best.selectionModel, best.triangleIndex)
}

private func rayTriangleDistance(
    origin: SIMD3<Float>,
    direction: SIMD3<Float>,
    a: SIMD3<Float>,
    b: SIMD3<Float>,
    c: SIMD3<Float>
) -> Float? {
    let epsilon: Float = 0.000001
    let edge1 = b - a
    let edge2 = c - a
    let h = simd_cross(direction, edge2)
    let det = simd_dot(edge1, h)
    guard abs(det) > epsilon else {
        return nil
    }

    let invDet = 1 / det
    let s = origin - a
    let u = invDet * simd_dot(s, h)
    guard u >= 0, u <= 1 else {
        return nil
    }

    let q = simd_cross(s, edge1)
    let v = invDet * simd_dot(direction, q)
    guard v >= 0, u + v <= 1 else {
        return nil
    }

    let t = invDet * simd_dot(edge2, q)
    return t > epsilon ? t : nil
}

private func surfaceOverlayScore(
    _ triangleIndices: [Int],
    using node: SCNNode,
    selectionModel: SelectionModel,
    cameraNode: SCNNode
) -> Float {
    var area: Float = 0
    var weightedNormal = SIMD3<Float>(repeating: 0)
    var weightedCentroid = SIMD3<Float>(repeating: 0)

    for triangleIndex in triangleIndices {
        guard let triangle = selectionModel.triangle(SelectionTriangleID(rawValue: triangleIndex)) else {
            continue
        }
        let localPoints = triangle.vertexIndices.map { selectionModel.vertices[$0] }
        let worldPoints = localPoints.map {
            qlsSIMD(node.convertPosition(qlsSCN($0), to: nil))
        }
        let rawNormal = simd_cross(worldPoints[1] - worldPoints[0], worldPoints[2] - worldPoints[0])
        let triangleArea = max(simd_length(rawNormal) * 0.5, 0.0001)
        let normal = qlsNormalized(rawNormal, fallback: SIMD3<Float>(0, 1, 0))
        let centroid = (worldPoints[0] + worldPoints[1] + worldPoints[2]) / 3

        area += triangleArea
        weightedNormal += normal * triangleArea
        weightedCentroid += centroid * triangleArea
    }

    guard area > 0 else {
        return 0
    }

    let centroid = weightedCentroid / area
    let normal = qlsNormalized(weightedNormal, fallback: SIMD3<Float>(0, 1, 0))
    let cameraDirection = qlsNormalized(cameraNode.simdWorldPosition - centroid, fallback: SIMD3<Float>(0, 0, 1))
    let facing = max(abs(simd_dot(normal, cameraDirection)), 0.12)
    return area * facing
}

private func makeSurfaceSelectionGeometry(
    triangleIndices: [Int],
    selectionModel: SelectionModel,
    baseMaterial: SCNMaterial?
) -> SCNGeometry? {
    let selected = Set(triangleIndices)
    guard !selected.isEmpty else {
        return nil
    }

    var vertices: [SCNVector3] = []
    var normals: [SCNVector3] = []
    var baseIndices: [UInt32] = []
    var selectedIndices: [UInt32] = []
    vertices.reserveCapacity(selectionModel.triangles.count * 3)
    normals.reserveCapacity(selectionModel.triangles.count * 3)
    baseIndices.reserveCapacity(selectionModel.triangles.count * 3)
    selectedIndices.reserveCapacity(selected.count * 3)

    for triangle in selectionModel.triangles {
        let triangleIndex = triangle.id.rawValue
        let targetIsSelected = selected.contains(triangleIndex)
        for vertexIndex in triangle.vertexIndices {
            guard vertexIndex >= 0, vertexIndex < selectionModel.vertices.count else {
                continue
            }

            vertices.append(qlsSCN(selectionModel.vertices[vertexIndex]))
            normals.append(qlsSCN(triangle.normal))
            let index = UInt32(vertices.count - 1)
            if targetIsSelected {
                selectedIndices.append(index)
            } else {
                baseIndices.append(index)
            }
        }
    }

    guard !selectedIndices.isEmpty else {
        return nil
    }

    let vertexSource = SCNGeometrySource(vertices: vertices)
    let normalSource = SCNGeometrySource(normals: normals)
    var elements: [SCNGeometryElement] = []
    var materials: [SCNMaterial] = []

    if !baseIndices.isEmpty {
        elements.append(makeTriangleElement(indices: baseIndices))
        materials.append(copyBaseSurfaceMaterial(baseMaterial))
    }

    elements.append(makeTriangleElement(indices: selectedIndices))
    materials.append(surfaceSelectionMaterial())

    let geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: elements)
    geometry.materials = materials
    return geometry
}

private func makeTriangleElement(indices: [UInt32]) -> SCNGeometryElement {
    SCNGeometryElement(
        data: indices.withUnsafeBytes { Data($0) },
        primitiveType: .triangles,
        primitiveCount: indices.count / 3,
        bytesPerIndex: MemoryLayout<UInt32>.size
    )
}

private func copyBaseSurfaceMaterial(_ material: SCNMaterial?) -> SCNMaterial {
    if let copy = material?.copy() as? SCNMaterial {
        return copy
    }

    let fallback = SCNMaterial()
    fallback.diffuse.contents = NSColor(calibratedWhite: 0.82, alpha: 1.0)
    fallback.lightingModel = .physicallyBased
    return fallback
}

private func makeSurfaceOverlayNode(
    triangleIndices: [Int],
    using node: SCNNode,
    mesh: MeshTopology,
    cameraNode: SCNNode
) -> SCNNode? {
    guard !triangleIndices.isEmpty else {
        return nil
    }

    var vertices: [SCNVector3] = []
    var indices: [UInt32] = []
    vertices.reserveCapacity(triangleIndices.count * 3)
    indices.reserveCapacity(triangleIndices.count * 3)

    for triangleIndex in triangleIndices {
        guard triangleIndex >= 0, triangleIndex < mesh.triangles.count else {
            continue
        }

        let triangle = mesh.triangles[triangleIndex]
        let localCentroid = mesh.triangleCentroid(triangle)
        let worldCentroid = qlsSIMD(node.convertPosition(qlsSCN(localCentroid), to: nil))
        let liftDirection = qlsNormalized(
            cameraNode.simdWorldPosition - worldCentroid,
            fallback: SIMD3<Float>(0, 1, 0)
        )
        let lift = max(mesh.maxExtent * 0.00045, 0.05)

        for vertexIndex in triangle.indices {
            guard vertexIndex >= 0, vertexIndex < mesh.vertices.count else {
                continue
            }

            let localPoint = mesh.vertices[vertexIndex]
            let worldPoint = qlsSIMD(node.convertPosition(qlsSCN(localPoint), to: nil)) + liftDirection * lift
            vertices.append(qlsSCN(worldPoint))
            indices.append(UInt32(vertices.count - 1))
        }
    }

    guard vertices.count >= 3, indices.count >= 3 else {
        return nil
    }

    let source = SCNGeometrySource(vertices: vertices)
    let element = SCNGeometryElement(
        data: indices.withUnsafeBytes { Data($0) },
        primitiveType: .triangles,
        primitiveCount: indices.count / 3,
        bytesPerIndex: MemoryLayout<UInt32>.size
    )
    let geometry = SCNGeometry(sources: [source], elements: [element])
    geometry.materials = [surfaceSelectionMaterial()]

    let surfaceNode = SCNNode(geometry: geometry)
    surfaceNode.name = "selection-surface"
    surfaceNode.renderingOrder = 40
    return surfaceNode
}

private func surfaceSelectionMaterial() -> SCNMaterial {
    let material = SCNMaterial()
    let color = NSColor(calibratedRed: 1.0, green: 0.38, blue: 0.0, alpha: 1.0)
    material.lightingModel = .constant
    material.diffuse.contents = color
    material.emission.contents = color
    material.transparency = 1.0
    material.blendMode = .replace
    material.isDoubleSided = true
    material.readsFromDepthBuffer = true
    material.writesToDepthBuffer = true
    return material
}

private func qlsSIMD(_ vector: SCNVector3) -> SIMD3<Float> {
    SIMD3<Float>(Float(vector.x), Float(vector.y), Float(vector.z))
}

private func qlsSCN(_ vector: SIMD3<Float>) -> SCNVector3 {
    SCNVector3(CGFloat(vector.x), CGFloat(vector.y), CGFloat(vector.z))
}

private func qlsNormalized(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
    let length = simd_length(vector)
    guard length.isFinite, length > 0 else {
        return fallback
    }
    return vector / length
}

private enum ResolvedSelection {
    case edge(hit: SCNHitTestResult, selection: EdgeSelectionCandidate)
    case surface(hit: SCNHitTestResult, selection: SurfaceSelectionCandidate)
}

private struct SurfaceSelectionCandidate {
    let seedTriangle: Int
    let triangleIndices: [Int]
    let nearestFeatureEdgeDistance: Float
    let nearestFeatureEdgeAcceleration: String
    let edgePromotionThreshold: Float
}

struct EdgeSelectionDownload: Codable {
    let producedAt: String
    let detectionVersion: String
    let selectedEdge: [Int]
    let chainKind: String
    let chainPoints: [[Float]]
    let shapeDetection: EdgeShapeDetectionDownload
    let hitWorldPoint: [Float]
    let snappedPoint: [Float]
    let snappedWorldPoint: [Float]
    let snapDistance: Float
    let isExactEdge: Bool
    let selectedTriangle: Int
    let visitedTriangles: Int
}

struct EdgeShapeDetectionDownload: Codable {
    let rawOrderShape: String
    let detectedShape: String
    let sequence: [String]
    let segments: [EdgeShapeSegmentDownload]
}

struct EdgeShapeSegmentDownload: Codable {
    let kind: String
    let pointCount: Int
    let length: Float
    let lineMaxResidual: Float?
    let circleRadius: Float?
    let circleMaxResidual: Float?
    let coverageDegrees: Float?
}

private enum EdgeShapeDetector {
    static func analyze(points rawPoints: [SIMD3<Float>]) -> EdgeShapeDetectionDownload {
        let points = dedupe(rawPoints)
        guard points.count >= 2 else {
            return EdgeShapeDetectionDownload(
                rawOrderShape: "unknown",
                detectedShape: "unknown",
                sequence: ["unknown"],
                segments: []
            )
        }

        let ordered = orderedClosedLoop(points)
        let rawLength = closedLength(points)
        let orderedLength = closedLength(ordered)
        let rawOrderShape = rawLength > orderedLength * 3 ? "fragmented" : "ordered"
        let segments = capsuleSegments(ordered) ?? extrudedSemicircleSegments(ordered) ?? fallbackSegments(ordered)
        let sequence = segments.map(\.kind)
        let detectedShape: String
        if sequence.count == 1 {
            detectedShape = sequence[0]
        } else {
            detectedShape = sequence.joined(separator: " -> ")
        }

        return EdgeShapeDetectionDownload(
            rawOrderShape: rawOrderShape,
            detectedShape: detectedShape,
            sequence: sequence,
            segments: segments
        )
    }

    static func selectedPrimitivePoints(
        points rawPoints: [SIMD3<Float>],
        nearest snappedPoint: SIMD3<Float>
    ) -> [SIMD3<Float>]? {
        guard let capsule = capsulePrimitiveGroups(rawPoints) ?? extrudedSemicirclePrimitiveGroups(rawPoints),
              capsule.map(\.kind) == ["line", "semicircle", "line", "semicircle"] else {
            return nil
        }

        let selected = capsule.min { lhs, rhs in
            lhs.distance(to: snappedPoint) < rhs.distance(to: snappedPoint)
        }
        guard let points = selected?.points, points.count >= 2 else {
            return nil
        }
        return points
    }

    private static func capsuleSegments(_ points: [SIMD3<Float>]) -> [EdgeShapeSegmentDownload]? {
        capsulePrimitiveGroups(points)?.map(\.download)
    }

    private static func extrudedSemicircleSegments(_ points: [SIMD3<Float>]) -> [EdgeShapeSegmentDownload]? {
        extrudedSemicirclePrimitiveGroups(points)?.map(\.download)
    }

    private struct PrimitiveGroup {
        let kind: String
        let points: [SIMD3<Float>]
        let download: EdgeShapeSegmentDownload

        func distance(to point: SIMD3<Float>) -> Float {
            guard points.count >= 2 else {
                return points.first.map { simd_distance($0, point) } ?? .greatestFiniteMagnitude
            }

            var best = Float.greatestFiniteMagnitude
            for pair in zip(points, points.dropFirst()) {
                best = min(best, distanceToSegment(point, pair.0, pair.1))
            }
            return best
        }
    }

    private struct CapsulePoint {
        let world: SIMD3<Float>
        let coord: SIMD2<Float>
    }

    private enum CoordinateAxis: CaseIterable {
        case x
        case y
        case z
    }

    private static func capsulePrimitiveGroups(_ rawPoints: [SIMD3<Float>]) -> [PrimitiveGroup]? {
        let points = orderedClosedLoop(dedupe(rawPoints))
        guard points.count >= 12 else { return nil }

        let basis = planeBasis(for: points)
        let projected = project(points, onto: basis)
        let axes = pcaAxes(projected)
        let capsulePoints = zip(points, projected).map { pair -> CapsulePoint in
            let point = pair.1
            let relative = point - axes.centroid
            let coord = SIMD2<Float>(simd_dot(relative, axes.major), simd_dot(relative, axes.minor))
            return CapsulePoint(world: pair.0, coord: coord)
        }

        let sValues = capsulePoints.map(\.coord.x)
        let tValues = capsulePoints.map(\.coord.y)
        guard let minS = sValues.min(),
              let maxS = sValues.max(),
              let minT = tValues.min(),
              let maxT = tValues.max() else {
            return nil
        }

        let width = maxS - minS
        let height = maxT - minT
        guard height > 0.0001, width > height * 2.4 else {
            return nil
        }

        let radius = height / 2
        let centerT = (minT + maxT) / 2
        let leftCenterS = minS + radius
        let rightCenterS = maxS - radius

        var topPoints: [CapsulePoint] = []
        var bottomPoints: [CapsulePoint] = []
        var leftCapPoints: [CapsulePoint] = []
        var rightCapPoints: [CapsulePoint] = []

        for cp in capsulePoints {
            let s = cp.coord.x
            let t = cp.coord.y
            let yDistTop = abs(t - maxT)
            let yDistBottom = abs(t - minT)
            let xDistLeft = abs(s - leftCenterS)
            let xDistRight = abs(s - rightCenterS)

            let railScale = height
            let capScale = width * 1.5

            let scores: [(zone: String, score: Float)] = [
                ("top", yDistTop / railScale),
                ("bottom", yDistBottom / railScale),
                ("left", xDistLeft / capScale),
                ("right", xDistRight / capScale),
            ]
            guard let best = scores.min(by: { $0.score < $1.score }) else {
                continue
            }
            switch best.zone {
            case "top": topPoints.append(cp)
            case "bottom": bottomPoints.append(cp)
            case "left": leftCapPoints.append(cp)
            case "right": rightCapPoints.append(cp)
            default: break
            }
        }

        guard topPoints.count >= 2,
              bottomPoints.count >= 2,
              leftCapPoints.count >= 6,
              rightCapPoints.count >= 6 else {
            return nil
        }

        let topLine = lineGroup(points: topPoints, targetT: maxT, ascending: true)
        let right = capGroup(points: rightCapPoints, center: SIMD2<Float>(rightCenterS, centerT), radius: radius)
        let bottomLine = lineGroup(points: bottomPoints, targetT: minT, ascending: false)
        let left = capGroup(points: leftCapPoints, center: SIMD2<Float>(leftCenterS, centerT), radius: radius)

        guard right.kind == "semicircle", left.kind == "semicircle" else {
            return nil
        }

        let correctedRight = PrimitiveGroup(
            kind: right.kind,
            points: [topLine.points.last!] + right.points + [bottomLine.points.first!],
            download: right.download
        )
        let correctedLeft = PrimitiveGroup(
            kind: left.kind,
            points: [bottomLine.points.last!] + left.points + [topLine.points.first!],
            download: left.download
        )
        return [topLine, correctedRight, bottomLine, correctedLeft]
    }

    private static func extrudedSemicirclePrimitiveGroups(_ rawPoints: [SIMD3<Float>]) -> [PrimitiveGroup]? {
        let points = dedupe(rawPoints)
        guard points.count >= 12 else { return nil }

        for axis in CoordinateAxis.allCases {
            let values = points.map { coordinate($0, axis: axis) }
            guard let minValue = values.min(), let maxValue = values.max() else {
                continue
            }

            let range = maxValue - minValue
            guard range > 0.0001 else {
                continue
            }

            let levelTolerance = max(range * 0.02, 0.01)
            var lower: [SIMD3<Float>] = []
            var upper: [SIMD3<Float>] = []
            var middleCount = 0

            for point in points {
                let value = coordinate(point, axis: axis)
                if abs(value - minValue) <= levelTolerance {
                    lower.append(point)
                } else if abs(value - maxValue) <= levelTolerance {
                    upper.append(point)
                } else {
                    middleCount += 1
                }
            }

            guard middleCount == 0,
                  lower.count >= 6,
                  upper.count >= 6 else {
                continue
            }

            guard let lowerArc = semicircleRailGroup(points: lower, axis: axis),
                  let upperArc = semicircleRailGroup(points: upper, axis: axis) else {
                continue
            }

            let lowerStart = lowerArc.points.first ?? lower[0]
            let lowerEnd = lowerArc.points.last ?? lower[lower.count - 1]
            let upperStart = upperArc.points.first ?? upper[0]
            let upperEnd = upperArc.points.last ?? upper[upper.count - 1]

            let alignedDistance = simd_distance(lowerStart, upperStart) + simd_distance(lowerEnd, upperEnd)
            let crossedDistance = simd_distance(lowerStart, upperEnd) + simd_distance(lowerEnd, upperStart)
            let firstLine: PrimitiveGroup
            let secondLine: PrimitiveGroup
            let orderedUpperArc: PrimitiveGroup

            if alignedDistance <= crossedDistance {
                firstLine = connectorLineGroup(lowerStart, upperStart)
                secondLine = connectorLineGroup(upperEnd, lowerEnd)
                orderedUpperArc = upperArc
            } else {
                firstLine = connectorLineGroup(lowerStart, upperEnd)
                secondLine = connectorLineGroup(upperStart, lowerEnd)
                orderedUpperArc = PrimitiveGroup(
                    kind: upperArc.kind,
                    points: upperArc.points.reversed(),
                    download: upperArc.download
                )
            }

            return [firstLine, orderedUpperArc, secondLine, lowerArc]
        }

        return nil
    }

    private static func fallbackSegments(_ points: [SIMD3<Float>]) -> [EdgeShapeSegmentDownload] {
        let line = lineFit(points)
        let extent = max(line.length, 0.0001)
        if line.maxResidual <= max(extent * 0.02, 0.75) {
            return [
                EdgeShapeSegmentDownload(
                    kind: "line",
                    pointCount: points.count,
                    length: line.length,
                    lineMaxResidual: line.maxResidual,
                    circleRadius: nil,
                    circleMaxResidual: nil,
                    coverageDegrees: nil
                )
            ]
        }

        guard points.count >= 6 else {
            return polygonLineSegments(points)
        }

        let basis = planeBasis(for: points)
        let circle = circleFit(project(points, onto: basis))
        if circle.maxResidual > max(circle.radius * 0.08, extent * 0.03, 0.75) {
            return polygonLineSegments(points)
        }

        let kind: String
        if circle.coverageDegrees >= 140 && circle.coverageDegrees <= 225 {
            kind = "semicircle"
        } else if circle.coverageDegrees > 325 {
            kind = "circle"
        } else if circle.coverageDegrees >= 25 {
            kind = "arc"
        } else {
            kind = "fragmented"
        }

        return [
            EdgeShapeSegmentDownload(
                kind: kind,
                pointCount: points.count,
                length: openLength(points),
                lineMaxResidual: nil,
                circleRadius: circle.radius,
                circleMaxResidual: circle.maxResidual,
                coverageDegrees: circle.coverageDegrees
            )
        ]
    }

    private static func polygonLineSegments(_ points: [SIMD3<Float>]) -> [EdgeShapeSegmentDownload] {
        guard points.count >= 2 else { return [] }

        var segments: [EdgeShapeSegmentDownload] = []
        segments.reserveCapacity(points.count)
        for index in 0..<points.count {
            let nextIndex = (index + 1) % points.count
            let start = points[index]
            let end = points[nextIndex]
            let length = simd_distance(start, end)
            guard length > 0.000001 else {
                continue
            }
            segments.append(
                EdgeShapeSegmentDownload(
                    kind: "line-segment",
                    pointCount: 2,
                    length: length,
                    lineMaxResidual: 0,
                    circleRadius: nil,
                    circleMaxResidual: nil,
                    coverageDegrees: nil
                )
            )
        }
        return segments
    }

    private static func lineGroup(
        points: [CapsulePoint],
        targetT: Float,
        ascending: Bool
    ) -> PrimitiveGroup {
        let sorted = points.sorted {
            ascending ? $0.coord.x < $1.coord.x : $0.coord.x > $1.coord.x
        }
        let coords = sorted.map(\.coord)
        let length = max(0, (coords.map(\.x).max() ?? 0) - (coords.map(\.x).min() ?? 0))
        let residual = coords.map { abs($0.y - targetT) }.max() ?? 0
        let download = EdgeShapeSegmentDownload(
            kind: "line",
            pointCount: points.count,
            length: length,
            lineMaxResidual: residual,
            circleRadius: nil,
            circleMaxResidual: nil,
            coverageDegrees: nil
        )
        return PrimitiveGroup(kind: "line", points: sorted.map(\.world), download: download)
    }

    private static func semicircleRailGroup(
        points: [SIMD3<Float>],
        axis: CoordinateAxis
    ) -> PrimitiveGroup? {
        let railPoints = points.map { point in
            CapsulePoint(world: point, coord: project(point, excluding: axis))
        }
        let coords = railPoints.map(\.coord)
        let fit = circleFit(coords)
        let residualLimit = max(fit.radius * 0.08, 0.05)
        guard fit.radius > 0.0001,
              fit.maxResidual <= residualLimit,
              fit.coverageDegrees >= 140,
              fit.coverageDegrees <= 220 else {
            return nil
        }

        let center = circleCenter(coords)
        let sorted = orderedByAngle(railPoints, center: center)
        let download = EdgeShapeSegmentDownload(
            kind: "semicircle",
            pointCount: sorted.count,
            length: fit.radius * fit.coverageDegrees * .pi / 180,
            lineMaxResidual: nil,
            circleRadius: fit.radius,
            circleMaxResidual: fit.maxResidual,
            coverageDegrees: fit.coverageDegrees
        )
        return PrimitiveGroup(kind: "semicircle", points: sorted.map(\.world), download: download)
    }

    private static func connectorLineGroup(_ start: SIMD3<Float>, _ end: SIMD3<Float>) -> PrimitiveGroup {
        let length = simd_distance(start, end)
        let download = EdgeShapeSegmentDownload(
            kind: "line",
            pointCount: 2,
            length: length,
            lineMaxResidual: 0,
            circleRadius: nil,
            circleMaxResidual: nil,
            coverageDegrees: nil
        )
        return PrimitiveGroup(kind: "line", points: [start, end], download: download)
    }

    private static func capGroup(
        points: [CapsulePoint],
        center: SIMD2<Float>,
        radius: Float
    ) -> PrimitiveGroup {
        let sorted = orderedByAngle(points, center: center)
        let coords = sorted.map(\.coord)
        let residual = coords.map { abs(simd_distance($0, center) - radius) }.max() ?? 0
        let coverage = angularCoverageDegrees(coords, center: center)
        let kind = coverage >= 140 && coverage <= 220 ? "semicircle" : "arc"
        let download = EdgeShapeSegmentDownload(
            kind: kind,
            pointCount: points.count,
            length: radius * coverage * .pi / 180,
            lineMaxResidual: nil,
            circleRadius: radius,
            circleMaxResidual: residual,
            coverageDegrees: coverage
        )
        return PrimitiveGroup(kind: kind, points: sorted.map(\.world), download: download)
    }

    private static func orderedByAngle(_ points: [CapsulePoint], center: SIMD2<Float>) -> [CapsulePoint] {
        let sorted = points.sorted {
            atan2f($0.coord.y - center.y, $0.coord.x - center.x)
                < atan2f($1.coord.y - center.y, $1.coord.x - center.x)
        }
        guard sorted.count >= 3 else { return sorted }

        let angles = sorted.map { atan2f($0.coord.y - center.y, $0.coord.x - center.x) }
        var splitIndex = 0
        var maxGap: Float = -1
        for index in 0..<angles.count {
            let nextIndex = (index + 1) % angles.count
            let nextAngle = nextIndex == 0 ? angles[0] + (2 * .pi) : angles[nextIndex]
            let gap = nextAngle - angles[index]
            if gap > maxGap {
                maxGap = gap
                splitIndex = nextIndex
            }
        }

        return Array(sorted[splitIndex...]) + Array(sorted[..<splitIndex])
    }

    private struct LineFit {
        let length: Float
        let maxResidual: Float
    }

    private struct CircleFit {
        let radius: Float
        let maxResidual: Float
        let coverageDegrees: Float
    }

    private struct PlaneBasis {
        let origin: SIMD3<Float>
        let u: SIMD3<Float>
        let v: SIMD3<Float>
    }

    private struct PCAAxes {
        let centroid: SIMD2<Float>
        let major: SIMD2<Float>
        let minor: SIMD2<Float>
    }

    private static func orderedClosedLoop(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        let basis = planeBasis(for: points)
        let projected = project(points, onto: basis)
        let centroid = projected.reduce(SIMD2<Float>(0, 0), +) / Float(max(projected.count, 1))
        return zip(points, projected)
            .sorted {
                atan2f($0.1.y - centroid.y, $0.1.x - centroid.x)
                    < atan2f($1.1.y - centroid.y, $1.1.x - centroid.x)
            }
            .map(\.0)
    }

    private static func pcaAxes(_ points: [SIMD2<Float>]) -> PCAAxes {
        let centroid = points.reduce(SIMD2<Float>(0, 0), +) / Float(max(points.count, 1))
        var xx: Float = 0
        var xy: Float = 0
        var yy: Float = 0
        for point in points {
            let centered = point - centroid
            xx += centered.x * centered.x
            xy += centered.x * centered.y
            yy += centered.y * centered.y
        }

        let angle = 0.5 * atan2f(2 * xy, xx - yy)
        let major = normalized(SIMD2<Float>(cosf(angle), sinf(angle)), fallback: SIMD2<Float>(1, 0))
        return PCAAxes(centroid: centroid, major: major, minor: SIMD2<Float>(-major.y, major.x))
    }

    private static func planeBasis(for points: [SIMD3<Float>]) -> PlaneBasis {
        let origin = points.first ?? SIMD3<Float>(0, 0, 0)
        let farthest = points.max(by: { simd_distance(origin, $0) < simd_distance(origin, $1) }) ?? origin
        let u = normalized(farthest - origin, fallback: SIMD3<Float>(1, 0, 0))
        let offAxis = points.max(by: { distanceToLine($0, origin, u) < distanceToLine($1, origin, u) }) ?? origin
        let normal = normalized(simd_cross(u, offAxis - origin), fallback: SIMD3<Float>(0, 1, 0))
        let v = normalized(simd_cross(normal, u), fallback: SIMD3<Float>(0, 0, 1))
        return PlaneBasis(origin: origin, u: u, v: v)
    }

    private static func project(_ points: [SIMD3<Float>], onto basis: PlaneBasis) -> [SIMD2<Float>] {
        points.map { point in
            let relative = point - basis.origin
            return SIMD2<Float>(simd_dot(relative, basis.u), simd_dot(relative, basis.v))
        }
    }

    private static func lineFit(_ points: [SIMD3<Float>]) -> LineFit {
        guard points.count >= 2 else {
            return LineFit(length: 0, maxResidual: 0)
        }

        var start = points[0]
        var end = points[1]
        var length = simd_distance(start, end)
        for first in points {
            for second in points {
                let distance = simd_distance(first, second)
                if distance > length {
                    start = first
                    end = second
                    length = distance
                }
            }
        }

        let direction = normalized(end - start, fallback: SIMD3<Float>(1, 0, 0))
        return LineFit(
            length: length,
            maxResidual: points.map { distanceToLine($0, start, direction) }.max() ?? 0
        )
    }

    private static func circleFit(_ points: [SIMD2<Float>]) -> CircleFit {
        guard points.count >= 3 else {
            return CircleFit(radius: 0, maxResidual: 0, coverageDegrees: 0)
        }

        var ata = simd_float3x3()
        var atb = SIMD3<Float>(repeating: 0)
        for point in points {
            let row = SIMD3<Float>(2 * point.x, 2 * point.y, 1)
            ata += simd_float3x3(
                SIMD3<Float>(row.x * row.x, row.x * row.y, row.x * row.z),
                SIMD3<Float>(row.y * row.x, row.y * row.y, row.y * row.z),
                SIMD3<Float>(row.z * row.x, row.z * row.y, row.z * row.z)
            )
            atb += row * (point.x * point.x + point.y * point.y)
        }

        let solution = ata.inverse * atb
        let center = SIMD2<Float>(solution.x, solution.y)
        let radius = sqrt(max(0.0001, solution.z + simd_dot(center, center)))
        let residuals = points.map { abs(simd_distance($0, center) - radius) }
        return CircleFit(
            radius: radius,
            maxResidual: residuals.max() ?? 0,
            coverageDegrees: angularCoverageDegrees(points, center: center)
        )
    }

    private static func circleCenter(_ points: [SIMD2<Float>]) -> SIMD2<Float> {
        guard points.count >= 3 else {
            return SIMD2<Float>(0, 0)
        }

        var ata = simd_float3x3()
        var atb = SIMD3<Float>(repeating: 0)
        for point in points {
            let row = SIMD3<Float>(2 * point.x, 2 * point.y, 1)
            ata += simd_float3x3(
                SIMD3<Float>(row.x * row.x, row.x * row.y, row.x * row.z),
                SIMD3<Float>(row.y * row.x, row.y * row.y, row.y * row.z),
                SIMD3<Float>(row.z * row.x, row.z * row.y, row.z * row.z)
            )
            atb += row * (point.x * point.x + point.y * point.y)
        }

        let solution = ata.inverse * atb
        return SIMD2<Float>(solution.x, solution.y)
    }

    private static func angularCoverageDegrees(_ points: [SIMD2<Float>], center: SIMD2<Float>) -> Float {
        let twoPi = Float.pi * 2
        let angles = points.map { atan2f($0.y - center.y, $0.x - center.x) }.sorted()
        guard angles.count >= 2 else { return 0 }

        var maxGap: Float = 0
        for pair in zip(angles, angles.dropFirst()) {
            maxGap = max(maxGap, pair.1 - pair.0)
        }
        maxGap = max(maxGap, (angles[0] + twoPi) - angles[angles.count - 1])
        return (twoPi - maxGap) * 180 / .pi
    }

    private static func openLength(_ points: [SIMD3<Float>]) -> Float {
        zip(points, points.dropFirst()).map(simd_distance).reduce(0, +)
    }

    private static func closedLength(_ points: [SIMD3<Float>]) -> Float {
        guard points.count >= 2 else { return 0 }
        return openLength(points) + simd_distance(points[0], points[points.count - 1])
    }

    private static func distanceToLine(_ point: SIMD3<Float>, _ linePoint: SIMD3<Float>, _ direction: SIMD3<Float>) -> Float {
        simd_length(simd_cross(point - linePoint, direction))
    }

    private static func distanceToSegment(_ point: SIMD3<Float>, _ start: SIMD3<Float>, _ end: SIMD3<Float>) -> Float {
        let segment = end - start
        let lengthSquared = simd_dot(segment, segment)
        guard lengthSquared > 0.000001 else {
            return simd_distance(point, start)
        }
        let t = min(1, max(0, simd_dot(point - start, segment) / lengthSquared))
        return simd_distance(point, start + segment * t)
    }

    private static func coordinate(_ point: SIMD3<Float>, axis: CoordinateAxis) -> Float {
        switch axis {
        case .x:
            return point.x
        case .y:
            return point.y
        case .z:
            return point.z
        }
    }

    private static func project(_ point: SIMD3<Float>, excluding axis: CoordinateAxis) -> SIMD2<Float> {
        switch axis {
        case .x:
            return SIMD2<Float>(point.y, point.z)
        case .y:
            return SIMD2<Float>(point.x, point.z)
        case .z:
            return SIMD2<Float>(point.x, point.y)
        }
    }

    private static func normalized(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(vector)
        guard length.isFinite, length > 0.000001 else { return fallback }
        return vector / length
    }

    private static func normalized(_ vector: SIMD2<Float>, fallback: SIMD2<Float>) -> SIMD2<Float> {
        let length = simd_length(vector)
        guard length.isFinite, length > 0.000001 else { return fallback }
        return vector / length
    }

    private static func dedupe(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        var result: [SIMD3<Float>] = []
        for point in points {
            if !result.contains(where: { simd_distance($0, point) < 0.00001 }) {
                result.append(point)
            }
        }
        return result
    }
}

private struct ProbeRecord: Codable {
    let producedAt: String
    let modelHint: String
    let sceneNodeName: String
    let chainKind: String
    let selectedTriangle: Int
    let selectedEdge: [Int]
    let hitLocalPoint: [Float]
    let hitWorldPoint: [Float]
    let hitWorldNormal: [Float]
    let snappedPoint: [Float]
    let snapDistance: Float
    let isExactEdge: Bool
    let visitedTriangles: Int
    let connectedFeatureVertices: [[Float]]
    let connectedFeatureSegments: [[Int]]
    let surroundingTriangles: [ProbeTriangleRecord]
}

private struct ProbeTriangleRecord: Codable {
    let indices: [Int]
    let points: [[Float]]
}

private extension SIMD3 where Scalar == Float {
    func asArray() -> [Float] {
        [x, y, z]
    }
}

private struct EdgeChain {
    let points: [SIMD3<Float>]
    let kind: String
}

private struct EdgeKey: Hashable {
    let a: Int
    let b: Int

    init(_ first: Int, _ second: Int) {
        if first < second {
            a = first
            b = second
        } else {
            a = second
            b = first
        }
    }

    func otherVertex(from vertex: Int) -> Int? {
        if vertex == a {
            return b
        }
        if vertex == b {
            return a
        }
        return nil
    }
}

private struct MeshTriangle {
    let indices: [Int]
    let normal: SIMD3<Float>
    var neighborTriangleIndices: [Int] = []

    var edgeKeys: [EdgeKey] {
        [
            EdgeKey(indices[0], indices[1]),
            EdgeKey(indices[1], indices[2]),
            EdgeKey(indices[2], indices[0]),
        ]
    }

    func localEdges(in vertices: [SIMD3<Float>]) -> [(SIMD3<Float>, SIMD3<Float>)] {
        [
            (vertices[indices[0]], vertices[indices[1]]),
            (vertices[indices[1]], vertices[indices[2]]),
            (vertices[indices[2]], vertices[indices[0]]),
        ]
    }
}

private struct MeshEdge {
    let a: Int
    let b: Int
    var triangleIndices: [Int] = []
    var displayNormal = SIMD3<Float>(0, 1, 0)
    var isFeatureEdge = false
}

private struct MeshTopology {
    let vertices: [SIMD3<Float>]
    private(set) var triangles: [MeshTriangle]
    private(set) var edges: [EdgeKey: MeshEdge]
    let maxExtent: Float
    let arcFitToleranceMultiplier: Float
    let minimumLineLengthScale: Float
    let minimumArcLengthScale: Float
    let lineDeviationDegrees: Float
    let minimumArcSweepDegrees: Float
    let arcRansacIterations: Int
    let minimumArcInlierRatio: Float
    let arcInlierGapAllowance: Int
    let minimumArcCoverage: Float

    private var minimumLineLength: Float {
        max(maxExtent * minimumLineLengthScale, 2.0)
    }

    private var minimumArcLength: Float {
        max(maxExtent * minimumArcLengthScale, 2.5)
    }

    private var minimumArcSweep: Float {
        minimumArcSweepDegrees * .pi / 180.0
    }

    init?(geometry: SCNGeometry, settings: EdgeFitSettings = .init()) {
        guard let vertexSource = geometry.sources(for: .vertex).first,
              let vertices = Self.readVertices(from: vertexSource),
              !vertices.isEmpty
        else {
            return nil
        }

        var triangles: [MeshTriangle] = []
        triangles.reserveCapacity(geometry.elements.reduce(0) { $0 + $1.primitiveCount })

        for element in geometry.elements where element.primitiveType == .triangles {
            for primitiveIndex in 0..<element.primitiveCount {
                guard
                    let i0 = Self.readIndex(from: element, at: primitiveIndex * 3),
                    let i1 = Self.readIndex(from: element, at: primitiveIndex * 3 + 1),
                    let i2 = Self.readIndex(from: element, at: primitiveIndex * 3 + 2),
                    i0 >= 0, i0 < vertices.count,
                    i1 >= 0, i1 < vertices.count,
                    i2 >= 0, i2 < vertices.count
                else {
                    continue
                }

                let normal = Self.triangleNormal(vertices[i0], vertices[i1], vertices[i2])
                triangles.append(MeshTriangle(indices: [i0, i1, i2], normal: normal))
            }
        }

        guard !triangles.isEmpty else {
            return nil
        }

        self.vertices = vertices
        self.triangles = triangles
        self.edges = [:]
        self.maxExtent = Self.maxExtent(of: vertices)
        self.arcFitToleranceMultiplier = max(settings.arcToleranceMultiplier, 1.0)
        self.minimumLineLengthScale = max(0.0005, settings.minimumLineLengthScale)
        self.minimumArcLengthScale = max(0.0005, settings.minimumArcLengthScale)
        self.lineDeviationDegrees = max(0.001, settings.lineDeviationDegrees)
        self.minimumArcSweepDegrees = max(settings.minimumArcSweepDegrees, 1.0)
        self.minimumArcCoverage = max(0.4, min(settings.minimumArcCoverage, 1.0))
        self.arcRansacIterations = min(max(settings.arcRansacIterations, 12), 240)
        self.minimumArcInlierRatio = max(0.55, min(settings.minimumArcInlierRatio, 0.99))
        self.arcInlierGapAllowance = max(0, settings.arcInlierGapAllowance)
        buildEdges()
    }

    private var minimumArcSeedPointCount: Int { 5 }

    private var minimumArcPointCount: Int {
        max(minimumArcSeedPointCount + 2, Int(maxExtent * 0.0005))
    }

    func closestTriangleIndex(to point: SIMD3<Float>) -> Int? {
        var bestIndex: Int?
        var bestDistance = Float.greatestFiniteMagnitude

        for (index, triangle) in triangles.enumerated() {
            let a = vertices[triangle.indices[0]]
            let b = vertices[triangle.indices[1]]
            let c = vertices[triangle.indices[2]]
            let distance = pointTriangleDistanceSquared(point, a, b, c)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }

        return bestIndex
    }

    func edgeChain(from seedEdge: EdgeKey) -> EdgeChain? {
        guard let seed = edges[seedEdge], !seed.triangleIndices.isEmpty else {
            return nil
        }
        if !seed.isFeatureEdge {
            return EdgeChain(
                points: [vertices[seed.a], vertices[seed.b]],
                kind: String(format: "single-edge only length=%.2f", simd_distance(vertices[seed.a], vertices[seed.b]))
            )
        }

        let incident = featureEdgesByVertex()
        let rawPath = rawFeaturePath(from: seedEdge, incident: incident)

        if let line = fittedLineSelection(in: rawPath, seedEdge: seedEdge) {
            return line
        }

        if let arc = fittedArcSelection(in: rawPath, seedEdge: seedEdge) {
            return arc
        }

        if let spline = fittedSplineSelection(in: rawPath) {
            return spline
        }

        return nil
    }

    func connectedFeatureEdgeComponent(startingFrom seedEdge: EdgeKey) -> Set<EdgeKey> {
        guard let seed = edges[seedEdge], seed.isFeatureEdge else {
            return []
        }

        var component: Set<EdgeKey> = []
        var queue: [EdgeKey] = [seedEdge]
        var visitedEdges: Set<EdgeKey> = []
        let incident = featureEdgesByVertex()

        while let edgeKey = queue.popLast() {
            guard visitedEdges.insert(edgeKey).inserted else {
                continue
            }
            guard let edge = edges[edgeKey], edge.isFeatureEdge else {
                continue
            }
            component.insert(edgeKey)
            let neighbors = incident[edge.a, default: []] + incident[edge.b, default: []]
            for next in neighbors where !visitedEdges.contains(next) {
                if let candidate = edges[next], candidate.isFeatureEdge {
                    queue.append(next)
                }
            }
        }
        return component
    }

    func connectedFeatureVertices(componentEdges: Set<EdgeKey>) -> [[Float]]? {
        var outputVertices: [SIMD3<Float>] = []
        var seen: Set<Int> = []

        for edgeKey in componentEdges {
            if !seen.contains(edgeKey.a) {
                seen.insert(edgeKey.a)
                outputVertices.append(vertices[edgeKey.a])
            }
            if !seen.contains(edgeKey.b) {
                seen.insert(edgeKey.b)
                outputVertices.append(vertices[edgeKey.b])
            }
        }

        guard !outputVertices.isEmpty else {
            return nil
        }
        return outputVertices.map { [$0.x, $0.y, $0.z] }
    }

    func connectedFeatureSegments(componentEdges: Set<EdgeKey>) -> [[Int]]? {
        guard !componentEdges.isEmpty else {
            return nil
        }
        var orderedSegments: [[Int]] = []
        orderedSegments.reserveCapacity(componentEdges.count)
        for edgeKey in componentEdges {
            orderedSegments.append([edgeKey.a, edgeKey.b])
        }
        return orderedSegments
    }

    func nearestFeatureEdge(to point: SIMD3<Float>, maxDistance: Float = .greatestFiniteMagnitude) -> EdgeKey? {
        var bestEdge: EdgeKey?
        var bestDistance = Float.greatestFiniteMagnitude

        for (edgeKey, edge) in edges where edge.isFeatureEdge {
            let start = vertices[edge.a]
            let end = vertices[edge.b]
            let ab = end - start
            let denominator = simd_dot(ab, ab)
            let t = denominator > 0 ? max(0, min(1, simd_dot(point - start, ab) / denominator)) : 0
            let projected = start + ab * t
            let distance = simd_distance(point, projected)
            if distance < bestDistance {
                bestDistance = distance
                bestEdge = edgeKey
            }
        }

        guard bestDistance <= maxDistance else {
            return nil
        }
        return bestEdge
    }

    func nearestFeatureEdgeDistance(to point: SIMD3<Float>) -> Float {
        var bestDistance = Float.greatestFiniteMagnitude

        for edge in geometricFeatureEdges() {
            let start = edge.start
            let end = edge.end
            let ab = end - start
            let denominator = simd_dot(ab, ab)
            let t = denominator > 0 ? max(0, min(1, simd_dot(point - start, ab) / denominator)) : 0
            let projected = start + ab * t
            bestDistance = min(bestDistance, simd_distance(point, projected))
        }

        return bestDistance
    }

    func connectedSurfaceTriangles(startingFrom seedTriangle: Int) -> [Int] {
        guard seedTriangle >= 0, seedTriangle < triangles.count else {
            return []
        }

        var result: [Int] = []
        var queue = [seedTriangle]
        var cursor = 0
        var visited = Set<Int>([seedTriangle])
        let geometricEdges = geometricEdgeBuckets()

        while cursor < queue.count {
            let triangleIndex = queue[cursor]
            cursor += 1
            result.append(triangleIndex)

            let triangle = triangles[triangleIndex]
            for localEdge in triangle.localEdges(in: vertices) {
                let key = geometricEdgeKey(from: localEdge.0, to: localEdge.1)
                guard let entries = geometricEdges[key],
                      !isGeometricFeatureEdge(entries)
                else {
                    continue
                }

                for entry in entries where entry.triangleIndex != triangleIndex {
                    let neighbor = entry.triangleIndex
                    if visited.insert(neighbor).inserted {
                        queue.append(neighbor)
                    }
                }
            }
        }

        return result
    }

    func inferredSurfaceTriangles(startingFrom seedTriangle: Int) -> [Int] {
        let smoothPatch = smoothSurfacePatchTriangles(startingFrom: seedTriangle)
        guard !smoothPatch.isEmpty else {
            return []
        }

        return smoothPatch
    }

    private func smoothSurfacePatchTriangles(startingFrom seedTriangle: Int) -> [Int] {
        guard seedTriangle >= 0, seedTriangle < triangles.count else {
            return []
        }

        var result: [Int] = []
        var queue = [seedTriangle]
        var cursor = 0
        var visited = Set<Int>([seedTriangle])
        let geometricEdges = geometricEdgeBuckets()

        while cursor < queue.count {
            let triangleIndex = queue[cursor]
            cursor += 1
            result.append(triangleIndex)

            let triangle = triangles[triangleIndex]
            for localEdge in triangle.localEdges(in: vertices) {
                let key = geometricEdgeKey(from: localEdge.0, to: localEdge.1)
                guard let entries = geometricEdges[key],
                      !isGeometricBoundaryEdge(entries, creaseDegrees: 65.0)
                else {
                    continue
                }

                for entry in entries where entry.triangleIndex != triangleIndex {
                    let neighbor = entry.triangleIndex
                    if visited.insert(neighbor).inserted {
                        queue.append(neighbor)
                    }
                }
            }
        }

        return result
    }

    private func isPlanarSurface(triangleIndices: [Int], seedTriangle: Int) -> Bool {
        guard seedTriangle >= 0, seedTriangle < triangles.count else {
            return false
        }

        let seed = triangles[seedTriangle]
        let seedNormal = seed.normal
        let seedPoint = vertices[seed.indices[0]]
        let normalDotLimit = cosf(7.0 * .pi / 180.0)
        let planeTolerance = surfacePlaneTolerance

        for triangleIndex in triangleIndices {
            guard triangleIndex >= 0, triangleIndex < triangles.count else {
                continue
            }

            let triangle = triangles[triangleIndex]
            guard simd_dot(seedNormal, triangle.normal) >= normalDotLimit else {
                return false
            }

            for vertexIndex in triangle.indices {
                let distance = abs(simd_dot(vertices[vertexIndex] - seedPoint, seedNormal))
                if distance > planeTolerance {
                    return false
                }
            }
        }

        return true
    }

    private func coplanarSurfaceTriangles(matching seedTriangle: Int) -> [Int] {
        guard seedTriangle >= 0, seedTriangle < triangles.count else {
            return []
        }

        let seed = triangles[seedTriangle]
        let seedNormal = seed.normal
        let seedPoint = vertices[seed.indices[0]]
        let normalDotLimit = cosf(7.0 * .pi / 180.0)
        let planeTolerance = surfacePlaneTolerance

        var result: [Int] = []
        result.reserveCapacity(triangles.count)

        for (triangleIndex, triangle) in triangles.enumerated() {
            guard simd_dot(seedNormal, triangle.normal) >= normalDotLimit else {
                continue
            }

            let centroid = triangleCentroid(triangle)
            guard abs(simd_dot(centroid - seedPoint, seedNormal)) <= planeTolerance else {
                continue
            }

            var verticesOnPlane = true
            for vertexIndex in triangle.indices {
                let distance = abs(simd_dot(vertices[vertexIndex] - seedPoint, seedNormal))
                if distance > planeTolerance * 1.5 {
                    verticesOnPlane = false
                    break
                }
            }

            if verticesOnPlane {
                result.append(triangleIndex)
            }
        }

        return result
    }

    private var surfacePlaneTolerance: Float {
        max(maxExtent * 0.00015, 0.000001)
    }

    func triangleCentroid(_ triangle: MeshTriangle) -> SIMD3<Float> {
        (vertices[triangle.indices[0]] + vertices[triangle.indices[1]] + vertices[triangle.indices[2]]) / 3
    }

    private struct GeometricEdgeEntry {
        let triangleIndex: Int
        let start: SIMD3<Float>
        let end: SIMD3<Float>
    }

    private struct GeometricFeatureEdge {
        let start: SIMD3<Float>
        let end: SIMD3<Float>
    }

    private struct QuantizedPointKey: Hashable, Comparable {
        let x: Int64
        let y: Int64
        let z: Int64

        static func < (lhs: QuantizedPointKey, rhs: QuantizedPointKey) -> Bool {
            if lhs.x != rhs.x { return lhs.x < rhs.x }
            if lhs.y != rhs.y { return lhs.y < rhs.y }
            return lhs.z < rhs.z
        }
    }

    private struct GeometricEdgeKey: Hashable {
        let a: QuantizedPointKey
        let b: QuantizedPointKey
    }

    private func geometricFeatureEdges() -> [GeometricFeatureEdge] {
        geometricEdgeBuckets().compactMap { _, entries in
            guard let first = entries.first, isGeometricFeatureEdge(entries) else {
                return nil
            }
            return GeometricFeatureEdge(start: first.start, end: first.end)
        }
    }

    private func geometricEdgeBuckets() -> [GeometricEdgeKey: [GeometricEdgeEntry]] {
        var buckets: [GeometricEdgeKey: [GeometricEdgeEntry]] = [:]
        buckets.reserveCapacity(edges.count)

        for (triangleIndex, triangle) in triangles.enumerated() {
            for localEdge in triangle.localEdges(in: vertices) {
                let key = geometricEdgeKey(from: localEdge.0, to: localEdge.1)
                buckets[key, default: []].append(
                    GeometricEdgeEntry(
                        triangleIndex: triangleIndex,
                        start: localEdge.0,
                        end: localEdge.1
                    )
                )
            }
        }

        return buckets
    }

    private func isGeometricFeatureEdge(_ entries: [GeometricEdgeEntry]) -> Bool {
        isGeometricBoundaryEdge(entries, creaseDegrees: 25.0)
    }

    private func isGeometricBoundaryEdge(_ entries: [GeometricEdgeEntry], creaseDegrees: Float) -> Bool {
        guard entries.count >= 2 else {
            return true
        }

        let normals = entries.map { triangles[$0.triangleIndex].normal }
        let dotLimit = cosf(creaseDegrees * .pi / 180.0)
        for i in 0..<normals.count {
            for j in (i + 1)..<normals.count {
                if simd_dot(normals[i], normals[j]) < dotLimit {
                    return true
                }
            }
        }
        return false
    }

    private func geometricEdgeKey(from start: SIMD3<Float>, to end: SIMD3<Float>) -> GeometricEdgeKey {
        let first = quantizedPointKey(start)
        let second = quantizedPointKey(end)
        if second < first {
            return GeometricEdgeKey(a: second, b: first)
        }
        return GeometricEdgeKey(a: first, b: second)
    }

    private func quantizedPointKey(_ point: SIMD3<Float>) -> QuantizedPointKey {
        let tolerance = max(maxExtent * 0.00002, 0.01)
        return QuantizedPointKey(
            x: Int64((point.x / tolerance).rounded()),
            y: Int64((point.y / tolerance).rounded()),
            z: Int64((point.z / tolerance).rounded())
        )
    }

    func surroundingTriangles(for componentEdges: Set<EdgeKey>, maxTriangles: Int) -> [ProbeTriangleRecord]? {
        guard !componentEdges.isEmpty else {
            return nil
        }

        var triangleIndices: Set<Int> = []
        for edgeKey in componentEdges {
            if let edge = edges[edgeKey] {
                for index in edge.triangleIndices {
                    triangleIndices.insert(index)
                }
            }
        }

        if triangleIndices.isEmpty {
            return nil
        }

        var outputTriangles: [ProbeTriangleRecord] = []
        outputTriangles.reserveCapacity(min(maxTriangles, triangleIndices.count))

        for index in triangleIndices.prefix(maxTriangles) {
            let sourceTriangle = self.triangles[index]
            let points = sourceTriangle.indices.map { vertexIndex in
                let vertex = vertices[vertexIndex]
                return [vertex.x, vertex.y, vertex.z]
            }
            outputTriangles.append(ProbeTriangleRecord(indices: sourceTriangle.indices, points: points))
        }
        return outputTriangles.isEmpty ? nil : outputTriangles
    }

    private func rawFeaturePath(from seedEdge: EdgeKey, incident: [Int: [EdgeKey]]) -> [Int] {
        var path = [seedEdge.a, seedEdge.b]
        var visitedEdges = Set<EdgeKey>([seedEdge])
        let continuityKind = edgeContinuityKind(seedEdge)

        extendRawFeaturePath(
            &path,
            currentVertex: seedEdge.b,
            previousEdge: seedEdge,
            continuityKind: continuityKind,
            incident: incident,
            visitedEdges: &visitedEdges,
            append: true
        )
        extendRawFeaturePath(
            &path,
            currentVertex: seedEdge.a,
            previousEdge: seedEdge,
            continuityKind: continuityKind,
            incident: incident,
            visitedEdges: &visitedEdges,
            append: false
        )

        return dedupedPath(from: path)
    }

    private func extendRawFeaturePath(
        _ path: inout [Int],
        currentVertex: Int,
        previousEdge: EdgeKey,
        continuityKind: Int,
        incident: [Int: [EdgeKey]],
        visitedEdges: inout Set<EdgeKey>,
        append: Bool
    ) {
        var currentVertex = currentVertex
        var previousEdge = previousEdge

        while true {
            let candidates = (incident[currentVertex] ?? [])
                .filter { $0 != previousEdge && !visitedEdges.contains($0) }
                .filter { edgeContinuityKind($0) == continuityKind }

            guard candidates.count == 1,
                  let candidate = candidates.first,
                  let nextVertex = candidate.otherVertex(from: currentVertex)
            else {
                break
            }

            visitedEdges.insert(candidate)
            if append {
                path.append(nextVertex)
                if nextVertex == path.first {
                    break
                }
            } else {
                path.insert(nextVertex, at: 0)
                if nextVertex == path.last {
                    break
                }
            }

            previousEdge = candidate
            currentVertex = nextVertex
        }
    }

    func rawVertexPath(from seedEdge: EdgeKey) -> [Int] {
        let incident = featureEdgesByVertex()
        var path = rawFeaturePath(from: seedEdge, incident: incident)
        guard path.count >= 2 else {
            return path
        }

        if path.first != path.last {
            if path.first! > path.last! {
                path.reverse()
            }
        } else {
            let interiorCount = path.count - 1
            guard interiorCount >= 2 else {
                return path
            }
            var minVertex = path[0]
            var minIndex = 0
            for i in 0..<interiorCount {
                if path[i] < minVertex {
                    minVertex = path[i]
                    minIndex = i
                }
            }
            if minIndex > 0 {
                var rotated = Array(path[minIndex..<interiorCount])
                rotated.append(contentsOf: path[0..<minIndex])
                rotated.append(path[minIndex])
                path = rotated
            }
        }

        return path
    }

    private func fittedLineSelection(in rawPath: [Int], seedEdge: EdgeKey) -> EdgeChain? {
        guard var range = seedRange(in: rawPath, seedEdge: seedEdge) else {
            return nil
        }

        let seedDirection = Self.normalized(
            vertices[rawPath[range.upperBound]] - vertices[rawPath[range.lowerBound]],
            fallback: SIMD3<Float>(0, 1, 0)
        )

        let incidentFeatureEdges = featureEdgesByVertex()
        let directionDot = cosf(lineDeviationDegrees * .pi / 180.0)

        var grew = true
        while grew {
            grew = false

            if range.lowerBound > 0 {
                let newVertex = rawPath[range.lowerBound - 1]
                let incidentDirectionsAgree = (incidentFeatureEdges[newVertex] ?? []).allSatisfy { edgeKey in
                    guard let edge = edges[edgeKey] else { return true }
                    let other = edge.a == newVertex ? edge.b : edge.a
                    let direction = Self.normalized(vertices[other] - vertices[newVertex], fallback: SIMD3<Float>(0, 1, 0))
                    return abs(simd_dot(direction, seedDirection)) >= directionDot
                }
                if incidentDirectionsAgree {
                    let candidate = Array(rawPath[(range.lowerBound - 1)...range.upperBound]).map { vertices[$0] }
                    if isLineCandidate(points: candidate, seedDirection: seedDirection) {
                        range = (range.lowerBound - 1)...range.upperBound
                        grew = true
                    }
                }
            }

            if range.upperBound + 1 < rawPath.count {
                let newVertex = rawPath[range.upperBound + 1]
                let incidentDirectionsAgree = (incidentFeatureEdges[newVertex] ?? []).allSatisfy { edgeKey in
                    guard let edge = edges[edgeKey] else { return true }
                    let other = edge.a == newVertex ? edge.b : edge.a
                    let direction = Self.normalized(vertices[other] - vertices[newVertex], fallback: SIMD3<Float>(0, 1, 0))
                    return abs(simd_dot(direction, seedDirection)) >= directionDot
                }
                if incidentDirectionsAgree {
                    let candidate = Array(rawPath[range.lowerBound...(range.upperBound + 1)]).map { vertices[$0] }
                    if isLineCandidate(points: candidate, seedDirection: seedDirection) {
                        range = range.lowerBound...(range.upperBound + 1)
                        grew = true
                    }
                }
            }
        }

        let points = Array(rawPath[range]).map { vertices[$0] }
        let length = polylineLength(points)
        guard length >= minimumLineLength,
              isLineCandidate(points: points, seedDirection: seedDirection)
        else {
            return nil
        }

        let kind = String(format: "line length=%.2f min=%.2f", length, minimumLineLength)
        return EdgeChain(points: points, kind: kind)
    }

    private func fittedArcSelection(in rawPath: [Int], seedEdge: EdgeKey) -> EdgeChain? {
        guard var range = seedRange(in: rawPath, seedEdge: seedEdge) else {
            return nil
        }
        var seedAnchor = 0

        var grew = true
        while grew {
            grew = false

            if range.lowerBound > 0 {
                let candidatePoints = Array(rawPath[(range.lowerBound - 1)...range.upperBound]).map { vertices[$0] }
                let candidateSeedAnchor = seedAnchor + 1
                if shouldGrowArc(with: candidatePoints, seedIndex: candidateSeedAnchor) {
                    range = (range.lowerBound - 1)...range.upperBound
                    seedAnchor = candidateSeedAnchor
                    grew = true
                }
            }

            if range.upperBound + 1 < rawPath.count {
                let candidatePoints = Array(rawPath[range.lowerBound...(range.upperBound + 1)]).map { vertices[$0] }
                if shouldGrowArc(with: candidatePoints, seedIndex: seedAnchor) {
                    range = range.lowerBound...(range.upperBound + 1)
                    grew = true
                }
            }
        }

        let points = Array(rawPath[range]).map { vertices[$0] }
        let boundedSeedAnchor = min(max(seedAnchor, 0), max(points.count - 1, 0))
        guard let fit = arcFit(for: points, seedIndex: boundedSeedAnchor) else {
            return nil
        }

        let selectedRange = fit.inlierSpan
        let selectedPoints = Array(points[selectedRange])
        let length = polylineLength(selectedPoints)
        guard length >= minimumArcLength,
              fit.sweepAngle >= minimumArcSweep
        else {
            return nil
        }

        if isLineCandidate(
            points: selectedPoints,
            seedDirection: Self.normalized(selectedPoints.last! - selectedPoints.first!, fallback: SIMD3<Float>(0, 1, 0)),
            toleranceScale: 0.012
        ) {
            return nil
        }

        let kind = String(
            format: "arc length=%.2f min=%.2f radius=%.2f sweep=%.1fdeg",
            length,
            minimumArcLength,
            fit.radius,
            fit.sweepAngle * 180.0 / .pi
        )
        return EdgeChain(points: selectedPoints, kind: kind)
    }

    private func shouldGrowArc(with candidatePoints: [SIMD3<Float>], seedIndex: Int) -> Bool {
        if candidatePoints.count < 3 {
            return true
        }

        if candidatePoints.count < minimumArcSeedPointCount {
            return arcFit(for: candidatePoints, seedIndex: seedIndex) != nil
        }

        guard let fit = arcFit(for: candidatePoints, seedIndex: seedIndex) else {
            return false
        }

        if fit.sweepAngle < minimumArcSweep {
            return false
        }

        if fit.inlierRatio < minimumArcCoverage {
            return false
        }

        return fit.sweepAngle >= minimumArcSweep * 0.66
            && polylineLength(Array(candidatePoints[fit.inlierSpan])) >= minimumArcLength
    }

    private func fittedSplineSelection(in rawPath: [Int]) -> EdgeChain? {
        let points = rawPath.map { vertices[$0] }
        let length = polylineLength(points)
        guard length >= minimumLineLength,
              isPlanar(points: points)
        else {
            return nil
        }

        let kind = String(format: "spline length=%.2f min=%.2f", length, minimumLineLength)
        return EdgeChain(points: points, kind: kind)
    }

    private mutating func buildEdges() {
        for (triangleIndex, triangle) in triangles.enumerated() {
            for edgeKey in triangle.edgeKeys {
                var edge = edges[edgeKey] ?? MeshEdge(a: edgeKey.a, b: edgeKey.b)
                edge.triangleIndices.append(triangleIndex)
                edges[edgeKey] = edge
            }
        }

        for (edgeKey, edge) in edges {
            for first in edge.triangleIndices {
                for second in edge.triangleIndices where first != second {
                    if !triangles[first].neighborTriangleIndices.contains(second) {
                        triangles[first].neighborTriangleIndices.append(second)
                    }
                }
            }

            var updated = edge
            let normals = edge.triangleIndices.map { triangles[$0].normal }
            updated.displayNormal = Self.averageNormal(normals)

            if edge.triangleIndices.count == 1 {
                updated.isFeatureEdge = true
            } else if edge.triangleIndices.count >= 2 {
                var isCrease = false
                for i in 0..<normals.count {
                    for j in (i + 1)..<normals.count {
                        if simd_dot(normals[i], normals[j]) < cosf(25.0 * .pi / 180.0) {
                            isCrease = true
                        }
                    }
                }
                updated.isFeatureEdge = isCrease
            }

            edges[edgeKey] = updated
        }
    }

    private func dedupedPath(from path: [Int]) -> [Int] {
        path.reduce(into: [Int]()) { partial, vertex in
            if partial.last != vertex {
                partial.append(vertex)
            }
        }
    }

    private func seedRange(in path: [Int], seedEdge: EdgeKey) -> ClosedRange<Int>? {
        guard path.count >= 2 else {
            return nil
        }

        for index in 0..<(path.count - 1) {
            let edge = EdgeKey(path[index], path[index + 1])
            if edge == seedEdge {
                return index...(index + 1)
            }
        }
        return nil
    }

    private func isLineCandidate(points: [SIMD3<Float>], seedDirection: SIMD3<Float>, toleranceScale: Float = 0.0015) -> Bool {
        guard points.count >= 2, let first = points.first else {
            return false
        }

        let directionDot = cosf(lineDeviationDegrees * .pi / 180.0)
        let distanceTolerance = max(maxExtent * toleranceScale, 0.05)
        let seedDirection = Self.normalized(seedDirection, fallback: SIMD3<Float>(0, 1, 0))

        var previousDirection: SIMD3<Float>?
        for pair in zip(points, points.dropFirst()) {
            let segment = pair.1 - pair.0
            let length = simd_length(segment)
            guard length > max(maxExtent * 0.00001, 0.0001) else {
                continue
            }

            let segmentDirection = segment / length
            if abs(simd_dot(segmentDirection, seedDirection)) < directionDot {
                return false
            }
            if let prev = previousDirection,
               abs(simd_dot(segmentDirection, prev)) < directionDot {
                return false
            }
            previousDirection = segmentDirection
        }

        for point in points {
            let projectedLength = simd_dot(point - first, seedDirection)
            let projected = first + seedDirection * projectedLength
            if simd_distance(point, projected) > distanceTolerance {
                return false
            }
        }

        return true
    }

    private struct PlaneBasis {
        let origin: SIMD3<Float>
        let u: SIMD3<Float>
        let v: SIMD3<Float>
        let normal: SIMD3<Float>
    }

    private struct ArcFit {
        let radius: Float
        let sweepAngle: Float
        let radialResidual: Float
        let planeResidual: Float
        let inlierRatio: Float
        let inlierSpan: ClosedRange<Int>
    }

    private func arcFit(for points: [SIMD3<Float>], seedIndex: Int) -> ArcFit? {
        guard points.count >= 3,
              let basis = planeBasis(for: points)
        else {
            return nil
        }

        let projected = points.map { point -> SIMD2<Float> in
            let relative = point - basis.origin
            return SIMD2<Float>(simd_dot(relative, basis.u), simd_dot(relative, basis.v))
        }

        let inlierTolerance = max(maxExtent * 0.003, 0.05) * arcFitToleranceMultiplier
        let planeTolerance = max(maxExtent * 0.003, 0.08) * arcFitToleranceMultiplier

        guard let circle = bestCircleFit(
            from: projected,
            inlierTolerance: inlierTolerance,
            minInlierRatio: adjustedArcInlierRatio(),
            iterations: max(0, arcRansacIterations),
            minCoverage: minimumArcCoverage,
            minimumArcLength: minimumArcLength,
            seedCount: minimumArcSeedPointCount,
            seedIndex: seedIndex
        ) else {
            return nil
        }

        let radius = circle.radius
        guard radius.isFinite,
              radius > max(maxExtent * 0.002, 0.05),
              radius <= max(maxExtent * 4.0, 10.0)
        else {
            return nil
        }

        var maxPlaneResidual: Float = 0
        for point in points {
            maxPlaneResidual = max(maxPlaneResidual, abs(simd_dot(point - basis.origin, basis.normal)))
        }
        guard maxPlaneResidual <= planeTolerance else {
            return nil
        }

        let arcPoints = Array(projected[circle.inlierSpan])
        let sweep = arcSweepAngle(points: arcPoints, center: circle.center)
        guard sweep >= minimumArcSweep,
              circle.maxResidual <= max(inlierTolerance, 0.5)
        else {
            return nil
        }

        let inlierCount = circle.inlierSpan.upperBound - circle.inlierSpan.lowerBound + 1
        let inlierRatio = Float(inlierCount) / Float(points.count)
        guard inlierRatio >= minimumArcCoverage else {
            return nil
        }

        return ArcFit(
            radius: radius,
            sweepAngle: sweep,
            radialResidual: circle.maxResidual,
            planeResidual: maxPlaneResidual,
            inlierRatio: inlierRatio,
            inlierSpan: circle.inlierSpan
        )
    }

    private func adjustedArcInlierRatio() -> Float {
        let loosen = max(0.0, (arcFitToleranceMultiplier - 1.0) * 0.025)
        return max(0.58, minimumArcInlierRatio - loosen)
    }

    private func bestCircleFit(
        from projected: [SIMD2<Float>],
        inlierTolerance: Float,
        minInlierRatio: Float,
        iterations: Int,
        minCoverage: Float,
        minimumArcLength: Float,
        seedCount: Int,
        seedIndex: Int
    ) -> (center: SIMD2<Float>, radius: Float, inlierSpan: ClosedRange<Int>, maxResidual: Float)? {
        var best: (center: SIMD2<Float>, radius: Float, inlierSpan: ClosedRange<Int>, maxResidual: Float, score: Float)?

        let clampedSeed = min(max(seedIndex, 0), max(projected.count - 1, 0))

        if let deterministic = deterministicCircleFit(projected, seedIndex: clampedSeed) {
            let minCount = min(seedCount, projected.count)
            if deterministic.inlierSpan.count >= minCount {
                let spanPoints = Array(projected[deterministic.inlierSpan])
                let spanLength = polylineLength2D(spanPoints)
                if spanLength >= minimumArcLength {
                    let score = Float(deterministic.inlierSpan.upperBound - deterministic.inlierSpan.lowerBound + 1)
                    best = (
                        deterministic.center,
                        deterministic.radius,
                        deterministic.inlierSpan,
                        deterministic.maxResidual,
                        score
                    )
                }
            }

            let candidateSpanLength = Float(deterministic.inlierSpan.upperBound - deterministic.inlierSpan.lowerBound + 1)
            let candidateRatio = candidateSpanLength / Float(projected.count)
            if candidateRatio < minCoverage {
                best = nil
            }
        }

        if projected.count >= 6 && iterations > 0 {
            for _ in 0..<iterations {
                guard let sample = randomThreeIndices(count: projected.count) else {
                    continue
                }

                guard let circle = circleFromThreePoints(
                    projected[sample.0],
                    projected[sample.1],
                    projected[sample.2]
                ) else {
                    continue
                }

                let residuals = circleFitResiduals(projected, circle)
                let inlierRatio = Float(residuals.inlierCount) / Float(projected.count)
                if residuals.inlierCount < 4 || inlierRatio < minInlierRatio {
                    continue
                }

                guard let span = inlierSpan(
                    from: residuals.inliers,
                    seed: clampedSeed,
                    maxGap: arcInlierGapAllowance
                ) else {
                    continue
                }

                guard span.count >= max(seedCount, 3) else {
                    continue
                }

                let spanLength = Float(span.upperBound - span.lowerBound + 1)
                let spanRatio = spanLength / Float(projected.count)
                if spanRatio < minCoverage {
                    continue
                }

                let spanPoints = Array(projected[span])
                if polylineLength2D(spanPoints) < minimumArcLength {
                    continue
                }

                let physicalSpanLength = polylineLength2D(spanPoints)
                let score = inlierRatio * 100.0
                    + min(1.0, physicalSpanLength / max(maxExtent, 1.0)) * 100.0
                    - residuals.maxResidual * 12.0
                if let current = best, score <= current.score {
                    continue
                }

                best = (
                    circle.center,
                    circle.radius,
                    span,
                    residuals.maxResidual,
                    score
                )
            }
        }

        return best.map { (center: $0.center, radius: $0.radius, inlierSpan: $0.inlierSpan, maxResidual: $0.maxResidual) }
    }

    private func deterministicCircleFit(
        _ projected: [SIMD2<Float>],
        seedIndex: Int
    ) -> (center: SIMD2<Float>, radius: Float, inlierSpan: ClosedRange<Int>, maxResidual: Float)? {
        guard let circle = fittedCircle2D(projected) else {
            return nil
        }

        let inlierTolerance = max(maxExtent * 0.003, 0.05) * arcFitToleranceMultiplier
        let residuals = circleFitResiduals(projected, circle)
        if residuals.maxResidual > max(inlierTolerance, 0.5) {
            return nil
        }

        let inlierRatio = Float(residuals.inlierCount) / Float(projected.count)
        guard inlierRatio >= adjustedArcInlierRatio() * 0.85 else {
            return nil
        }

        guard let span = inlierSpan(
            from: residuals.inliers,
            seed: seedIndex,
            maxGap: arcInlierGapAllowance
        ) else {
            return nil
        }

        return (circle.center, circle.radius, span, residuals.maxResidual)
    }

    private struct CircleFitResiduals {
        let inliers: [Bool]
        let inlierCount: Int
        let maxResidual: Float
        let maxConsecutiveSeed: Int?
    }

    private func circleFitResiduals(_ projected: [SIMD2<Float>], _ circle: (center: SIMD2<Float>, radius: Float)) -> CircleFitResiduals {
        let tolerance = max(maxExtent * 0.003, 0.05) * arcFitToleranceMultiplier
        var inliers = [Bool](repeating: false, count: projected.count)
        var maxResidual: Float = 0
        var inlierCount = 0

        for index in projected.indices {
            let residual = abs(simd_distance(projected[index], circle.center) - circle.radius)
            if residual <= tolerance {
                inliers[index] = true
                inlierCount += 1
            }
            maxResidual = max(maxResidual, residual)
        }

        return CircleFitResiduals(
            inliers: inliers,
            inlierCount: inlierCount,
            maxResidual: maxResidual,
            maxConsecutiveSeed: longestInlierSeed(inliers)
        )
    }

    private func inlierSpan(from inliers: [Bool], seed: Int, maxGap: Int) -> ClosedRange<Int>? {
        guard !inliers.isEmpty else {
            return nil
        }

        let start = min(max(seed, 0), inliers.count - 1)
        if !inliers[start], let restored = closestInlierIndex(inliers, from: start) {
            return inlierSpan(from: inliers, seed: restored, maxGap: maxGap)
        }

        var left = start
        var right = start

        var gaps = 0
        while left > 0 {
            if inliers[left - 1] {
                left -= 1
                continue
            }
            if gaps < maxGap {
                gaps += 1
                left -= 1
                continue
            }
            break
        }

        gaps = 0
        while right + 1 < inliers.count {
            if inliers[right + 1] {
                right += 1
                continue
            }
            if gaps < maxGap {
                gaps += 1
                right += 1
                continue
            }
            break
        }

        if right <= left {
            return nil
        }
        return left...right
    }

    private func closestInlierIndex(_ inliers: [Bool], from seed: Int) -> Int? {
        for offset in 0..<inliers.count {
            let lower = seed - offset
            if lower >= 0, inliers[lower] {
                return lower
            }

            let upper = seed + offset
            if upper < inliers.count, inliers[upper] {
                return upper
            }
        }
        return nil
    }

    private func longestInlierSeed(_ inliers: [Bool]) -> Int? {
        var bestSpan = 0
        var bestSeed: Int?
        var currentStart: Int?
        var currentSpan = 0

        for index in inliers.indices {
            if inliers[index] {
                if currentStart == nil {
                    currentStart = index
                }
                currentSpan += 1
            } else if currentStart != nil {
                if currentSpan > bestSpan {
                    bestSpan = currentSpan
                    bestSeed = currentStart! + currentSpan / 2
                }
                currentStart = nil
                currentSpan = 0
            }
        }

        if let start = currentStart, currentSpan > bestSpan {
            bestSeed = start + currentSpan / 2
        }
        return bestSeed
    }

    private func randomThreeIndices(count: Int) -> (Int, Int, Int)? {
        guard count >= 3 else {
            return nil
        }

        let first = Int.random(in: 0..<count)
        var second = Int.random(in: 0..<count)
        while second == first {
            second = Int.random(in: 0..<count)
        }
        var third = Int.random(in: 0..<count)
        while third == first || third == second {
            third = Int.random(in: 0..<count)
        }
        return (first, second, third)
    }

    private func circleFromThreePoints(
        _ first: SIMD2<Float>,
        _ second: SIMD2<Float>,
        _ third: SIMD2<Float>
    ) -> (center: SIMD2<Float>, radius: Float)? {
        let d = 2 * (first.x * (second.y - third.y) + second.x * (third.y - first.y) + third.x * (first.y - second.y))
        guard abs(d) > 0.000001 else {
            return nil
        }

        let a2 = simd_dot(first, first)
        let b2 = simd_dot(second, second)
        let c2 = simd_dot(third, third)
        let ux = (a2 * (second.y - third.y) + b2 * (third.y - first.y) + c2 * (first.y - second.y)) / d
        let uy = (a2 * (third.x - second.x) + b2 * (first.x - third.x) + c2 * (second.x - first.x)) / d
        let center = SIMD2<Float>(ux, uy)
        let radius = simd_distance(center, first)
        guard radius > 0.0001 else {
            return nil
        }
        return (center, radius)
    }

    private func planeBasis(for points: [SIMD3<Float>]) -> PlaneBasis? {
        guard points.count >= 3, let origin = points.first else {
            return nil
        }

        var bestNormal = SIMD3<Float>(repeating: 0)
        var bestLength: Float = 0

        for i in 1..<(points.count - 1) {
            for j in (i + 1)..<points.count {
                let candidate = simd_cross(points[i] - origin, points[j] - origin)
                let length = simd_length(candidate)
                if length > bestLength {
                    bestLength = length
                    bestNormal = candidate
                }
            }
        }

        guard bestLength > max(maxExtent * 0.00001, 0.0001) else {
            return nil
        }

        let normal = bestNormal / bestLength
        guard let axisPoint = points.dropFirst().first(where: { simd_distance($0, origin) > max(maxExtent * 0.00001, 0.0001) }) else {
            return nil
        }

        let u = Self.normalized(axisPoint - origin, fallback: SIMD3<Float>(1, 0, 0))
        let v = Self.normalized(simd_cross(normal, u), fallback: SIMD3<Float>(0, 1, 0))
        return PlaneBasis(origin: origin, u: u, v: v, normal: normal)
    }

    private func fittedCircle2D(_ points: [SIMD2<Float>]) -> (center: SIMD2<Float>, radius: Float)? {
        var xx: Float = 0
        var xy: Float = 0
        var x: Float = 0
        var yy: Float = 0
        var y: Float = 0
        var xr: Float = 0
        var yr: Float = 0
        var r: Float = 0

        for point in points {
            let radiusSquared = point.x * point.x + point.y * point.y
            xx += point.x * point.x
            xy += point.x * point.y
            x += point.x
            yy += point.y * point.y
            y += point.y
            xr += point.x * radiusSquared
            yr += point.y * radiusSquared
            r += radiusSquared
        }

        let matrix: [[Float]] = [
            [xx, xy, x],
            [xy, yy, y],
            [x, y, Float(points.count)],
        ]
        let vector = [-xr, -yr, -r]
        guard let solution = solve3x3(matrix, vector) else {
            return nil
        }

        let center = SIMD2<Float>(-solution.x * 0.5, -solution.y * 0.5)
        let radiusSquared = simd_length_squared(center) - solution.z
        guard radiusSquared > 0 else {
            return nil
        }

        return (center, sqrtf(radiusSquared))
    }

    private func solve3x3(_ matrix: [[Float]], _ vector: [Float]) -> SIMD3<Float>? {
        var rows = [
            [matrix[0][0], matrix[0][1], matrix[0][2], vector[0]],
            [matrix[1][0], matrix[1][1], matrix[1][2], vector[1]],
            [matrix[2][0], matrix[2][1], matrix[2][2], vector[2]],
        ]

        for column in 0..<3 {
            var pivot = column
            for row in column..<3 where abs(rows[row][column]) > abs(rows[pivot][column]) {
                pivot = row
            }

            guard abs(rows[pivot][column]) > 0.000001 else {
                return nil
            }

            if pivot != column {
                rows.swapAt(pivot, column)
            }

            let divisor = rows[column][column]
            for index in column...3 {
                rows[column][index] /= divisor
            }

            for row in 0..<3 where row != column {
                let factor = rows[row][column]
                for index in column...3 {
                    rows[row][index] -= factor * rows[column][index]
                }
            }
        }

        return SIMD3<Float>(rows[0][3], rows[1][3], rows[2][3])
    }

    private func arcSweepAngle(points: [SIMD2<Float>], center: SIMD2<Float>) -> Float {
        guard points.count >= 2 else {
            return 0
        }

        let angles = points.map { atan2f($0.y - center.y, $0.x - center.x) }
        var sweep: Float = 0
        for pair in zip(angles, angles.dropFirst()) {
            var delta = pair.1 - pair.0
            while delta > .pi {
                delta -= 2.0 * .pi
            }
            while delta < -.pi {
                delta += 2.0 * .pi
            }
            sweep += abs(delta)
        }
        return sweep
    }

    private func polylineLength(_ points: [SIMD3<Float>]) -> Float {
        zip(points, points.dropFirst()).reduce(Float(0)) { partial, pair in
            partial + simd_distance(pair.0, pair.1)
        }
    }

    private func polylineLength2D(_ points: [SIMD2<Float>]) -> Float {
        zip(points, points.dropFirst()).reduce(Float(0)) { partial, pair in
            partial + simd_length(pair.1 - pair.0)
        }
    }

    private func edgeContinuityKind(_ edgeKey: EdgeKey) -> Int {
        guard let edge = edges[edgeKey] else {
            return 0
        }
        return edge.triangleIndices.count == 1 ? 1 : 2
    }

    private func featureEdgesByVertex() -> [Int: [EdgeKey]] {
        var result: [Int: [EdgeKey]] = [:]
        for (edgeKey, edge) in edges where edge.isFeatureEdge {
            result[edge.a, default: []].append(edgeKey)
            result[edge.b, default: []].append(edgeKey)
        }
        return result
    }

    private func isStraight(points: [SIMD3<Float>], toleranceScale: Float = 0.006) -> Bool {
        guard points.count >= 2,
              let first = points.first,
              let last = points.last
        else {
            return false
        }

        let direction = Self.normalized(last - first, fallback: SIMD3<Float>(0, 1, 0))
        let tolerance = max(maxExtent * toleranceScale, 0.12)
        for point in points {
            let projectedLength = simd_dot(point - first, direction)
            let projected = first + direction * projectedLength
            if simd_distance(point, projected) > tolerance {
                return false
            }
        }
        return true
    }

    private func isPlanar(points: [SIMD3<Float>]) -> Bool {
        guard points.count >= 3, let origin = points.first else {
            return true
        }

        let tolerance = max(maxExtent * 0.01, 0.18)
        var planeNormal: SIMD3<Float>?

        for i in 1..<(points.count - 1) {
            let candidate = simd_cross(points[i] - origin, points[i + 1] - origin)
            if simd_length(candidate) > tolerance {
                planeNormal = Self.normalized(candidate, fallback: SIMD3<Float>(0, 1, 0))
                break
            }
        }

        guard let planeNormal else {
            return true
        }

        for point in points {
            let distance = abs(simd_dot(point - origin, planeNormal))
            if distance > tolerance {
                return false
            }
        }
        return true
    }

    private static func readVertices(from source: SCNGeometrySource) -> [SIMD3<Float>]? {
        guard source.bytesPerComponent == MemoryLayout<Float>.size,
              source.componentsPerVector >= 3
        else {
            return nil
        }

        var vertices = [SIMD3<Float>]()
        vertices.reserveCapacity(source.vectorCount)
        let stride = max(source.dataStride, source.componentsPerVector * source.bytesPerComponent)
        let offset = source.dataOffset

        let failed = source.data.withUnsafeBytes { raw -> Bool in
            guard let baseAddress = raw.baseAddress else { return true }
            for index in 0..<source.vectorCount {
                let pointer = baseAddress
                    .advanced(by: offset + index * stride)
                    .assumingMemoryBound(to: Float.self)
                let vertex = SIMD3<Float>(pointer[0], pointer[1], pointer[2])
                if !vertex.x.isFinite || !vertex.y.isFinite || !vertex.z.isFinite {
                    return true
                }
                vertices.append(vertex)
            }
            return false
        }

        return failed ? nil : vertices
    }

    private static func readIndex(from element: SCNGeometryElement, at position: Int) -> Int? {
        let bytesPerIndex = element.bytesPerIndex
        let byteOffset = position * bytesPerIndex
        guard byteOffset + bytesPerIndex <= element.data.count else {
            return nil
        }

        return element.data.withUnsafeBytes { raw -> Int? in
            guard let baseAddress = raw.baseAddress else { return nil }
            let pointer = baseAddress.advanced(by: byteOffset)
            switch bytesPerIndex {
            case 1:
                return Int(pointer.assumingMemoryBound(to: UInt8.self).pointee)
            case 2:
                return Int(pointer.assumingMemoryBound(to: UInt16.self).pointee)
            case 4:
                return Int(pointer.assumingMemoryBound(to: UInt32.self).pointee)
            default:
                return nil
            }
        }
    }

    private static func triangleNormal(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> SIMD3<Float> {
        let normal = simd_cross(b - a, c - a)
        let length = simd_length(normal)
        guard length > 0 else {
            return SIMD3<Float>(0, 1, 0)
        }
        return normal / length
    }

    private static func averageNormal(_ normals: [SIMD3<Float>]) -> SIMD3<Float> {
        let sum = normals.reduce(SIMD3<Float>(repeating: 0), +)
        let length = simd_length(sum)
        guard length > 0 else {
            return normals.first ?? SIMD3<Float>(0, 1, 0)
        }
        return sum / length
    }

    private static func normalized(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(vector)
        guard length.isFinite, length > 0 else {
            return fallback
        }
        return vector / length
    }

    private static func maxExtent(of vertices: [SIMD3<Float>]) -> Float {
        var minPoint = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var maxPoint = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)

        for vertex in vertices {
            minPoint = min(minPoint, vertex)
            maxPoint = max(maxPoint, vertex)
        }

        let size = maxPoint - minPoint
        return max(size.x, max(size.y, size.z))
    }

    private func pointTriangleDistanceSquared(
        _ point: SIMD3<Float>,
        _ a: SIMD3<Float>,
        _ b: SIMD3<Float>,
        _ c: SIMD3<Float>
    ) -> Float {
        let ab = b - a
        let ac = c - a
        let ap = point - a
        let d1 = simd_dot(ab, ap)
        let d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return simd_length_squared(ap) }

        let bp = point - b
        let d3 = simd_dot(ab, bp)
        let d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return simd_length_squared(bp) }

        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 {
            let v = d1 / (d1 - d3)
            return simd_length_squared(point - (a + v * ab))
        }

        let cp = point - c
        let d5 = simd_dot(ab, cp)
        let d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return simd_length_squared(cp) }

        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 {
            let w = d2 / (d2 - d6)
            return simd_length_squared(point - (a + w * ac))
        }

        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return simd_length_squared(point - (b + w * (c - b)))
        }

        let normal = Self.triangleNormal(a, b, c)
        let signedDistance: Float = simd_dot(point - a, normal)
        return signedDistance * signedDistance
    }
}
