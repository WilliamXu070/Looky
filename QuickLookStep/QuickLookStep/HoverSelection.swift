import AppKit
import Foundation
import QuickLookCore
import SceneKit
import simd

struct SelectionCameraSignature: Equatable {
    let transform: [Float]
    let fieldOfView: Float
    let orthographicScale: Float
    let usesOrthographicProjection: Bool
    let viewportWidth: Float
    let viewportHeight: Float
}

struct HoverSelectionSnapshot {
    let point: CGPoint
    let camera: SelectionCameraSignature
    let selectionGeneration: Int
    let resolution: ResolvedSelection?
    let elapsedMs: Double

    var summary: HoverSelectionSummary {
        let pointKind: String?
        if case .point(_, let candidate) = resolution {
            pointKind = candidate.semanticPoint.kind.rawValue
        } else {
            pointKind = nil
        }
        return HoverSelectionSummary(
            kind: resolution?.kindName ?? "none",
            selectedEntityID: resolution?.entityID.rawValue,
            pointKind: pointKind,
            elapsedMs: elapsedMs
        )
    }
}

struct HoverSelectionSummary: Codable, Equatable {
    let kind: String
    let selectedEntityID: String?
    let pointKind: String?
    let elapsedMs: Double
}

extension DebugSelectableSCNView {
    func selectionCameraSignature() -> SelectionCameraSignature {
        let matrix = pointOfView?.simdWorldTransform ?? matrix_identity_float4x4
        let values = [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3]
            .flatMap { [$0.x, $0.y, $0.z, $0.w] }
        let camera = pointOfView?.camera
        return SelectionCameraSignature(
            transform: values,
            fieldOfView: Float(camera?.fieldOfView ?? 0),
            orthographicScale: Float(camera?.orthographicScale ?? 0),
            usesOrthographicProjection: camera?.usesOrthographicProjection ?? false,
            viewportWidth: Float(bounds.width),
            viewportHeight: Float(bounds.height)
        )
    }

    func clearHoverSelection() {
        hoverScreenStableHighlightNodes.removeAll()
        if let overlay = scene?.rootNode.childNode(withName: hoverRootName, recursively: false) {
            overlay.isHidden = true
            overlay.removeFromParentNode()
        }
    }

    func drawHoverSelection(_ resolution: ResolvedSelection?) {
        clearHoverSelection()
        guard let scene, let resolution else { return }
        if measurementState.entities.contains(where: { $0.id == resolution.entityID.rawValue }) {
            return
        }

        let root = SCNNode()
        root.name = hoverRootName
        scene.rootNode.addChildNode(root)

        switch resolution {
        case .point(_, let candidate):
            root.addChildNode(makeHoverPointNode(at: candidate.worldPosition))
        case .edge(_, let candidate):
            root.addChildNode(makeHoverEdgeChainNode(points: candidate.chainWorldPoints))
        case .surface(let hit, let candidate):
            guard let geometry = hit.node.geometry,
                  let selectionModel = selectionModel(for: geometry),
                  let hoverGeometry = makeSurfaceSelectionGeometry(
                    triangleIndices: candidate.triangleIndices,
                    selectionModel: selectionModel,
                    baseMaterial: geometry.materials.first
                  ) else {
                root.removeFromParentNode()
                return
            }
            hoverGeometry.materials = [hoverSurfaceMaterial()]
            let node = SCNNode(geometry: hoverGeometry)
            node.name = "hover-surface"
            node.renderingOrder = 39
            node.simdWorldTransform = hit.node.simdWorldTransform
            root.addChildNode(node)
        }
        updateScreenStableHighlights()
    }

    func drawPointSelection(
        _ candidate: PointSelectionCandidate,
        scene: SCNScene,
        selectionStart: CFAbsoluteTime
    ) -> Bool {
        clearDebugSelection(from: scene)
        activeSurfaceHighlight = nil
        let root = SCNNode()
        root.name = selectionRootName
        scene.rootNode.addChildNode(root)
        root.addChildNode(makeEndpointNode(at: candidate.worldPosition))
        updateScreenStableHighlights()
        NSLog(
            "Point selected: kind=%@ entity=%@ projectedDistance=%.2f elapsedMs=%.2f",
            candidate.semanticPoint.kind.rawValue,
            candidate.semanticPoint.id.rawValue,
            candidate.projectedDistancePoints,
            (CFAbsoluteTimeGetCurrent() - selectionStart) * 1000
        )
        return true
    }

