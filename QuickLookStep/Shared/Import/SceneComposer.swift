import Cocoa
import Foundation
import SceneKit
import simd

enum SceneComposer {
    private enum MetadataKey {
        static let sourceToSceneScale = "quicklook.sourceToSceneScale"
        static let sourceCenterX = "quicklook.sourceCenter.x"
        static let sourceCenterY = "quicklook.sourceCenter.y"
        static let sourceCenterZ = "quicklook.sourceCenter.z"
    }

    static func compose(from modelRoot: SCNNode, fileName: String) throws -> SCNScene {
        applyMeshLightingFixups(to: modelRoot)
        modelRoot.removeFromParentNode()

        let scene = SCNScene()
        scene.rootNode.addChildNode(modelRoot)

        let (minimum, maximum) = modelRoot.boundingBox
        let size = SCNVector3(
            maximum.x - minimum.x,
            maximum.y - minimum.y,
            maximum.z - minimum.z
        )
        let maxExtent = max(size.x, max(size.y, size.z))
        guard maxExtent.isFinite, maxExtent > 0 else {
            throw ModelImportError.invalidGeometryBounds
        }

        let targetSize: CGFloat = 100
        let scale = Float(targetSize / maxExtent)
        let sourceCenter = SIMD3<Float>(
            Float((maximum.x + minimum.x) / 2),
            Float((maximum.y + minimum.y) / 2),
            Float((maximum.z + minimum.z) / 2)
        )
        modelRoot.scale = SCNVector3(scale, scale, scale)
        modelRoot.position = SCNVector3(
            -sourceCenter.x * scale,
            -sourceCenter.y * scale,
            -sourceCenter.z * scale
        )
        recordSourceTransform(scale: scale, center: sourceCenter, in: scene)

        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        let camera = SCNCamera()
        camera.zNear = 1
        camera.zFar = 10_000
        camera.fieldOfView = 45
        cameraNode.camera = camera

        let sx = Float(size.x)
        let sy = Float(size.y)
        let sz = Float(size.z)
        let radius = (sqrt(sx * sx + sy * sy + sz * sz) / 2) * scale
        guard radius.isFinite, radius > 0 else {
            throw ModelImportError.invalidGeometryBounds
        }
        let halfFOV = Float(camera.fieldOfView) * .pi / 360
        let distance = radius / tan(halfFOV)
        cameraNode.position = SCNVector3(distance, distance, distance)
        cameraNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(cameraNode)

        scene.rootNode.addChildNode(omniLight(intensity: 850, position: cameraNode.position))
        scene.rootNode.addChildNode(
            omniLight(intensity: 700, position: SCNVector3(0, 0, -Float(targetSize * 2)))
        )

        let directional = SCNNode()
        directional.light = SCNLight()
        directional.light?.type = .directional
        directional.light?.intensity = 450
        directional.light?.castsShadow = true
        directional.eulerAngles = SCNVector3(-0.4, 0.4, 0)
        scene.rootNode.addChildNode(directional)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = NSColor.white
        ambient.light?.intensity = 170
        scene.rootNode.addChildNode(ambient)

        NSLog("SceneComposer loaded %@ successfully", fileName)
        return scene
    }

    static func sourceTransform(from scene: SCNScene) -> ImportedModelTransform {
        guard let scale = scene.attribute(forKey: MetadataKey.sourceToSceneScale) as? NSNumber else {
            return .identity
        }
        let center = SIMD3<Float>(
            (scene.attribute(forKey: MetadataKey.sourceCenterX) as? NSNumber)?.floatValue ?? 0,
            (scene.attribute(forKey: MetadataKey.sourceCenterY) as? NSNumber)?.floatValue ?? 0,
            (scene.attribute(forKey: MetadataKey.sourceCenterZ) as? NSNumber)?.floatValue ?? 0
        )
        return ImportedModelTransform(sourceToSceneScale: scale.floatValue, sourceCenter: center)
    }

    static func sourcePoint(fromScenePoint point: SIMD3<Float>, in scene: SCNScene) -> SIMD3<Float> {
        let transform = sourceTransform(from: scene)
        guard transform.sourceToSceneScale.isFinite, transform.sourceToSceneScale != 0 else {
            return point
        }
        return point / transform.sourceToSceneScale + transform.sourceCenter
    }

