import AppKit
import Foundation
import QuickLookCore
import SceneKit
import simd

struct SelectionScreenProjector {
    private let cameraFromWorld: simd_float4x4
    private let worldFromLocal: simd_float4x4
    private let viewportSize: SIMD2<Float>
    private let fieldOfViewRadians: Float
    private let orthographicScale: Float
    private let usesOrthographicProjection: Bool
    private let horizontalFieldOfView: Bool

    init?(view: SCNView, node: SCNNode) {
        guard
            let cameraNode = view.pointOfView,
            let camera = cameraNode.camera,
            view.bounds.width > 0,
            view.bounds.height > 0
        else {
            return nil
        }
        cameraFromWorld = simd_inverse(cameraNode.simdWorldTransform)
        worldFromLocal = node.simdWorldTransform
        viewportSize = SIMD2<Float>(Float(view.bounds.width), Float(view.bounds.height))
        fieldOfViewRadians = Float(camera.fieldOfView) * .pi / 180
        orthographicScale = Float(camera.orthographicScale)
        usesOrthographicProjection = camera.usesOrthographicProjection
        horizontalFieldOfView = camera.projectionDirection == .horizontal
    }

    func project(local point: SIMD3<Float>) -> SIMD3<Float>? {
        project(world: worldPoint(point))
    }

    func project(world point: SIMD3<Float>) -> SIMD3<Float>? {
        let cameraPoint4 = cameraFromWorld * SIMD4<Float>(point.x, point.y, point.z, 1)
        let cameraPoint = SIMD3<Float>(cameraPoint4.x, cameraPoint4.y, cameraPoint4.z)
        let depth = -cameraPoint.z
        guard depth.isFinite, depth > 0 else { return nil }

        let aspect = viewportSize.x / viewportSize.y
        let halfWidth: Float
        let halfHeight: Float
        if usesOrthographicProjection {
            if horizontalFieldOfView {
                halfWidth = orthographicScale
                halfHeight = orthographicScale / aspect
            } else {
                halfHeight = orthographicScale
                halfWidth = orthographicScale * aspect
            }
        } else {
            let halfPrimary = tan(fieldOfViewRadians / 2) * depth
            if horizontalFieldOfView {
                halfWidth = halfPrimary
                halfHeight = halfPrimary / aspect
            } else {
                halfHeight = halfPrimary
                halfWidth = halfPrimary * aspect
            }
        }
        guard halfWidth > 0, halfHeight > 0 else { return nil }
        let normalizedX = cameraPoint.x / halfWidth
        let normalizedY = cameraPoint.y / halfHeight
        return SIMD3<Float>(
            (normalizedX + 1) * viewportSize.x / 2,
            (normalizedY + 1) * viewportSize.y / 2,
            depth
        )
    }

    func worldPoint(_ localPoint: SIMD3<Float>) -> SIMD3<Float> {
        let world = worldFromLocal * SIMD4<Float>(localPoint.x, localPoint.y, localPoint.z, 1)
        return SIMD3<Float>(world.x, world.y, world.z)
    }

