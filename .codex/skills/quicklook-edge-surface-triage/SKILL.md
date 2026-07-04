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

## 2026-07-03 Update

### Problem context
- Cube-hole center/inner-cylinder behavior was still inconsistent: clicks near the hole could resolve to planar faces or fragmented curved patches because the selection topology used absolute tolerance floors larger than the model's small features.

### What changed
- Tightened `SelectionModel` weld/coplanar tolerance floors to `0.000001`.
- Replaced global coplanar expansion with bounded welded smooth patches.
- Changed the live edge prefilter from `maxExtent * 0.018` with a `0.35` floor to `maxExtent * 0.03` with a `0.0005` floor, preserving rounded-edge goldens while avoiding whole-model edge auto-aim on tiny parts.

### Why it helped
- The repo cube-hole OBJ now classifies the internal cylinder as one 126-triangle smooth component while keeping front/back planar faces at 67 triangles each.
- Surface selection no longer relies on a same-plane sweep that can make selected regions look non-finite or disconnected from the clicked face.

### Validation
- `testing/surface-selection/scripts/run_surface_layer_test.sh`
- `swift testing/selection-engine/scripts/replay_selection_engine.swift testing/selection-engine/reports/latest.json`
- `testing/edge-shape-detection/scripts/run_shape_detection_loop.sh`
- `xcodebuild -project QuickLookStep/QuickLookStep.xcodeproj -scheme QuickLookStep -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build`
- `testing/surface-selection/scripts/run_visible_surface_overlay_test.sh`

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

## 2026-07-03 Update

### Problem context
- Internal cylinder wall clicks in the cube-hole STEP fixture still do not select the complete cylindrical surface.
- The current selection model uses absolute minimums (`0.01` weld tolerance and `0.35` edge-selection threshold) that are larger than or comparable to small meter-scale STEP features.

### What changed
- Added the internal-cylinder diagnosis: avoid trusting the synthetic half-cylinder result as proof for small concave hole surfaces; check actual model scale, welded bucket sizes, and edge-candidate thresholds.

### Why it helped
- Identifies why the resolver can fragment the cylinder wall, mark too many internal edges as feature edges, or let an edge steal a cylinder-wall click.
- Establishes that the next fix should scale tolerances to the model/feature size and add a repo cube-hole internal-cylinder golden flow.

### Validation
- For `testing/input/cube_hole_from_step.obj`, tolerance `0.01` creates oversized welded buckets and splits the likely cylinder triangles; a tolerance near `maxExtent * 0.00002` keeps bucket size near 2 and groups the cylinder wall as one patch.
- Inspect `SceneKitView.localSelectionDistanceThreshold`: the `0.35` floor is larger than the whole cube-hole model and should not be used as a model-space near-edge threshold for this fixture.

## 2026-07-03 Update

### Problem context
- Undefined-looking selections needed structured proof of whether the click chose an edge, a finite surface patch, no hit, or a disconnected/clipped surface highlight.

### What changed
- Added `SelectionDebugEvent` sessions, HUD summaries, `TestingActionKind.selectAt`, `TestingActionKind.setCamera`, replay tooling, and a cube-hole selection-debug golden plan.
- Render validation now records selected bounds, triangle/edge counts, material depth state, and warnings such as `selected surface triangles disconnected from seed`.

### Why it helped
- Edge/surface triage can now compare the live resolver decision, rejected alternatives, thresholds, and visual artifact paths in one JSON bundle.
- The 67-triangle cube-hole surface capture is now replayable and exposes the disconnected-surface warning instead of relying on a screenshot alone.

### Validation
- `xcodebuild -project QuickLookStep/QuickLookStep.xcodeproj -scheme QuickLookStep -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build`
- `QLS_FORCE_DIRECT_LAUNCH=1 QLS_SELECTION_DEBUG=1 QLS_SELECTION_DEBUG_OUTPUT=/tmp/quicklook-selection-debug testing/scripts/run-testing.sh testing/plans/selection-debug-cube-hole.json testing/results/selection-debug-cube-hole.json`
- `swift testing/selection-debug/replay_selection_session.swift /tmp/quicklook-selection-debug/selection-debug-session.json testing/results/selection-debug-cube-hole-replay.json`
- `testing/scripts/verify_quicklook_ui_launch.sh /Users/williamxu/Desktop/Projects/quicklook/build/Build/Products/Debug/QuickLookStep.app /Users/williamxu/Desktop/Projects/quicklook/testing/input/cube_hole.step /tmp/quicklook-ui-launch-check-cube.png`

## 2026-07-03 Update

### Problem context
- Log replay showed intermittent `selectAt` failures where the test report camera stayed fixed, but the live `SCNView.pointOfView` drifted and the same normalized click returned `none`.
- The same runs also showed that `expect` data was recorded without failing `run-testing.sh`, and a stray manual `mouseUp` could append an extra debug event after the test report was written.

