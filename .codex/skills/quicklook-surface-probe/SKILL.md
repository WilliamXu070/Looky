---
name: quicklook-surface-probe
description: Use when QuickLookStep surface clicks route to edges or surface selection feels wrong in the live GUI. Launches the app with surface-probe recording, captures the exact manual click point and resolver decision, analyzes whether an edge stole a surface click, and uses that probe for regression testing.
---

# QuickLookStep Surface Probe

Use this when the live GUI selects an edge instead of the intended surface.

## Launch Probe

From repo root:

```bash
rm -rf /tmp/quicklook-surface-probe
mkdir -p /tmp/quicklook-surface-probe
xcodebuild -project QuickLookStep/QuickLookStep.xcodeproj -scheme QuickLookStep -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
open -n -a "/Users/williamxu/Desktop/Projects/quicklook/build/Build/Products/Debug/QuickLookStep.app" --args \
  --selection-mode=connected \
  --surface-probe \
  --surface-probe-output /tmp/quicklook-surface-probe \
  --sample "/Users/williamxu/Downloads/thor luminos adaptor.step"
```

Click the exact surface location that fails. Each click writes a `*surface-probe-*.json` file.

## Analyze Latest Probe

```bash
testing/surface-selection/scripts/analyze_surface_probe.py /tmp/quicklook-surface-probe
```

Buckets:

- `resolved-surface`: click routed to surface correctly.
- `edge-stole-surface-click`: surface candidate existed, but resolver returned edge. Fix routing/priority.
- `click-inside-edge-promotion-zone`: click was too close to a feature edge under current threshold. Tune threshold or require a surface modifier.
- `no-surface-candidate`: inferred surface logic failed for the hit triangle. Fix mesh/surface reconstruction.

## Required Verification

After changes:

```bash
testing/surface-selection/scripts/run_surface_layer_test.sh
testing/surface-selection/scripts/run_visible_surface_overlay_test.sh
testing/scripts/verify_quicklook_ui_launch.sh
```

Also run edge regressions:

```bash
testing/edge-shape-detection/scripts/run_shape_detection_loop.sh
testing/edge-shape-detection/scripts/replay_surface_invariance.sh
```

Do not call the live surface issue fixed until a probe click either resolves to `surface` or the chosen failure bucket has been intentionally handled.

## 2026-07-03 Update

### Problem context
- `testing/edge-shape-detection/scripts/replay_surface_invariance.sh` depended on stale `/tmp/quicklook-edge-download` JSON files, so a fresh checkout failed before exercising the replay logic.

### What changed
- The replay now defaults to the checked-in saved edge fixture at `testing/edge-shape-detection/polygons/saved/thor-connected-edge-semicircle.json` and prints explicit instructions when custom top/side inputs are missing.

### Why it helped
- Keeps the probe/golden replay lane reproducible from repo state while still allowing freshly captured top/side edge downloads for live regression checks.

### Validation
- `testing/edge-shape-detection/scripts/replay_surface_invariance.sh`
- For live probe pairs: `testing/edge-shape-detection/scripts/replay_surface_invariance.sh /path/to/top-edge-download.json /path/to/side-edge-download.json`

## 2026-07-03 Update

### Problem context
- Manual GUI clicks during surface probing can appear to do nothing if QuickLookStep is not frontmost, and repeated clicks within the same second can overwrite the same `surface-probe-*.json` filename.

### What changed
- Added this probing caveat: before automated coordinate clicks, force QuickLookStep frontmost and clear the probe directory before the single click under test.

### Why it helped
- Prevents confusing stale probe reads with current click results.
- Makes it clear when a click actually hit the app versus when focus stayed in Codex or another foreground app.

### Validation
- Run:
  - `rm -f /tmp/quicklook-surface-probe/*.json`
  - `osascript -e 'tell application "QuickLookStep" to activate' -e 'tell application "System Events" to tell application process "QuickLookStep" to set frontmost to true'`
  - click once
  - `ls -lt /tmp/quicklook-surface-probe | head`

