---
title: QuickLookStep Edge + Surface Selection Triage
name: quicklook-edge-surface-triage
description: Use this skill to fix and validate QuickLookStep selection regressions where clicks map to the wrong edge/surface, orange overlay leaks through geometry, or curved/planar surfaces are selected inconsistently.
---

# QuickLookStep Edge + Surface Selection Triage

Use when click-to-select behavior fails in the viewer.

## Scope
- Edge/connected selection snapping and local edge targeting.
- Surface-selection overlay and occlusion.
- Plane/curve threshold regressions that choose wrong faces.

Do **not** touch shape-classification algorithms here unless they are proven stable.

## One-Line Runbook

```bash
cd /Users/williamxu/Desktop/Projects/quicklook
rm -rf /tmp/quicklook-edge-probe /tmp/quicklook-surface-probe /tmp/quicklook-edge-download /tmp/quicklook-edge-reports
mkdir -p /tmp/quicklook-edge-probe /tmp/quicklook-surface-probe /tmp/quicklook-edge-download /tmp/quicklook-edge-reports
xcodebuild -project QuickLookStep/QuickLookStep.xcodeproj -scheme QuickLookStep -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
open -n -a "/Users/williamxu/Desktop/Projects/quicklook/build/Build/Products/Debug/QuickLookStep.app" --args \
  --selection-mode=connected \
  --edge-probe \
  --edge-probe-output /tmp/quicklook-edge-probe \
  --surface-probe \
  --surface-probe-output /tmp/quicklook-surface-probe \
  --sample "/Users/williamxu/Downloads/thor luminos adaptor.step"
```

After launch, click the failing location once and keep the UI open.

## What to check first

```bash
/usr/bin/log show --predicate 'process == "QuickLookStep" AND (eventMessage CONTAINS "Selection snapped" OR eventMessage CONTAINS "Selection accepted" OR eventMessage CONTAINS "Selection ignored" OR eventMessage CONTAINS "Selection completed" OR eventMessage CONTAINS "orange" OR eventMessage CONTAINS "Fatal error")' --last 5m --style compact | tail -n 200
```

Green flags:
- Small `Selection snapped` / `Selection accepted` distance
- Quick `Selection completed` time
- No `Fatal error` or long buffering
- `Selection ignored` when clicking obvious non-feature surface

## Probe artifacts

Newest edge probe:
```bash
ls -t /tmp/quicklook-edge-probe/* | head -n 1
```

Newest surface probe:
```bash
ls -t /tmp/quicklook-surface-probe/* | head -n 1
```

Open probe JSON and verify:
- edge mode resolves nearest local edge, not distant feature
- surface mode resolves actual visible surface (frontmost triangle seed)
- `edgeProbed` and `surfaceProbed` records align with clicked geometry

## Core quick tests

```bash
testing/edge-shape-detection/scripts/run_shape_detection_loop.sh
testing/edge-shape-detection/scripts/replay_surface_invariance.sh
testing/surface-selection/scripts/run_surface_layer_test.sh
testing/surface-selection/scripts/run_visible_surface_overlay_test.sh
testing/scripts/verify_quicklook_ui_launch.sh
```

## Fix targets

1. If surface selection jumps through geometry:
- ensure surface highlighting uses selected mesh triangles (not separate always-on-top overlay)
- keep depth reads true for highlight materials

2. If surface selection grabs adjacent offset/hidden plane:
- tighten coplanar tolerance for seed expansion
- enforce frontmost-camera ray seed ordering in surface solver

3. If long edge chain triggers when only a segment is needed:
- keep selection layer boundary checks local
- only expand to connected edges after local exact edge acceptance

4. If top surface click resolves a lower plane:
- reject candidate surfaces behind the visible hit triangle
- lower permissive plane joining threshold

## Closure criteria

- run all 5 commands above
- visible surface screenshot shows orange only on intended surface
- `run_surface_layer_test.sh` passes `nearby-offset-plane-does-not-join-top-surface`
- no `Index out of range` in latest logs

## 2026-06-07 — Deterministic connected-edge chain ordering

### Problem context
- Clicking the same geometric edge from different surfaces (top vs bottom) produced different `chainWorldPoints` — different point counts, different lengths, different shape classifications.
- Root cause: `connectedFeatureSegments` iterates a `Set<EdgeKey>`, which has non-deterministic iteration order in Swift. Same connected component → different vertex sequences on each call.

