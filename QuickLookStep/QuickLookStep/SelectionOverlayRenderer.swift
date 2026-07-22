import AppKit
import Foundation
import SceneKit
import simd

extension DebugSelectableSCNView {
    func addSurfaceOverlay(
        _ geometry: SCNGeometry,
        matching sourceNode: SCNNode,
        to scene: SCNScene
    ) {
        let overlayRoot = scene.rootNode.childNode(withName: selectionRootName, recursively: false) ?? {
            let node = SCNNode()
            node.name = selectionRootName
            scene.rootNode.addChildNode(node)
            return node
        }()
        let overlay = SCNNode(geometry: geometry)
        overlayRoot.addChildNode(overlay)
        overlay.simdWorldTransform = sourceNode.simdWorldTransform
    }

    func makeEdgeChainNode(points: [SIMD3<Float>]) -> SCNNode {
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

    func makeSelectedEdgeNode(
        edge: EdgeKey,
        using node: SCNNode,
        meshVertices: [SIMD3<Float>]
    ) -> SCNNode? {
        guard let points = selectedEdgeWorldPoints(edge: edge, using: node, meshVertices: meshVertices) else {
            return nil
        }
        return makeEdgeChainNode(points: points)
    }

    func selectedEdgeWorldPoints(
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

    func makeConnectedComponentNode(
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

    func makeSurfaceSelectionNode(
        triangleIndices: [Int],
        using node: SCNNode,
        mesh: EdgePrimitiveIndex,
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

    func makeEdgeSegmentNode(from start: SIMD3<Float>, to end: SIMD3<Float>) -> SCNNode {
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

    func makeEndpointNode(at position: SIMD3<Float>) -> SCNNode {
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

    func updateScreenStableHighlights() {
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

    func worldRadius(forPixelRadius pixelRadius: CGFloat, at anchor: SIMD3<Float>) -> Float {
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

    func selectionMaterial(alpha: CGFloat) -> SCNMaterial {
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

    func isSelectionOverlay(_ node: SCNNode) -> Bool {
        var current: SCNNode? = node
        while let node = current {
            if node.name == selectionRootName {
                return true
            }
            current = node.parent
        }
        return false
    }
}
