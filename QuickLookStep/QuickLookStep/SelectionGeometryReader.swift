import Foundation
import QuickLookCore
import SceneKit
import simd

struct SelectionGeometryMesh {
    let vertices: [SIMD3<Float>]
    let triangleVertexIndices: [[Int]]
}

enum SelectionGeometryReader {
    static func snapshot(
        from geometry: SCNGeometry,
        sourceID: MeshSourceID,
        sourceUnit: ModelUnit = .unknown,
        transform: ModelTransform = .init(),
        topologyHints: TopologyHints? = nil
    ) -> MeshSnapshot? {
        guard let mesh = readMesh(from: geometry) else { return nil }
        return MeshSnapshot(
            sourceID: sourceID,
            vertices: mesh.vertices,
            triangleIndices: mesh.triangleVertexIndices.map {
                SIMD3<Int32>(Int32($0[0]), Int32($0[1]), Int32($0[2]))
            },
            sourceUnit: sourceUnit,
            transform: transform,
            topologyHints: topologyHints
        )
    }

    static func readMesh(from geometry: SCNGeometry) -> SelectionGeometryMesh? {
        guard let vertexSource = geometry.sources(for: .vertex).first,
              let vertices = readVertices(from: vertexSource),
              !vertices.isEmpty
        else {
            return nil
        }

        var triangleVertexIndices: [[Int]] = []
        triangleVertexIndices.reserveCapacity(geometry.elements.reduce(0) { $0 + $1.primitiveCount })

        for element in geometry.elements where element.primitiveType == .triangles {
            for primitiveIndex in 0..<element.primitiveCount {
                guard
                    let i0 = readIndex(from: element, at: primitiveIndex * 3),
                    let i1 = readIndex(from: element, at: primitiveIndex * 3 + 1),
                    let i2 = readIndex(from: element, at: primitiveIndex * 3 + 2),
                    i0 >= 0, i0 < vertices.count,
                    i1 >= 0, i1 < vertices.count,
                    i2 >= 0, i2 < vertices.count
                else {
                    continue
                }

                triangleVertexIndices.append([i0, i1, i2])
            }
        }

        guard !triangleVertexIndices.isEmpty else {
            return nil
        }
        return SelectionGeometryMesh(vertices: vertices, triangleVertexIndices: triangleVertexIndices)
    }

    static func readVertices(from source: SCNGeometrySource) -> [SIMD3<Float>]? {
        guard source.bytesPerComponent == MemoryLayout<Float>.size,
              source.componentsPerVector >= 3
        else {
            return nil
        }

        var vertices = [SIMD3<Float>]()
        vertices.reserveCapacity(source.vectorCount)
        let stride = max(source.dataStride, source.componentsPerVector * source.bytesPerComponent)
        let offset = source.dataOffset

        let failed = source.data.withUnsafeBytes { raw -> Bool in
            guard let baseAddress = raw.baseAddress else { return true }
            for index in 0..<source.vectorCount {
                let pointer = baseAddress
                    .advanced(by: offset + index * stride)
                    .assumingMemoryBound(to: Float.self)
                let vertex = SIMD3<Float>(pointer[0], pointer[1], pointer[2])
                if !vertex.x.isFinite || !vertex.y.isFinite || !vertex.z.isFinite {
                    return true
                }
                vertices.append(vertex)
            }
            return false
        }

        return failed ? nil : vertices
    }

    static func readIndex(from element: SCNGeometryElement, at position: Int) -> Int? {
        let bytesPerIndex = element.bytesPerIndex
        let byteOffset = position * bytesPerIndex
        guard byteOffset + bytesPerIndex <= element.data.count else {
            return nil
        }

        return element.data.withUnsafeBytes { raw -> Int? in
            guard let baseAddress = raw.baseAddress else { return nil }
            let pointer = baseAddress.advanced(by: byteOffset)
            switch bytesPerIndex {
            case 1:
                return Int(pointer.assumingMemoryBound(to: UInt8.self).pointee)
            case 2:
                return Int(pointer.assumingMemoryBound(to: UInt16.self).pointee)
            case 4:
                return Int(pointer.assumingMemoryBound(to: UInt32.self).pointee)
            default:
                return nil
            }
        }
    }
}
