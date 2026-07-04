import SceneKit
import SceneKit.ModelIO
import Cocoa
import Quartz
import ModelIO
#if canImport(GLTFKit2)
import GLTFKit2
#endif
#if canImport(AssetImportKit)
import AssetImportKit
#endif


/// A helper that builds a SceneKit scene for supported 3D formats and applies a
/// unified camera/lighting setup so host, preview, and thumbnail agree.
enum SceneBuilder {
    static let supportedExtensions: Set<String> = ["step", "stp", "gltf", "glb", "obj", "stl", "3mf", "sldprt", "sldasm"]
    
    struct SceneLoadResult {
        let scene: SCNScene
        let method: String
        let metadata: [String: String]

        init(scene: SCNScene, method: String, metadata: [String: String] = [:]) {
            self.scene = scene
            self.method = method
            self.metadata = metadata
        }
    }

    enum LoadFormat: String {
        case step = "step"
        case stp = "stp"
        case gltf = "gltf"
        case glb = "glb"
        case obj = "obj"
        case stl = "stl"
        case threeMF = "3mf"
        case sldprt = "sldprt"
        case sldasm = "sldasm"
        case unsupported = ""
    }

    enum SceneBuilderError: LocalizedError {
        case unsupportedFile(String)
        case emptyModel(URL)
        case invalidGeometryBounds
        case stepLoadFailed
        case conversionUnavailable
        case conversionFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFile(let ext):
                "Unsupported model format: .\(ext)"
            case .emptyModel(let url):
                "Model contains no renderable geometry: \(url.lastPathComponent)"
            case .invalidGeometryBounds:
                "Model has invalid geometry bounds"
            case .stepLoadFailed:
                "Failed to load STEP geometry"
            case .conversionUnavailable:
                "Python conversion tooling unavailable for format conversion"
            case .conversionFailed(let message):
                "Failed to convert model to a supported format: \(message)"
            }
        }
    }

    private struct MeshDump: Decodable {
        let meshes: [MeshPartDump]?
        let vertices: [[Double]]
        let normals: [[Double]]?
        let faces: [[Int]]
        let vertexColors: [[Int]]?
        let faceColors: [[Int]]
    }

    private struct MeshPartDump: Decodable {
        let name: String?
        let vertices: [[Double]]
        let normals: [[Double]]?
        let faces: [[Int]]
        let uvs: [[Double]]?
        let vertexColors: [[Int]]?
        let faceColors: [[Int]]
        let materialName: String?
        let diffuseTexturePath: String?
        let normalTexturePath: String?
        let mainColor: [Int]?
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

    static func canLoad(fileURL: URL) -> Bool {
        supportedExtensions.contains(fileURL.pathExtension.lowercased())
    }

    /// Builds a SceneKit scene from supported model files.
    static func scene(for url: URL) throws -> SCNScene {
        try sceneWithTrace(for: url).scene
    }
    
    static func sceneWithTrace(for url: URL) throws -> SceneLoadResult {
        let format = supportedFormat(for: url)
        NSLog("SceneBuilder scene(for:) resolved format=%@ for %@", format.rawValue, url.path)
        switch format {
        case .step, .stp:
            return SceneLoadResult(scene: try sceneFromSTEPFile(url), method: "step-native")
        case .threeMF:
            return try sceneFromThreeMFFileOrConvertWithTrace(url)
        case .gltf, .glb:
            return try sceneFromGLTFFileOrConvertWithTrace(url, primaryFormat: format)
        case .obj, .stl:
            return try sceneFromSceneKitFileOrConvertWithTrace(url, primaryFormat: format)
        case .sldprt, .sldasm:
            return try sceneFromSolidWorksFileOrFallbackWithTrace(url, primaryFormat: format)
        case .unsupported:
            throw SceneBuilderError.unsupportedFile(url.pathExtension)
        }
    }

    private static func supportedFormat(for url: URL) -> LoadFormat {
        LoadFormat(rawValue: url.pathExtension.lowercased()) ?? .unsupported
    }

    private static func sceneFromSceneKitFile(_ url: URL, sourceName: String? = nil) throws -> SCNScene {
        let imported = try SCNScene(url: url, options: nil)
        let sourceChildren = imported.rootNode.childNodes
        guard !sourceChildren.isEmpty else {
            throw SceneBuilderError.emptyModel(url)
        }

        let modelRoot = SCNNode()
        modelRoot.name = "model-root"
        for child in sourceChildren {
            child.removeFromParentNode()
            modelRoot.addChildNode(child)
        }

        applyMeshLightingFixups(to: modelRoot)
        return try buildStandardizedScene(from: modelRoot, fileName: sourceName ?? url.lastPathComponent)
    }

    private static func sceneFromModelIOFile(_ url: URL, sourceName: String? = nil) throws -> SCNScene {
        let asset = MDLAsset(url: url)
        guard asset.count > 0 else {
            throw SceneBuilderError.emptyModel(url)
        }

        let imported = SCNScene(mdlAsset: asset)
        let sourceChildren = imported.rootNode.childNodes
        guard !sourceChildren.isEmpty else {
            throw SceneBuilderError.emptyModel(url)
        }

        let modelRoot = SCNNode()
        modelRoot.name = "model-root"
        for child in sourceChildren {
            child.removeFromParentNode()
            modelRoot.addChildNode(child)
        }

        applyMeshLightingFixups(to: modelRoot)
        return try buildStandardizedScene(from: modelRoot, fileName: sourceName ?? url.lastPathComponent)
    }

    private static func sceneFromGLTFFileOrConvertWithTrace(_ url: URL, primaryFormat: LoadFormat) throws -> SceneLoadResult {
        var fallbackReasons: [String] = []

        #if canImport(GLTFKit2)
        do {
            let scene = try sceneFromGLTFKit2File(url)
            return SceneLoadResult(
                scene: scene,
                method: "gltfkit2",
                metadata: importDiagnosticsMetadata(
                    for: scene,
                    url: url,
                    method: "gltfkit2",
                    format: primaryFormat,
                    materialQuality: "native-gltf",
                    degradationReason: nil,
                    fallbackReason: nil
                )
            )
        } catch {
            fallbackReasons.append("gltfkit2:\(shortErrorDescription(error))")
            NSLog("GLTFKit2 load failed for %@ with %@", url.path, error as NSError)
        }
        #else
        fallbackReasons.append("gltfkit2:module-unavailable")
        #endif

        do {
            let scene = try sceneFromModelIOFile(url)
            return SceneLoadResult(
                scene: scene,
                method: "modelio",
                metadata: importDiagnosticsMetadata(
                    for: scene,
                    url: url,
                    method: "modelio",
                    format: primaryFormat,
                    materialQuality: nil,
                    degradationReason: nil,
                    fallbackReason: nil
                )
            )
        } catch {
            fallbackReasons.append("modelio:\(shortErrorDescription(error))")
            NSLog("Model I/O load failed for %@ with %@", url.path, error as NSError)
        }

        do {
            let scene = try sceneFromSceneKitFile(url)
            return SceneLoadResult(
                scene: scene,
                method: "scenekit",
                metadata: importDiagnosticsMetadata(
                    for: scene,
                    url: url,
                    method: "scenekit",
                    format: primaryFormat,
                    materialQuality: nil,
                    degradationReason: nil,
                    fallbackReason: fallbackReasons.joined(separator: " | ")
                )
            )
        } catch {
            fallbackReasons.append("scenekit:\(shortErrorDescription(error))")
            NSLog("Direct SceneKit load failed for %@ with %@", url.path, error as NSError)
        }

        #if canImport(AssetImportKit)
        do {
            if let importedScene = try attemptAssetImportKitLoad(url) {
                return SceneLoadResult(
                    scene: importedScene,
                    method: "asset-importkit",
                    metadata: importDiagnosticsMetadata(
                        for: importedScene,
                        url: url,
                        method: "asset-importkit",
                        format: primaryFormat,
                        materialQuality: nil,
                        degradationReason: nil,
                        fallbackReason: fallbackReasons.joined(separator: " | ")
                    )
                )
            }
        } catch {
            fallbackReasons.append("asset-importkit:\(shortErrorDescription(error))")
        }
        #endif

        do {
            NSLog("Attempting material-preserving mesh-conversion fallback for %@", url.path)
            let scene = try sceneFromConvertedMeshSource(url)
            NSLog("Loaded %@ via material-preserving mesh-conversion fallback", url.path)
            return SceneLoadResult(
                scene: scene,
                method: "mesh-conversion",
                metadata: importDiagnosticsMetadata(
                    for: scene,
                    url: url,
                    method: "mesh-conversion",
                    format: primaryFormat,
                    materialQuality: "fallback-textured",
                    degradationReason: "mesh-conversion-preserves-uv-diffuse-normal-textures-but-strips-skins-animation-and-some-pbr-metadata",
                    fallbackReason: fallbackReasons.joined(separator: " | ")
                )
            )
        } catch {
            NSLog("Mesh conversion failed for %@: %@", url.path, error.localizedDescription)
            throw error
        }
    }

    #if canImport(GLTFKit2)
    private static func sceneFromGLTFKit2File(_ url: URL) throws -> SCNScene {
        if ProcessInfo.processInfo.environment["QLS_DISABLE_GLTFKIT2"] == "1" {
            throw SceneBuilderError.conversionFailed("GLTFKit2 disabled by QLS_DISABLE_GLTFKIT2=1")
        }

        let start = CFAbsoluteTimeGetCurrent()
        let asset = try GLTFAsset(url: url, options: [:])
        let imported = SCNScene(gltfAsset: asset)
        let sourceChildren = imported.rootNode.childNodes
        guard !sourceChildren.isEmpty else {
            throw SceneBuilderError.emptyModel(url)
        }

        let modelRoot = SCNNode()
        modelRoot.name = "model-root"
        for child in sourceChildren {
            child.removeFromParentNode()
            modelRoot.addChildNode(child)
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        NSLog("GLTFKit2 loaded %@ in %.2f ms", url.path, elapsed)
        return try buildStandardizedScene(from: modelRoot, fileName: url.lastPathComponent)
    }
    #endif

    private static func sceneFromSceneKitFileOrConvertWithTrace(_ url: URL, primaryFormat: LoadFormat) throws -> SceneLoadResult {
        do {
            let scene = try sceneFromSceneKitFile(url)
            return SceneLoadResult(
                scene: scene,
                method: "scenekit",
                metadata: importDiagnosticsMetadata(
                    for: scene,
                    url: url,
                    method: "scenekit",
                    format: primaryFormat,
                    materialQuality: nil,
                    degradationReason: nil,
                    fallbackReason: nil
                )
            )
        } catch {
            NSLog("Direct SceneKit load failed for %@ with %@", url.path, error as NSError)
            #if canImport(AssetImportKit)
            if let importedScene = try attemptAssetImportKitLoad(url) {
                return SceneLoadResult(
                    scene: importedScene,
                    method: "asset-importkit",
                    metadata: importDiagnosticsMetadata(
                        for: importedScene,
                        url: url,
                        method: "asset-importkit",
                        format: primaryFormat,
                        materialQuality: nil,
                        degradationReason: nil,
                        fallbackReason: "scenekit:\(shortErrorDescription(error))"
                    )
                )
            }
            #endif
            switch primaryFormat {
            case .gltf, .glb, .obj, .stl, .threeMF, .sldprt, .sldasm:
                do {
                    NSLog("Attempting mesh-conversion fallback for %@", url.path)
                    let scene = try sceneFromConvertedMeshSource(url)
                    NSLog("Loaded %@ via mesh-conversion fallback", url.path)
                    return SceneLoadResult(
                        scene: scene,
                        method: "mesh-conversion",
                        metadata: importDiagnosticsMetadata(
                            for: scene,
                            url: url,
                            method: "mesh-conversion",
                            format: primaryFormat,
                            materialQuality: "degraded",
                            degradationReason: "mesh-conversion-strips-uv-textures-normal-maps-pbr-skins-animation",
                            fallbackReason: "scenekit:\(shortErrorDescription(error))"
                        )
                    )
                } catch {
                    NSLog("Mesh conversion failed for %@: %@", url.path, error.localizedDescription)
                    throw error
                }
            case .step, .unsupported, .stp:
                throw error
            }
        }
    }

    private static func sceneFromThreeMFFileOrConvertWithTrace(_ url: URL) throws -> SceneLoadResult {
        do {
            let result = try ThreeMFImporter.load(url: url)
            NSLog("Loaded %@ via native 3MF importer with metadata %@", url.path, result.metadata)
            return SceneLoadResult(scene: result.scene, method: "three-mf-native", metadata: result.metadata)
        } catch {
            NSLog("Native 3MF load failed for %@ with %@", url.path, error as NSError)
            return try sceneFromSceneKitFileOrConvertWithTrace(url, primaryFormat: .threeMF)
        }
    }

    private static func sceneFromSolidWorksFileOrFallbackWithTrace(_ url: URL, primaryFormat: LoadFormat) throws -> SceneLoadResult {
        var fallbackReasons: [String] = []

        do {
            let scene = try sceneFromModelIOFile(url)
            return SceneLoadResult(
                scene: scene,
                method: "modelio-solidworks",
                metadata: importDiagnosticsMetadata(
                    for: scene,
                    url: url,
                    method: "modelio-solidworks",
                    format: primaryFormat,
                    materialQuality: nil,
                    degradationReason: nil,
                    fallbackReason: nil
                )
            )
        } catch {
            fallbackReasons.append("modelio:\(shortErrorDescription(error))")
            NSLog("Model I/O SolidWorks load failed for %@ with %@", url.path, error as NSError)
        }

        do {
            let scene = try sceneFromSceneKitFile(url)
            return SceneLoadResult(
                scene: scene,
                method: "scenekit-solidworks",
                metadata: importDiagnosticsMetadata(
                    for: scene,
                    url: url,
                    method: "scenekit-solidworks",
                    format: primaryFormat,
                    materialQuality: nil,
                    degradationReason: nil,
                    fallbackReason: fallbackReasons.joined(separator: " | ")
                )
            )
        } catch {
            fallbackReasons.append("scenekit:\(shortErrorDescription(error))")
            NSLog("Direct SceneKit SolidWorks load failed for %@ with %@", url.path, error as NSError)
        }

        if let sidecarURL = solidWorksSidecarModelURL(for: url) {
            do {
                let result = try solidWorksSceneLoadResult(from: sidecarURL, sourceURL: url, sourceFormat: primaryFormat, sourceKind: "sidecar-export", fallbackReasons: fallbackReasons)
                NSLog("Loaded %@ via SolidWorks sidecar %@", url.path, sidecarURL.path)
                return result
            } catch {
                fallbackReasons.append("sidecar:\(shortErrorDescription(error))")
                NSLog("SolidWorks sidecar load failed for %@ with %@", sidecarURL.path, error as NSError)
            }
        }

        let converterLookup = solidWorksConverterLookup()
        if let converter = converterLookup.url {
            do {
                let convertedURL = try convertedSolidWorksSidecarURL(for: url, converterURL: converter)
                let result = try solidWorksSceneLoadResult(from: convertedURL, sourceURL: url, sourceFormat: primaryFormat, sourceKind: "local-converter", fallbackReasons: fallbackReasons)
                NSLog("Loaded %@ via SolidWorks local converter output %@", url.path, convertedURL.path)
                return result
            } catch {
                fallbackReasons.append("local-converter:\(shortErrorDescription(error))")
                NSLog("SolidWorks local converter failed for %@ with %@", url.path, error as NSError)
            }
        } else {
            fallbackReasons.append("local-converter:\(converterLookup.diagnostic)")
        }

        throw SceneBuilderError.conversionFailed(
            "SolidWorks .\(url.pathExtension) requires an exported STEP/STL/OBJ/3MF/GLB sidecar or configured local converter; \(converterLookup.diagnostic); native SolidWorks B-rep import is not available in this build"
        )
    }

    static func standardizedScene(from modelRoot: SCNNode, fileName: String) throws -> SCNScene {
        try buildStandardizedScene(from: modelRoot, fileName: fileName)
    }

    private static func solidWorksSidecarModelURL(for url: URL) -> URL? {
        let preferredExtensions = ["step", "stp", "3mf", "glb", "gltf", "obj", "stl"]
        return siblingURL(for: url, extensions: preferredExtensions)
    }

    private static func solidWorksSceneLoadResult(
        from outputURL: URL,
        sourceURL: URL,
        sourceFormat: LoadFormat,
        sourceKind: String,
        fallbackReasons: [String]
    ) throws -> SceneLoadResult {
        let result = try sceneWithTrace(for: outputURL)
        var metadata = result.metadata
        metadata["loadMethod"] = "solidworks-\(sourceKind)-\(result.method)"
        metadata["sourceFormat"] = sourceFormat.rawValue
        metadata["solidWorksOutputPath"] = outputURL.path
        metadata["solidWorksOutputFormat"] = outputURL.pathExtension.lowercased()
        metadata["solidWorksGeometrySource"] = sourceKind
        metadata["solidWorksSourcePath"] = sourceURL.path
        metadata["fallbackReason"] = fallbackReasons.joined(separator: " | ")
        return SceneLoadResult(scene: result.scene, method: "solidworks-\(sourceKind)", metadata: metadata)
    }

    private struct SolidWorksConverterLookup {
        let url: URL?
        let diagnostic: String
    }

    private static func solidWorksConverterLookup() -> SolidWorksConverterLookup {
        var rejected: [String] = []
        for candidate in solidWorksConverterPathCandidates() {
            let expanded = NSString(string: candidate.value).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                NSLog("Using SolidWorks converter from %@: %@", candidate.source, url.path)
                return SolidWorksConverterLookup(url: url, diagnostic: "converter=\(candidate.source)")
            }
            NSLog("Ignoring non-executable SolidWorks converter from %@: %@", candidate.source, url.path)
            rejected.append("\(candidate.source)-not-executable:\(url.path)")
        }

        if !rejected.isEmpty {
            return SolidWorksConverterLookup(url: nil, diagnostic: rejected.joined(separator: " | "))
        }

        return SolidWorksConverterLookup(
            url: nil,
            diagnostic: "no converter configured; set QLS_SOLIDWORKS_CONVERTER env or defaults key com.johnboiles.QuickLookStep QLS_SOLIDWORKS_CONVERTER"
        )
    }

    private static func solidWorksConverterPathCandidates() -> [(source: String, value: String)] {
        let keys = ["QLS_SOLIDWORKS_CONVERTER", "solidWorksConverterPath"]
        var candidates: [(String, String)] = []

        if let value = ProcessInfo.processInfo.environment["QLS_SOLIDWORKS_CONVERTER"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            candidates.append(("env:QLS_SOLIDWORKS_CONVERTER", value))
        }

        for key in keys {
            if let value = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                candidates.append(("defaults:\(key)", value))
            }
        }

        for key in keys {
            if let value = solidWorksConverterPathFromPreferencesFile(key: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                candidates.append(("container-preferences:\(key)", value))
            }
        }

        return candidates
    }

    private static func solidWorksConverterPathFromPreferencesFile(key: String) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent("com.johnboiles.QuickLookStep", isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("com.johnboiles.QuickLookStep.plist")

        guard let values = NSDictionary(contentsOf: url) as? [String: Any] else {
            return nil
        }
        return values[key] as? String
    }

    private static func convertedSolidWorksSidecarURL(for sourceURL: URL, converterURL: URL) throws -> URL {
        let outputDirectory = try solidWorksConversionOutputDirectory(for: sourceURL)
        let existing = solidWorksModelURL(in: outputDirectory, basename: sourceURL.deletingPathExtension().lastPathComponent)
        if let existing {
            NSLog("Using cached SolidWorks converter output %@", existing.path)
            return existing
        }

        let process = Process()
        process.executableURL = converterURL
        process.arguments = [sourceURL.path, outputDirectory.path]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let start = CFAbsoluteTimeGetCurrent()
        try process.run()
        process.waitUntilExit()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw SceneBuilderError.conversionFailed("SolidWorks converter failed with exit \(process.terminationStatus): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        let printedOutput = stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        if let printedOutput {
            let printedURL = URL(fileURLWithPath: NSString(string: printedOutput).expandingTildeInPath)
            if isSupportedSolidWorksOutput(printedURL), FileManager.default.fileExists(atPath: printedURL.path) {
                NSLog("SolidWorks converter produced %@ in %.2f ms", printedURL.path, elapsed)
                return printedURL
            }
        }

        if let generated = solidWorksModelURL(in: outputDirectory, basename: sourceURL.deletingPathExtension().lastPathComponent) {
            NSLog("SolidWorks converter produced %@ in %.2f ms", generated.path, elapsed)
            return generated
        }

        throw SceneBuilderError.conversionFailed("SolidWorks converter completed but did not produce STEP/STL/OBJ/3MF/GLB output in \(outputDirectory.path)")
    }

    private static func solidWorksConversionOutputDirectory(for sourceURL: URL) throws -> URL {
        let manager = FileManager.default
        let caches = try manager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let sourceFingerprint = try solidWorksSourceFingerprint(for: sourceURL)
        let outputDirectory = caches
            .appendingPathComponent("QuickLookStep", isDirectory: true)
            .appendingPathComponent("SolidWorksConversions", isDirectory: true)
            .appendingPathComponent(sourceFingerprint, isDirectory: true)
        try manager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        return outputDirectory
    }

    private static func solidWorksSourceFingerprint(for sourceURL: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let source = "\(sourceURL.path)|\(size)|\(modified)"
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(format: "%016llx", hash)
    }

    private static func solidWorksModelURL(in directory: URL, basename: String) -> URL? {
        let preferredExtensions = ["step", "stp", "3mf", "glb", "gltf", "obj", "stl"]
        let manager = FileManager.default

        for ext in preferredExtensions {
            let exact = directory.appendingPathComponent(basename).appendingPathExtension(ext)
            if manager.fileExists(atPath: exact.path) {
                return exact
            }
            let uppercase = directory.appendingPathComponent(basename).appendingPathExtension(ext.uppercased())
            if manager.fileExists(atPath: uppercase.path) {
                return uppercase
            }
        }

        guard let contents = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        return contents.first { isSupportedSolidWorksOutput($0) }
    }

    private static func isSupportedSolidWorksOutput(_ url: URL) -> Bool {
        ["step", "stp", "3mf", "glb", "gltf", "obj", "stl"].contains(url.pathExtension.lowercased())
    }

    private static func siblingURL(for url: URL, extensions: [String]) -> URL? {
        let manager = FileManager.default
        let baseName = url.deletingPathExtension().lastPathComponent
        let directories = [
            url.deletingLastPathComponent(),
            url.deletingLastPathComponent().deletingLastPathComponent(),
            url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),
        ]

        for directory in directories {
            for ext in extensions {
                let candidate = directory.appendingPathComponent(baseName).appendingPathExtension(ext)
                if manager.fileExists(atPath: candidate.path) {
                    return candidate
                }
                let uppercaseCandidate = directory.appendingPathComponent(baseName).appendingPathExtension(ext.uppercased())
                if manager.fileExists(atPath: uppercaseCandidate.path) {
                    return uppercaseCandidate
                }
            }
        }

        return nil
    }

    #if canImport(AssetImportKit)
    private static func attemptAssetImportKitLoad(_ url: URL) throws -> SCNScene? {
        guard SCNScene.canImportFileExtension(url.pathExtension.lowercased()) else {
            return nil
        }
        let importerStart = CFAbsoluteTimeGetCurrent()
        NSLog("Attempting AssetImportKit load for %@", url.path)

        let importerScene = try SCNScene.assimpScene(
            with: url,
            postProcessSteps: .defaultQuality
        )

        let modelRoot = SCNNode()
        modelRoot.name = "model-root"
        for child in importerScene.modelScene.rootNode.childNodes {
            child.removeFromParentNode()
            modelRoot.addChildNode(child)
        }

        guard !modelRoot.childNodes.isEmpty else {
            return nil
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - importerStart) * 1000.0
        NSLog("AssetImportKit loaded %@ in %.2f ms", url.path, elapsed)
        return try buildStandardizedScene(from: modelRoot, fileName: url.lastPathComponent)
    }
    #endif

    private static func sceneFromConvertedMeshSource(_ sourceURL: URL) throws -> SCNScene {
        let jsonURL = try exportedMeshJSON(for: sourceURL)

        do {
            let data = try Data(contentsOf: jsonURL)
            let dump = try JSONDecoder().decode(MeshDump.self, from: data)

            let model = try sceneFromMeshDump(dump)
            return try buildStandardizedScene(from: model, fileName: sourceURL.lastPathComponent)
        } catch {
            NSLog("Failed to load converted mesh dump for %@ from %@: %@", sourceURL.path, jsonURL.path, error.localizedDescription)
            throw SceneBuilderError.conversionFailed("Unable to parse mesh conversion result")
        }
    }

    private static func sceneFromMeshDump(_ dump: MeshDump) throws -> SCNNode {
        if let meshParts = dump.meshes, !meshParts.isEmpty {
            let modelRoot = SCNNode()
            modelRoot.name = "model-root"
            for part in meshParts {
                let node = try sceneNodeFromMeshPartDump(part)
                modelRoot.addChildNode(node)
            }
            guard !modelRoot.childNodes.isEmpty else {
                throw SceneBuilderError.emptyModel(URL(fileURLWithPath: ""))
            }
            return modelRoot
        }

        let legacyPart = MeshPartDump(
            name: nil,
            vertices: dump.vertices,
            normals: dump.normals,
            faces: dump.faces,
            uvs: nil,
            vertexColors: dump.vertexColors,
            faceColors: dump.faceColors,
            materialName: nil,
            diffuseTexturePath: nil,
            normalTexturePath: nil,
            mainColor: nil
        )
        return try sceneNodeFromMeshPartDump(legacyPart)
    }

    private static func sceneNodeFromMeshPartDump(_ dump: MeshPartDump) throws -> SCNNode {
        guard !dump.vertices.isEmpty else {
            throw SceneBuilderError.emptyModel(URL(fileURLWithPath: ""))
        }
        guard !dump.faces.isEmpty else {
            throw SceneBuilderError.emptyModel(URL(fileURLWithPath: ""))
        }

        var vertices = [SIMD3<Float>]()
        vertices.reserveCapacity(dump.vertices.count)
        for vertex in dump.vertices {
            guard vertex.count >= 3 else {
                continue
            }
            vertices.append(SIMD3<Float>(Float(vertex[0]), Float(vertex[1]), Float(vertex[2])))
        }
        guard !vertices.isEmpty else {
            throw SceneBuilderError.emptyModel(URL(fileURLWithPath: ""))
        }

        var normals = [SIMD3<Float>]()
        if let normalsData = dump.normals, !normalsData.isEmpty {
            normals.reserveCapacity(min(normalsData.count, vertices.count))
            for normal in normalsData where normal.count >= 3 {
                normals.append(SIMD3<Float>(Float(normal[0]), Float(normal[1]), Float(normal[2])))
            }
        }

        var flatVertexColors: [SIMD4<Float>]?
        if let colors = dump.vertexColors, colors.count == dump.vertices.count {
            flatVertexColors = []
            flatVertexColors?.reserveCapacity(colors.count)

            for color in colors where color.count >= 3 {
                let r = color.count > 0 ? Float(color[0]) / 255.0 : 1
                let g = color.count > 1 ? Float(color[1]) / 255.0 : r
                let b = color.count > 2 ? Float(color[2]) / 255.0 : g
                let a = color.count > 3 ? Float(color[3]) / 255.0 : 1
                flatVertexColors?.append(SIMD4<Float>(x: r, y: g, z: b, w: a))
            }
        }

        guard let firstFace = dump.faces.first, firstFace.count == 3 else {
            throw SceneBuilderError.emptyModel(URL(fileURLWithPath: ""))
        }

        let vertexData = vertices.withUnsafeBytes { Data($0) }
        let vertexSource = SCNGeometrySource(
            data: vertexData,
            semantic: .vertex,
            vectorCount: vertices.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.size
        )

        let indexFlat = dump.faces.flatMap { face in
            face.compactMap { Int32($0) }
        }
        let indexData = indexFlat.withUnsafeBytes { Data($0) }

        let geometryElement = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: dump.faces.count,
            bytesPerIndex: MemoryLayout<Int32>.size
        )

        var sources: [SCNGeometrySource] = [vertexSource]
        if !normals.isEmpty && normals.count == vertices.count {
            let normalData = normals.withUnsafeBytes { Data($0) }
            let normalSource = SCNGeometrySource(
                data: normalData,
                semantic: .normal,
                vectorCount: normals.count,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<SIMD3<Float>>.size
            )
            sources.append(normalSource)
        }

        if let vertexColors = flatVertexColors, vertexColors.count == vertices.count {
            let colorData = vertexColors.withUnsafeBytes { Data($0) }
            let colorSource = SCNGeometrySource(
                data: colorData,
                semantic: .color,
                vectorCount: vertexColors.count,
                usesFloatComponents: true,
                componentsPerVector: 4,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<SIMD4<Float>>.size
            )
            sources.append(colorSource)
        }

        if let uvData = textureCoordinateSource(from: dump.uvs, expectedCount: vertices.count) {
            sources.append(uvData)
        }

        let geometry = SCNGeometry(sources: sources, elements: [geometryElement])

        let material = SCNMaterial()
        material.name = dump.materialName
        material.lightingModel = dump.diffuseTexturePath != nil ? .physicallyBased : .blinn
        material.diffuse.contents = materialContents(
            texturePath: dump.diffuseTexturePath,
            fallbackColor: flatVertexColors != nil ? NSColor.white : normalizedDefaultColor(
                from: dump.vertexColors,
                faceColors: dump.faceColors,
                mainColor: dump.mainColor
            )
        )
        if let normalPath = dump.normalTexturePath {
            material.normal.contents = URL(fileURLWithPath: normalPath)
            material.normal.minificationFilter = .linear
            material.normal.magnificationFilter = .linear
            material.normal.mipFilter = .linear
        }
        material.diffuse.minificationFilter = .linear
        material.diffuse.magnificationFilter = .linear
        material.diffuse.mipFilter = .linear
        material.specular.contents = NSColor(white: 0.18, alpha: 1)
        material.roughness.contents = 0.48
        material.metalness.contents = 0
        material.shininess = 18
        material.isDoubleSided = true
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.name = dump.name
        return node
    }

    private static func textureCoordinateSource(from uvs: [[Double]]?, expectedCount: Int) -> SCNGeometrySource? {
        guard let uvs, uvs.count == expectedCount else {
            return nil
        }

        var coordinates = [SIMD2<Float>]()
        coordinates.reserveCapacity(expectedCount)
        for uv in uvs {
            guard uv.count >= 2 else {
                return nil
            }
            coordinates.append(SIMD2<Float>(Float(uv[0]), Float(1.0 - uv[1])))
        }

        let data = coordinates.withUnsafeBytes { Data($0) }
        return SCNGeometrySource(
            data: data,
            semantic: .texcoord,
            vectorCount: coordinates.count,
            usesFloatComponents: true,
            componentsPerVector: 2,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD2<Float>>.size
        )
    }

    private static func materialContents(texturePath: String?, fallbackColor: NSColor) -> Any {
        guard let texturePath, FileManager.default.fileExists(atPath: texturePath) else {
            return fallbackColor
        }
        return URL(fileURLWithPath: texturePath)
    }

    private static func normalizedDefaultColor(from vertexColors: [[Int]]?, faceColors: [[Int]], mainColor: [Int]? = nil) -> NSColor {
        if let mainColor, mainColor.count >= 3 {
            return NSColor(
                red: CGFloat(Double(mainColor[0]) / 255.0),
                green: CGFloat(Double(mainColor[1]) / 255.0),
                blue: CGFloat(Double(mainColor[2]) / 255.0),
                alpha: mainColor.count > 3 ? CGFloat(Double(mainColor[3]) / 255.0) : 1
            )
        }

        if let colors = vertexColors, let first = colors.first, first.count >= 3 {
            return NSColor(
                red: CGFloat(Double(first[0]) / 255.0),
                green: CGFloat(Double(first[1]) / 255.0),
                blue: CGFloat(Double(first[2]) / 255.0),
                alpha: first.count > 3 ? CGFloat(Double(first[3]) / 255.0) : 1
            )
        }

        if let first = faceColors.first, first.count >= 3 {
            return NSColor(
                red: CGFloat(Double(first[0]) / 255.0),
                green: CGFloat(Double(first[1]) / 255.0),
                blue: CGFloat(Double(first[2]) / 255.0),
                alpha: first.count > 3 ? CGFloat(Double(first[3]) / 255.0) : 1
            )
        }

        return NSColor(red: 0.615, green: 0.812, blue: 0.929, alpha: 1)
    }

    private static func exportedMeshJSON(for url: URL) throws -> URL {
        guard let pythonURL = fallbackPythonURL() else {
            throw SceneBuilderError.conversionUnavailable
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quicklookstep-exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let outputURL = temporaryDirectory
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("json")

        let convertScript = """
        import json
        import pathlib
        import numpy as np
        import trimesh
        import sys
        import re

        source_path = pathlib.Path(sys.argv[1])
        output_path = pathlib.Path(sys.argv[2])
        texture_dir = output_path.with_suffix('')
        texture_dir.mkdir(parents=True, exist_ok=True)

        def safe_name(value):
            value = str(value or 'material')
            value = re.sub(r'[^A-Za-z0-9_.-]+', '_', value).strip('_')
            return value[:120] or 'material'

        def color_array(value):
            if value is None:
                return None
            try:
                arr = np.asarray(value).reshape(-1)
                if arr.size < 3:
                    return None
                if arr.max(initial=0) <= 1.0:
                    arr = arr * 255.0
                if arr.size < 4:
                    arr = np.append(arr[:3], 255)
                return np.clip(arr[:4], 0, 255).astype(int).tolist()
            except Exception:
                return None

        def save_texture(image, stem, suffix):
            if image is None:
                return None
            try:
                texture_path = texture_dir / f'{safe_name(stem)}_{suffix}.png'
                image.save(texture_path)
                return str(texture_path)
            except Exception:
                return None

        def mesh_payload(mesh, name=None, index=0):
            visual = getattr(mesh, 'visual', None)
            vertex_colors = None
            face_colors = []
            uvs = None
            material_name = None
            diffuse_texture = None
            normal_texture = None
            main_color = None

            if visual is not None:
                if getattr(visual, 'kind', None) == 'texture':
                    if hasattr(visual, 'uv') and visual.uv is not None:
                        uvs = np.asarray(visual.uv).tolist()
                    material = getattr(visual, 'material', None)
                    if material is not None:
                        material_name = getattr(material, 'name', None)
                        texture_stem = material_name or name or f'mesh_{index}'
                        diffuse_texture = save_texture(
                            getattr(material, 'baseColorTexture', None) or getattr(material, 'image', None),
                            texture_stem,
                            'diffuse'
                        )
                        normal_texture = save_texture(
                            getattr(material, 'normalTexture', None),
                            texture_stem,
                            'normal'
                        )
                        main_color = color_array(getattr(material, 'main_color', None))
                else:
                    color_visual = visual
                    if hasattr(color_visual, 'to_color'):
                        try:
                            color_visual = color_visual.to_color()
                        except Exception:
                            pass

                    if hasattr(color_visual, 'vertex_colors'):
                        vertex_colors = color_visual.vertex_colors
                        if hasattr(vertex_colors, 'ndim') and vertex_colors.ndim == 1 and len(vertex_colors) == 4:
                            vertex_colors = np.repeat(vertex_colors[np.newaxis, :], len(mesh.vertices), axis=0)

                    if hasattr(color_visual, 'face_colors'):
                        face_colors = color_visual.face_colors

                    if face_colors is not None and len(np.shape(face_colors)) == 1 and len(face_colors) == 4:
                        face_colors = np.repeat(face_colors[np.newaxis, :], len(mesh.faces), axis=0)

            return {
                'name': name,
                'vertices': np.asarray(mesh.vertices).tolist(),
                'normals': np.asarray(mesh.vertex_normals).tolist() if hasattr(mesh, 'vertex_normals') else None,
                'faces': np.asarray(mesh.faces).astype(np.int32).tolist(),
                'uvs': uvs,
                'vertexColors': None if vertex_colors is None else np.asarray(vertex_colors).astype(int).tolist(),
                'faceColors': [] if face_colors is None else np.asarray(face_colors).astype(int).tolist(),
                'materialName': material_name,
                'diffuseTexturePath': diffuse_texture,
                'normalTexturePath': normal_texture,
                'mainColor': main_color,
            }

        scene = trimesh.load(str(source_path), force='scene')
        meshes = []
        if isinstance(scene, trimesh.Scene):
            for index, (name, mesh) in enumerate(scene.geometry.items()):
                if mesh.is_empty:
                    continue
                meshes.append(mesh_payload(mesh, name=name, index=index))

        if meshes:
            payload = {
                'meshes': meshes,
                'vertices': [],
                'normals': None,
                'faces': [],
                'vertexColors': None,
                'faceColors': [],
            }
            output_path.write_text(json.dumps(payload), encoding='utf-8')
            raise SystemExit(0)

        mesh = trimesh.load(str(source_path), force='mesh')
        if mesh.is_empty:
            raise RuntimeError('Mesh was empty')

        if hasattr(mesh, 'visual'):
            visual = mesh.visual
            if hasattr(visual, 'to_color'):
                try:
                    visual = visual.to_color()
                except Exception:
                    pass

            vertex_colors = None
            face_colors = []
            if hasattr(visual, 'vertex_colors'):
                vertex_colors = visual.vertex_colors
                if hasattr(vertex_colors, 'ndim') and vertex_colors.ndim == 1 and len(vertex_colors) == 4:
                    vertex_colors = np.repeat(vertex_colors[np.newaxis, :], len(mesh.vertices), axis=0)

            if hasattr(visual, 'face_colors'):
                face_colors = visual.face_colors

            if face_colors is not None and len(np.shape(face_colors)) == 1 and len(face_colors) == 4:
                face_colors = np.repeat(face_colors[np.newaxis, :], len(mesh.faces), axis=0)
        else:
            vertex_colors = None
            face_colors = []

        payload = {
            'vertices': np.asarray(mesh.vertices).tolist(),
            'normals': np.asarray(mesh.vertex_normals).tolist() if hasattr(mesh, 'vertex_normals') else None,
            'faces': np.asarray(mesh.faces).astype(np.int32).tolist(),
            'vertexColors': None if vertex_colors is None else np.asarray(vertex_colors).astype(int).tolist(),
            'faceColors': [] if face_colors is None else np.asarray(face_colors).astype(int).tolist(),
        }
        output_path.write_text(json.dumps(payload), encoding='utf-8')
        """

        let process = Process()
        process.executableURL = pythonURL
        process.arguments = ["-c", convertScript, url.path, outputURL.path]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !errText.isEmpty {
            NSLog("Python mesh export stderr for %@: %@", url.path, errText)
        }

        guard process.terminationStatus == 0 else {
            let errMessage = errText.isEmpty ? "Unknown conversion error" : errText
            throw SceneBuilderError.conversionFailed(errMessage.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw SceneBuilderError.conversionFailed("Converted mesh JSON not generated")
        }

        return outputURL
    }

    private static func fallbackPythonURL() -> URL? {
        var candidates: [String] = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
            "/opt/anaconda3/bin/python3",
            "/opt/local/bin/python3",
        ]

        let pathDirs = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map { String($0) } ?? []
        for dir in pathDirs {
            candidates.append("\(dir)/python3")
            candidates.append("\(dir)/python")
        }

        var seen = Set<String>()
        for candidate in candidates {
            guard !seen.contains(candidate) else { continue }
            seen.insert(candidate)

            if FileManager.default.fileExists(atPath: candidate) {
                let candidateURL = URL(fileURLWithPath: candidate)
                if canImportTrimesh(pythonURL: candidateURL) {
                    return candidateURL
                }
            }
        }

        return nil
    }

    private static func canImportTrimesh(pythonURL: URL) -> Bool {
        let probe = Process()
        probe.executableURL = pythonURL
        probe.arguments = ["-c", "import trimesh"]
        probe.standardOutput = Pipe()
        probe.standardError = Pipe()
        do {
            try probe.run()
            probe.waitUntilExit()
            return probe.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func sceneFromSTEPFile(_ url: URL) throws -> SCNScene {
        // --- Load via FFI and measure duration ---
        var mesh = MeshSlice()
        let start = CFAbsoluteTimeGetCurrent()
        let ok = url.path.withCString { cPath in
            foxtrot_load_step(cPath, &mesh)
        }
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        NSLog("foxtrot_load_step(%@) -> %@ in %.2f ms", url.path, ok ? "OK" : "FAIL", elapsedMs)
        guard ok else {
            throw SceneBuilderError.stepLoadFailed
        }
        defer { foxtrot_free_mesh(mesh) }

        // Build SceneKit geometry from the raw buffers.
        let vertexCount = Int(mesh.vert_count)
        let indexCount = Int(mesh.tri_count) * 3
        guard vertexCount > 0 else {
            throw SceneBuilderError.emptyModel(url)
        }
        guard indexCount > 0 else {
            throw SceneBuilderError.emptyModel(url)
        }
        guard let vertexPointer = mesh.verts, let indexPointer = mesh.tris else {
            throw SceneBuilderError.stepLoadFailed
        }

        let vertexData = Data(
            bytes: vertexPointer,
            count: vertexCount * 3 * MemoryLayout<Float>.size
        )
        let vertexSource = SCNGeometrySource(
            data: vertexData,
            semantic: .vertex,
            vectorCount: vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: 3 * MemoryLayout<Float>.size
        )

        let geometryElement = SCNGeometryElement(
            data: Data(bytes: indexPointer, count: indexCount * MemoryLayout<UInt32>.size),
            primitiveType: .triangles,
            primitiveCount: Int(mesh.tri_count),
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let baseGeometry = SCNGeometry(sources: [vertexSource], elements: [geometryElement])
        let fixedGeometry = ensureNormalsIfMissing(for: baseGeometry)
        let stepMaterial = SCNMaterial()
        stepMaterial.lightingModel = .blinn
        stepMaterial.diffuse.contents = NSColor(white: 0.9, alpha: 1)
        stepMaterial.isDoubleSided = true
        fixedGeometry.materials = [stepMaterial]

        let modelRoot = SCNNode()
        modelRoot.name = "model-root"
        modelRoot.addChildNode(SCNNode(geometry: fixedGeometry))
        return try buildStandardizedScene(from: modelRoot, fileName: url.lastPathComponent)
    }

    private static func buildStandardizedScene(from modelRoot: SCNNode, fileName: String) throws -> SCNScene {
        applyMeshLightingFixups(to: modelRoot)

        if modelRoot.parent != nil {
            modelRoot.removeFromParentNode()
        }

        let scene = SCNScene()
        scene.rootNode.addChildNode(modelRoot)

        // --- Scale & centre geometry ---
        let (minBounds, maxBounds) = modelRoot.boundingBox
        let size = SCNVector3(
            maxBounds.x - minBounds.x,
            maxBounds.y - minBounds.y,
            maxBounds.z - minBounds.z
        )

        // Uniformly scale so the largest dimension maps to `targetSize` units.
        let targetSize: CGFloat = 100.0
        let maxExtent = max(size.x, max(size.y, size.z))
        guard maxExtent.isFinite, maxExtent > 0 else {
            throw SceneBuilderError.invalidGeometryBounds
        }
        let scaleFactor = targetSize / maxExtent
        let sf = Float(scaleFactor)
        modelRoot.scale = SCNVector3(sf, sf, sf)

        // Re-centre so model origin is at (0,0,0)
        let center = SCNVector3(
            (maxBounds.x + minBounds.x) / 2.0,
            (maxBounds.y + minBounds.y) / 2.0,
            (maxBounds.z + minBounds.z) / 2.0
        )
        modelRoot.position = SCNVector3(
            Float(-center.x * scaleFactor),
            Float(-center.y * scaleFactor),
            Float(-center.z * scaleFactor)
        )

        // --- Camera setup ---
        let cameraNode = scene.rootNode.childNode(withName: "camera", recursively: true) ?? SCNNode()
        cameraNode.name = "camera"
        let camera = SCNCamera()
        camera.zNear = 1
        camera.zFar = 10000
        camera.fieldOfView = 45
        cameraNode.camera = camera

        // Place camera so the entire bounding sphere fits inside the view.
        let sx = Float(size.x), sy = Float(size.y), sz = Float(size.z)
        let radius = (sqrt(sx*sx + sy*sy + sz*sz) / 2.0) * sf
        guard radius.isFinite && radius > 0 else {
            throw SceneBuilderError.invalidGeometryBounds
        }
        let fovRadians = (Float(camera.fieldOfView) / 2.0) * (.pi / 180.0)
        let distance = radius / tanf(fovRadians)
        cameraNode.position = SCNVector3(distance, distance, distance)
        cameraNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(cameraNode)

        // --- Lighting ---
        func makeOmni(intensity: CGFloat, position: SCNVector3) -> SCNNode {
            let lightNode = SCNNode()
            lightNode.light = SCNLight()
            lightNode.light?.type = .omni
            lightNode.light?.intensity = intensity
            lightNode.position = position
            return lightNode
        }
        scene.rootNode.addChildNode(makeOmni(intensity: 850, position: cameraNode.position))
        scene.rootNode.addChildNode(makeOmni(intensity: 700, position: SCNVector3(0, 0, -targetSize * 2)))

        let directionalNode = SCNNode()
        directionalNode.light = SCNLight()
        directionalNode.light?.type = .directional
        directionalNode.light?.intensity = 450
        directionalNode.light?.castsShadow = true
        directionalNode.eulerAngles = SCNVector3(-0.4, 0.4, 0)
        scene.rootNode.addChildNode(directionalNode)

        let ambientNode = SCNNode()
        ambientNode.light = SCNLight()
        ambientNode.light?.type = .ambient
        ambientNode.light?.color = NSColor(white: 1, alpha: 1)
        ambientNode.light?.intensity = 170
        scene.rootNode.addChildNode(ambientNode)

        NSLog("SceneBuilder loaded %@ successfully", fileName)
        return scene
    }

    private static func importDiagnosticsMetadata(
        for scene: SCNScene,
        url: URL,
        method: String,
        format: LoadFormat,
        materialQuality explicitMaterialQuality: String?,
        degradationReason: String?,
        fallbackReason: String?
    ) -> [String: String] {
        let diagnostics = sceneMaterialDiagnostics(for: scene)
        var metadata = diagnostics.metadata
        metadata["sourceFormat"] = format.rawValue
        metadata["loadMethod"] = method
        metadata["materialQuality"] = explicitMaterialQuality ?? inferredMaterialQuality(
            diagnostics: diagnostics,
            format: format
        )
        metadata["textureResolutionHint"] = textureResolutionHint(for: url)

        if let degradationReason, !degradationReason.isEmpty {
            metadata["degradationReason"] = degradationReason
        }
        if let fallbackReason, !fallbackReason.isEmpty {
            metadata["fallbackReason"] = fallbackReason
        }

        NSLog("SceneBuilder import diagnostics for %@: %@", url.lastPathComponent, metadata)
        return metadata
    }

    private static func sceneMaterialDiagnostics(for scene: SCNScene) -> SceneMaterialDiagnostics {
        var diagnostics = SceneMaterialDiagnostics()

        scene.rootNode.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else {
                return
            }

            diagnostics.geometryCount += 1
            diagnostics.triangleCount += geometry.elements.reduce(0) { total, element in
                total + (element.primitiveType == .triangles ? element.primitiveCount : 0)
            }

            for material in geometry.materials {
                diagnostics.materialCount += 1

                let diffuseTexture = isTextureBacked(material.diffuse)
                let normalTexture = isTextureBacked(material.normal)
                let textureSlots = [
                    material.diffuse,
                    material.normal,
                    material.ambientOcclusion,
                    material.emission,
                    material.metalness,
                    material.multiply,
                    material.reflective,
                    material.roughness,
                    material.specular,
                    material.transparent,
                ].filter(isTextureBacked(_:)).count

                if diffuseTexture {
                    diagnostics.diffuseTextureMaterialCount += 1
                }
                if normalTexture {
                    diagnostics.normalMapMaterialCount += 1
                }
                if textureSlots > 0 {
                    diagnostics.texturedMaterialCount += 1
                    diagnostics.textureSlotCount += textureSlots
                }
                if material.lightingModel == .physicallyBased {
                    diagnostics.pbrMaterialCount += 1
                }
            }
        }

        return diagnostics
    }

    private static func isTextureBacked(_ property: SCNMaterialProperty) -> Bool {
        guard let contents = property.contents else {
            return false
        }
        if contents is NSColor || contents is NSNumber {
            return false
        }
        return true
    }

    private static func inferredMaterialQuality(
        diagnostics: SceneMaterialDiagnostics,
        format: LoadFormat
    ) -> String {
        switch format {
        case .gltf, .glb:
            if diagnostics.texturedMaterialCount > 0 || diagnostics.pbrMaterialCount > 0 {
                return "full"
            }
            return "possibly-degraded"
        case .obj, .stl:
            return diagnostics.texturedMaterialCount > 0 ? "textured" : "untextured"
        case .step, .stp, .threeMF, .sldprt, .sldasm, .unsupported:
            return "not-evaluated"
        }
    }

    private static func textureResolutionHint(for url: URL) -> String {
        switch supportedFormat(for: url) {
        case .gltf:
            return "external-uris-may-require-model-parent-texture-search"
        case .glb:
            return "glb-usually-embedded-but-external-textures-can-be-used-as-recovery-overrides"
        case .sldprt, .sldasm:
            return "solidworks-native-geometry-requires-sidecar-export"
        default:
            return "not-applicable"
        }
    }

    private static func shortErrorDescription(_ error: Error) -> String {
        let text = (error as NSError).localizedDescription
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(220))
    }

    private static func applyMeshLightingFixups(to modelRoot: SCNNode) {
        modelRoot.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else {
                return
            }

            let fixedGeometry = ensureNormalsIfMissing(for: geometry)
            node.geometry = fixedGeometry

            if fixedGeometry.materials.isEmpty {
                fixedGeometry.materials = [defaultLitMaterial()]
            }

            for material in fixedGeometry.materials {
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

    private static func ensureNormalsIfMissing(for geometry: SCNGeometry) -> SCNGeometry {
        if !geometry.sources(for: .normal).isEmpty {
            return geometry
        }
        guard let vertexSource = geometry.sources(for: .vertex).first else {
            return geometry
        }
        let vertexCount = vertexSource.vectorCount
        guard vertexCount > 0 else {
            return geometry
        }
        guard geometry.elements.allSatisfy({ $0.primitiveType == .triangles }) else {
            return geometry
        }

        let vertexData = vertexSource.data
        let vertexStride = max(vertexSource.dataStride, vertexSource.bytesPerComponent * vertexSource.componentsPerVector)
        let vertexOffset = vertexSource.dataOffset
        let bytesPerComponent = vertexSource.bytesPerComponent
        guard bytesPerComponent == MemoryLayout<Float>.size else {
            return geometry
        }

        var vertices = [SIMD3<Float>](repeating: SIMD3<Float>(repeating: 0), count: vertexCount)
        let readVertexFailure = vertexData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return false }
            for index in 0..<vertexCount {
                let pointer = base.advanced(by: vertexOffset + (index * vertexStride))
                    .assumingMemoryBound(to: Float.self)
                let x = pointer[0]
                let y = pointer[1]
                let z = pointer[2]
                if [x, y, z].contains(where: { !$0.isFinite }) {
                    return true
                }
                vertices[index] = SIMD3<Float>(x: x, y: y, z: z)
            }
            return false
        }
        guard !readVertexFailure else {
            return geometry
        }

        var normalSums = [SIMD3<Float>](repeating: SIMD3<Float>(repeating: 0), count: vertexCount)

        func sub(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> SIMD3<Float> {
            lhs - rhs
        }

        func length(_ vector: SIMD3<Float>) -> Float {
            simd_length(vector)
        }

        func readIndex(_ element: SCNGeometryElement, _ position: Int) -> Int? {
            let bytesPerIndex = element.bytesPerIndex
            guard bytesPerIndex == 2 || bytesPerIndex == 4 else {
                return nil
            }
            return element.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
                guard let base = raw.baseAddress else { return nil }
                let baseIndex = base.advanced(by: position * bytesPerIndex)
                switch bytesPerIndex {
                case 2:
                    return Int(baseIndex.assumingMemoryBound(to: UInt16.self).pointee)
                default:
                    return Int(baseIndex.assumingMemoryBound(to: UInt32.self).pointee)
                }
            }
        }

        let hadInvalidIndex = geometry.elements.withUnsafeBufferPointer { _ in
            var invalid = false
            for element in geometry.elements {
                let triCount = element.primitiveCount
                for indexOffset in 0..<triCount {
                    let base = indexOffset * 3
                    guard
                        let i0 = readIndex(element, base),
                        let i1 = readIndex(element, base + 1),
                        let i2 = readIndex(element, base + 2),
                        i0 < vertexCount,
                        i1 < vertexCount,
                        i2 < vertexCount,
                        i0 >= 0,
                        i1 >= 0,
                        i2 >= 0
                    else {
                        invalid = true
                        continue
                    }

                    let v0 = vertices[i0]
                    let v1 = vertices[i1]
                    let v2 = vertices[i2]
                    let edge1 = sub(v1, v0)
                    let edge2 = sub(v2, v0)
                    var faceNormal = simd_cross(edge1, edge2)
                    let faceLength = length(faceNormal)
                    guard faceLength > 0 else {
                        continue
                    }
                    let inv = 1.0 / faceLength
                    faceNormal = faceNormal * inv

                    normalSums[i0] += faceNormal
                    normalSums[i1] += faceNormal
                    normalSums[i2] += faceNormal
                }
            }
            return invalid
        }
        guard !hadInvalidIndex else {
            return geometry
        }

        var normalData = Data(capacity: vertexCount * 3 * MemoryLayout<Float>.size)
        for normal in normalSums {
            var normalToWrite = normal
            let len = length(normalToWrite)
            if len > 0 {
                let inv = 1.0 / len
                normalToWrite *= inv
            } else {
                normalToWrite = SIMD3<Float>(0, 1, 0)
            }
            var x = normalToWrite.x
            var y = normalToWrite.y
            var z = normalToWrite.z
            normalData.append(Data(bytes: &x, count: MemoryLayout<Float>.size))
            normalData.append(Data(bytes: &y, count: MemoryLayout<Float>.size))
            normalData.append(Data(bytes: &z, count: MemoryLayout<Float>.size))
        }

        let normalSource = SCNGeometrySource(
            data: normalData,
            semantic: .normal,
            vectorCount: vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: 3 * MemoryLayout<Float>.size
        )

        var sources = geometry.sources.filter { $0.semantic != .normal }
        sources.append(normalSource)
        let rebuilt = SCNGeometry(sources: sources, elements: geometry.elements)
        rebuilt.materials = geometry.materials
        return rebuilt
    }
}
