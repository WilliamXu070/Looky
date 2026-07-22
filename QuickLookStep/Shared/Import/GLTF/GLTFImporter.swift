import Foundation
import SceneKit
#if canImport(GLTFKit2)
import GLTFKit2
#endif

struct GLTFImporter: ModelImporter {
    let supportedFormats: Set<ModelFormat> = [.gltf, .glb]

    func load(_ request: ModelLoadRequest) throws -> ImportedScene {
        let format = ModelFormat(url: request.url) ?? .glb
        var failures: [String] = []

        #if canImport(GLTFKit2)
        do {
            let scene = try loadWithGLTFKit2(request.url)
            return importedScene(
                scene,
                request: request,
                format: format,
                method: "gltfkit2",
                quality: "native-gltf",
                failures: failures
            )
        } catch {
            failures.append("gltfkit2:\(ImportDiagnosticsCollector.shortDescription(error))")
            NSLog("GLTFKit2 load failed for %@ with %@", request.url.path, error as NSError)
        }
        #else
        failures.append("gltfkit2:module-unavailable")
        #endif

        for method in ["modelio", "scenekit"] {
            do {
                let scene = method == "modelio"
                    ? try SceneKitAssetLoader.loadWithModelIO(request.url)
                    : try SceneKitAssetLoader.loadWithSceneKit(request.url)
                return importedScene(
                    scene,
                    request: request,
                    format: format,
                    method: method,
                    quality: nil,
                    failures: failures
                )
            } catch {
                failures.append("\(method):\(ImportDiagnosticsCollector.shortDescription(error))")
                NSLog("%@ load failed for %@ with %@", method, request.url.path, error as NSError)
            }
        }

        throw ModelImportError.importFailed(
            "No native glTF importer succeeded (\(failures.joined(separator: " | ")))"
        )
    }

    private func importedScene(
        _ scene: SCNScene,
        request: ModelLoadRequest,
        format: ModelFormat,
        method: String,
        quality: String?,
        failures: [String]
    ) -> ImportedScene {
        ImportedScene(
            scene: scene,
            diagnostics: ImportDiagnostics(
                format: format,
                method: method,
                metadata: ImportDiagnosticsCollector.metadata(
                    for: scene,
                    url: request.url,
                    method: method,
                    format: format,
                    materialQuality: quality,
                    degradationReason: nil,
                    fallbackReason: failures.isEmpty ? nil : failures.joined(separator: " | ")
                ),
                fallbackAttempts: failures
            ),
            sourceTransform: SceneComposer.sourceTransform(from: scene)
        )
    }

    #if canImport(GLTFKit2)
    private func loadWithGLTFKit2(_ url: URL) throws -> SCNScene {
        if ProcessInfo.processInfo.environment["QLS_DISABLE_GLTFKIT2"] == "1" {
            throw ModelImportError.importFailed("GLTFKit2 disabled by QLS_DISABLE_GLTFKIT2=1")
        }

        let start = CFAbsoluteTimeGetCurrent()
        let asset = try GLTFAsset(url: url, options: [:])
        let imported = SCNScene(gltfAsset: asset)
        let sourceChildren = imported.rootNode.childNodes
        guard !sourceChildren.isEmpty else {
            throw ModelImportError.emptyModel(url)
        }

        let modelRoot = SCNNode()
        modelRoot.name = "model-root"
        for child in sourceChildren {
            child.removeFromParentNode()
            modelRoot.addChildNode(child)
        }
        NSLog(
            "GLTFKit2 loaded %@ in %.2f ms",
            url.path,
            (CFAbsoluteTimeGetCurrent() - start) * 1000
        )
        return try SceneComposer.compose(from: modelRoot, fileName: url.lastPathComponent)
    }
    #endif
}
