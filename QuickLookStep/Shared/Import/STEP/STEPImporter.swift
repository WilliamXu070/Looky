import AppKit
import Foundation
import SceneKit

struct STEPImporter: ModelImporter {
    let supportedFormats: Set<ModelFormat> = [.step, .stp]

    func load(_ request: ModelLoadRequest) throws -> ImportedScene {
        var mesh = MeshSlice()
        let start = CFAbsoluteTimeGetCurrent()
        let loaded = request.url.path.withCString { path in
            foxtrot_load_step(path, &mesh)
        }
        let elapsedMilliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
        NSLog(
            "foxtrot_load_step(%@) -> %@ in %.2f ms",
            request.url.path,
            loaded ? "OK" : "FAIL",
            elapsedMilliseconds
        )
        guard loaded else {
            throw ModelImportError.stepLoadFailed
        }
        defer { foxtrot_free_mesh(mesh) }

        let vertexCount = Int(mesh.vert_count)
        let triangleCount = Int(mesh.tri_count)
        guard vertexCount > 0, triangleCount > 0 else {
            throw ModelImportError.emptyModel(request.url)
        }
        guard let vertexPointer = mesh.verts, let indexPointer = mesh.tris else {
            throw ModelImportError.stepLoadFailed
        }

        let vertexSource = SCNGeometrySource(
            data: Data(bytes: vertexPointer, count: vertexCount * 3 * MemoryLayout<Float>.size),
            semantic: .vertex,
            vectorCount: vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: 3 * MemoryLayout<Float>.size
        )
        let element = SCNGeometryElement(
            data: Data(bytes: indexPointer, count: triangleCount * 3 * MemoryLayout<UInt32>.size),
            primitiveType: .triangles,
            primitiveCount: triangleCount,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let geometry = SceneComposer.ensureNormalsIfMissing(
            for: SCNGeometry(sources: [vertexSource], elements: [element])
        )
        let material = SCNMaterial()
        material.lightingModel = .blinn
        material.diffuse.contents = NSColor(white: 0.9, alpha: 1)
        material.isDoubleSided = true
        geometry.materials = [material]

        let modelRoot = SCNNode()
        modelRoot.name = "model-root"
        modelRoot.addChildNode(SCNNode(geometry: geometry))
        let scene = try SceneComposer.compose(from: modelRoot, fileName: request.url.lastPathComponent)
        let format = ModelFormat(url: request.url) ?? .step
        return ImportedScene(
            scene: scene,
            diagnostics: ImportDiagnostics(
                format: format,
                method: "step-native",
                metadata: [
                    "vertexCount": "\(vertexCount)",
                    "triangleCount": "\(triangleCount)",
                    "loadMilliseconds": String(format: "%.2f", elapsedMilliseconds),
                ]
            ),
            sourceUnit: .unknown,
            sourceTransform: SceneComposer.sourceTransform(from: scene)
        )
    }
}
