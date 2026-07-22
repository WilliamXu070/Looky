import AppKit
import Foundation
import SceneKit
import simd

extension DebugSelectableSCNView {
    func makeSelectionDebugEventIfNeeded(
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

    func writeSelectionDebugEvent(
        _ event: SelectionDebugEvent?,
        beforeImage: NSImage?
    ) -> SelectionDebugEvent? {
        guard let event else {
            return nil
        }

        let prepared = SelectionDebugRecorder.shared.preparedEvent(
            event,
            outputDirectory: selectionDebugOutputDirectory,
            hasBeforeImage: beforeImage != nil,
            hasAfterImage: true
        )
        onSelectionDebugEvent?(prepared)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            SelectionDebugRecorder.shared.record(
                event: prepared,
                beforeImage: beforeImage,
                afterImage: self.snapshot(),
                outputDirectory: self.selectionDebugOutputDirectory
            )
        }
        return prepared
    }

    func makeSelectionDebugEvent(
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
                selectedEntityID = "\(selectionEntityScope(for: hit.node)):surfacePatch:\(patchID.rawValue)"
            } else {
                selectedEntityID = "\(selectionEntityScope(for: hit.node)):surfaceSeed:\(surfaceSelection.seedTriangle)"
            }
        case .edge(let hit, let edgeSelection):
            selectedEdgePointCount = edgeSelection.chainWorldPoints.count
            selectedSurfaceTriangleCount = 0
            seedTriangle = edgeSelection.edgeSnap.selectedTriangle
            selectedEntityID = "\(selectionEntityScope(for: hit.node)):edge:\(edgeSelection.edgeSnap.selectedEdge.a)-\(edgeSelection.edgeSnap.selectedEdge.b)"
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

    func selectionDebugReason(
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

    func selectionDebugRejectedAlternatives(
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

    func selectionDebugRenderValidation(
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

    func selectedSurfaceBounds(
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

    func selectedPointBounds(
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

    func selectedSurfaceDisconnected(
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

    func selectionDebugCameraState() -> SelectionDebugCameraState {
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

    func normalizedViewportPoint(_ point: CGPoint) -> [Double] {
        let width = max(Double(bounds.width), 1.0)
        let height = max(Double(bounds.height), 1.0)
        return [
            min(max(Double(point.x) / width, 0), 1),
            min(max(Double(point.y) / height, 0), 1),
        ]
    }

    func hitDistanceFromCamera(hitWorldPoint: [Float]?) -> Float? {
        guard let hitWorldPoint,
              hitWorldPoint.count >= 3,
              let cameraNode = pointOfView else {
            return nil
        }
        let hit = SIMD3<Float>(hitWorldPoint[0], hitWorldPoint[1], hitWorldPoint[2])
        return simd_distance(cameraNode.simdWorldPosition, hit)
    }

    func clearDebugSelection(from scene: SCNScene) {
        screenStableHighlightNodes.removeAll()
        scene.rootNode
            .childNode(withName: selectionRootName, recursively: false)?
            .removeFromParentNode()
    }

}