### What changed
- Added the validation rule: automated `selectAt` must sync `SCNView.pointOfView` from the scene camera before clicking, `run-testing.sh` must fail on `selectionDebugExpectationFailures`, and test-plan launches should suppress manual mouse selection while still allowing explicit `selectAt`.
- Added a session sanity check: event count must match planned `selectAt` count, and all event camera positions should match the camera restored/reported by the plan unless the plan intentionally moves it.

### Why it helped
- Makes click goldens deterministic and prevents false-green reports where the JSON captures a failed expectation but the script exits 0.
- Separates real resolver warnings, such as `selected surface triangles disconnected from seed`, from harness noise caused by camera drift or stray mouse events.

### Validation
- `xcodebuild -project QuickLookStep/QuickLookStep.xcodeproj -scheme QuickLookStep -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build`
- `QLS_FORCE_DIRECT_LAUNCH=1 QLS_SELECTION_DEBUG=1 QLS_SELECTION_DEBUG_OUTPUT=/tmp/quicklook-selection-debug-fixed-2 testing/scripts/run-testing.sh testing/plans/selection-debug-cube-hole.json testing/results/selection-debug-fixed-2.json`
- `swift testing/selection-debug/replay_selection_session.swift /tmp/quicklook-selection-debug-fixed-2/selection-debug-session.json testing/results/selection-debug-fixed-2-replay.json`
- Repeat the direct run once and confirm `selection-debug-session.json` has exactly 4 events, no expectation failures, and stable camera positions.

## 2026-07-03 Update

### Problem context
- Nearest feature-edge distance was still rebuilt and scanned on CPU for every surface/edge resolver pass, making the hottest shared edge/surface gate slower on larger meshes.

### What changed
- Added the GPU-assisted selection triage path: `SelectionModel.featureEdgeSegments` caches welded feature segments, `SelectionMetalAccelerator` runs the nearest-feature-edge distance kernel when the segment count reaches the threshold, and selection-debug summaries record `nearestFeatureEdgeAcceleration`.
- Added the validation override `QLS_SELECTION_METAL_MIN_SEGMENTS=1` for small repo fixtures; production default remains 256 segments, and `QLS_DISABLE_SELECTION_METAL=1` forces the CPU fallback path.

### Why it helped
- Keeps SceneKit hit testing, surface topology expansion, and highlight rendering unchanged while offloading the repeated nearest-feature-edge scan when a model is large enough to justify Metal dispatch.
- Debug sessions now show whether a click used `metal`, intentional `cpu`, or `unavailable` fallback, which makes speed/accuracy investigations less ambiguous.

### Validation
- `swift testing/selection-engine/scripts/check_metal_feature_distance.swift`
- `QLS_SELECTION_METAL_MIN_SEGMENTS=1 QLS_FORCE_DIRECT_LAUNCH=1 QLS_SELECTION_DEBUG=1 QLS_SELECTION_DEBUG_OUTPUT=/tmp/quicklook-selection-debug-gpu-metal testing/scripts/run-testing.sh testing/plans/selection-debug-cube-hole.json testing/results/selection-debug-gpu-metal.json`
- `QLS_SELECTION_METAL_MIN_SEGMENTS=1 QLS_DISABLE_SELECTION_METAL=1 QLS_FORCE_DIRECT_LAUNCH=1 QLS_SELECTION_DEBUG=1 QLS_SELECTION_DEBUG_OUTPUT=/tmp/quicklook-selection-debug-gpu-unavailable testing/scripts/run-testing.sh testing/plans/selection-debug-cube-hole.json testing/results/selection-debug-gpu-unavailable.json`
- Existing gates still apply: surface layer test, selection-engine replay, edge-shape loop, and the selection-debug cube-hole golden flow.

## 2026-07-03 Update

### Problem context
- Users needed a live, user-facing measurement panel after edge/surface selection, plus deterministic coverage for single edge, Shift multi-edge, surface replacement, blank clearing, and unit calibration behavior.

### What changed
- Added the measurement viewer triage workflow: normal click replaces selection, Shift-click adds an edge, Command-click toggles an edge, surface clicks replace all edges, and blank clicks clear unless Shift/Command is held.
- Measurement goldens should use `testing/plans/measurement-viewer-cube-hole.json`; reset units inside the plan because `quicklook.measurement.unit` and `quicklook.measurement.mmPerModelUnit` are persisted with app defaults.
- Automated plans can assert `measurementExpect`, and `run-testing.sh` fails on `measurementExpectationFailures`.

### Why it helped
- Separates user-facing measurements from debug telemetry while still keeping replayable JSON evidence for selected kind, entity count, raw model-unit length/area/perimeter, and unit mode.
- Prevents false confidence from screenshots alone by checking the measurement reducer state directly after each click.

