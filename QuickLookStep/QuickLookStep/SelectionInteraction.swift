import AppKit
import Foundation
import SceneKit
import simd

extension DebugSelectableSCNView {
    func performDebugHoverAt(_ request: SelectionDebugHoverAtRequest) -> HoverSelectionSnapshot? {
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
        return selectionController.previewImmediately(at: point)
    }

    func performDebugClearHover() {
        selectionController.clearPreview()
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

        pendingSelectionBeforeImage = selectionDebugScreenshotsEnabled
            ? captureSelectionDebugSnapshot()
            : nil
        return selectionController.select(
            at: point,
            event: nil,
            expectation: request.expectation,
            forceDebugEvent: true,
            modifierFlags: request.modifiers
        )
    }

    func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScreenStableHighlights()
            self.selectionController.invalidatePreviewForCameraChange()
        }
    }

    func invalidateSelectionCaches() {
        selectionIndexGeneration += 1
        selectionEngineCache.removeAll()
        pendingSelectionEngineKeys.removeAll()
        cachedMeshSettings = edgeFitSettings
        activeSurfaceHighlight = nil
        activeSurfaceHighlights.removeAll()
        measurementState = .empty
        selectionController.clearPreview()
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
        prepareSelectionIndex(for: geometry)
        return nil
    }

    func prepareSelectionIndexes() {
        guard let scene else { return }
        scene.rootNode.enumerateChildNodes { [weak self] node, _ in
            guard let self, let geometry = node.geometry, !self.isSelectionOverlay(node) else { return }
            self.prepareSelectionIndex(for: geometry)
        }
    }

    func prepareSelectionIndex(for geometry: SCNGeometry) {
        let key = ObjectIdentifier(geometry)
        guard selectionEngineCache[key] == nil,
              pendingSelectionEngineKeys.insert(key).inserted else {
            return
        }
        let generation = selectionIndexGeneration
        let settings = edgeFitSettings
        let modelIdentifier = edgeProbeModelHint
        let hints = importedTopologyHints
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak geometry] in
            guard let geometry else { return }
            let engine = SceneSelectionEngine(
                geometry: geometry,
                edgeSettings: settings,
                modelIdentifier: modelIdentifier,
                topologyHints: hints
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingSelectionEngineKeys.remove(key)
                guard self.selectionIndexGeneration == generation, let engine else { return }
                self.selectionEngineCache[key] = engine
                self.selectionController.selectionIndexDidChange()
                NSLog(
                    "Selection index ready triangles=%ld exactFaces=%ld exactEdges=%ld",
                    engine.snapshot.triangles.count,
                    hints.faces.count,
                    hints.edges.count
                )
            }
        }
    }

    @discardableResult
    func drawDebugSelection(
        at point: CGPoint,
        event: NSEvent? = nil,
        expectation: SelectionDebugExpectation? = nil,
        forceDebugEvent: Bool = false,
        modifierFlagsOverride: [String]? = nil,
        commitSource: SelectionCommitSource = .resolve
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

        let resolverStart = CFAbsoluteTimeGetCurrent()
        let resolvedSelection: ResolvedSelection?
        switch commitSource {
        case .resolve:
            resolvedSelection = resolveSelection(at: point)
        case .cached(let cached):
            resolvedSelection = cached
        }
        guard let selectionResult = resolvedSelection else {
            let resolverElapsedMs = (CFAbsoluteTimeGetCurrent() - resolverStart) * 1000
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
            let pendingDebugEvent = makeSelectionDebugEventIfNeeded(
                at: point,
                event: event,
                resolvedSelection: nil,
                elapsedMs: resolverElapsedMs,
                expectation: expectation,
                forceDebugEvent: forceDebugEvent,
                modifierFlagsOverride: modifierFlagsOverride
            )
            let debugEvent = writeSelectionDebugEvent(pendingDebugEvent, beforeImage: beforeImage)
            let totalElapsedMs = (CFAbsoluteTimeGetCurrent() - selectionStart) * 1000
            NSLog(
                "Selection ignored: no nearby downloadable edge or surface resolverMs=%.2f totalMs=%.2f",
                resolverElapsedMs,
                totalElapsedMs
            )
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

        let resolvedElapsedMs = (CFAbsoluteTimeGetCurrent() - resolverStart) * 1000
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
        case .point(let hit, let pointSelection):
            let didDraw = drawPointSelection(
                pointSelection,
                scene: scene,
                selectionStart: selectionStart
            )
            if didDraw {
                activeSurfaceHighlights.removeAll()
                setMeasurementState(.entities([makePointMeasurementEntity(pointSelection, hit: hit)]))
            } else {
                activeSurfaceHighlight = nil
                activeSurfaceHighlights.removeAll()
                setMeasurementState(.empty)
            }
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
                updateMeasurementStateForSurface(
                    measurementEntity,
                    hit: hit,
                    surfaceSelection: surfaceSelection,
                    modifiers: modifierNames,
                    scene: scene
                )
            } else if didDraw == false {
                activeSurfaceHighlight = nil
                activeSurfaceHighlights.removeAll()
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
                activeSurfaceHighlights.removeAll()
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

        if resolved.semanticEdge != nil {
            overlayRoot.addChildNode(makeEdgeChainNode(points: chainWorldPoints))
        } else if edgeSelectionMode == .connected {
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

    func setMeasurementState(
        _ state: SelectionMeasurementState,
        analyzeSurfaceRelationships: Bool = false
    ) {
        measurementAnalysisGeneration += 1
        let generation = measurementAnalysisGeneration
        measurementState = state
        onMeasurementStateChanged?(state)

        guard analyzeSurfaceRelationships,
              state.entities.count >= 2,
              state.entities.contains(where: { $0.kind == .surface }) else {
            return
        }
        let entities = state.entities
        let entityIDs = entities.map(\.id)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let analyzed = SelectionMeasurementState.entities(entities)
            DispatchQueue.main.async {
                guard let self,
                      self.measurementAnalysisGeneration == generation,
                      self.measurementState.entities.map(\.id) == entityIDs else {
                    return
                }
                self.measurementState = analyzed
                self.onMeasurementStateChanged?(analyzed)
            }
        }
    }

    func updateMeasurementStateForNoSelection(modifiers: [String], scene: SCNScene) {
        if preservesSelection(modifiers: modifiers), !measurementState.isEmpty {
            redrawMeasurementHighlight(for: measurementState, scene: scene)
            onMeasurementStateChanged?(measurementState)
            return
        }

        activeSurfaceHighlight = nil
        activeSurfaceHighlights.removeAll()
        setMeasurementState(.empty)
    }

    func updateMeasurementStateForEdge(
        _ resolved: EdgeSelectionCandidate,
        hit: SCNHitTestResult,
        modifiers: [String],
        scene: SCNScene
    ) {
        let entity = makeEdgeMeasurementEntity(resolved, hit: hit)
        activeSurfaceHighlight = nil
        if !preservesSelection(modifiers: modifiers) {
            activeSurfaceHighlights.removeAll()
        }
        let needsSurfaceAnalysis = preservesSelection(modifiers: modifiers)
            && measurementState.entities.contains(where: { $0.kind == .surface })
        let nextState = SelectionMeasurementState.updating(
            measurementState,
            with: entity,
            modifiers: modifiers,
            includeDistanceDetail: !needsSurfaceAnalysis
        )
        setMeasurementState(
            nextState,
            analyzeSurfaceRelationships: needsSurfaceAnalysis
        )
        redrawMeasurementHighlight(for: nextState, scene: scene)
    }

    func updateMeasurementStateForSurface(
        _ entity: SelectionMeasurementEntity,
        hit: SCNHitTestResult,
        surfaceSelection: SurfaceSelectionCandidate,
        modifiers: [String],
        scene: SCNScene
    ) {
        if !preservesSelection(modifiers: modifiers) {
            activeSurfaceHighlights.removeAll()
        }
        let nextState = SelectionMeasurementState.updating(
            measurementState,
            with: entity,
            modifiers: modifiers,
            includeDistanceDetail: false
        )
        if nextState.entities.contains(where: { $0.id == entity.id }) {
            activeSurfaceHighlights[entity.id] = SurfaceHighlightRecord(
                node: hit.node,
                triangleIndices: surfaceSelection.triangleIndices
            )
        } else {
            activeSurfaceHighlights.removeValue(forKey: entity.id)
        }
        activeSurfaceHighlight = nil
        setMeasurementState(nextState, analyzeSurfaceRelationships: true)
        redrawMeasurementHighlight(for: nextState, scene: scene)
    }

    func preservesSelection(modifiers: [String]) -> Bool {
        modifiers.contains("shift") || modifiers.contains("command")
    }

    func redrawMeasurementHighlight(for state: SelectionMeasurementState, scene: SCNScene) {
        clearDebugSelection(from: scene)
        guard !state.isEmpty else {
            activeSurfaceHighlight = nil
            activeSurfaceHighlights.removeAll()
            return
        }

        let edgeEntities = state.entities.filter { $0.kind == .edge && $0.simdDisplayPoints.count >= 2 }
        if !edgeEntities.isEmpty {
            let overlayRoot = SCNNode()
            overlayRoot.name = selectionRootName
            scene.rootNode.addChildNode(overlayRoot)
            for entity in edgeEntities {
                overlayRoot.addChildNode(makeEdgeChainNode(points: entity.simdDisplayPoints))
            }
            updateScreenStableHighlights()
        }

        if let pointEntity = state.entities.first(where: { $0.kind == .point }),
           let point = pointEntity.simdDisplayPoints.first {
            let overlayRoot = scene.rootNode.childNode(withName: selectionRootName, recursively: false) ?? {
                let node = SCNNode()
                node.name = selectionRootName
                scene.rootNode.addChildNode(node)
                return node
            }()
            overlayRoot.addChildNode(makeEndpointNode(at: point))
            updateScreenStableHighlights()
        }

        for entity in state.entities where entity.kind == .surface {
            redrawSurfaceHighlight(entityID: entity.id, scene: scene)
        }
    }

    func redrawSurfaceHighlight(entityID: String, scene: SCNScene) {
        guard let highlight = activeSurfaceHighlights[entityID],
              let node = highlight.node,
              let geometry = node.geometry,
              let selectionModel = selectionModel(for: geometry),
              let selectedGeometry = makeSurfaceSelectionGeometry(
                triangleIndices: highlight.triangleIndices,
                selectionModel: selectionModel,
                baseMaterial: geometry.materials.first
              ) else {
            return
        }
        addSurfaceOverlay(selectedGeometry, matching: node, to: scene)
    }

    func removeMeasurementEntity(id: String) {
        guard let scene else { return }
        activeSurfaceHighlights.removeValue(forKey: id)
        let nextState = measurementState.removing(
            entityID: id,
            includeDistanceDetail: false
        )
        setMeasurementState(nextState, analyzeSurfaceRelationships: true)
        redrawMeasurementHighlight(for: nextState, scene: scene)
    }

    func makeEdgeMeasurementEntity(
        _ resolved: EdgeSelectionCandidate,
        hit: SCNHitTestResult
    ) -> SelectionMeasurementEntity {
        let edge = resolved.edgeSnap.selectedEdge
        let scope = selectionEntityScope(for: hit.node)
        let edgeID = resolved.semanticEdge?.id.rawValue ?? "\(scope):edge:\(edge.a)-\(edge.b)"
        let displayPoints = userFacingEdgePoints(for: resolved, hit: hit)
        let sourcePoints = scene.map { scene in
            displayPoints.map { SceneComposer.sourcePoint(fromScenePoint: $0, in: scene) }
        } ?? displayPoints
        let shapeDetection = EdgeShapeDetector.analyze(points: displayPoints)
        let sourceShapeDetection = EdgeShapeDetector.analyze(points: sourcePoints)
        let semanticKind = resolved.semanticEdge?.descriptor.kind.rawValue
        let shapeLabel = semanticKind ?? (shapeDetection.detectedShape == "unknown" ? "Edge" : shapeDetection.detectedShape)
        let radius = resolved.semanticEdge?.descriptor.radius
            ?? sourceShapeDetection.segments.compactMap(\.circleRadius).first

        return SelectionMeasurementEntity(
            id: edgeID,
            kind: .edge,
            label: shapeLabel,
            sourceIDs: [
                edgeID,
                "\(scope):triangle:\(resolved.edgeSnap.selectedTriangle)",
            ],
            length: SelectionMeasurementCalculator.polylineLength(sourcePoints),
            radius: radius,
            area: nil,
            perimeter: nil,
            triangleCount: nil,
            pointCount: displayPoints.count,
            shape: semanticKind ?? shapeDetection.detectedShape,
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
        if resolved.semanticEdge != nil {
            return resolved.chainWorldPoints
        }
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

        let measurements = SelectionMeasurementCalculator.surfaceMeasurements(
            triangleIndices: surfaceSelection.triangleIndices,
            selectionModel: selectionModel,
            node: hit.node,
            scene: scene
        )
        let scope = selectionEntityScope(for: hit.node)
        let entityID = surfaceSelection.semanticSurface?.id.rawValue
            ?? "\(scope):surfaceSeed:\(surfaceSelection.seedTriangle)"
        let surfaceType = surfaceSelection.semanticSurface?.descriptor.kind.rawValue.capitalized ?? "Surface"
        let descriptor = surfaceSelection.semanticSurface?.descriptor

        return SelectionMeasurementEntity(
            id: entityID,
            kind: .surface,
            label: surfaceType,
            sourceIDs: [entityID, "\(scope):seedTriangle:\(surfaceSelection.seedTriangle)"],
            length: nil,
            radius: descriptor?.radius,
            area: measurements.area,
            perimeter: measurements.perimeter,
            triangleCount: surfaceSelection.triangleIndices.count,
            pointCount: nil,
            shape: nil,
            surfaceType: surfaceType,
            points: [],
            displayPoints: nil,
            sourcePoints: nil,
            sourceTriangleVertices: measurements.sourceTriangleVertices.map { $0.asArray() },
            origin: descriptor?.origin?.asArray(),
            axis: descriptor?.axis?.asArray(),
            normal: descriptor?.normal?.asArray()
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
