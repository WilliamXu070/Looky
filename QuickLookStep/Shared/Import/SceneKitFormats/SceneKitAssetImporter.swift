import Foundation
import SceneKit

struct SceneKitAssetImporter: ModelImporter {
    let supportedFormats: Set<ModelFormat> = [.obj, .stl]

    func load(_ request: ModelLoadRequest) throws -> ImportedScene {
        let format = ModelFormat(url: request.url) ?? .obj
        let methods = format == .obj
            ? OBJImportPolicy().preferredMethods
            : STLImportPolicy().preferredMethods
        let materialPolicy = format == .obj
            ? OBJImportPolicy().materialPolicy(for: request.url)
            : STLImportPolicy().materialPolicy
        var failures: [String] = []

        for method in methods {
            do {
                let scene: SCNScene
                switch method {
                case "scenekit":
                    scene = try SceneKitAssetLoader.loadWithSceneKit(
                        request.url,
                        materialPolicy: materialPolicy
                    )
                case "modelio":
                    scene = try SceneKitAssetLoader.loadWithModelIO(
                        request.url,
                        materialPolicy: materialPolicy
                    )
                default:
                    continue
                }
                return ImportedScene(
                    scene: scene,
                    diagnostics: ImportDiagnostics(
                        format: format,
                        method: method,
                        metadata: ImportDiagnosticsCollector.metadata(
                            for: scene,
                            url: request.url,
                            method: method,
                            format: format,
                            materialQuality: nil,
                            degradationReason: nil,
                            fallbackReason: failures.isEmpty ? nil : failures.joined(separator: " | ")
                        ),
                        fallbackAttempts: failures
                    ),
                    sourceTransform: SceneComposer.sourceTransform(from: scene)
                )
            } catch {
                failures.append("\(method):\(ImportDiagnosticsCollector.shortDescription(error))")
            }
        }

        throw ModelImportError.importFailed(
            "No native \(format.rawValue) importer succeeded (\(failures.joined(separator: " | ")))"
        )
    }
}
