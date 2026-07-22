import AppKit
import Foundation
import SceneKit
import simd

extension DebugSelectableSCNView {
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

        pendingSelectionBeforeImage = snapshot()
        return selectionController.select(
            at: point,
            event: nil,
            expectation: request.expectation,
            forceDebugEvent: true,
            modifierFlags: request.modifiers
        )
    }

    func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
        updateScreenStableHighlights()
    }

    func invalidateSelectionCaches() {
        selectionEngineCache.removeAll()
        cachedMeshSettings = edgeFitSettings
        activeSurfaceHighlight = nil
        measurementState = .empty
    }

    func selectionModel(for geometry: SCNGeometry) -> SelectionModel? {
        selectionEngine(for: geometry)?.selectionModel
    }

    func meshTopology(for geometry: SCNGeometry) -> EdgePrimitiveIndex? {
        if cachedMeshSettings != edgeFitSettings {
            selectionEngineCache.removeAll()
            cachedMeshSettings = edgeFitSettings
        }

        return selectionEngine(for: geometry)?.edgeTopology
    }

    func selectionEngine(for geometry: SCNGeometry) -> SceneSelectionEngine? {
        let key = ObjectIdentifier(geometry)
        if let cached = selectionEngineCache[key] {
            return cached
        }
        guard let engine = SceneSelectionEngine(geometry: geometry, edgeSettings: edgeFitSettings) else {
            return nil
        }
        selectionEngineCache[key] = engine
        return engine
    }

    @discardableResult
    func drawDebugSelection(
        at point: CGPoint,
        event: NSEvent? = nil,
        expectation: SelectionDebugExpectation? = nil,
        forceDebugEvent: Bool = false,
        modifierFlagsOverride: [String]? = nil
    ) -> SelectionDebugEvent? {
        let shouldWriteDebugEvent = selectionDebugMode || forceDebugEvent
        let beforeImage = shouldWriteDebugEvent ? pendingSelectionBeforeImage : nil
        pendingSelectionBeforeImage = nil
        let selectionStart = CFAbsoluteTimeGetCurrent()
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

    func drawEdgeSelection(
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

    func drawSurfaceSelection(
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

        activeSurfaceHighlight = (node: hit.node, triangleIndices: surfaceSelection.triangleIndices)
        addSurfaceOverlay(selectedGeometry, matching: hit.node, to: scene)

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

    func setMeasurementState(_ state: SelectionMeasurementState) {
        measurementState = state
        onMeasurementStateChanged?(state)
    }

    func updateMeasurementStateForNoSelection(modifiers: [String], scene: SCNScene) {
        if preservesSelection(modifiers: modifiers), !measurementState.isEmpty {
            redrawMeasurementHighlight(for: measurementState, scene: scene)
            onMeasurementStateChanged?(measurementState)
            return
        }

        activeSurfaceHighlight = nil
        setMeasurementState(.empty)
    }

    func updateMeasurementStateForEdge(
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
            let currentEdges = measurementState.entities.filter { $0.kind == .edge }
            if currentEdges.contains(where: { $0.id == entity.id }) {
                nextEdges = currentEdges.filter { $0.id != entity.id }
            } else {
                nextEdges = currentEdges + [entity]
            }
        } else if isShift {
            nextEdges = measurementState.entities.filter { $0.kind == .edge } + [entity]
        } else {
            nextEdges = [entity]
        }

        activeSurfaceHighlight = nil
        let nextState = SelectionMeasurementState.edges(nextEdges)
        setMeasurementState(nextState)
        redrawMeasurementHighlight(for: nextState, scene: scene)
    }

    func preservesSelection(modifiers: [String]) -> Bool {
        modifiers.contains("shift") || modifiers.contains("command")
    }

    func redrawMeasurementHighlight(for state: SelectionMeasurementState, scene: SCNScene) {
        clearDebugSelection(from: scene)

        switch state.kind {
        case .edge, .multiEdge:
            activeSurfaceHighlight = nil
            let edgeEntities = state.entities.filter { $0.kind == .edge && $0.simdDisplayPoints.count >= 2 }
            guard !edgeEntities.isEmpty else {
                return
            }

            let overlayRoot = SCNNode()
            overlayRoot.name = selectionRootName
            scene.rootNode.addChildNode(overlayRoot)

            for entity in edgeEntities {
                overlayRoot.addChildNode(makeEdgeChainNode(points: entity.simdDisplayPoints))
            }
            updateScreenStableHighlights()

        case .surface:
            redrawActiveSurfaceHighlight()

        case .empty:
            activeSurfaceHighlight = nil
        }
    }

    func redrawActiveSurfaceHighlight() {
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

        guard let scene else { return }
        addSurfaceOverlay(selectedGeometry, matching: activeSurfaceHighlight.node, to: scene)
    }

    func makeEdgeMeasurementEntity(
        _ resolved: EdgeSelectionCandidate,
        hit: SCNHitTestResult
    ) -> SelectionMeasurementEntity {
        let edge = resolved.edgeSnap.selectedEdge
        let scope = selectionEntityScope(for: hit.node)
        let edgeID = "\(scope):edge:\(edge.a)-\(edge.b)"
        let displayPoints = userFacingEdgePoints(for: resolved, hit: hit)
        let sourcePoints = scene.map { scene in
            displayPoints.map { SceneComposer.sourcePoint(fromScenePoint: $0, in: scene) }
        } ?? displayPoints
        let shapeDetection = EdgeShapeDetector.analyze(points: displayPoints)
        let shapeLabel = shapeDetection.detectedShape == "unknown" ? "Edge" : shapeDetection.detectedShape
        let radius = shapeDetection.segments.compactMap(\.circleRadius).first

        return SelectionMeasurementEntity(
            id: edgeID,
            kind: .edge,
            label: shapeLabel,
            sourceIDs: [
                edgeID,
                "\(scope):triangle:\(resolved.edgeSnap.selectedTriangle)",
            ],
            length: SelectionMeasurementCalculator.polylineLength(displayPoints),
            radius: radius,
            area: nil,
            perimeter: nil,
            triangleCount: nil,
            pointCount: displayPoints.count,
            shape: shapeDetection.detectedShape,
            surfaceType: nil,
            points: displayPoints.map { $0.asArray() },
            displayPoints: displayPoints.map { $0.asArray() },
            sourcePoints: sourcePoints.map { $0.asArray() }
        )
    }

    func userFacingEdgePoints(
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

    func makeSurfaceMeasurementEntity(
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
        let scope = selectionEntityScope(for: hit.node)
        let entityID = patchID.map { "\(scope):surfacePatch:\($0.rawValue)" }
            ?? "\(scope):surfaceSeed:\(surfaceSelection.seedTriangle)"
        let surfaceType = patch?.isPlanar == true ? "Planar" : "Curved"

        return SelectionMeasurementEntity(
            id: entityID,
            kind: .surface,
            label: patchID.map { "Surface \($0.rawValue)" } ?? "Surface",
            sourceIDs: [entityID, "\(scope):seedTriangle:\(surfaceSelection.seedTriangle)"],
            length: nil,
            radius: nil,
            area: measurements.area,
            perimeter: measurements.perimeter,
            triangleCount: surfaceSelection.triangleIndices.count,
            pointCount: nil,
            shape: nil,
            surfaceType: surfaceType,
            points: [],
            displayPoints: nil,
            sourcePoints: nil
        )
    }

    func selectionEntityScope(for node: SCNNode) -> String {
        var pathComponents: [String] = []
        var current: SCNNode? = node
        while let value = current, let parent = value.parent {
            let siblingIndex = parent.childNodes.firstIndex(where: { $0 === value }) ?? 0
            let name = value.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = name.flatMap { $0.isEmpty ? nil : $0 } ?? "node"
            pathComponents.append("\(siblingIndex):\(label)")
            current = parent
        }

        let source = edgeProbeModelHint.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = "\(source.isEmpty ? "unknown-model" : source)|\(pathComponents.reversed().joined(separator: "/"))"
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in identity.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "modelNode:%016llx", hash)
    }
}