### Validation
- `swift testing/selection-engine/scripts/check_selection_measurements.swift`
- `xcodebuild -project QuickLookStep/QuickLookStep.xcodeproj -scheme QuickLookStep -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build`
- `QLS_FORCE_DIRECT_LAUNCH=1 QLS_SELECTION_DEBUG=1 testing/scripts/run-testing.sh testing/plans/measurement-viewer-cube-hole.json testing/results/measurement-viewer-cube-hole.json`
- `testing/scripts/verify_quicklook_ui_launch.sh /Users/williamxu/Desktop/Projects/quicklook/build/Build/Products/Debug/QuickLookStep.app /Users/williamxu/Desktop/Projects/quicklook/testing/input/cube_hole.step /tmp/quicklook-ui-launch-measurement.png`

## 2026-07-04 Update

### Problem context
- User requested temporary operational disablement of surface detection to reduce jump-to-surface regressions during live manual testing.

### What changed
- Switched launch default for `edgeOnlyMode` in [QuickLookStepApp.swift](/Users/williamxu/Desktop/Projects/quicklook/QuickLookStep/QuickLookStep/QuickLookStepApp.swift) to `true` so selection stays edge-only by default.
- Existing `--edge-only` / `--edge-only=1` and `QLS_EDGE_ONLY=1` flags still force edge-only behavior; `--edge-only=0`/`QLS_EDGE_ONLY=0` now re-enables surface logic for targeted checks.

### Why it helped
- Prevents automatic fallback-to-surface routing for ambiguous clicks while the surface pathway is being tuned, with minimum behavioral disturbance to edge-path logic.

### Validation
- Build: `xcodebuild -project QuickLookStep/QuickLookStep.xcodeproj -scheme QuickLookStep -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build`
- Manual check: launch normally and verify surface mode no longer appears in click outcomes; re-run with `--edge-only=0` if surface behavior checks are needed.

```text
content change: default launch behavior changed to edge-only mode.
example usage: run without `--edge-only=0` while triaging edge clicks; pass `--edge-only=0` only when you want surface selection back.
```

## 2026-07-04 Update

### Problem context
- Multi-edge measurement needed CAD-style diagnostic detail instead of only total length and a coarse minimum distance.

### What changed
- Added user-facing multi-edge distance detail to the measurement model and panel: selected edge list, minimum/maximum edge-pair distance, XYZ component deltas, closest-point coordinates, and an expandable `Distance Details` section.
- Added `minMinimumDistance` / `maxMinimumDistance` measurement expectations and a focused golden plan at `testing/plans/measurement-multi-edge-details-cube-hole.json`.

### Why it helped
- Makes Shift/Cmd multi-edge selection inspectable and regression-testable without relying only on screenshots.
- Captures the same kind of per-axis measurement evidence expected from CAD measure panels.

### Validation
- `xcodebuild -project QuickLookStep/QuickLookStep.xcodeproj -scheme QuickLookStep -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build`
- `swift testing/selection-engine/scripts/check_selection_measurements.swift`
- `QLS_FORCE_DIRECT_LAUNCH=1 QLS_SELECTION_DEBUG=1 testing/scripts/run-testing.sh testing/plans/measurement-multi-edge-details-cube-hole.json testing/results/measurement-multi-edge-details-cube-hole.json`

```text
content change: multi-edge measurement now records expandable XYZ distance diagnostics.
example usage: Shift-select two edges in the viewer, open Distance Details, and inspect min/max distance, per-axis deltas, and closest points.
```

## 2026-07-04 Update

### Problem context
- A normal single edge click could appear as one "Single" selection while actually measuring/highlighting an inferred connected feature chain (for example `300 u`, 5 points, `line-segment -> ...`).

### What changed
- User-facing fitted-mode edge measurement/highlight now derives points from `edgeSnap.selectedEdge` endpoints instead of `resolved.chainWorldPoints`.
- Connected/debug/download chain data remains available; explicit connected mode still uses the broader chain.
- Added `testing/plans/measurement-single-edge-no-overmerge-cube-hole.json` as a regression plan.

### Why it helped
- Restores the expected CAD behavior: one click measures exactly one edge, while multi-edge measurement requires Shift/Cmd accumulation.

### Validation
- `xcodebuild -project QuickLookStep/QuickLookStep.xcodeproj -scheme QuickLookStep -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build`
- `QLS_FORCE_DIRECT_LAUNCH=1 QLS_SELECTION_DEBUG=1 testing/scripts/run-testing.sh testing/plans/measurement-single-edge-no-overmerge-cube-hole.json testing/results/measurement-single-edge-no-overmerge-cube-hole.json`
- `QLS_FORCE_DIRECT_LAUNCH=1 QLS_SELECTION_DEBUG=1 testing/scripts/run-testing.sh testing/plans/measurement-multi-edge-details-cube-hole.json testing/results/measurement-multi-edge-details-cube-hole.json`

```text
content change: fitted single-click edge display and measurement now use selected edge endpoints.
example usage: when a "Single" measurement shows combined edge chains, run the no-overmerge plan and verify length stays near one edge with `pointCount: 2`.
```