### What changed
- Added `MeshTopology.rawVertexPath(from:)` which walks the connected feature edges in topological order (stopping at junctions), normalizes direction (min-vertex-first for open paths, rotation-to-min-vertex for closed loops).
- Modified `resolvedChain` in `SceneKitView.swift` (`.connected` mode) to use `rawVertexPath` instead of `connectedFeatureEdgeComponent` + `connectedFeatureSegments`.

### Why it helped
- Same connected component now always produces the same vertex sequence, regardless of which edge was the BFS seed.
- `polylineLength`, `EdgeShapeDetector.analyze`, and visual overlay are now deterministic.
- Eliminates the "fragmented" classification caused by unordered point clouds.

### Validation
- Build: `xcodebuild -project QuickLookStep/QuickLookStep.xcodeproj -scheme QuickLookStep -sdk macosx build CODE_SIGNING_ALLOWED=NO`
- Manual: launch app with `--selection-mode=connected --edge-only`, click same edge on top and bottom surface, verify identical `chainKind`, `points`, and `chainWorldPoints` in logs and edge-download JSON.
- Replay: `swift testing/edge-shape-detection/scripts/replay_shape_sequence.swift /tmp/quicklook-edge-download/edge-download-*.json testing/edge-shape-detection/reports/latest-sequence.json` should show identical sequence for top vs bottom clicks on the same feature edge.

## 2026-07-03 Update

### Problem context
- Diagnosis found that current edge/surface selection still rebuilds `MeshTopology` during click/probe/overlay paths and relies on repeated linear scans over triangles and feature edges.

### What changed
- Added the refactor target: cache per-geometry selectable topology once after scene load, keep face/edge selectable entities separate from render geometry, and add an acceleration structure/BVH-style candidate query before local edge or surface resolution.

### Why it helped
- Aligns the code with CAD viewer selection architecture and gives a concrete speed/accuracy path instead of tuning thresholds inside a 4,500-line `SceneKitView.swift`.

### Validation
- `xcodebuild -project QuickLookStep/QuickLookStep.xcodeproj -scheme QuickLookStep -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build`
- `testing/surface-selection/scripts/run_surface_layer_test.sh`
- `testing/edge-shape-detection/scripts/run_shape_detection_loop.sh`
- `QLS_FORCE_DIRECT_LAUNCH=1 testing/scripts/run-testing.sh testing/plans/orientation-zoom.json testing/results/diagnosis-orientation-zoom-direct.json`

## 2026-07-03 Update

### Problem context
- Integration planning found that `SceneKitView.resolveSelection(at:)` currently owns too much of the selection stack: hit-test arbitration, topology construction, edge candidates, surface candidates, and edge-vs-surface promotion.

### What changed
- Added the integration boundary: `SelectionModel` should own topology, selectable entities, candidate search, resolver decisions, and rejected-alternative evidence; SceneKit should keep hit-test input, overlay rendering, materials, geometry restoration, and probe/file output.

### Why it helped
- Keeps the refactor focused on one CAD-like selection engine while avoiding a second mesh-scanning path inside the view layer.

### Validation
- After integrating the engine, inspect `SceneKitView.swift` and confirm `resolveSelection(at:)` delegates to the engine instead of rebuilding `MeshTopology` directly.
- Run `xcodebuild -project QuickLookStep/QuickLookStep.xcodeproj -scheme QuickLookStep -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build`.
- Run `testing/surface-selection/scripts/run_surface_layer_test.sh`, `testing/edge-shape-detection/scripts/run_shape_detection_loop.sh`, and a direct-launch plan with `QLS_FORCE_DIRECT_LAUNCH=1`.

## 2026-07-03 Update

### Problem context
- The first production selection-engine foundation now lives outside `SceneKitView.swift`, but the view is not wired to use it yet.

### What changed
- Added guidance to treat `SelectionModel`, `SelectionTopology`, and `SelectionGeometryReader` as the cacheable topology layer: stable triangle/edge/surface/loop IDs, welded/geometric edge buckets, 25° feature edges, 65° smooth-surface boundaries, max-extent-scaled coplanar expansion, and precomputed surface patches/edge loops.