## 2026-07-03 Update

### Problem context
- Surface probes and automated camera snapshots were separate, so a bad manual click did not produce one replayable artifact with the click, camera, resolver decision, screenshots, and expectation.

### What changed
- Added the consolidated selection-debug workflow: launch with `--selection-debug --selection-debug-hud=1 --selection-debug-output /tmp/quicklook-selection-debug`, inspect `selection-debug-session.json`, replay with `testing/selection-debug/replay_selection_session.swift`, and promote one event with `testing/selection-debug/promote_debug_event.py`.

### Why it helped
- One click now explains the final kind, seed triangle, surface/edge candidate counts, nearest feature-edge distance, thresholds, render bounds, clipping/disconnected warnings, and before/after screenshots.
- Captured bad clicks can become `selectAt` golden plans instead of one-off manual notes.

### Validation
- `QLS_FORCE_DIRECT_LAUNCH=1 QLS_SELECTION_DEBUG=1 QLS_SELECTION_DEBUG_OUTPUT=/tmp/quicklook-selection-debug testing/scripts/run-testing.sh testing/plans/selection-debug-cube-hole.json testing/results/selection-debug-cube-hole.json`
- `swift testing/selection-debug/replay_selection_session.swift /tmp/quicklook-selection-debug/selection-debug-session.json testing/results/selection-debug-cube-hole-replay.json`
- Manual HUD check: launch with `--selection-debug --selection-debug-hud=1`, click the suspect region, then confirm `selection-debug-session.json` plus `screenshots/*-before.png` and `screenshots/*-after.png` exist.

## 2026-07-03 Update

### Problem context
- A selection-debug log pull found two probe-quality pitfalls: automated `selectAt` could use a drifted live `SCNView.pointOfView`, and a real `mouseUp` could write an extra event after automated output was complete.

### What changed
- Added this probe sanity rule: when using selection-debug sessions for regression evidence, confirm event count matches the intended clicks and compare `event.camera.position` across events before diagnosing the resolver.
- Prefer `selectAt` goldens with enforced expectations for repeatable surface bugs; use manual HUD/probe clicks for discovery, then promote the captured event.

### Why it helped
- Prevents treating harness noise as a surface-selection bug.
- Makes it clear whether a wrong/blank selection was caused by camera state, click routing, or the actual surface resolver.

### Validation
- `QLS_FORCE_DIRECT_LAUNCH=1 QLS_SELECTION_DEBUG=1 QLS_SELECTION_DEBUG_OUTPUT=/tmp/quicklook-selection-debug-fixed testing/scripts/run-testing.sh testing/plans/selection-debug-cube-hole.json testing/results/selection-debug-fixed.json`
- Inspect `/tmp/quicklook-selection-debug-fixed/selection-debug-session.json`: planned cube-hole debug runs should have 4 events, stable camera positions, and no `selectionDebugExpectationFailures` in the test result JSON.

## 2026-07-03 Update

### Problem context
- Live selection-debug recording snapped back to the default camera after clicks or HUD updates, and camera drags could be recorded as selection clicks.

### What changed
- Updated the live-recorder guidance: preserve the active `SCNView.pointOfView` unless the scene changes, and treat mouse drags over a small threshold as camera movement instead of selection events.

### Why it helped
- Manual probes can orbit/pan the viewer between clicks without losing camera state or polluting `selection-debug-session.json` with drag-release events.

### Validation
- Launch with `open -n -a build/Build/Products/Debug/QuickLookStep.app --args --selection-debug --selection-debug-hud=1 --selection-debug-output /tmp/quicklook-live-recorder --sample /Users/williamxu/Desktop/Projects/quicklook/testing/input/cube_hole.step`.
- Drag/orbit the model, then inspect `/tmp/quicklook-live-recorder/selection-debug-session.json`: drags should not add events, and subsequent click events should keep the moved camera position.
