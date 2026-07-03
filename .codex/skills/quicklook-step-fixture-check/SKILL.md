---
name: quicklook-step-fixture-check
description: Use this skill to run small .step/.stp validation checks and isolate parsing/render issues in QuickLookStep or Foxtrot.
---

# QuickLookStep STEP validation

Use this when a `.step` or `.stp` sample is loading incorrectly, appears rotated oddly, renders with missing geometry, or needs to be compared between Foxtrot and the host app.

## Default fixtures in this repo
- `testing/input/cube_hole.step`
- `testing/input/cuboid.step`
- user multi-format plan:
  `testing/plans/user-thor-multiformat.json`

## Fast Foxtrot parser isolation
Start with the parser alone so we can separate Foxtrot failures from SceneKit/host failures:

```bash
cd /Users/williamxu/Desktop/Projects/quicklook
make test-foxtrot
```

For a specific local sample:

```bash
cd /Users/williamxu/Desktop/Projects/quicklook/foxtrot
cargo run --release -- "/Users/williamxu/Downloads/thor luminos adaptor.step"
```

If the path has spaces, keep the quotes.

## Host app validation
Run the app directly against the same sample:

```bash
/Users/williamxu/Desktop/Projects/quicklook/build/Build/Products/Debug/QuickLookStep.app/Contents/MacOS/QuickLookStep \
  --sample "/Users/williamxu/Downloads/thor luminos adaptor.step"
```

What this isolates:
- Foxtrot fails and app fails: parser/input issue
- Foxtrot succeeds and app fails: SceneBuilder / SceneKit / importer path issue
- app succeeds but Finder preview fails: extension registration/cache issue

## Automated fixture pass
For orientation, zoom, and screenshot capture:

```bash
cd /Users/williamxu/Desktop/Projects/quicklook
testing/scripts/run-testing.sh "testing/plans/orientation-zoom.json"
testing/scripts/run-testing.sh "testing/plans/multi-format-orientation-speed.json"
```

For a single known-good smoke run:

```bash
cd /Users/williamxu/Desktop/Projects/quicklook
testing/scripts/run-sample.sh "testing/input/cube_hole.step"
```

## Edge-selection fixture path
When the task is specifically about click-to-edge behavior on STEP:

```bash
mkdir -p /tmp/quicklook-edge-download /tmp/quicklook-edge-probe
open -n -a "/Users/williamxu/Desktop/Projects/quicklook/build/Build/Products/Debug/QuickLookStep.app" --args \
  --selection-mode=connected \
  --edge-probe \
  --edge-probe-output /tmp/quicklook-edge-probe \
  --sample "/Users/williamxu/Downloads/thor luminos adaptor.step"
```

After manual clicks, inspect:
- `/tmp/quicklook-edge-download/edge-download-*.json`
- `/tmp/quicklook-edge-probe/*.json`
- `/tmp/quicklook-test-logs/quicklook-connect.log`

Also inspect unified logs for candidate locality and click timing:

```bash
/usr/bin/log show --predicate 'process == "QuickLookStep" AND (eventMessage CONTAINS "Selection candidates" OR eventMessage CONTAINS "Selection accepted" OR eventMessage CONTAINS "Selection ignored" OR eventMessage CONTAINS "Selection completed" OR eventMessage CONTAINS "Fatal error")' --last 5m --style compact | tail -n 160
```

For click bugs, use `quicklook-edge-selection-debug`. The main learned failure mode is broad mesh search: selecting the longest/most-point connected chain can jump to a different location and buffer. Healthy selection is local-first, has small `snapDistance`, bounded `localTriangles`, and ignores blank/flat clicks quickly.

## What to record when a fixture fails
- exact source file path
- whether failure reproduces in Foxtrot CLI
- `SceneBuilder` load method if available
- whether screenshots were produced
- whether selection JSON contains `chainPoints`, `selectedEdge`, `snapDistance`, and `isExactEdge`
- for click bugs: `Selection candidates`, `Selection accepted`, `Selection ignored`, and `Selection completed elapsedMs` logs

## Common interpretations
- Missing triangles or holes in STEP: likely Foxtrot tessellation/parsing issue
- Loads in app but with wrong shading only: likely SceneKit material/import path issue
- `.stp` works but `.step` does not: check UTI/extension handling, not geometry logic
- Click logs say `connected edges` with long `chainPoints`, but UI looks wrong: overlay/rendering issue, not chain extraction issue
- Click selects a totally different edge or buffers: candidate discovery is too broad or ranking prefers long chains; diagnose with `quicklook-edge-selection-debug`

## 2026-07-02 Update

### Problem context
- The current repo has multiple fixture tiers: local STEP fixtures, multi-format converted fixtures, user thor samples, and surface-selection checks.

### What changed
- Added the practical testing split: use `run-sample.sh` for one-file smoke checks, `run-testing.sh` with `orientation-zoom.json` or `multi-format-orientation-speed.json` for regression runs, and `run_visible_surface_overlay_test.sh` when surface overlay visibility is in scope.

### Why it helped
- Makes it faster to pick the smallest useful test instead of jumping straight to broad manual Finder checks.

### Validation
- `testing/scripts/run-sample.sh "testing/input/cube_hole.step"`
- `testing/scripts/run-testing.sh "testing/plans/orientation-zoom.json" "testing/results/orientation-zoom-local.json"`
- `testing/scripts/run-testing.sh "testing/plans/multi-format-orientation-speed.json" "testing/results/multi-format-local.json"`
- `testing/surface-selection/scripts/run_visible_surface_overlay_test.sh`
