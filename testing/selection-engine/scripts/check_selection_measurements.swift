#!/usr/bin/env swift

import Foundation
import simd

struct EdgeKey: Hashable {
    let a: Int
    let b: Int

    init(_ first: Int, _ second: Int) {
        a = min(first, second)
        b = max(first, second)
    }
}

func assertClose(_ actual: Float, _ expected: Float, tolerance: Float = 0.00001, _ label: String) {
    guard abs(actual - expected) <= tolerance else {
        fputs("\(label) expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

func assertClose(_ actual: Double, _ expected: Double, tolerance: Double = 0.00001, _ label: String) {
    guard abs(actual - expected) <= tolerance else {
        fputs("\(label) expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

func polylineLength(_ points: [SIMD3<Float>]) -> Float {
    zip(points, points.dropFirst()).reduce(Float(0)) { partial, pair in
        partial + simd_distance(pair.0, pair.1)
    }
}

func segments(in points: [SIMD3<Float>]) -> [(SIMD3<Float>, SIMD3<Float>)] {
    zip(points, points.dropFirst()).compactMap { pair in
        simd_distance(pair.0, pair.1) > 0.000001 ? pair : nil
    }
}

func segmentSegmentDistance(
    _ p1: SIMD3<Float>,
    _ q1: SIMD3<Float>,
    _ p2: SIMD3<Float>,
    _ q2: SIMD3<Float>
) -> Float {
    let d1 = q1 - p1
    let d2 = q2 - p2
    let r = p1 - p2
    let a = simd_dot(d1, d1)
    let e = simd_dot(d2, d2)
    let f = simd_dot(d2, r)
    let epsilon: Float = 0.000001

    if a <= epsilon, e <= epsilon {
        return simd_distance(p1, p2)
    }
    if a <= epsilon {
        let t = min(max(f / e, 0), 1)
        return simd_distance(p1, p2 + d2 * t)
    }
    if e <= epsilon {
        let s = min(max(-simd_dot(d1, r) / a, 0), 1)
        return simd_distance(p1 + d1 * s, p2)
    }

    let b = simd_dot(d1, d2)
    let c = simd_dot(d1, r)
    let denominator = a * e - b * b
    var s: Float = 0
    if denominator != 0 {
        s = min(max((b * f - c * e) / denominator, 0), 1)
    }

    let tNominal = b * s + f
    let t: Float
    if tNominal < 0 {
        t = 0
        s = min(max(-c / a, 0), 1)
    } else if tNominal > e {
        t = 1
        s = min(max((b - c) / a, 0), 1)
    } else {
        t = tNominal / e
    }

    return simd_distance(p1 + d1 * s, p2 + d2 * t)
}

func minimumDistance(between polylines: [[SIMD3<Float>]]) -> Float {
    var best = Float.greatestFiniteMagnitude
    for firstIndex in polylines.indices {
        for secondIndex in polylines.indices where secondIndex > firstIndex {
            for first in segments(in: polylines[firstIndex]) {
                for second in segments(in: polylines[secondIndex]) {
                    best = min(best, segmentSegmentDistance(first.0, first.1, second.0, second.1))
                }
            }
        }
    }
    return best
}

func principalDirection(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
    let longest = segments(in: points).max {
        simd_length_squared($0.1 - $0.0) < simd_length_squared($1.1 - $1.0)
    }!
    return simd_normalize(longest.1 - longest.0)
}

func angleDegrees(_ first: [SIMD3<Float>], _ second: [SIMD3<Float>]) -> Float {
    let dot = min(max(abs(simd_dot(principalDirection(first), principalDirection(second))), -1), 1)
    return acosf(dot) * 180 / .pi
}

func triangleArea(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float {
    simd_length(simd_cross(b - a, c - a)) * 0.5
}

func rectanglePatchMeasurements() -> (area: Float, perimeter: Float) {
    let vertices = [
        SIMD3<Float>(0, 0, 0),
        SIMD3<Float>(3, 0, 0),
        SIMD3<Float>(3, 4, 0),
        SIMD3<Float>(0, 4, 0),
    ]
    let triangles = [
        [0, 1, 2],
        [0, 2, 3],
    ]
    var area: Float = 0
    var edgeCounts: [EdgeKey: Int] = [:]

    for triangle in triangles {
        area += triangleArea(vertices[triangle[0]], vertices[triangle[1]], vertices[triangle[2]])
        for index in 0..<3 {
            edgeCounts[EdgeKey(triangle[index], triangle[(index + 1) % 3]), default: 0] += 1
        }
    }

    let perimeter = edgeCounts.reduce(Float(0)) { partial, entry in
        guard entry.value == 1 else {
            return partial
        }
        return partial + simd_distance(vertices[entry.key.a], vertices[entry.key.b])
    }
    return (area, perimeter)
}

func convertLengthToMillimeters(_ value: Float, mmPerModelUnit: Double) -> Double {
    Double(value) * mmPerModelUnit
}

func convertAreaToMillimeters(_ value: Float, mmPerModelUnit: Double) -> Double {
    Double(value) * mmPerModelUnit * mmPerModelUnit
}

assertClose(
    polylineLength([SIMD3<Float>(0, 0, 0), SIMD3<Float>(3, 4, 0)]),
    5,
    "synthetic line length"
)
assertClose(
    minimumDistance(between: [
        [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 4, 0)],
        [SIMD3<Float>(2, 0, 0), SIMD3<Float>(2, 4, 0)],
    ]),
    2,
    "two-edge minimum distance"
)
assertClose(
    angleDegrees(
        [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0)],
        [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 1, 0)]
    ),
    90,
    "two-edge angle"
)
assertClose(
    triangleArea(SIMD3<Float>(0, 0, 0), SIMD3<Float>(3, 0, 0), SIMD3<Float>(0, 4, 0)),
    6,
    "triangle area"
)
let patch = rectanglePatchMeasurements()
assertClose(patch.area, 12, "rectangular patch area")
assertClose(patch.perimeter, 14, "rectangular patch perimeter")
assertClose(convertLengthToMillimeters(2, mmPerModelUnit: 1.5), 3, "unit length conversion")
assertClose(convertAreaToMillimeters(4, mmPerModelUnit: 2), 16, "unit area conversion")

print("selection measurement checks passed")
