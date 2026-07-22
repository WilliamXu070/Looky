import AppKit
import Foundation
import SceneKit
import simd

extension DebugSelectableSCNView {
    func edgeSelectionWorldRadius(for hit: SCNHitTestResult) -> Float {
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

    func localRayThroughScreenPoint(_ point: CGPoint, in node: SCNNode) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
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

    func distanceFromRayToSegment(
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

    func resolveSelection(at point: CGPoint) -> ResolvedSelection? {
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
            let surfaceCandidate = resolveSurfaceSelection(
                for: hit,
                in: selectionModel,
                nearestFeatureEdge: nearestFeatureEdge
            )
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
                guard let seedTriangle = triangleID(for: hit, in: selectionModel)?.rawValue else {
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

    func resolveSurfaceSelection(
        for hit: SCNHitTestResult,
        in selectionModel: SelectionModel,
        nearestFeatureEdge: SelectionDistanceResult? = nil
    ) -> SurfaceSelectionCandidate? {
        let hitLocal = simdVector(hit.localCoordinates)
        guard let seedTriangle = triangleID(for: hit, in: selectionModel) else {
            return nil
        }

        let threshold = localSurfaceSelectionDistanceThreshold(for: selectionModel)
        let nearestFeatureEdge = nearestFeatureEdge ?? nearestFeatureEdgeDistance(in: selectionModel, to: hitLocal)
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

    func nearestFeatureEdgeDistance(
        in selectionModel: SelectionModel,
        to point: SIMD3<Float>
    ) -> SelectionDistanceResult {
        let result = selectionModel.nearestFeatureEdgeDistance(
            to: point,
            backend: selectionDistanceBackend,
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

    func triangleID(
        for hit: SCNHitTestResult,
        in selectionModel: SelectionModel
    ) -> SelectionTriangleID? {
        if selectionModel.triangles.indices.contains(hit.faceIndex) {
            return selectionModel.triangleID(at: hit.faceIndex)
        }
        return selectionModel.closestTriangleID(to: simdVector(hit.localCoordinates))
    }

    func triangleIndex(for hit: SCNHitTestResult, in mesh: EdgePrimitiveIndex) -> Int? {
        if mesh.triangles.indices.contains(hit.faceIndex) {
            return hit.faceIndex
        }
        return mesh.closestTriangleIndex(to: simdVector(hit.localCoordinates))
    }
}
