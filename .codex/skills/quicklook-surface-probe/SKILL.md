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
