import Cocoa
import Foundation
import SceneKit

struct ThreeMFImportResult {
    let scene: SCNScene
    let metadata: [String: String]
}

enum ThreeMFImporter {
    enum ImportError: LocalizedError {
        case missingModelXML
        case invalidModel
        case emptyMesh
        case unzipFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingModelXML:
                "3MF package does not contain 3D/3dmodel.model"
            case .invalidModel:
                "3MF model XML could not be parsed"
            case .emptyMesh:
                "3MF model contains no renderable triangles"
            case .unzipFailed(let message):
                "Could not read 3MF package: \(message)"
            }
        }
    }

    fileprivate struct Triangle {
        let v1: Int
        let v2: Int
        let v3: Int
        let pid: String?
        let p1: Int?
        let p2: Int?
        let p3: Int?
    }

    fileprivate struct ObjectMesh {
        let id: String
        let name: String?
        let pid: String?
        let pindex: Int?
        var vertices: [SIMD3<Float>] = []
        var triangles: [Triangle] = []
    }

    static func load(url: URL) throws -> ThreeMFImportResult {
        let xml = try modelXML(from: url)
        let parser = ThreeMFModelParser()
        let model = try parser.parse(data: xml)
        let modelRoot = try buildNode(from: model)
        let scene = try SceneBuilder.standardizedScene(from: modelRoot, fileName: url.lastPathComponent)

        return ThreeMFImportResult(
            scene: scene,
            metadata: [
                "format": "3mf",
                "objectCount": "\(model.objects.count)",
                "vertexCount": "\(model.objects.reduce(0) { $0 + $1.vertices.count })",
                "triangleCount": "\(model.objects.reduce(0) { $0 + $1.triangles.count })",
                "colorCount": "\(model.colors.values.reduce(0) { $0 + $1.count })",
                "normalMode": "flat-face",
            ]
        )
    }

    private static func modelXML(from url: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, "3D/3dmodel.model"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus == 0, !data.isEmpty {
            return data
        }

        let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus != 0 {
            throw ImportError.unzipFailed(message ?? "unzip exited with \(process.terminationStatus)")
        }
        throw ImportError.missingModelXML
    }

    private static func buildNode(from model: ThreeMFModelParser.Model) throws -> SCNNode {
        let root = SCNNode()
        root.name = "model-root"

        for object in model.objects where !object.triangles.isEmpty {
            let node = try buildObjectNode(object, colors: model.colors)
            root.addChildNode(node)
        }

        guard !root.childNodes.isEmpty else {
            throw ImportError.emptyMesh
        }
        return root
    }

    private static func buildObjectNode(
        _ object: ObjectMesh,
        colors: [String: [NSColor]]
    ) throws -> SCNNode {
        var expandedVertices: [SIMD3<Float>] = []
        var expandedNormals: [SIMD3<Float>] = []
        var expandedColors: [SIMD4<Float>] = []
        var indices: [UInt32] = []

        expandedVertices.reserveCapacity(object.triangles.count * 3)
        expandedNormals.reserveCapacity(object.triangles.count * 3)
        expandedColors.reserveCapacity(object.triangles.count * 3)
        indices.reserveCapacity(object.triangles.count * 3)

        for triangle in object.triangles {
            guard
                triangle.v1 >= 0, triangle.v1 < object.vertices.count,
                triangle.v2 >= 0, triangle.v2 < object.vertices.count,
                triangle.v3 >= 0, triangle.v3 < object.vertices.count
            else {
                continue
            }

            let v1 = object.vertices[triangle.v1]
            let v2 = object.vertices[triangle.v2]
            let v3 = object.vertices[triangle.v3]
            let normal = flatNormal(v1, v2, v3)
            let baseIndex = UInt32(expandedVertices.count)

            expandedVertices.append(contentsOf: [v1, v2, v3])
            expandedNormals.append(contentsOf: [normal, normal, normal])

            let firstColorRef: Int? = triangle.p1 ?? triangle.p2 ?? triangle.p3 ?? object.pindex
            let secondColorRef: Int? = triangle.p2 ?? triangle.p1 ?? triangle.p3 ?? object.pindex
            let thirdColorRef: Int? = triangle.p3 ?? triangle.p1 ?? triangle.p2 ?? object.pindex
            let colorRefs: [Int?] = [firstColorRef, secondColorRef, thirdColorRef]
            let colorGroup = triangle.pid ?? object.pid
            for ref in colorRefs {
                expandedColors.append(colorVector(colorGroup: colorGroup, colorIndex: ref, colors: colors))
            }

            indices.append(contentsOf: [baseIndex, baseIndex + 1, baseIndex + 2])
        }

        guard !expandedVertices.isEmpty else {
            throw ImportError.emptyMesh
        }

        let geometry = SCNGeometry(
            sources: [
                geometrySource(expandedVertices, semantic: .vertex, components: 3),
                geometrySource(expandedNormals, semantic: .normal, components: 3),
                geometrySource(expandedColors, semantic: .color, components: 4),
            ],
            elements: [
                SCNGeometryElement(
                    data: indices.withUnsafeBytes { Data($0) },
                    primitiveType: .triangles,
                    primitiveCount: indices.count / 3,
                    bytesPerIndex: MemoryLayout<UInt32>.size
                )
            ]
        )

        let material = SCNMaterial()
        material.name = object.name
        material.lightingModel = .blinn
        material.diffuse.contents = NSColor.white
        material.specular.contents = NSColor(white: 0.16, alpha: 1)
        material.shininess = 10
        material.isDoubleSided = true
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.name = object.name ?? "3mf-object-\(object.id)"
        return node
    }

    private static func flatNormal(_ v1: SIMD3<Float>, _ v2: SIMD3<Float>, _ v3: SIMD3<Float>) -> SIMD3<Float> {
        let crossed = simd_cross(v2 - v1, v3 - v1)
        let length = simd_length(crossed)
        guard length > 0 else {
            return SIMD3<Float>(0, 1, 0)
        }
        return crossed / length
    }

    private static func geometrySource<T>(
        _ values: [T],
        semantic: SCNGeometrySource.Semantic,
        components: Int
    ) -> SCNGeometrySource {
        let stride = MemoryLayout<T>.stride
        let data = values.withUnsafeBytes { Data($0) }
        return SCNGeometrySource(
            data: data,
            semantic: semantic,
            vectorCount: values.count,
            usesFloatComponents: true,
            componentsPerVector: components,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: stride
        )
    }

    private static func colorVector(
        colorGroup: String?,
        colorIndex: Int?,
        colors: [String: [NSColor]]
    ) -> SIMD4<Float> {
        guard
            let colorGroup,
            let colorIndex,
            let group = colors[colorGroup],
            colorIndex >= 0,
            colorIndex < group.count
        else {
            return SIMD4<Float>(0.615, 0.812, 0.929, 1.0)
        }

        let color = group[colorIndex].usingColorSpace(.sRGB) ?? group[colorIndex]
        return SIMD4<Float>(
            Float(color.redComponent),
            Float(color.greenComponent),
            Float(color.blueComponent),
            Float(color.alphaComponent)
        )
    }
}

