import simd

protocol SelectionDistanceBackend: AnyObject {
    var name: String { get }
    func nearestFeatureEdgeDistance(
        point: SIMD3<Float>,
        segments: [SelectionFeatureSegment],
        fingerprint: UInt64
    ) -> Float?
}
