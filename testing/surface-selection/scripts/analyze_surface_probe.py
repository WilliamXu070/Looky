#!/usr/bin/env python3
import glob
import json
import os
import sys


def latest_probe(path):
    if os.path.isdir(path):
        matches = sorted(glob.glob(os.path.join(path, "*surface-probe-*.json")))
        if not matches:
            raise SystemExit(f"no surface probe json files found in {path}")
        return matches[-1]
    return path


def main():
    source = latest_probe(sys.argv[1] if len(sys.argv) > 1 else "/tmp/quicklook-surface-probe")
    with open(source) as handle:
        probe = json.load(handle)

    resolved = probe.get("resolvedKind")
    promoted = bool(probe.get("surfacePromoted"))
    surface_count = int(probe.get("surfaceTriangleCount") or 0)
    edge_distance = probe.get("bestEdgeDistance")
    nearest_feature = probe.get("nearestFeatureEdgeDistance")
    threshold = probe.get("surfacePromotionThreshold")
    current_point_is_edge = probe.get("bestEdgeCurrentPointIsEdge")

    if resolved == "surface":
        status = "pass"
        bucket = "resolved-surface"
    elif promoted and resolved == "edge":
        status = "fail"
        bucket = "edge-stole-surface-click"
    elif not promoted and nearest_feature is not None and threshold is not None and nearest_feature <= threshold:
        status = "fail"
        bucket = "click-inside-edge-promotion-zone"
    elif not promoted:
        status = "fail"
        bucket = "no-surface-candidate"
    else:
        status = "fail"
        bucket = "unknown-routing-failure"

    report = {
        "source": source,
        "status": status,
        "bucket": bucket,
        "resolvedKind": resolved,
        "surfacePromoted": promoted,
        "surfaceTriangleCount": surface_count,
        "nearestFeatureEdgeDistance": nearest_feature,
        "surfacePromotionThreshold": threshold,
        "bestEdgeDistance": edge_distance,
        "bestEdgeCurrentPointIsEdge": current_point_is_edge,
        "viewportPoint": probe.get("viewportPoint"),
        "viewSize": probe.get("viewSize"),
        "note": probe.get("note"),
    }
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if status == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