private final class ThreeMFModelParser: NSObject, XMLParserDelegate {
    struct Model {
        let objects: [ThreeMFImporter.ObjectMesh]
        let colors: [String: [NSColor]]
    }

    private var colors: [String: [NSColor]] = [:]
    private var objects: [ThreeMFImporter.ObjectMesh] = []
    private var activeColorGroupID: String?
    private var activeObject: ThreeMFImporter.ObjectMesh?

    func parse(data: Data) throws -> Model {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = true

        guard parser.parse() else {
            throw ThreeMFImporter.ImportError.invalidModel
        }

        return Model(objects: objects, colors: colors)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch normalized(elementName) {
        case "colorgroup":
            if let id = attributeDict["id"] {
                activeColorGroupID = id
                colors[id] = []
            }
        case "color":
            guard let activeColorGroupID, let hex = attributeDict["color"] else { return }
            colors[activeColorGroupID, default: []].append(Self.color(from: hex))
        case "object":
            guard let id = attributeDict["id"] else { return }
            activeObject = ThreeMFImporter.ObjectMesh(
                id: id,
                name: attributeDict["name"],
                pid: attributeDict["pid"],
                pindex: Self.int(attributeDict["pindex"])
            )
        case "vertex":
            guard var activeObject else { return }
            let vertex = SIMD3<Float>(
                Self.float(attributeDict["x"]),
                Self.float(attributeDict["y"]),
                Self.float(attributeDict["z"])
            )
            activeObject.vertices.append(vertex)
            self.activeObject = activeObject
        case "triangle":
            guard var activeObject else { return }
            let triangle = ThreeMFImporter.Triangle(
                v1: Self.int(attributeDict["v1"]) ?? -1,
                v2: Self.int(attributeDict["v2"]) ?? -1,
                v3: Self.int(attributeDict["v3"]) ?? -1,
                pid: attributeDict["pid"],
                p1: Self.int(attributeDict["p1"]),
                p2: Self.int(attributeDict["p2"]),
                p3: Self.int(attributeDict["p3"])
            )
            activeObject.triangles.append(triangle)
            self.activeObject = activeObject
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch normalized(elementName) {
        case "colorgroup":
            activeColorGroupID = nil
        case "object":
            if let activeObject {
                objects.append(activeObject)
            }
            self.activeObject = nil
        default:
            break
        }
    }

    private func normalized(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    private static func int(_ value: String?) -> Int? {
        guard let value else { return nil }
        return Int(value)
    }

    private static func float(_ value: String?) -> Float {
        guard let value, let result = Float(value) else { return 0 }
        return result
    }

    private static func color(from hex: String) -> NSColor {
        let raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard raw.count == 6 || raw.count == 8, let value = UInt32(raw, radix: 16) else {
            return NSColor(red: 0.615, green: 0.812, blue: 0.929, alpha: 1)
        }

        let r: UInt32
        let g: UInt32
        let b: UInt32
        let a: UInt32
        if raw.count == 8 {
            r = (value >> 24) & 0xff
            g = (value >> 16) & 0xff
            b = (value >> 8) & 0xff
            a = value & 0xff
        } else {
            r = (value >> 16) & 0xff
            g = (value >> 8) & 0xff
            b = value & 0xff
            a = 0xff
        }

        return NSColor(
            red: CGFloat(r) / 255.0,
            green: CGFloat(g) / 255.0,
            blue: CGFloat(b) / 255.0,
            alpha: CGFloat(a) / 255.0
        )
    }
}
