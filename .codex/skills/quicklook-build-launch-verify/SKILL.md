---
name: quicklook-build-launch-verify
description: Use this skill after every QuickLookStep build or when debugging launch/UI visibility. Requires building the app, launching the real macOS UI with the thor STEP sample, verifying the top visible window belongs to QuickLookStep, and capturing a screenshot. A passing xcodebuild alone is not sufficient.
---

# QuickLookStep Build And Launch Verify

Use this after every code edit/build in this project. Build success is not enough: the app must visibly launch.

## Required Command

From repo root:

```bash
xcodebuild -project QuickLookStep/QuickLookStep.xcodeproj -scheme QuickLookStep -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
testing/scripts/verify_quicklook_ui_launch.sh
```

The verifier launches:

```bash
open -n -a "/Users/williamxu/Desktop/Projects/quicklook/build/Build/Products/Debug/QuickLookStep.app" --args \
  --selection-mode=connected \
  --sample "/Users/williamxu/Downloads/thor luminos adaptor.step"
```

## Passing Criteria

- `xcodebuild` exits 0.
- `QuickLookStep` process stays alive.
- System Events reports at least one `QuickLookStep` window.
- CoreGraphics reports the top visible window owner is `QuickLookStep`.
- CoreGraphics reports the top visible `QuickLookStep` window is at least `900x600`; a tiny `1x32` frontmost window is a failure.
- Screenshot exists at `/tmp/quicklook-ui-launch-check.png`.
- Lifecycle log shows `bring-front-... visible=true`.

## If It Fails

Use `diagnose-fix`. Do not claim the build is good. Check:

```bash
cat /tmp/quicklookstep-lifecycle.log
pgrep -af "QuickLookStep.app/Contents/MacOS/QuickLookStep"
osascript -e 'tell application "System Events" to get name of every window of process "QuickLookStep"'
```

If the process exists but the top visible window is not `QuickLookStep`, the UI is still broken for this workflow.

## 2026-07-03 Update

### Problem context
- Golden-flow diagnosis showed `open -n`/LaunchServices runs can fail to deliver test-plan arguments or keep another app's chrome as the top visible window, while direct binary launch still produces valid test JSON.

### What changed
- Added the fallback rule: when `run-testing.sh` times out with no output JSON and no `Automated load` logs, rerun with `QLS_FORCE_DIRECT_LAUNCH=1`; when the thor Downloads sample is absent, pass an absolute repo fixture to `verify_quicklook_ui_launch.sh` and report that the original thor UI proof was not executed.

### Why it helped
- Separates app correctness from local LaunchServices/focus state and prevents a missing user Downloads fixture from blocking all UI verification.

### Validation
- `QLS_FORCE_DIRECT_LAUNCH=1 testing/scripts/run-testing.sh testing/plans/orientation-zoom.json testing/results/diagnosis-orientation-zoom-direct.json`
- `testing/scripts/verify_quicklook_ui_launch.sh /Users/williamxu/Desktop/Projects/quicklook/build/Build/Products/Debug/QuickLookStep.app /Users/williamxu/Desktop/Projects/quicklook/testing/input/cube_hole.step /tmp/quicklook-ui-launch-check-cube.png`
- Check `/tmp/quicklookstep-lifecycle.log` and top-window output before claiming the UI launch verifier passed.
