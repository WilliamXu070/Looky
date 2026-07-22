import Foundation
import SceneKit

enum ModelFormat: String, CaseIterable, Sendable {
    case step
    case stp
    case gltf
    case glb
    case obj
    case stl
    case threeMF = "3mf"
    case sldprt
    case sldasm

    init?(url: URL) {
        self.init(rawValue: url.pathExtension.lowercased())
    }
}

enum ModelRenderProfile: String, Sendable {
    case interactive
    case preview
    case thumbnail
}

struct ModelLoadRequest: Sendable {
    let url: URL
    let profile: ModelRenderProfile

    init(url: URL, profile: ModelRenderProfile = .interactive) {
        self.url = url
        self.profile = profile
    }
}

enum ImportedModelUnit: String, Sendable {
    case unknown
    case millimeter
    case centimeter
    case meter
    case inch
}

struct ImportedModelTransform: Sendable {
    let sourceToSceneScale: Float
    let sourceCenter: SIMD3<Float>

    static let identity = ImportedModelTransform(sourceToSceneScale: 1, sourceCenter: .zero)
}

struct ImportedTopologyHints: Sendable {
    let faceTriangleGroups: [String: [Int]]
    let edgeSegmentGroups: [String: [[Int]]]

    static let empty = ImportedTopologyHints(faceTriangleGroups: [:], edgeSegmentGroups: [:])
}

struct ImportDiagnostics: Sendable {
    let format: ModelFormat
    let method: String
    let metadata: [String: String]
    let fallbackAttempts: [String]

    init(
        format: ModelFormat,
        method: String,
        metadata: [String: String] = [:],
        fallbackAttempts: [String] = []
    ) {
        self.format = format
        self.method = method
        self.metadata = metadata
        self.fallbackAttempts = fallbackAttempts
    }

    var flattenedMetadata: [String: String] {
        var result = metadata
        result["sourceFormat"] = format.rawValue
        result["loadMethod"] = method
        if !fallbackAttempts.isEmpty {
            result["fallbackAttempts"] = fallbackAttempts.joined(separator: " | ")
        }
        return result
    }
}

struct ImportedScene {
    let scene: SCNScene
    let diagnostics: ImportDiagnostics
    let sourceUnit: ImportedModelUnit
    let sourceTransform: ImportedModelTransform
    let topologyHints: ImportedTopologyHints

    init(
        scene: SCNScene,
        diagnostics: ImportDiagnostics,
        sourceUnit: ImportedModelUnit = .unknown,
        sourceTransform: ImportedModelTransform = .identity,
        topologyHints: ImportedTopologyHints = .empty
    ) {
        self.scene = scene
        self.diagnostics = diagnostics
        self.sourceUnit = sourceUnit
        self.sourceTransform = sourceTransform
        self.topologyHints = topologyHints
    }
}

protocol ModelImporter {
    var supportedFormats: Set<ModelFormat> { get }
    func load(_ request: ModelLoadRequest) throws -> ImportedScene
}

enum ModelImportError: LocalizedError {
    case unsupportedFormat(String)
    case noImporter(ModelFormat)
    case emptyModel(URL)
    case invalidGeometryBounds
    case stepLoadFailed
    case importFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let value):
            "Unsupported model format: .\(value)"
        case .noImporter(let format):
            "No importer is registered for .\(format.rawValue)"
        case .emptyModel(let url):
            "Model contains no renderable geometry: \(url.lastPathComponent)"
        case .invalidGeometryBounds:
            "Model has invalid geometry bounds"
        case .stepLoadFailed:
            "Failed to load STEP geometry"
        case .importFailed(let message):
            "Failed to import model: \(message)"
        }
    }
}
