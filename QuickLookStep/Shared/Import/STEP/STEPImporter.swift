import AppKit
import Foundation
import SceneKit
import simd

struct STEPImporter: ModelImporter {
    let supportedFormats: Set<ModelFormat> = [.step, .stp]

    func load(_ request: ModelLoadRequest) throws -> ImportedScene {
        var mesh = MeshSlice()
        let start = CFAbsoluteTimeGetCurrent()
        let loaded = request.url.path.withCString { path in
            foxtrot_load_step(path, &mesh)
        }
        let elapsedMilliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
        NSLog(
            "foxtrot_load_step(%@) -> %@ in %.2f ms",
            request.url.path,
            loaded ? "OK" : "FAIL",
            elapsedMilliseconds
        )
        guard loaded else {
            throw ModelImportError.stepLoadFailed
        }
        defer { foxtrot_free_mesh(mesh) }

        let vertexCount = Int(mesh.vert_count)
        let triangleCount = Int(mesh.tri_count)
        guard vertexCount > 0, triangleCount > 0 else {
            throw ModelImportError.emptyModel(request.url)
        }
        guard let vertexPointer = mesh.verts, let indexPointer = mesh.tris else {
            throw ModelImportError.stepLoadFailed
        }

        let vertexSource = SCNGeometrySource(
            data: Data(bytes: vertexPointer, count: vertexCount * 3 * MemoryLayout<Float>.size),
            semantic: .vertex,
            vectorCount: vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: 3 * MemoryLayout<Float>.size
        )
        let element = SCNGeometryElement(
            data: Data(bytes: indexPointer, count: triangleCount * 3 * MemoryLayout<UInt32>.size),
            primitiveType: .triangles,
            primitiveCount: triangleCount,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        var sources = [vertexSource]
        if let normalPointer = mesh.normals {
            sources.append(
                SCNGeometrySource(
                    data: Data(bytes: normalPointer, count: vertexCount * 3 * MemoryLayout<Float>.size),
                    semantic: .normal,
                    vectorCount: vertexCount,
                    usesFloatComponents: true,
                    componentsPerVector: 3,
                    bytesPerComponent: MemoryLayout<Float>.size,
                    dataOffset: 0,
                    dataStride: 3 * MemoryLayout<Float>.size
                )
            )
        }
        let geometry = SceneComposer.ensureNormalsIfMissing(
            for: SCNGeometry(sources: sources, elements: [element])
        )
        let material = SCNMaterial()
        material.lightingModel = .blinn
        material.diffuse.contents = NSColor(white: 0.9, alpha: 1)
        material.isDoubleSided = true
        geometry.materials = [material]

        let modelRoot = SCNNode()
        modelRoot.name = "model-root"
        modelRoot.addChildNode(SCNNode(geometry: geometry))
        let scene = try SceneComposer.compose(from: modelRoot, fileName: request.url.lastPathComponent)
        let format = ModelFormat(url: request.url) ?? .step
        let modelHash = Self.modelHash(for: request.url)
        let topologyHints = Self.topologyHints(
            from: mesh,
            triangleCount: triangleCount,
            modelHash: modelHash
        )
        let sourceUnit = Self.sourceUnit(from: mesh.length_unit)
        return ImportedScene(
            scene: scene,
            diagnostics: ImportDiagnostics(
                format: format,
                method: "step-native",
                metadata: [
                    "vertexCount": "\(vertexCount)",
                    "triangleCount": "\(triangleCount)",
                    "exactFaceCount": "\(topologyHints.faces.count)",
                    "exactEdgeCount": "\(topologyHints.edges.count)",
                    "modelHash": modelHash,
                    "stepLengthUnit": sourceUnit.rawValue,
                    "loadMilliseconds": String(format: "%.2f", elapsedMilliseconds),
                ]
            ),
            sourceUnit: sourceUnit,
            sourceTransform: SceneComposer.sourceTransform(from: scene),
            topologyHints: topologyHints
        )
    }

    private static func sourceUnit(from rawValue: UInt32) -> ImportedModelUnit {
        switch rawValue {
        case 1: .millimeter
        case 2: .centimeter
        case 3: .meter
        case 4: .inch
        case 5: .foot
        default: .unknown
        }
    }

    private static func topologyHints(
        from mesh: MeshSlice,
        triangleCount: Int,
        modelHash: String
    ) -> ImportedTopologyHints {
        let faces: [ImportedFaceTopology]
        if let pointer = mesh.faces, mesh.face_count > 0 {
            faces = UnsafeBufferPointer(start: pointer, count: Int(mesh.face_count)).compactMap { record in
                let start = Int(record.triangle_start)
                let end = start + Int(record.triangle_count)
                guard start >= 0, start < end, end <= triangleCount else { return nil }
                return ImportedFaceTopology(
                    sourceID: faceID(modelHash, record.brep_id, record.instance_id, record.entity_id),
                    triangleIndices: Array(start..<end),
                    descriptor: ImportedSurfaceDescriptor(
                        kind: surfaceKind(record.surface_kind),
                        origin: optionalVector(record.origin),
                        axis: optionalVector(record.axis),
                        normal: optionalVector(record.normal),
                        radius: optionalPositive(record.radius),
                        secondaryRadius: optionalPositive(record.secondary_radius),
                        halfAngle: optionalPositive(record.half_angle)
                    )
                )
            }
        } else {
            faces = []
        }

        let edgePoints = mesh.edge_points.map {
            UnsafeBufferPointer(start: $0, count: Int(mesh.edge_point_count))
        }
        let incidentFaceIDs = mesh.edge_incident_face_ids.map {
            UnsafeBufferPointer(start: $0, count: Int(mesh.edge_incident_face_id_count))
        }
        let edges: [ImportedEdgeTopology]
        if let pointer = mesh.edges, mesh.edge_count > 0,
           let edgePoints, let incidentFaceIDs {
            edges = UnsafeBufferPointer(start: pointer, count: Int(mesh.edge_count)).compactMap { record in
                let pointStart = Int(record.point_start)
                let pointEnd = pointStart + Int(record.point_count)
                let faceStart = Int(record.incident_face_start)
                let faceEnd = faceStart + Int(record.incident_face_count)
                guard pointStart >= 0, pointStart < pointEnd, pointEnd <= edgePoints.count,
                      faceStart >= 0, faceStart <= faceEnd, faceEnd <= incidentFaceIDs.count else {
                    return nil
                }
                let points = edgePoints[pointStart..<pointEnd].map(vector)
                guard points.count >= 2 else { return nil }
                return ImportedEdgeTopology(
                    sourceID: edgeID(modelHash, record.brep_id, record.instance_id, record.entity_id),
                    points: points,
                    incidentFaceIDs: incidentFaceIDs[faceStart..<faceEnd].map {
                        faceID(modelHash, record.brep_id, record.instance_id, $0)
                    },
                    descriptor: ImportedCurveDescriptor(kind: curveKind(record.curve_kind))
                )
            }
        } else {
            edges = []
        }

        return ImportedTopologyHints(faces: faces, edges: edges)
    }

    private static func faceID(
        _ modelHash: String,
        _ brepID: UInt64,
        _ instanceID: UInt64,
        _ entityID: UInt64
    ) -> String {
        "step:\(modelHash):brep:\(brepID):instance:\(instanceID):face:\(entityID)"
    }

    private static func edgeID(
        _ modelHash: String,
        _ brepID: UInt64,
        _ instanceID: UInt64,
        _ entityID: UInt64
    ) -> String {
        "step:\(modelHash):brep:\(brepID):instance:\(instanceID):edge:\(entityID)"
    }

    private static func modelHash(for url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "unavailable" }
        defer { try? handle.close() }
        var hash: UInt64 = 0xcbf29ce484222325
        while true {
            let data = try? handle.read(upToCount: 256 * 1024)
            guard let chunk = data, !chunk.isEmpty else { break }
            for byte in chunk {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3
            }
        }
        return String(format: "fnv1a64-%016llx", hash)
    }

    private static func surfaceKind(_ rawValue: UInt32) -> ImportedSurfaceKind {
        switch rawValue {
        case 1: .plane
        case 2: .cylinder
        case 3: .cone
        case 4: .sphere
        case 5: .torus
        case 6: .bSpline
        default: .other
        }
    }

    private static func curveKind(_ rawValue: UInt32) -> ImportedCurveKind {
        switch rawValue {
        case 1: .line
        case 2: .circle
        case 3: .ellipse
        case 4: .bSpline
        default: .other
        }
    }

    private static func vector(_ value: FoxtrotFloat3) -> SIMD3<Float> {
        SIMD3<Float>(value.x, value.y, value.z)
    }

    private static func optionalVector(_ value: FoxtrotFloat3) -> SIMD3<Float>? {
        let result = vector(value)
        return simd_length_squared(result) > 0 ? result : nil
    }

    private static func optionalPositive(_ value: Float) -> Float? {
        value.isFinite && value > 0 ? value : nil
    }
}
