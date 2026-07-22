import ModelIO
import SceneKit
import SceneKit.ModelIO

enum SceneKitAssetLoader {
    static func loadWithSceneKit(
        _ url: URL,
        sourceName: String? = nil,
        materialPolicy: SceneMaterialPolicy = .preserve
    ) throws -> SCNScene {
        let imported = try SCNScene(url: url, options: nil)
        return try composedScene(
            imported,
            sourceURL: url,
            sourceName: sourceName,
            materialPolicy: materialPolicy
        )
    }

    static func loadWithModelIO(
        _ url: URL,
        sourceName: String? = nil,
        materialPolicy: SceneMaterialPolicy = .preserve
    ) throws -> SCNScene {
        let asset = MDLAsset(url: url)
        guard asset.count > 0 else {
            throw ModelImportError.emptyModel(url)
        }
        return try composedScene(
            SCNScene(mdlAsset: asset),
            sourceURL: url,
            sourceName: sourceName,
            materialPolicy: materialPolicy
        )
    }

    private static func composedScene(
        _ imported: SCNScene,
        sourceURL: URL,
        sourceName: String?,
        materialPolicy: SceneMaterialPolicy
    ) throws -> SCNScene {
        let sourceChildren = imported.rootNode.childNodes
        guard !sourceChildren.isEmpty else {
            throw ModelImportError.emptyModel(sourceURL)
        }

        let modelRoot = SCNNode()
        modelRoot.name = "model-root"
        for child in sourceChildren {
            child.removeFromParentNode()
            modelRoot.addChildNode(child)
        }
        return try SceneComposer.compose(
            from: modelRoot,
            fileName: sourceName ?? sourceURL.lastPathComponent,
            materialPolicy: materialPolicy
        )
    }
}
