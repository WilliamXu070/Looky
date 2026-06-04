# QuickLookStep Testing

This folder contains a lightweight, script-driven test harness for evaluating
input response + orientation/zoom behavior as you add features.

## Structure

- `plans/` – JSON test plans
- `scripts/` – runner scripts
- `results/` – generated output from runs

## Test plan format

A test plan is JSON with one or more scenarios:

```json
{
  "scenarios": [
    {
      "name": "friendly-name",
      "file": "testing/input/cube_hole.step",
      "actions": [
        { "kind": "rotateY", "value": 25, "durationMs": 120 },
        { "kind": "zoom", "value": -6, "durationMs": 120 },
        { "kind": "wait", "durationMs": 200 }
      ]
    }
  ]
}
```

Supported action kinds:
- `rotateX`, `rotateY`, `rotateZ` (value in degrees)
- `zoom` (`value` is delta field-of-view in degrees; clamp is currently 5..120)
- `wait` (`durationMs` only)

## Run a test suite

```bash
./testing/scripts/run-testing.sh [path/to/plan.json] [path/to/output.json]
```

Run one sample quickly (builds a throwaway plan for a single file):

```bash
./testing/scripts/run-sample.sh testing/input/cube_hole.step testing/results/sample-quickrun.json
```

### Run a single sample directly

You can open the app and load one sample file immediately with:

```bash
build/Build/Products/Release/QuickLookStep.app/Contents/MacOS/QuickLookStep --sample testing/input/cube_hole.step
```

Or using a plan:

```bash
build/Build/Products/Release/QuickLookStep.app/Contents/MacOS/QuickLookStep \
  --test-plan testing/plans/orientation-zoom.json \
  --test-output testing/results/manual-run.json \
  --auto-quit
```

You can also launch the app directly with one sample path:

```bash
./build/Build/Products/Release/QuickLookStep.app/Contents/MacOS/QuickLookStep --sample testing/input/cube_hole.step --auto-quit
```

Run this script from a macOS desktop session (the app uses SwiftUI/SceneKit and requires AppKit).  
From CI/headless shells it can fail to start with an `Abort trap` before creating output.

The runner reads:
- `QLS_TEST_PLAN`: test plan file
- `QLS_TEST_OUTPUT`: output JSON path
- `QLS_TEST_AUTO_QUIT=1`: closes the app after run

Output JSON includes:
- `loadTimeMs` per scenario
- timeline events with `orientationDegrees`, `cameraPosition`, `fieldOfView`, and `distanceFromOrigin`

`elapsedMs` is wall-clock time relative to run start in each sample.

## Add new scenarios

Drop new `*.step` files into `testing/input/` (or reference absolute paths)
and add new scenarios to a new plan file.

`testing/input/` ships with a few small samples from the repo:
- `cube_hole.step`
- `cuboid.step`
- `abstract_pca.step`
