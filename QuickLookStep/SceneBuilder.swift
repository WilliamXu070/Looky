import SceneKit
import Cocoa
import Quartz
#if canImport(AssetImportKit)
import AssetImportKit
#endif


/// A helper that builds a SceneKit scene for supported 3D formats and applies a
/// unified camera/lighting setup so host, preview, and thumbnail agree.
enum SceneBuilder {
    static let supportedExtensions: Set<String> = ["step", "stp", "gltf", "glb", "obj", "stl", "3mf"]
    
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
        let vertices: [[Double]]
        let normals: [[Double]]?
        let faces: [[Int]]
        let vertexColors: [[Int]]?
        let faceColors: [[Int]]
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
        case .gltf, .glb, .obj, .stl:
            return try sceneFromSceneKitFileOrConvertWithTrace(url, primaryFormat: format)
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

    private static func sceneFromSceneKitFileOrConvertWithTrace(_ url: URL, primaryFormat: LoadFormat) throws -> SceneLoadResult {
        do {
            return SceneLoadResult(scene: try sceneFromSceneKitFile(url), method: "scenekit")
        } catch {
            NSLog("Direct SceneKit load failed for %@ with %@", url.path, error as NSError)
            #if canImport(AssetImportKit)
            if let importedScene = try attemptAssetImportKitLoad(url) {
                return SceneLoadResult(scene: importedScene, method: "asset-importkit")
            }
            #endif
            switch primaryFormat {
            case .gltf, .glb, .obj, .stl, .threeMF:
                do {
                    NSLog("Attempting mesh-conversion fallback for %@", url.path)
                    let scene = try sceneFromConvertedMeshSource(url)
                    NSLog("Loaded %@ via mesh-conversion fallback", url.path)
                    return SceneLoadResult(scene: scene, method: "mesh-conversion")
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

    static func standardizedScene(from modelRoot: SCNNode, fileName: String) throws -> SCNScene {
        try buildStandardizedScene(from: modelRoot, fileName: fileName)
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

        let geometry = SCNGeometry(sources: sources, elements: [geometryElement])

        let material = SCNMaterial()
        material.lightingModel = .blinn
        material.diffuse.contents = flatVertexColors != nil ? NSColor.white : normalizedDefaultColor(from: dump.vertexColors, faceColors: dump.faceColors)
        material.specular.contents = NSColor(white: 0.18, alpha: 1)
        material.shininess = 18
        material.isDoubleSided = true
        geometry.materials = [material]

        return SCNNode(geometry: geometry)
    }

    private static func normalizedDefaultColor(from vertexColors: [[Int]]?, faceColors: [[Int]]) -> NSColor {
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

        source_path = pathlib.Path(sys.argv[1])
        output_path = pathlib.Path(sys.argv[2])

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

        let indexData = Data(
            bytes: indexPointer,
            count: indexCount * MemoryLayout<UInt32>.size
        )
        let geometryElement = SCNGeometryElement(
            data: indexData,
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
