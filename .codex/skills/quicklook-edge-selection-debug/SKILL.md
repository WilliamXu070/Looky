---
name: quicklook-edge-selection-debug
description: Use this skill when QuickLookStep click-to-edge selection jumps to the wrong edge, selects a distant feature, buffers too long after a click, or needs connected/probe validation on the STEP viewer. Covers hit testing, nearest-edge candidate search, connected edge extraction, probe JSON, and timing logs.
---

# QuickLookStep Edge Selection Debug

Use this for the upstream click-selection layer: hit point -> nearest local edge -> optional connected edge component -> overlay/probe/download.

Do not use this skill for pure line/arc/semicircle classification after `chainPoints` already exist. Use `quicklook-edge-shape-detection` for that later shape layer.

## Key Lesson

Wrong-edge selections and long buffering usually come from letting a click search too broadly:

- `nearestEdgeCandidates(for:in:)` must stay local to the clicked triangle neighborhood.
- candidate ranking must prefer the closest snapped edge, not the longest chain or most points.
- connected mode may recover a component only after choosing a nearby local edge.
- `nearestFeatureEdge(to:)` must have a max-distance guard, or blank clicks can jump to distant model features.
- probe/download JSON can still save the full connected chain; the UI overlay can draw only the selected primitive.

The current fix pattern is in [SceneKitView.swift](/Users/williamxu/Desktop/Projects/quicklook/QuickLookStep/QuickLookStep/SceneKitView.swift):

- `localSelectionDistanceThreshold(for:)`
- bounded local candidate scan in `nearestEdgeCandidates(for:in:)`
- closest-first `resolveBestDownloadSelection(...)`
- `nearestFeatureEdge(to:maxDistance:)`
- timing logs: `Selection candidates ...`, `Selection accepted ...`, `Selection completed elapsedMs=...`, `Selection ignored ...`

## Diagnose Workflow

When selection feels wrong:

1. Reproduce with connected mode and probe enabled.
2. Click once near a visible edge and once on a flat/blank area.
3. Inspect logs for candidate count, snap distance, accepted edge, and elapsed time.
4. Inspect the newest `/tmp/quicklook-edge-download/edge-download-*.json`:
   - `selectedEdge`
   - `snapDistance`
   - `isExactEdge`
   - `chainKind`
   - `chainPoints.count`
   - `shapeDetection.sequence`
5. Inspect the newest `/tmp/quicklook-edge-probe/*.json`:
   - `connectedFeatureSegments`
   - `surroundingTriangles`
6. If a flat/blank click writes a download, selection is too permissive.
7. If logs show many local triangles/candidates or elapsed time spikes, candidate discovery is too broad or chain fitting is happening too early.

## Exact Manual Repro Command

Build first, then launch:

```bash
cd /Users/williamxu/Desktop/Projects/quicklook
rm -rf /tmp/quicklook-edge-probe /tmp/quicklook-edge-download
mkdir -p /tmp/quicklook-edge-probe /tmp/quicklook-edge-download
open -n -a "/Users/williamxu/Desktop/Projects/quicklook/build/Build/Products/Debug/QuickLookStep.app" --args \
  --selection-mode=connected \
  --edge-probe \
  --edge-probe-output /tmp/quicklook-edge-probe \
  --sample "/Users/williamxu/Downloads/thor luminos adaptor.step"
```

If `open -a` creates a process with no usable window, activate it:

```bash
osascript -e 'tell application id "com.johnboiles.QuickLookStep" to activate'
```

## Log Checks

Use unified logs after clicking:

```bash
/usr/bin/log show --predicate 'process == "QuickLookStep" AND (eventMessage CONTAINS "Selection candidates" OR eventMessage CONTAINS "Selection accepted" OR eventMessage CONTAINS "Selection snapped" OR eventMessage CONTAINS "Selection ignored" OR eventMessage CONTAINS "Selection completed" OR eventMessage CONTAINS "Fatal error")' --last 5m --style compact | tail -n 160
```

Healthy signs:

- near-edge click has small `distance`
- `Selection candidates localTriangles=...` is bounded, not whole-mesh scale
- `Selection completed elapsedMs=...` is small enough to feel immediate
- blank/flat click logs `Selection ignored`
- no `Fatal error` or `Index out of range`

Bad signs:

- accepted `distance` is large relative to the visible local feature
- candidate selection says connected/component but click was on blank flat face
- app writes new edge-download JSON after blank click
- timing grows with full mesh complexity

## JSON Checks

Latest download:

```bash
latest=$(ls -t /tmp/quicklook-edge-download/edge-download-*.json | head -n 1)
swift testing/edge-shape-detection/scripts/replay_shape_sequence.swift "$latest" /tmp/quicklook-live-shape-sequence.json
cat /tmp/quicklook-live-shape-sequence.json
```

For the thor rounded slot, expected sequence remains:

```text
line -> semicircle -> line -> semicircle
```

That sequence verifies the saved chain. It does not by itself prove the clicked edge was local; always pair it with `snapDistance` and logs.

If the same physical rounded feature gives different shape sequences depending on whether the click came from the top surface or adjacent connection surface, treat that as a shape-layer surface-invariance bug after confirming `snapDistance` is local. Use `quicklook-edge-shape-detection` and run `testing/edge-shape-detection/scripts/replay_surface_invariance.sh`; do not widen selection search to fix that symptom.

## Implementation Guardrails

Keep these boundaries:

- Do not rank candidates by longest chain in the selection layer.
- Do not scan the entire mesh per click unless explicitly building an offline analysis tool.
- Do not use global nearest feature fallback without a max distance.
- Do not perform connected-component traversal until a local candidate is accepted.
- Do not make shape detection responsible for fixing wrong click target selection.

If behavior regresses, create/update a local ticket under:

```text
testing/edge-shape-detection/tickets/
```

Known ticket for this issue:

```text
testing/edge-shape-detection/tickets/004-local-selection-jumps-and-buffering.md
```
