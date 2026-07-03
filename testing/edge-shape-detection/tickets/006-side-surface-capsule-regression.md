# 006 Side-Surface Capsule Regression

## Symptom

Selecting the rounded slot from the top surface classified the connected loop as:

```text
line -> semicircle -> line -> semicircle
```

Selecting the matching rounded feature from the adjacent connection surface degraded into a noisy curve/segmented output even though the physical feature is still two semicircle rails joined by two straight connectors.

## Repro Artifacts

- Top surface: `/tmp/quicklook-edge-download/edge-download-2026-06-05T15-26-14Z.json`
- Adjacent side surface: `/tmp/quicklook-edge-download/edge-download-2026-06-05T15-26-15Z.json`

Before the fix, the side artifact failed `replay_shape_sequence.swift`.

## Root Cause

The shape detector only understood flat capsule loops and generic circle fallback. The side surface is an extruded semicircle loop: two parallel semicircle rails on different coordinate levels, plus two connector lines. Generic circle fitting sees this as a high-residual arc and the app fell back to tiny line segments.

## Fix

Added an extruded-semicircle recovery path in `EdgeShapeDetector` after normal flat capsule detection and before generic fallback. The new path:

- finds loops split cleanly across two coordinate levels,
- fits each rail as a semicircle in the orthogonal projection,
- reconstructs the two connector lines,
- returns `line -> semicircle -> line -> semicircle`.

`selectedPrimitivePoints` now also uses this side-surface primitive grouping so UI highlighting can pick the nearest primitive instead of the whole connected component.

## Verification

```bash
testing/edge-shape-detection/scripts/replay_surface_invariance.sh
swift testing/edge-shape-detection/scripts/replay_line_segment_selection.swift \
  /tmp/quicklook-edge-download/edge-download-2026-06-05T15-26-16Z.json \
  /tmp/quicklook-edge-probe/_Users_williamxu_Downloads_thor_luminos_adaptor.step-edge-probe-2026-06-05T15-26-16Z.json \
  testing/edge-shape-detection/reports/latest-line-segment.json
```

True-circle artifacts from `2026-06-05T15-28-09Z`, `15-28-11Z`, and `15-28-16Z` still report `["circle"]`.
