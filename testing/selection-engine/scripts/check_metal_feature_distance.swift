#!/usr/bin/env swift
import Foundation
import Metal
import simd

private struct PackedFloat3 {
    var x: Float
    var y: Float
    var z: Float

    init(_ value: SIMD3<Float>) {
        x = value.x
        y = value.y
        z = value.z
    }

    var simd: SIMD3<Float> {
        SIMD3<Float>(x, y, z)
    }
}

private struct MetalSegment {
    var start: PackedFloat3
    var end: PackedFloat3
}

private struct MetalQuery {
    var point: PackedFloat3
    var segmentCount: UInt32
}

private func closestPoint(start: SIMD3<Float>, end: SIMD3<Float>, point: SIMD3<Float>) -> SIMD3<Float> {
    let segment = end - start
    let denominator = simd_dot(segment, segment)
    guard denominator > 0 else {
        return start
    }
    let t = max(0, min(1, simd_dot(point - start, segment) / denominator))
    return start + segment * t
}

private func cpuDistance(point: SIMD3<Float>, segments: [MetalSegment]) -> Float {
    var best = Float.greatestFiniteMagnitude
    for segment in segments {
        let closest = closestPoint(start: segment.start.simd, end: segment.end.simd, point: point)
        best = min(best, simd_length(point - closest))
    }
    return best
}

private func gpuDistance(
    device: MTLDevice,
    pipeline: MTLComputePipelineState,
    commandQueue: MTLCommandQueue,
    point: SIMD3<Float>,
    segments: [MetalSegment]
) throws -> Float {
    let threadsPerThreadgroup = threadgroupSize(maxTotalThreads: pipeline.maxTotalThreadsPerThreadgroup)
    let threadgroups = (segments.count + threadsPerThreadgroup - 1) / threadsPerThreadgroup

    guard let segmentBuffer = segments.withUnsafeBytes({ rawBuffer in
        rawBuffer.baseAddress.flatMap {
            device.makeBuffer(bytes: $0, length: rawBuffer.count, options: [.storageModeShared])
        }
    }),
    let partialsBuffer = device.makeBuffer(
        length: MemoryLayout<Float>.stride * threadgroups,
        options: [.storageModeShared]
    ),
    let commandBuffer = commandQueue.makeCommandBuffer(),
    let encoder = commandBuffer.makeComputeCommandEncoder()
    else {
        throw NSError(domain: "check_metal_feature_distance", code: 1)
    }

    var query = MetalQuery(point: PackedFloat3(point), segmentCount: UInt32(segments.count))
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(segmentBuffer, offset: 0, index: 0)
    encoder.setBytes(&query, length: MemoryLayout<MetalQuery>.stride, index: 1)
    encoder.setBuffer(partialsBuffer, offset: 0, index: 2)
    encoder.dispatchThreadgroups(
        MTLSize(width: threadgroups, height: 1, depth: 1),
        threadsPerThreadgroup: MTLSize(width: threadsPerThreadgroup, height: 1, depth: 1)
    )
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    guard commandBuffer.status == .completed else {
        throw NSError(domain: "check_metal_feature_distance", code: 2)
    }

    let partials = partialsBuffer.contents().bindMemory(to: Float.self, capacity: threadgroups)
    var bestSquared = Float.greatestFiniteMagnitude
    for index in 0..<threadgroups {
        bestSquared = min(bestSquared, partials[index])
    }
    return sqrtf(bestSquared)
}

private func threadgroupSize(maxTotalThreads: Int) -> Int {
    let cappedSize = max(1, min(256, maxTotalThreads))
    var size = 1
    while size * 2 <= cappedSize {
        size *= 2
    }
    return size
}

guard MemoryLayout<MetalSegment>.stride == 24 else {
    fatalError("MetalSegment stride \(MemoryLayout<MetalSegment>.stride) != 24")
}
guard MemoryLayout<MetalQuery>.stride == 16 else {
    fatalError("MetalQuery stride \(MemoryLayout<MetalQuery>.stride) != 16")
}
guard ProcessInfo.processInfo.environment["QLS_DISABLE_SELECTION_METAL"] != "1" else {
    fatalError("QLS_DISABLE_SELECTION_METAL=1 disables this validation")
}
guard let device = MTLCreateSystemDefaultDevice(),
      let commandQueue = device.makeCommandQueue() else {
    fatalError("Metal is unavailable")
}

let shaderPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("QuickLookStep/QuickLookStep/SelectionKernels.metal")
let source = try String(contentsOf: shaderPath, encoding: .utf8)
let library = try device.makeLibrary(source: source, options: nil)
guard let function = library.makeFunction(name: "selectionNearestFeatureEdgeDistance") else {
    fatalError("selectionNearestFeatureEdgeDistance kernel missing")
}
let pipeline = try device.makeComputePipelineState(function: function)

private let segments: [MetalSegment] = (0..<1024).map { index in
    let t = Float(index) * 0.037
    return MetalSegment(
        start: PackedFloat3(SIMD3<Float>(sinf(t) * 40, cosf(t * 0.7) * 20, Float(index % 29) - 14)),
        end: PackedFloat3(SIMD3<Float>(sinf(t + 0.31) * 40, cosf(t * 0.7 + 0.19) * 20, Float((index + 7) % 31) - 15))
    )
}
private let points: [SIMD3<Float>] = [
    SIMD3<Float>(0, 0, 0),
    SIMD3<Float>(12.5, -3.25, 8),
    SIMD3<Float>(-33, 11, -9),
    SIMD3<Float>(2.25, 25.5, 4.75),
]

for point in points {
    let cpu = cpuDistance(point: point, segments: segments)
    let gpu = try gpuDistance(device: device, pipeline: pipeline, commandQueue: commandQueue, point: point, segments: segments)
    let delta = abs(cpu - gpu)
    guard delta <= 0.00001 else {
        fatalError("CPU/GPU mismatch point=\(point) cpu=\(cpu) gpu=\(gpu) delta=\(delta)")
    }
    print(String(format: "point=(%.3f,%.3f,%.3f) cpu=%.8f gpu=%.8f delta=%.8f", point.x, point.y, point.z, cpu, gpu, delta))
}
