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
- `disconnected-coplanar-island-stays-bounded`
- `nearby-offset-plane-does-not-join-top-surface`
- `half-cylinder-selects-complete-curved-surface`
- `small-internal-cylinder-selects-complete-curved-surface`
- `tapered-cone-selects-complete-curved-surface`

## What The Test Proves

The fixture is a flat plate with side faces and intentionally duplicated triangle vertices. Passing means:

- a broad face click promotes to surface selection
- a near-edge click stays available for edge selection
- the recovered surface contains all top-face triangles
- the recovered surface does not leak into side faces
- adjacency is geometric/welded, not raw vertex-ID based
- same-plane mesh islands are not joined unless welded smooth adjacency exists
- nearby offset/parallel planes are not swallowed into the selected planar face
- curved cylindrical/conical-style surfaces recover a full smooth patch, not a single triangle island
- cube-hole-scale internal cylinders recover a full smooth patch despite small model dimensions

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

## 2026-07-03 Update

### Problem context
- Internal cylinder wall selection still fails on the repo cube-hole fixture even though synthetic half-cylinder and cone layer tests pass.
- Diagnosis showed the cube-hole mesh is only about `0.0508` units wide with a `0.00635` radius hole, while the surface/edge weld minimum is `0.01` model units.

### What changed
- Added this gap to the surface-selection runbook: internal hole-cylinder coverage must use the small repo fixture scale, not only the larger synthetic ruled-surface fixtures.

### Why it helped
- Explains why synthetic curved-surface tests can pass while the actual internal cylinder wall is fragmented or routed to edge selection.
- Points future fixes at unit-scaled tolerances and a dedicated internal-cylinder golden case.

### Validation
- Reproduce by analyzing `testing/input/cube_hole_from_step.obj`: with tolerance `0.01`, cylinder triangles split into many patches; with tolerance near `maxExtent * 0.00002`, the cylinder wall becomes one smooth component.
- Add a golden case that clicks the inner wall of `testing/input/cube_hole.step` or its converted OBJ/STL derivative and expects the full cylindrical wall patch.

## 2026-07-03 Update

### Problem context
- Cube-hole internal cylinder selection and finite face selection were unstable because absolute tolerance floors were larger than small CAD features, and disconnected coplanar islands were treated as one surface without adjacency evidence.

### What changed
- Production `SelectionModel` now uses a `0.000001` weld/coplanar tolerance floor instead of `0.01`/`0.004`.
- Surface inference now returns the welded smooth patch rather than globally expanding to every same-plane triangle island.
- `run_surface_layer_test.sh` now includes `small-internal-cylinder-selects-complete-curved-surface` and `disconnected-coplanar-island-stays-bounded`.

### Why it helped
- The repo cube-hole cylinder resolves as one smooth component instead of many fragments.
- Planar face selection stays finite and distinct unless the mesh has real welded adjacency.

### Validation
- `testing/surface-selection/scripts/run_surface_layer_test.sh`
- `swift testing/selection-engine/scripts/replay_selection_engine.swift testing/selection-engine/reports/latest.json`
- `testing/surface-selection/scripts/run_visible_surface_overlay_test.sh`
