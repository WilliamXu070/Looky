import Foundation

struct ThreeMFModelImporter: ModelImporter {
    let supportedFormats: Set<ModelFormat> = [.threeMF]

    func load(_ request: ModelLoadRequest) throws -> ImportedScene {
        do {
            let result = try ThreeMFImporter.load(url: request.url)
            return ImportedScene(
                scene: result.scene,
                diagnostics: ImportDiagnostics(
                    format: .threeMF,
                    method: "three-mf-native",
                    metadata: result.metadata
                ),
                sourceTransform: SceneComposer.sourceTransform(from: result.scene)
            )
        } catch {
            let nativeFailure = "three-mf-native:\(ImportDiagnosticsCollector.shortDescription(error))"
            for method in ["scenekit", "modelio"] {
                do {
                    let scene = method == "scenekit"
                        ? try SceneKitAssetLoader.loadWithSceneKit(request.url)
                        : try SceneKitAssetLoader.loadWithModelIO(request.url)
                    return ImportedScene(
                        scene: scene,
                        diagnostics: ImportDiagnostics(
                            format: .threeMF,
                            method: method,
                            metadata: ImportDiagnosticsCollector.metadata(
                                for: scene,
                                url: request.url,
                                method: method,
                                format: .threeMF,
                                materialQuality: nil,
                                degradationReason: nil,
                                fallbackReason: nativeFailure
                            ),
                            fallbackAttempts: [nativeFailure]
                        ),
                        sourceTransform: SceneComposer.sourceTransform(from: scene)
                    )
                } catch {
                    continue
                }
            }
            throw ModelImportError.importFailed(
                "3MF importer failed: \(ImportDiagnosticsCollector.shortDescription(error))"
            )
        }
    }
}
