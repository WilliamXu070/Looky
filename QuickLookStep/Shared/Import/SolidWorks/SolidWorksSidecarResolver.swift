import Foundation

struct SolidWorksSidecarResolver: ModelImporter {
    let supportedFormats: Set<ModelFormat> = [.sldprt, .sldasm]

    func load(_ request: ModelLoadRequest) throws -> ImportedScene {
        let format = ModelFormat(url: request.url) ?? .sldprt
        guard let sidecarURL = sidecarURL(for: request.url) else {
            throw ModelImportError.importFailed(
                "SolidWorks .\(request.url.pathExtension) requires an exported STEP/STL/OBJ/3MF/GLB sidecar; native SolidWorks B-rep import is not available"
            )
        }

        do {
            let sidecar = try ModelImportPipeline.loadSynchronously(
                ModelLoadRequest(url: sidecarURL, profile: request.profile)
            )
            var metadata = sidecar.diagnostics.flattenedMetadata
            metadata["sidecarPath"] = sidecarURL.path
            metadata["sidecarFormat"] = sidecarURL.pathExtension.lowercased()
            metadata["solidWorksGeometrySource"] = "sidecar-export"
            return ImportedScene(
                scene: sidecar.scene,
                diagnostics: ImportDiagnostics(
                    format: format,
                    method: "solidworks-sidecar",
                    metadata: metadata,
                    fallbackAttempts: sidecar.diagnostics.fallbackAttempts
                ),
                sourceUnit: sidecar.sourceUnit,
                sourceTransform: sidecar.sourceTransform,
                topologyHints: sidecar.topologyHints
            )
        } catch {
            throw ModelImportError.importFailed(
                "SolidWorks sidecar failed: \(ImportDiagnosticsCollector.shortDescription(error))"
            )
        }
    }

    private func sidecarURL(for sourceURL: URL) -> URL? {
        let extensions = ["step", "stp", "3mf", "glb", "gltf", "obj", "stl"]
        let manager = FileManager.default
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let sourceDirectory = sourceURL.deletingLastPathComponent()
        let directories = [
            sourceDirectory,
            sourceDirectory.deletingLastPathComponent(),
            sourceDirectory.deletingLastPathComponent().deletingLastPathComponent(),
        ]

        for directory in directories {
            for fileExtension in extensions {
                for candidateExtension in [fileExtension, fileExtension.uppercased()] {
                    let candidate = directory
                        .appendingPathComponent(baseName)
                        .appendingPathExtension(candidateExtension)
                    if manager.fileExists(atPath: candidate.path) {
                        return candidate
                    }
                }
            }
        }
        return nil
    }
}
