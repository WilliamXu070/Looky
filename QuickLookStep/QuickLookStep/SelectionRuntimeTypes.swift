import AppKit
import Foundation
import SceneKit
import simd

struct EdgeSnap {
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

struct EdgeSelectionCandidate {
    let edgeSnap: EdgeSnap
    let chainWorldPoints: [SIMD3<Float>]
    let chainKind: String
}

struct SurfaceProbeRecord: Codable {
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

func frontmostSurfaceSeed(
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

func rayTriangleDistance(
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

func surfaceOverlayScore(
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

func makeSurfaceSelectionGeometry(
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

func makeTriangleElement(indices: [UInt32]) -> SCNGeometryElement {
    SCNGeometryElement(
        data: indices.withUnsafeBytes { Data($0) },
        primitiveType: .triangles,
        primitiveCount: indices.count / 3,
        bytesPerIndex: MemoryLayout<UInt32>.size
    )
}

func copyBaseSurfaceMaterial(_ material: SCNMaterial?) -> SCNMaterial {
    if let copy = material?.copy() as? SCNMaterial {
        return copy
    }

    let fallback = SCNMaterial()
    fallback.diffuse.contents = NSColor(calibratedWhite: 0.82, alpha: 1.0)
    fallback.lightingModel = .physicallyBased
    return fallback
}

func makeSurfaceOverlayNode(
    triangleIndices: [Int],
    using node: SCNNode,
    mesh: EdgePrimitiveIndex,
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

func surfaceSelectionMaterial() -> SCNMaterial {
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

func qlsSIMD(_ vector: SCNVector3) -> SIMD3<Float> {
    SIMD3<Float>(Float(vector.x), Float(vector.y), Float(vector.z))
}

func qlsSCN(_ vector: SIMD3<Float>) -> SCNVector3 {
    SCNVector3(CGFloat(vector.x), CGFloat(vector.y), CGFloat(vector.z))
}

func qlsNormalized(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
    let length = simd_length(vector)
    guard length.isFinite, length > 0 else {
        return fallback
    }
    return vector / length
}

enum ResolvedSelection {
    case edge(hit: SCNHitTestResult, selection: EdgeSelectionCandidate)
    case surface(hit: SCNHitTestResult, selection: SurfaceSelectionCandidate)
}

struct SurfaceSelectionCandidate {
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