    func makePointMeasurementEntity(
        _ candidate: PointSelectionCandidate,
        hit: SCNHitTestResult
    ) -> SelectionMeasurementEntity {
        let displayPoint = candidate.worldPosition
        let sourcePoint = scene.map {
            SceneComposer.sourcePoint(fromScenePoint: displayPoint, in: $0)
        } ?? displayPoint
        let label = candidate.semanticPoint.kind == .curveCenter ? "Curve Center" : "Vertex"
        return SelectionMeasurementEntity(
            id: candidate.semanticPoint.id.rawValue,
            kind: .point,
            label: label,
            sourceIDs: candidate.semanticPoint.parentEntityIDs.map(\.rawValue).sorted(),
            length: nil,
            radius: nil,
            area: nil,
            perimeter: nil,
            triangleCount: nil,
            pointCount: 1,
            shape: candidate.semanticPoint.kind.rawValue,
            surfaceType: nil,
            points: [displayPoint.asArray()],
            displayPoints: [displayPoint.asArray()],
            sourcePoints: [sourcePoint.asArray()],
            origin: sourcePoint.asArray()
        )
    }

    private func makeHoverEdgeChainNode(points: [SIMD3<Float>]) -> SCNNode {
        let root = SCNNode()
        root.name = "hover-edge-chain"
        guard points.count >= 2 else { return root }
        for index in 0..<(points.count - 1) {
            root.addChildNode(makeHoverEdgeSegmentNode(from: points[index], to: points[index + 1]))
        }
        return root
    }

    private func makeHoverEdgeSegmentNode(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>
    ) -> SCNNode {
        let vector = end - start
        let length = simd_length(vector)
        guard length > 0 else { return SCNNode() }
        let cylinder = SCNCylinder(radius: 1, height: CGFloat(length))
        cylinder.radialSegmentCount = 12
        cylinder.materials = [hoverLineMaterial()]
        let node = SCNNode(geometry: cylinder)
        node.name = "hover-edge-segment"
        node.simdPosition = (start + end) * 0.5
        node.simdOrientation = simd_quatf(
            from: SIMD3<Float>(0, 1, 0),
            to: normalized(vector, fallback: SIMD3<Float>(0, 1, 0))
        )
        node.renderingOrder = 41
        hoverScreenStableHighlightNodes.append(
            ScreenStableHighlightNode(
                node: node,
                anchor: node.simdPosition,
                pixelRadius: 1.7,
                scaleMode: .radial
            )
        )
        return node
    }

    private func makeHoverPointNode(at position: SIMD3<Float>) -> SCNNode {
        let torus = SCNTorus(ringRadius: 1, pipeRadius: 0.16)
        torus.ringSegmentCount = 24
        torus.pipeSegmentCount = 8
        torus.materials = [hoverLineMaterial()]
        let ringNode = SCNNode(geometry: torus)
        ringNode.name = "hover-point-ring"
        ringNode.eulerAngles.x = .pi / 2
        ringNode.renderingOrder = 42
        let billboardNode = SCNNode()
        billboardNode.name = "hover-point"
        billboardNode.simdPosition = position
        billboardNode.addChildNode(ringNode)
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
        billboardNode.constraints = [billboard]
        hoverScreenStableHighlightNodes.append(
            ScreenStableHighlightNode(
                node: billboardNode,
                anchor: position,
                pixelRadius: 6,
                scaleMode: .uniform
            )
        )
        return billboardNode
    }

    private func hoverLineMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        let color = NSColor(calibratedRed: 1.0, green: 0.68, blue: 0.18, alpha: 0.92)
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.emission.contents = color.withAlphaComponent(0.72)
        material.transparency = 0.92
        material.blendMode = .alpha
        material.isDoubleSided = true
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        return material
    }

    private func hoverSurfaceMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        let color = NSColor(calibratedRed: 1.0, green: 0.64, blue: 0.16, alpha: 0.32)
        material.lightingModel = .blinn
        material.diffuse.contents = color
        material.emission.contents = color.withAlphaComponent(0.08)
        material.specular.contents = NSColor(white: 0.12, alpha: 0.25)
        material.shininess = 10
        material.transparency = 0.32
        material.blendMode = .alpha
        material.isDoubleSided = true
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        return material
    }
}
