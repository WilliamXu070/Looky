import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("Usage: check_surface_congruence.swift <report1.json> <report2.json>")
    exit(1)
}

let source1 = args[1]
let source2 = args[2]

struct SequenceReport: Decodable {
    let chainKind: String
    let selectedEdge: [Int]
    let pointCount: Int
    let detectedSequence: [String]
    let segments: [SegmentReport]
}

struct SegmentReport: Decodable {
    let kind: String
    let pointCount: Int
    let length: Float
    let lineMaxResidual: Float?
    let circleRadius: Float?
    let circleMaxResidual: Float?
    let coverageDegrees: Float?
}

func load(_ path: String) throws -> SequenceReport {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try JSONDecoder().decode(SequenceReport.self, from: data)
}

let report1 = try load(source1)
let report2 = try load(source2)

var failures: [String] = []

func check<Value: Comparable>(
    label: String,
    got: Value,
    expected: Value,
    tolerance: Value,
    comparison: (Value, Value) -> Bool
) {
    if !comparison(got, expected) {
        failures.append("\(label): got \(got), expected \(expected) ± \(tolerance)")
    }
}

func approx(_ a: Float, _ b: Float, tolerance: Float) -> Bool {
    abs(a - b) <= tolerance || abs(a - b) <= max(abs(a), abs(b)) * tolerance
}

func checkMetric(
    label: String,
    got: Float,
    expected: Float,
    absTolerance: Float = 0.02,
    relTolerance: Float = 0.05
) {
    if abs(got - expected) > absTolerance && abs(got - expected) > max(abs(got), abs(expected)) * relTolerance {
        failures.append("\(label): got \(got), expected \(expected) (abs tol \(absTolerance), rel tol \(relTolerance))")
    }
}

if report1.detectedSequence != report2.detectedSequence {
    failures.append("sequence mismatch: \(report1.detectedSequence) vs \(report2.detectedSequence)")
}

if report1.segments.count != report2.segments.count {
    failures.append("segment count mismatch: \(report1.segments.count) vs \(report2.segments.count)")
} else {
    for (index, (seg1, seg2)) in zip(report1.segments, report2.segments).enumerated() {
        let prefix = "segment[\(index)]"
        if seg1.kind != seg2.kind {
            failures.append("\(prefix).kind: \(seg1.kind) vs \(seg2.kind)")
        }
        checkMetric(label: "\(prefix).length", got: seg1.length, expected: seg2.length)
        checkMetric(label: "\(prefix).pointCount", got: Float(seg1.pointCount), expected: Float(seg2.pointCount),
                    absTolerance: 0, relTolerance: 0)
        if let r1 = seg1.lineMaxResidual, let r2 = seg2.lineMaxResidual {
            checkMetric(label: "\(prefix).lineMaxResidual", got: r1, expected: r2,
                        absTolerance: 0.01, relTolerance: 0.1)
        }
        if let r1 = seg1.circleRadius, let r2 = seg2.circleRadius {
            checkMetric(label: "\(prefix).circleRadius", got: r1, expected: r2,
                        absTolerance: 0.02, relTolerance: 0.02)
        }
        if let r1 = seg1.circleMaxResidual, let r2 = seg2.circleMaxResidual {
            checkMetric(label: "\(prefix).circleMaxResidual", got: r1, expected: r2,
                        absTolerance: 0.01, relTolerance: 0.1)
        }
        if let c1 = seg1.coverageDegrees, let c2 = seg2.coverageDegrees {
            checkMetric(label: "\(prefix).coverageDegrees", got: c1, expected: c2,
                        absTolerance: 1.0, relTolerance: 0.01)
        }
    }
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

let result: [String: Any] = [
    "source1": source1,
    "source2": source2,
    "congruent": failures.isEmpty,
    "failures": failures
]

let resultData = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(resultData)
FileHandle.standardOutput.write(Data([0x0a]))

exit(failures.isEmpty ? 0 : 1)
