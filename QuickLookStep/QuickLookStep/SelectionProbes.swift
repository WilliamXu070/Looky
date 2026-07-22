import AppKit
import Foundation
import SceneKit
import simd

extension DebugSelectableSCNView {
    func makeEdgeProbeRecord(
        using mesh: EdgePrimitiveIndex,
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

    func writeEdgeProbeRecord(_ record: ProbeRecord) {
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

    func makeSurfaceProbeRecord(
        at point: CGPoint,
        event: NSEvent?,
        modifierFlagsOverride: [String]? = nil,
        resolvedSelection: ResolvedSelection?
    ) -> SurfaceProbeRecord {
        let resolvedKind: String
        switch resolvedSelection {
        case .point:
            resolvedKind = "point"
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
        let seedTriangle = triangleID(for: hit, in: selectionModel)?.rawValue
        let nearestFeatureEdge = nearestFeatureEdgeDistance(in: selectionModel, to: hitLocal)
        let surfaceCandidate = resolveSurfaceSelection(
            for: hit,
            in: selectionModel,
            nearestFeatureEdge: nearestFeatureEdge
        )
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

    func writeSurfaceProbeRecord(_ record: SurfaceProbeRecord) {
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

    func modifierFlagNames(_ flags: NSEvent.ModifierFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.shift) { names.append("shift") }
        if flags.contains(.control) { names.append("control") }
        if flags.contains(.option) { names.append("option") }
        if flags.contains(.command) { names.append("command") }
        if flags.contains(.capsLock) { names.append("capsLock") }
        return names
    }

    func selectionModifierNames(event: NSEvent?, override: [String]?) -> [String] {
        if let override {
            return normalizedModifierNames(override)
        }
        return modifierFlagNames(event?.modifierFlags ?? [])
    }

    func normalizedModifierNames(_ names: [String]) -> [String] {
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

    func canDownloadSelection(mode: EdgeSelectionMode, candidate: EdgeSelectionCandidate) -> Bool {
        if candidate.chainWorldPoints.count < 2 {
            return false
        }
        let chainLength = polylineLength(candidate.chainWorldPoints)
        if chainLength < 0.0001 {
            return false
        }

        return true
    }

    func writeEdgeDownloadRecord(
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

    func resolveBestDownloadSelection(
        from candidates: [EdgeSnap],
        mesh: EdgePrimitiveIndex,
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

    func resolveBestDownloadSelection(
        from candidates: [EdgeSnap],
        mesh: EdgePrimitiveIndex,
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

    func resolvedChain(
        for candidate: EdgeSnap,
        mesh: EdgePrimitiveIndex,
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

    func isDownloadable(
        selection: EdgeSelectionCandidate,
        mesh: EdgePrimitiveIndex,
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

    func polylineLength(_ points: [SIMD3<Float>]) -> Float {
        zip(points, points.dropFirst()).reduce(Float(0)) { partial, pair in
            partial + simd_distance(pair.0, pair.1)
        }
    }

    func nearestEdgeCandidates(for hit: SCNHitTestResult, in mesh: EdgePrimitiveIndex) -> [EdgeSnap] {
        let hitLocal = simdVector(hit.localCoordinates)
        guard let startTriangle = triangleIndex(for: hit, in: mesh) else {
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

    func localSelectionDistanceThreshold(for mesh: EdgePrimitiveIndex) -> Float {
        max(mesh.maxExtent * 0.03, 0.0005)
    }

    func localSurfaceSelectionDistanceThreshold(for mesh: EdgePrimitiveIndex) -> Float {
        max(mesh.maxExtent * 0.00008, 0.001)
    }

    func localSurfaceSelectionDistanceThreshold(for selectionModel: SelectionModel) -> Float {
        max(selectionModel.maxExtent * 0.00008, 0.001)
    }

    func shouldPromoteSurfaceOver(
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

    func sanitizeFileHint(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "unknown-model"
        }
        return trimmed.replacingOccurrences(of: "/", with: "_")
    }

    func nearestEdgeSnap(for hit: SCNHitTestResult, in mesh: EdgePrimitiveIndex) -> EdgeSnap? {
        let hitLocal = simdVector(hit.localCoordinates)
        guard let startTriangle = triangleIndex(for: hit, in: mesh) else {
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

    func closestPoint(onSegmentFrom a: SIMD3<Float>, to b: SIMD3<Float>, point: SIMD3<Float>) -> SIMD3<Float> {
        let ab = b - a
        let denominator = simd_dot(ab, ab)
        guard denominator > 0 else {
            return a
        }
        let t = max(0, min(1, simd_dot(point - a, ab) / denominator))
        return a + ab * t
    }

    func simdVector(_ vector: SCNVector3) -> SIMD3<Float> {
        SIMD3<Float>(Float(vector.x), Float(vector.y), Float(vector.z))
    }

    func scnVector(_ vector: SIMD3<Float>) -> SCNVector3 {
        SCNVector3(CGFloat(vector.x), CGFloat(vector.y), CGFloat(vector.z))
    }

    func normalized(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(vector)
        guard length.isFinite, length > 0 else {
            return fallback
        }
        return vector / length
    }
}