    static func ensureNormalsIfMissing(for geometry: SCNGeometry) -> SCNGeometry {
        if !geometry.sources(for: .normal).isEmpty { return geometry }
        guard let vertexSource = geometry.sources(for: .vertex).first,
              vertexSource.bytesPerComponent == MemoryLayout<Float>.size,
              geometry.elements.allSatisfy({ $0.primitiveType == .triangles })
        else {
            return geometry
        }

        let vertices = readVertices(from: vertexSource)
        guard vertices.count == vertexSource.vectorCount else { return geometry }
        var normalSums = [SIMD3<Float>](repeating: .zero, count: vertices.count)

        for element in geometry.elements {
            for primitive in 0..<element.primitiveCount {
                guard
                    let i0 = readIndex(from: element, position: primitive * 3),
                    let i1 = readIndex(from: element, position: primitive * 3 + 1),
                    let i2 = readIndex(from: element, position: primitive * 3 + 2),
                    vertices.indices.contains(i0),
                    vertices.indices.contains(i1),
                    vertices.indices.contains(i2)
                else {
                    return geometry
                }
                let cross = simd_cross(vertices[i1] - vertices[i0], vertices[i2] - vertices[i0])
                let length = simd_length(cross)
                guard length > 0 else { continue }
                let normal = cross / length
                normalSums[i0] += normal
                normalSums[i1] += normal
                normalSums[i2] += normal
            }
        }

        var values: [Float] = []
        values.reserveCapacity(normalSums.count * 3)
        for sum in normalSums {
            let length = simd_length(sum)
            let normal = length > 0 ? sum / length : SIMD3<Float>(0, 1, 0)
            values.append(contentsOf: [normal.x, normal.y, normal.z])
        }
        let source = values.withUnsafeBytes { bytes in
            SCNGeometrySource(
                data: Data(bytes),
                semantic: .normal,
                vectorCount: normalSums.count,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: 3 * MemoryLayout<Float>.size
            )
        }
        let rebuilt = SCNGeometry(
            sources: geometry.sources.filter { $0.semantic != .normal } + [source],
            elements: geometry.elements
        )
        rebuilt.materials = geometry.materials
        return rebuilt
    }

    private static func recordSourceTransform(
        scale: Float,
        center: SIMD3<Float>,
        in scene: SCNScene
    ) {
        scene.setAttribute(NSNumber(value: scale), forKey: MetadataKey.sourceToSceneScale)
        scene.setAttribute(NSNumber(value: center.x), forKey: MetadataKey.sourceCenterX)
        scene.setAttribute(NSNumber(value: center.y), forKey: MetadataKey.sourceCenterY)
        scene.setAttribute(NSNumber(value: center.z), forKey: MetadataKey.sourceCenterZ)
    }

    private static func omniLight(intensity: CGFloat, position: SCNVector3) -> SCNNode {
        let node = SCNNode()
        node.light = SCNLight()
        node.light?.type = .omni
        node.light?.intensity = intensity
        node.position = position
        return node
    }

    private static func applyMeshLightingFixups(to root: SCNNode) {
        root.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            let fixed = ensureNormalsIfMissing(for: geometry)
            node.geometry = fixed
            if fixed.materials.isEmpty {
                fixed.materials = [defaultLitMaterial()]
            }
            for material in fixed.materials {
                material.isDoubleSided = true
                if material.lightingModel == .constant {
                    material.lightingModel = .blinn
                }
                if material.diffuse.contents == nil {
                    material.diffuse.contents = NSColor(white: 0.85, alpha: 1)
                }
            }
        }
    }

    private static func defaultLitMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .blinn
        material.diffuse.contents = NSColor(white: 0.9, alpha: 1)
        material.specular.contents = NSColor(white: 0.2, alpha: 1)
        material.shininess = 18
        material.isDoubleSided = true
        return material
    }

    private static func readVertices(from source: SCNGeometrySource) -> [SIMD3<Float>] {
        var vertices: [SIMD3<Float>] = []
        vertices.reserveCapacity(source.vectorCount)
        let stride = max(source.dataStride, source.componentsPerVector * source.bytesPerComponent)
        source.data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            for index in 0..<source.vectorCount {
                let values = base.advanced(by: source.dataOffset + index * stride)
                    .assumingMemoryBound(to: Float.self)
                let vertex = SIMD3<Float>(values[0], values[1], values[2])
                guard vertex.x.isFinite, vertex.y.isFinite, vertex.z.isFinite else { return }
                vertices.append(vertex)
            }
        }
        return vertices
    }

    private static func readIndex(from element: SCNGeometryElement, position: Int) -> Int? {
        let offset = position * element.bytesPerIndex
        guard offset + element.bytesPerIndex <= element.data.count else { return nil }
        return element.data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return nil }
            let pointer = base.advanced(by: offset)
            switch element.bytesPerIndex {
            case 1: return Int(pointer.assumingMemoryBound(to: UInt8.self).pointee)
            case 2: return Int(pointer.assumingMemoryBound(to: UInt16.self).pointee)
            case 4: return Int(pointer.assumingMemoryBound(to: UInt32.self).pointee)
            default: return nil
            }
        }
    }
}