### Why it helped
- Gives future edge/surface triage a concrete engine boundary to validate before changing click routing, probes, or highlight rendering.

### Validation
- `xcodebuild -project QuickLookStep/QuickLookStep.xcodeproj -scheme QuickLookStep -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build`
- Before replacing `MeshTopology` calls, compare `SelectionModel.nearestFeatureEdgeDistance(to:)`, `surfacePatch(forTriangle:)`, and `edgeLoop(containing:)` against the existing view behavior on the same hit triangle/edge.

## 2026-07-03 Update

### Problem context
- SceneKit click/probe/visible-overlay flows still rebuilt mesh topology even after `SelectionModel` existed, so surface selection accuracy and speed did not benefit from the new shared model.

### What changed
- Wired `SceneKitView` to cache `SelectionModel` per `SCNGeometry` and use it for surface candidate resolution, nearest feature-edge distance, surface probe records, and automated visible-surface overlays.
- Kept cached legacy `MeshTopology` only for the fitted edge-chain compatibility path until edge fitting fully moves into the selection engine.

### Why it helped
- Surface selection now runs through one reusable CAD-like topology model instead of rebuilding a view-local mesh for every click and test overlay.
- The remaining edge path is isolated, making the next refactor step smaller: port fitted edge-chain extraction into `SelectionModel`.

### Validation
- `xcodebuild -project QuickLookStep/QuickLookStep.xcodeproj -scheme QuickLookStep -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build`
- `testing/surface-selection/scripts/run_surface_layer_test.sh`
- `testing/edge-shape-detection/scripts/run_shape_detection_loop.sh`
- After merging probe script fixes, rerun `testing/surface-selection/scripts/run_visible_surface_overlay_test.sh`.

## 2026-07-02 Update

### Problem context
- The requested refactor needs one consolidated edge + surface detector instead of separate SceneKit click heuristics, surface thresholds, edge chain fitting, and overlay code all living in the view layer.

### What changed
- Added the implementation sequence: extract `SelectionModel`, cache selectable topology per model node, compute surface patches and edge loops once, query a BVH/spatial index on click, then route the result through one resolver that decides edge vs surface before SceneKit draws highlights.

### Why it helped
- Gives a clean boundary between rendering and CAD-like selection, making speed improvements and accuracy tests converge on the same engine.

### Validation
- `testing/surface-selection/scripts/run_surface_layer_test.sh`
- `testing/edge-shape-detection/scripts/run_shape_detection_loop.sh`
- `QLS_FORCE_DIRECT_LAUNCH=1 testing/scripts/run-testing.sh testing/plans/orientation-zoom.json testing/results/selection-engine-orientation.json`
- Manual probe: launch with `--selection-mode=connected --edge-probe --surface-probe`, click the same feature as edge and surface, and verify one resolver records the chosen entity and rejected alternative.

## 2026-07-02 Update

### Problem context
- Parallel implementation needs file ownership boundaries so multiple worktree agents do not all edit `SceneKitView.swift` at once.

### What changed
- Added orchestration guidance: split work into foundation topology, resolver/golden tests, SceneKit integration, and probe/visual validation branches; merge in that order.

### Why it helped
- Reduces conflict risk and keeps the core selection engine testable before UI wiring and highlight rendering change.

### Validation
- Before creating worktrees, run `git status --short`, preserve/commit current selection work, and add `.worktrees/` to `.git/info/exclude`.
- After each merge: build, run surface layer tests, edge shape tests, direct-launch orientation tests, and final probe/UI validation.

## 2026-07-03 Update

### Problem context
- Consolidated edge + surface selection needs a standalone golden-flow gate before SceneKit UI integration changes.

### What changed
- Added guidance to run `testing/selection-engine/run_selection_engine_tests.sh` for the unified resolver contract: center face -> surface, near feature edge -> edge, offset plane isolation, curved patch selection, blank click -> none, and stable rounded-loop IDs from adjacent surfaces.

### Why it helped
- Catches resolver-priority and topology-contract regressions before UI hit testing, overlays, or probe plumbing are involved.

### Validation
- `testing/selection-engine/run_selection_engine_tests.sh`
- `testing/surface-selection/scripts/run_surface_layer_test.sh`
- `testing/edge-shape-detection/scripts/run_shape_detection_loop.sh`
