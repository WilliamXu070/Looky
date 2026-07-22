import Foundation
import Metal
import simd

private struct SelectionMetalPackedFloat3 {
    var x: Float
    var y: Float
    var z: Float

    init(_ point: SIMD3<Float>) {
        x = point.x
        y = point.y
        z = point.z
    }
}

private struct SelectionMetalFeatureSegment {
    var start: SelectionMetalPackedFloat3
    var end: SelectionMetalPackedFloat3

    init(_ segment: SelectionFeatureSegment) {
        start = SelectionMetalPackedFloat3(segment.start)
        end = SelectionMetalPackedFloat3(segment.end)
    }
}

private struct SelectionMetalDistanceQuery {
    var point: SelectionMetalPackedFloat3
    var segmentCount: UInt32
}

final class SelectionMetalAccelerator: SelectionDistanceBackend {
    let name = "metal"
    static let disabledByEnvironment = ProcessInfo.processInfo.environment["QLS_DISABLE_SELECTION_METAL"] == "1"
    static let explicitlyEnabled = ProcessInfo.processInfo.environment["QLS_ENABLE_SELECTION_METAL"] == "1"
        || ProcessInfo.processInfo.environment["QLS_SELECTION_METAL_MIN_SEGMENTS"] != nil
    static let minimumSegmentThreshold: Int = {
        guard explicitlyEnabled else {
            return .max
        }
        guard let rawValue = ProcessInfo.processInfo.environment["QLS_SELECTION_METAL_MIN_SEGMENTS"],
              let parsedValue = Int(rawValue)
        else {
            return 256
        }
        return max(1, parsedValue)
    }()

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let threadsPerThreadgroup: Int
    private var cachedFingerprint: UInt64?
    private var cachedSegmentCount = 0
    private var cachedSegmentBuffer: MTLBuffer?
    private var cachedPartialsCapacity = 0
    private var cachedPartialsBuffer: MTLBuffer?

    init?() {
        guard Self.disabledByEnvironment == false,
              let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue()
        else {
            return nil
        }

        let library = (try? device.makeDefaultLibrary(bundle: .main)) ?? device.makeDefaultLibrary()
        guard let function = library?.makeFunction(name: "selectionNearestFeatureEdgeDistance") else {
            NSLog("Selection Metal accelerator unavailable: selectionNearestFeatureEdgeDistance kernel not found")
            return nil
        }

        do {
            let pipeline = try device.makeComputePipelineState(function: function)
            self.device = device
            self.commandQueue = commandQueue
            self.pipeline = pipeline
            self.threadsPerThreadgroup = Self.threadgroupSize(maxTotalThreads: pipeline.maxTotalThreadsPerThreadgroup)
            if MemoryLayout<SelectionMetalFeatureSegment>.stride != 24 {
                NSLog(
                    "Selection Metal accelerator unavailable: segment stride=%ld expected=24",
                    MemoryLayout<SelectionMetalFeatureSegment>.stride
                )
                return nil
            }
        } catch {
            NSLog("Selection Metal accelerator unavailable: %@", error.localizedDescription)
            return nil
        }
    }

    func nearestFeatureEdgeDistance(
        point: SIMD3<Float>,
        segments: [SelectionFeatureSegment],
        fingerprint: UInt64
    ) -> Float? {
        guard !segments.isEmpty,
              segments.count <= Int(UInt32.max),
              let segmentBuffer = buffer(for: segments, fingerprint: fingerprint),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            return nil
        }

        let threadgroups = (segments.count + threadsPerThreadgroup - 1) / threadsPerThreadgroup
        guard let partialsBuffer = partialsBuffer(requiredCount: threadgroups) else {
            return nil
        }

        var query = SelectionMetalDistanceQuery(
            point: SelectionMetalPackedFloat3(point),
            segmentCount: UInt32(segments.count)
        )

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(segmentBuffer, offset: 0, index: 0)
        encoder.setBytes(&query, length: MemoryLayout<SelectionMetalDistanceQuery>.stride, index: 1)
        encoder.setBuffer(partialsBuffer, offset: 0, index: 2)
        encoder.dispatchThreadgroups(
            MTLSize(width: threadgroups, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadsPerThreadgroup, height: 1, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        guard commandBuffer.status == .completed else {
            return nil
        }

        let partials = partialsBuffer.contents().bindMemory(to: Float.self, capacity: threadgroups)
        var bestSquared = Float.greatestFiniteMagnitude
        for index in 0..<threadgroups {
            bestSquared = min(bestSquared, partials[index])
        }
        guard bestSquared.isFinite else {
            return nil
        }
        return sqrtf(bestSquared)
    }

    private func buffer(for segments: [SelectionFeatureSegment], fingerprint: UInt64) -> MTLBuffer? {
        if cachedFingerprint == fingerprint,
           cachedSegmentCount == segments.count,
           let cachedSegmentBuffer {
            return cachedSegmentBuffer
        }

        let metalSegments = segments.map(SelectionMetalFeatureSegment.init)
        let buffer = metalSegments.withUnsafeBytes { rawBuffer in
            rawBuffer.baseAddress.flatMap {
                device.makeBuffer(
                    bytes: $0,
                    length: rawBuffer.count,
                    options: [.storageModeShared]
                )
            }
        }
        guard let buffer else {
            return nil
        }

        cachedFingerprint = fingerprint
        cachedSegmentCount = segments.count
        cachedSegmentBuffer = buffer
        return buffer
    }

    private func partialsBuffer(requiredCount: Int) -> MTLBuffer? {
        if requiredCount <= cachedPartialsCapacity, let cachedPartialsBuffer {
            return cachedPartialsBuffer
        }
        guard let buffer = device.makeBuffer(
            length: MemoryLayout<Float>.stride * requiredCount,
            options: [.storageModeShared]
        ) else {
            return nil
        }
        cachedPartialsCapacity = requiredCount
        cachedPartialsBuffer = buffer
        return buffer
    }

    private static func threadgroupSize(maxTotalThreads: Int) -> Int {
        let cappedSize = max(1, min(256, maxTotalThreads))
        var size = 1
        while size * 2 <= cappedSize {
            size *= 2
        }
        return size
    }

}