    func interpolatedDepth(start: Float, end: Float, t: Float) -> Float {
        if usesOrthographicProjection {
            return start + (end - start) * t
        }
        let reciprocalDepth = (1 - t) / start + t / end
        return reciprocalDepth > 0 ? 1 / reciprocalDepth : .greatestFiniteMagnitude
    }
}

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

    func resolveSelection(
        at point: CGPoint,
        preferredEntityID: SelectionEntityID? = nil
    ) -> ResolvedSelection? {
        lastSelectionRejectionCode = nil
        let hitTestStart = CFAbsoluteTimeGetCurrent()
        let hits = hitTest(point, options: [
            .searchMode: SCNHitTestSearchMode.all.rawValue,
            .ignoreHiddenNodes: true,
            .backFaceCulling: false,
        ])
        let hitTestElapsedMs = (CFAbsoluteTimeGetCurrent() - hitTestStart) * 1000
        if selectionDebugMode {
            NSLog("Selection hit-test elapsedMs=%.2f hits=%ld", hitTestElapsedMs, hits.count)
        }
        guard let hit = hits.first(where: { !isSelectionOverlay($0.node) }),
              let geometry = hit.node.geometry else {
            lastSelectionRejectionCode = .invalidHit
            return nil
        }
        guard let engine = selectionEngine(for: geometry) else {
            lastSelectionRejectionCode = .selectionIndexPending
            return nil
        }
        guard engine.snapshot.triangles.indices.contains(hit.faceIndex) else {
            lastSelectionRejectionCode = .invalidHit
            return nil
        }

        let triangleID = MeshTriangleID(hit.faceIndex)
        let surface = engine.semanticEngine.surface(at: triangleID)
        if pointSelectionEnabled, let pointCandidate = pointCandidate(
            at: point,
            hit: hit,
            engine: engine,
            incidentSurface: surface,
            preferredEntityID: preferredEntityID
        ) {
            return .point(hit: hit, selection: pointCandidate)
        }
        if let exactEdge = exactEdgeCandidate(
            at: point,
            hit: hit,
            engine: engine,
            incidentSurface: surface,
            preferredEntityID: preferredEntityID
        ) {
            return .edge(hit: hit, selection: exactEdge)
        }

        if engine.semanticEngine.exactEdges.isEmpty,
           let inferredEdge = inferredEdgeCandidate(
                at: point,
                hit: hit,
                engine: engine,
                preferredEntityID: preferredEntityID
           ) {
            return .edge(hit: hit, selection: inferredEdge)
        }

        guard !edgeOnlyMode, let surface else {
            lastSelectionRejectionCode = surface == nil ? .unsupportedSurface : .outsideEdgeAperture
            return nil
        }
        let nearest = nearestFeatureEdgeDistance(
            in: engine.selectionModel,
            to: simdVector(hit.localCoordinates)
        )
        return .surface(
            hit: hit,
            selection: SurfaceSelectionCandidate(
                seedTriangle: hit.faceIndex,
                triangleIndices: surface.triangles.map(\.rawValue),
                nearestFeatureEdgeDistance: nearest.distance,
                nearestFeatureEdgeAcceleration: nearest.acceleration,
                edgePromotionThreshold: localSurfaceSelectionDistanceThreshold(for: engine.selectionModel),
                semanticSurface: surface
            )
        )
    }

    private func pointCandidate(
        at point: CGPoint,
        hit: SCNHitTestResult,
        engine: SceneSelectionEngine,
        incidentSurface: SelectedSurface?,
        preferredEntityID: SelectionEntityID?
    ) -> PointSelectionCandidate? {
        guard let projector = SelectionScreenProjector(view: self, node: hit.node),
              let projectedHit = projector.project(world: simdVector(hit.worldCoordinates)) else {
            return nil
        }

        var best: (point: SelectedPoint, distance: Float, depth: Float)?
        for candidate in engine.semanticEngine.points(incidentTo: incidentSurface) {
            guard let projected = projector.project(local: candidate.position) else {
                continue
            }
            // A curve center is not on its parent curve, so its projected depth can sit
            // behind the surface hit at the empty center of a visible circle. Its
            // incident-face filter above is the visibility contract; vertices must
            // still be at the frontmost hit depth.
            let hasDepthValidIncidentParent = !candidate.incidentFaceIDs.isEmpty
            guard candidate.kind == .curveCenter ||
                    hasDepthValidIncidentParent ||
                    projected.z <= projectedHit.z + 0.05 else {
                continue
            }
            let dx = projected.x - Float(point.x)
            let dy = projected.y - Float(point.y)
            let distance = sqrtf(dx * dx + dy * dy)
            let aperture: Float = candidate.id == preferredEntityID ? 10 : 8
            guard distance <= aperture else { continue }

            if let current = best {
                if distance > current.distance { continue }
                if distance == current.distance, projected.z > current.depth { continue }
                if distance == current.distance, projected.z == current.depth, candidate.id >= current.point.id { continue }
            }
            best = (candidate, distance, projected.z)
        }

        guard let best else { return nil }
        return PointSelectionCandidate(
            semanticPoint: best.point,
            worldPosition: projector.worldPoint(best.point.position),
            projectedDistancePoints: best.distance
        )
    }

    private func exactEdgeCandidate(
        at point: CGPoint,
        hit: SCNHitTestResult,
        engine: SceneSelectionEngine,
        incidentSurface: SelectedSurface?,
        preferredEntityID: SelectionEntityID?
    ) -> EdgeSelectionCandidate? {
        guard let projector = SelectionScreenProjector(view: self, node: hit.node),
              let projectedHit = projector.project(world: simdVector(hit.worldCoordinates)) else {
            return nil
        }
        let hitDepth = projectedHit.z
        let incidentEdges = engine.semanticEngine.exactEdges.filter { edge in
            guard let incidentSurface, !edge.incidentFaceIDs.isEmpty else { return true }
            return edge.incidentFaceIDs.contains { incidentSurface.id.rawValue.hasSuffix($0) }
        }

        var best: (edge: SelectedEdge, distance: Float, depth: Float, segment: Int, t: Float)?
        for edge in incidentEdges where edge.points.count >= 2 {
            let projected = edge.points.compactMap(projector.project(local:))
            guard projected.count == edge.points.count else { continue }
            for index in 0..<(projected.count - 1) {
                let closest = closestScreenPoint(
                    point,
                    start: SIMD2<Float>(projected[index].x, projected[index].y),
                    end: SIMD2<Float>(projected[index + 1].x, projected[index + 1].y)
                )
                let depth = projector.interpolatedDepth(
                    start: projected[index].z,
                    end: projected[index + 1].z,
                    t: closest.t
                )
                guard depth <= hitDepth + 0.05 else { continue }
                let candidate = (edge, closest.distance, depth, index, closest.t)
                if let current = best {
                    if candidate.1 > current.distance { continue }
                    if candidate.1 == current.distance, candidate.2 > current.depth { continue }
                    if candidate.1 == current.distance, candidate.2 == current.depth, candidate.0.id >= current.edge.id { continue }
                }
                best = candidate
            }
        }

        guard let best else { return nil }
        let aperture: Float = best.edge.id == preferredEntityID ? 8 : 6
        guard best.distance <= aperture else { return nil }
        let localStart = best.edge.points[best.segment]
        let localEnd = best.edge.points[best.segment + 1]
        let localSnap = localStart + (localEnd - localStart) * best.t
        let worldPoints = best.edge.points.map(projector.worldPoint)
        guard worldPoints.count >= 2 else { return nil }
        let fallbackEdge = EdgeKey(0, min(1, max(0, engine.edgeTopology.vertices.count - 1)))
        let edgeSnap = EdgeSnap(
            position: localSnap,
            normal: simdVector(hit.localNormal),
            distance: simd_distance(localSnap, simdVector(hit.localCoordinates)),
            selectedTriangle: hit.faceIndex,
            selectedEdge: fallbackEdge,
            currentPointIsEdge: true,
            isFeatureEdge: true,
            visitedTriangleCount: 1,
            chainPoints: best.edge.points,
            chainKind: best.edge.descriptor.kind.rawValue
        )
        return EdgeSelectionCandidate(
            edgeSnap: edgeSnap,
            chainWorldPoints: worldPoints,
            chainKind: best.edge.descriptor.kind.rawValue,
            semanticEdge: best.edge,
            projectedDistancePoints: best.distance
        )
    }

    private func inferredEdgeCandidate(
        at point: CGPoint,
        hit: SCNHitTestResult,
        engine: SceneSelectionEngine,
        preferredEntityID: SelectionEntityID?
    ) -> EdgeSelectionCandidate? {
        let candidatesForSelection = nearestEdgeCandidates(for: hit, in: engine.edgeTopology)
            .filter(\.isFeatureEdge)
        guard var selected = resolveBestDownloadSelection(
            from: candidatesForSelection,
            mesh: engine.edgeTopology,
            hit: hit,
            node: hit.node
        ),
              let curveKind = inferredCurveKind(from: selected.chainKind),
              let projectedDistance = projectedDistance(
                from: point,
                to: selected.edgeSnap.selectedEdge,
                node: hit.node,
                mesh: engine.edgeTopology
              ),
              projectedDistance <= 8 else {
            return nil
        }

        let edge = selected.edgeSnap.selectedEdge
        let semanticEdge = SelectedEdge(
            source: engine.snapshot.sourceID,
            edges: [MeshEdgeID(edge.a, edge.b)],
            points: selected.edgeSnap.chainPoints,
            id: SelectionEntityID(
                "\(engine.snapshot.sourceID.model):\(engine.snapshot.sourceID.node):\(engine.snapshot.sourceID.geometry):inferred:edge:\(edge.a)-\(edge.b)"
            ),
            descriptor: CurveDescriptor(kind: curveKind)
        )
        let aperture: Float = semanticEdge.id == preferredEntityID ? 8 : 6
        guard projectedDistance <= aperture else { return nil }
        selected = EdgeSelectionCandidate(
            edgeSnap: selected.edgeSnap,
            chainWorldPoints: selected.chainWorldPoints,
            chainKind: selected.chainKind,
            semanticEdge: semanticEdge,
            projectedDistancePoints: projectedDistance
        )
        return selected
    }

    private func inferredCurveKind(from chainKind: String) -> CurvePrimitiveKind? {
        let normalized = chainKind.lowercased()
        if normalized.contains("arc") || normalized.contains("circle") { return .circle }
        if normalized.contains("line") || normalized.contains("single-edge") { return .line }
        return nil
    }

    private func projectedDistance(
        from point: CGPoint,
        to edge: EdgeKey,
        node: SCNNode,
        mesh: EdgePrimitiveIndex
    ) -> Float? {
        guard mesh.vertices.indices.contains(edge.a),
              mesh.vertices.indices.contains(edge.b),
              let projector = SelectionScreenProjector(view: self, node: node),
              let first = projector.project(local: mesh.vertices[edge.a]),
              let second = projector.project(local: mesh.vertices[edge.b]) else {
            return nil
        }
        return closestScreenPoint(
            point,
            start: SIMD2<Float>(first.x, first.y),
            end: SIMD2<Float>(second.x, second.y)
        ).distance
    }

    private func closestScreenPoint(
        _ point: CGPoint,
        start: SIMD2<Float>,
        end: SIMD2<Float>
    ) -> (distance: Float, t: Float) {
        let query = SIMD2<Float>(Float(point.x), Float(point.y))
        let segment = end - start
        let denominator = simd_length_squared(segment)
        let t = denominator > 0 ? max(0, min(1, simd_dot(query - start, segment) / denominator)) : 0
        return (simd_distance(query, start + segment * t), t)
    }

    func resolveSurfaceSelection(
        for hit: SCNHitTestResult,
        in selectionModel: SelectionModel,
        nearestFeatureEdge: SelectionDistanceResult? = nil
    ) -> SurfaceSelectionCandidate? {
        guard let geometry = hit.node.geometry,
              let engine = selectionEngine(for: geometry),
              engine.snapshot.triangles.indices.contains(hit.faceIndex),
              let surface = engine.semanticEngine.surface(at: MeshTriangleID(hit.faceIndex)) else {
            return nil
        }

        let threshold = localSurfaceSelectionDistanceThreshold(for: selectionModel)
        let nearestFeatureEdge = nearestFeatureEdge ?? nearestFeatureEdgeDistance(
            in: selectionModel,
            to: simdVector(hit.localCoordinates)
        )
        let nearestFeatureEdgeDistance = nearestFeatureEdge.distance

        return SurfaceSelectionCandidate(
            seedTriangle: hit.faceIndex,
            triangleIndices: surface.triangles.map(\.rawValue),
            nearestFeatureEdgeDistance: nearestFeatureEdgeDistance,
            nearestFeatureEdgeAcceleration: nearestFeatureEdge.acceleration,
            edgePromotionThreshold: threshold,
            semanticSurface: surface
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
