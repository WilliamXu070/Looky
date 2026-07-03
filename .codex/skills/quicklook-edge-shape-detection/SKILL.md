---
name: quicklook-edge-shape-detection
description: Use this skill when testing, diagnosing, or optimizing QuickLookStep edge shape detection from saved edge-download polygons. Applies to line/arc/semicircle classification after the existing click, snapping, nearest-edge, and connected-edge algorithms have already produced chainPoints. Do not use it to change upstream edge detection.
---

# QuickLookStep Edge Shape Detection

Use this skill for the shape layer only: replay saved edge JSON, classify the shape, and optimize line/semicircle detection without touching the upstream click or edge-detection algorithms.

If the symptom is that clicking selects the wrong physical edge, jumps to another part of the model, or buffers for a long time before any shape JSON is written, use `quicklook-edge-selection-debug` first. Shape detection starts only after the click-selection layer has produced trustworthy local `chainPoints`.

## Boundary

Allowed:
- consume existing `edge-download-*.json`
- read `chainPoints`, `snappedWorldPoint`, `selectedEdge`, `chainKind`, and logs
- classify shapes as `line`, `semicircle`, `arc`, `circle`, `fragmented`, or `unknown`
- reorder or interpret points inside the shape-detection layer
- write reports and diagnosis tickets

Not allowed:
- changing hit testing
- changing nearest-edge selection
- changing connected-edge extraction
- changing UI click behavior
- changing the edge JSON producer just to help the shape detector

Exception: drawing only a selected primitive after a valid connected chain is allowed here because it is a post-selection overlay decision. Do not use overlay logic to hide a bad upstream selection.

## Default Loop

Run from repo root:

```bash
testing/edge-shape-detection/scripts/run_shape_detection_loop.sh
```

Expected outputs:
- `testing/edge-shape-detection/reports/latest.json`
- archived report under `testing/edge-shape-detection/reports/history/`
- failure ticket under `testing/edge-shape-detection/tickets/` if expectations fail

When validating a fresh GUI click, inspect the new fields in `/tmp/quicklook-edge-download/edge-download-*.json`:

- `shapeDetection.rawOrderShape`
- `shapeDetection.detectedShape`
- `shapeDetection.sequence`
- `shapeDetection.segments`

## Custom Expectations

Add cases to:

```text
testing/edge-shape-detection/expectations/expected-shapes.json
```

Case shape:

```json
{
  "name": "thor-curved-click",
  "source": "/tmp/quicklook-edge-download/edge-download-example.json",
  "expectedShape": "semicircle",
  "expectedRawOrderShape": "fragmented",
  "notes": "Raw order may be scrambled; final shape detector should recover the whole curve."
}
```

Use `expectedRawOrderShape` when preserving proof that the current saved order is bad. Use `expectedShape` for the shape-layer result.

## Diagnose Rule

If the loop fails, use the `diagnose-fix` skill before editing. Keep diagnosis scoped to shape detection only.

Failure buckets to check:
- `unordered-chain`: raw `chainPoints` are not path ordered
- `bad-seed`: snapped point maps to the wrong local shape
- `over-merge`: line and curve are combined incorrectly
- `under-merged-arc`: semicircle is split into smaller arcs
- `bad-circle-fit`: points are coherent but circle fitting rejects them
- `bad-expectation`: expected shape does not match the saved polygon

## 2026-06-07 — Chain ordering is now deterministic

### What changed
- `resolvedChain` in `SceneKitView.swift` now uses `MeshTopology.rawVertexPath(from:)` instead of `connectedFeatureSegments` (which iterated a `Set<EdgeKey>` in non-deterministic order).
- Connected-mode chain points are now topologically walked and direction-normalized.

### Why it matters
- Shape detection now receives consistently ordered points for the same geometric edge, regardless of which surface was clicked.
- The `fragmented` `rawOrderShape` bucket caused by unordered points should no longer occur for click-to-click replay of the same edge.

### Validation
- Replay the same edge-download JSON twice and confirm identical sequences.
- `replay_surface_invariance.sh` should show identical sequence for top and side surface clicks on the same feature.

## Verification Standard

For a curved click case:
- `rawOrderShape` should now be `line`, `semicircle`, or `arc` (not `fragmented`) for clicks on the same feature edge from any surface
- whole-shape recovery may report a broad `semicircle`, but this is not enough for capsule-like closed loops
- primitive sequence replay must be checked when the saved polygon represents a loop

For a straight click case:
- `detectedShape` must be `line`
- line residual metrics should be low in `reports/latest.json`

For the current thor capsule loop:

```bash
swift testing/edge-shape-detection/scripts/replay_shape_sequence.swift \
  /tmp/quicklook-edge-download/edge-download-2026-06-05T13-21-40Z.json \
  testing/edge-shape-detection/reports/latest-sequence.json
```

Required sequence:

```text
line -> semicircle -> line -> semicircle
```

For surface-invariance regressions, compare a top-surface capsule click with the adjacent connection/side-surface click:

```bash
testing/edge-shape-detection/scripts/replay_surface_invariance.sh
```

Both reports must produce:

```text
line -> semicircle -> line -> semicircle
```

If the top surface passes but the side surface becomes one `arc` or many `line-segment`s, keep the fix in shape detection. This is usually an extruded-semicircle loop: two semicircle rails on parallel levels plus two connector lines. Do not change hit testing or connected-edge extraction for this class of failure.

## 2026-06-07 — Capsule primitive boundary alignment fix

### Problem context
- Visual overlay line extended past the curve junction in `.connected` mode. The gap was caused by `capsulePrimitiveGroups` returning non-contiguous cap groups (arc endpoints stripped by exclusive proximity scoring into adjacent rail groups, creating ~9.7-unit gaps).

### What changed
- `capsulePrimitiveGroups` in `SceneKitView.swift`: widened `capScale = width * 1.5` (was `width`) to bias the exclusive proximity scoring in favor of caps, so true arc endpoints stay in their cap groups.
- Added post-process that prepends the previous rail's last point and appends the next rail's first point to each cap group, ensuring zero-distance boundaries.

### Why it helped
- Visual overlay is now contiguous across all four primitive boundaries (line→semicircle→line→semicircle), with 0.0 units at every junction.
- Cap angular coverage increased from ~132° back into the 140-220° semicircle range.

### Validation
- `swift testing/edge-shape-detection/scripts/check_primitive_boundary.swift <polygon>` — all 4 boundary checks pass at distance ≤ 0.01
- `swift testing/edge-shape-detection/scripts/replay_shape_sequence.swift <edge-download>` — sequence must be `["line", "semicircle", "line", "semicircle"]`

Only move back to live UI/manual click testing after saved polygon replay passes.
