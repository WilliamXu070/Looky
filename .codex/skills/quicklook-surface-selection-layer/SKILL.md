---
name: quicklook-surface-selection-layer
description: Use this skill when testing or debugging QuickLookStep surface selection before GUI click automation. It validates the isolated face/surface layer: feature-edge distance thresholding, welded geometric triangle adjacency, and whole-surface overlay candidates.
---

# QuickLookStep Surface Selection Layer

Use this when working on surface selection: click point -> decide edge vs surface -> recover the inferred mesh surface bounded by feature edges. The selected surface can be planar, fragmented-coplanar, cylindrical/conical-style curved, or smooth freeform-ish.

Current render path: surface selection should tint the actual selected mesh triangles by rebuilding the selected node geometry into base and selected material elements. Do not reintroduce an always-on-top duplicate surface overlay for live selection; it causes orange to bleed through occluding model geometry. Automated visible-surface tests should seed from the frontmost camera ray hit so they validate the surface the viewer can actually see.

## Boundary

This is the surface layer only. Keep it separate from edge shape detection.

Allowed:
- test inferred surface adjacency
- tune the surface promotion threshold
- verify duplicate-vertex STEP-style tessellation still forms one surface
- verify surfaces stop at boundary/crease feature edges
- verify fragmented planar CAD faces expand across same-plane triangle islands
- verify curved cylindrical/conical mesh patches select as complete smooth surfaces

Not allowed:
- changing line/arc/semicircle shape classification
- widening edge selection search to make surface selection pass
- using GUI screenshots as the first proof; use the offline surface layer test first

## Required Test

Run from repo root:

```bash
testing/surface-selection/scripts/run_surface_layer_test.sh
```

Expected output:

```text
surface-layer report: .../testing/surface-selection/reports/latest.json
PASS
```

Inspect:

```bash
cat testing/surface-selection/reports/latest.json
```

All cases must pass:
- `center-top-face-promotes-to-whole-surface`
- `near-feature-edge-stays-edge-selection`
- `off-center-top-face-still-bounded-to-top`
- `fragmented-coplanar-face-expands-to-all-plane-patches`
- `nearby-offset-plane-does-not-join-top-surface`
- `half-cylinder-selects-complete-curved-surface`
- `tapered-cone-selects-complete-curved-surface`

## What The Test Proves

The fixture is a flat plate with side faces and intentionally duplicated triangle vertices. Passing means:

- a broad face click promotes to surface selection
- a near-edge click stays available for edge selection
- the recovered surface contains all top-face triangles
- the recovered surface does not leak into side faces
- adjacency is geometric/welded, not raw vertex-ID based
- planar surfaces can expand across fragmented same-plane mesh islands
- nearby offset/parallel planes are not swallowed into the selected planar face
- curved cylindrical/conical-style surfaces recover a full smooth patch, not a single triangle island

## When It Fails

Use these buckets:

- `threshold-too-large`: face clicks remain edge selections
- `threshold-too-small`: near-edge clicks promote to surface
- `no-weld`: duplicated triangles do not connect into one surface
- `leaks-across-crease`: selected top surface includes side faces
- `leaks-across-offset-plane`: selected top surface includes nearby lower/recessed parallel planes
- `bad-feature-edge`: crease/boundary detection is wrong

After this offline test passes, run the app build and real UI launch verifier before trying manual GUI clicks.

## Visible Orange Proof

For any change that affects surface highlighting, also run:

```bash
testing/surface-selection/scripts/run_visible_surface_overlay_test.sh
```

Passing output must include:

- `Wrote test results to: .../visible-surface-overlay.json`
- `orangeRatio` greater than or equal to the script threshold
- `visible surface screenshot: ...selectSurface.png`
- `orange pixel report: ...visible-surface-orange-pixels.json`

Open the screenshot and verify the loaded STEP model has a visible orange surface overlay. This catches false positives where the surface math passes but the rendered UI stays gray or pale yellow.

## 2026-07-03 Update

### Problem context
- `testing/surface-selection/scripts/run_visible_surface_overlay_test.sh` used a plan that pointed at `/Users/williamxu/Downloads/thor luminos adaptor.step`, which is private machine state and missing in fresh worktrees.

### What changed
- `testing/plans/surface-selection-visible.json` now uses the repo fixture `../input/cube_hole.step`, and the visible overlay script validates plan file references before launching QuickLookStep.

### Why it helped
- Makes the visible orange proof runnable from checked-in fixtures and fails early with the missing scenario file instead of timing out inside the app launch path.

### Validation
- `testing/surface-selection/scripts/run_visible_surface_overlay_test.sh`
- If LaunchServices does not deliver the plan, retry with `QLS_FORCE_DIRECT_LAUNCH=1 testing/surface-selection/scripts/run_visible_surface_overlay_test.sh`.
