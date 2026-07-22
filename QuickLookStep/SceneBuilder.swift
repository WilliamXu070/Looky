import Foundation
import SceneKit

/// Compatibility facade for callers that still expect a SceneKit-only result.
/// Format routing and import behavior live under Shared/Import.
enum SceneBuilder {
    struct SceneLoadResult {
        let scene: SCNScene
        let method: String
        let metadata: [String: String]
    }

    static var supportedExtensions: Set<String> {
        ModelImportPipeline.supportedExtensions
    }

    static func canLoad(fileURL: URL) -> Bool {
        ModelImportPipeline.canLoad(fileURL)
    }

    static func scene(for url: URL) throws -> SCNScene {
        try sceneWithTrace(for: url).scene
    }

    static func sceneWithTrace(for url: URL) throws -> SceneLoadResult {
        let imported = try ModelImportPipeline.loadSynchronously(.init(url: url))
        return SceneLoadResult(
            scene: imported.scene,
            method: imported.diagnostics.method,
            metadata: imported.diagnostics.flattenedMetadata
        )
    }
}