private struct SceneMaterialDiagnostics {
    var geometryCount = 0
    var materialCount = 0
    var texturedMaterialCount = 0
    var diffuseTextureMaterialCount = 0
    var normalMapMaterialCount = 0
    var pbrMaterialCount = 0
    var textureSlotCount = 0
    var triangleCount = 0

    var metadata: [String: String] {
        [
            "geometryCount": "\(geometryCount)",
            "materialCount": "\(materialCount)",
            "texturedMaterialCount": "\(texturedMaterialCount)",
            "diffuseTextureMaterialCount": "\(diffuseTextureMaterialCount)",
            "normalMapMaterialCount": "\(normalMapMaterialCount)",
            "pbrMaterialCount": "\(pbrMaterialCount)",
            "textureSlotCount": "\(textureSlotCount)",
            "triangleCount": "\(triangleCount)",
        ]
    }
}

enum ImportDiagnosticsCollector {
    static func metadata(
        for scene: SCNScene,
        url: URL,
        method: String,
        format: ModelFormat,
        materialQuality: String?,
        degradationReason: String?,
        fallbackReason: String?
    ) -> [String: String] {
        let diagnostics = inspect(scene)
        var metadata = diagnostics.metadata
        metadata["sourceFormat"] = format.rawValue
        metadata["loadMethod"] = method
        metadata["materialQuality"] = materialQuality ?? inferredQuality(diagnostics, format: format)
        metadata["textureResolutionHint"] = textureHint(for: format)
        if let degradationReason, !degradationReason.isEmpty {
            metadata["degradationReason"] = degradationReason
        }
        if let fallbackReason, !fallbackReason.isEmpty {
            metadata["fallbackReason"] = fallbackReason
        }
        NSLog("Import diagnostics for %@: %@", url.lastPathComponent, metadata)
        return metadata
    }

    static func shortDescription(_ error: Error) -> String {
        let value = (error as NSError).localizedDescription
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(value.prefix(220))
    }

    private static func inspect(_ scene: SCNScene) -> SceneMaterialDiagnostics {
        var result = SceneMaterialDiagnostics()
        scene.rootNode.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            result.geometryCount += 1
            result.triangleCount += geometry.elements.reduce(0) {
                $0 + ($1.primitiveType == .triangles ? $1.primitiveCount : 0)
            }
            for material in geometry.materials {
                result.materialCount += 1
                let slots = [
                    material.diffuse, material.normal, material.ambientOcclusion,
                    material.emission, material.metalness, material.multiply,
                    material.reflective, material.roughness, material.specular,
                    material.transparent,
                ].filter(isTextureBacked).count
                if isTextureBacked(material.diffuse) { result.diffuseTextureMaterialCount += 1 }
                if isTextureBacked(material.normal) { result.normalMapMaterialCount += 1 }
                if slots > 0 {
                    result.texturedMaterialCount += 1
                    result.textureSlotCount += slots
                }
                if material.lightingModel == .physicallyBased { result.pbrMaterialCount += 1 }
            }
        }
        return result
    }

    private static func isTextureBacked(_ property: SCNMaterialProperty) -> Bool {
        guard let contents = property.contents else { return false }
        return !(contents is NSColor) && !(contents is NSNumber)
    }

    private static func inferredQuality(
        _ diagnostics: SceneMaterialDiagnostics,
        format: ModelFormat
    ) -> String {
        switch format {
        case .gltf, .glb:
            return diagnostics.texturedMaterialCount > 0 || diagnostics.pbrMaterialCount > 0
                ? "full" : "possibly-degraded"
        case .obj, .stl:
            return diagnostics.texturedMaterialCount > 0 ? "textured" : "untextured"
        default:
            return "not-evaluated"
        }
    }

    private static func textureHint(for format: ModelFormat) -> String {
        switch format {
        case .gltf: "external-uris-may-require-model-parent-texture-search"
        case .glb: "glb-usually-embedded-but-external-textures-can-be-used-as-recovery-overrides"
        case .sldprt, .sldasm: "solidworks-native-geometry-requires-sidecar-export"
        default: "not-applicable"
        }
    }
}
