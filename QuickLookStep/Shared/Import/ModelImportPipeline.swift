import Foundation

enum ModelImportPipeline {
    private static let importers: [any ModelImporter] = [
        STEPImporter(),
        GLTFImporter(),
        SceneKitAssetImporter(),
        ThreeMFModelImporter(),
        SolidWorksSidecarResolver(),
    ]

    static var supportedExtensions: Set<String> {
        Set(importers.flatMap(\.supportedFormats).map(\.rawValue))
    }

    static func canLoad(_ url: URL) -> Bool {
        guard let format = ModelFormat(url: url) else { return false }
        return importers.contains { $0.supportedFormats.contains(format) }
    }

    static func loadSynchronously(_ request: ModelLoadRequest) throws -> ImportedScene {
        guard let format = ModelFormat(url: request.url) else {
            throw ModelImportError.unsupportedFormat(request.url.pathExtension)
        }
        guard let importer = importers.first(where: { $0.supportedFormats.contains(format) }) else {
            throw ModelImportError.noImporter(format)
        }
        return try importer.load(request)
    }

    static func load(_ request: ModelLoadRequest) async throws -> ImportedScene {
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try loadSynchronously(request)
        }.value
    }
}
