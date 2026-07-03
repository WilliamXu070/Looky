#include <metal_stdlib>
using namespace metal;

struct SelectionMetalFeatureSegment {
    packed_float3 start;
    packed_float3 end;
};

struct SelectionMetalDistanceQuery {
    packed_float3 point;
    uint segmentCount;
};

kernel void selectionNearestFeatureEdgeDistance(
    const device SelectionMetalFeatureSegment *segments [[buffer(0)]],
    constant SelectionMetalDistanceQuery &query [[buffer(1)]],
    device float *partialMinDistances [[buffer(2)]],
    uint localID [[thread_position_in_threadgroup]],
    uint groupID [[threadgroup_position_in_grid]],
    uint threadsInGroup [[threads_per_threadgroup]]
) {
    threadgroup float scratch[256];

    float best = INFINITY;
    uint segmentIndex = groupID * threadsInGroup + localID;
    if (segmentIndex < query.segmentCount) {
        float3 start = float3(segments[segmentIndex].start);
        float3 end = float3(segments[segmentIndex].end);
        float3 segment = end - start;
        float denominator = dot(segment, segment);
        float t = 0.0;
        if (denominator > 0.0) {
            t = clamp(dot(float3(query.point) - start, segment) / denominator, 0.0, 1.0);
        }
        float3 closest = start + segment * t;
        float3 delta = float3(query.point) - closest;
        best = dot(delta, delta);
    }

    scratch[localID] = best;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint stride = threadsInGroup >> 1; stride > 0; stride >>= 1) {
        if (localID < stride) {
            scratch[localID] = min(scratch[localID], scratch[localID + stride]);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (localID == 0) {
        partialMinDistances[groupID] = scratch[0];
    }
}
