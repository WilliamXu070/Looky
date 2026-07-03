# 007 Build Launch UI Verification Gap

## Symptom

After a successful build, launching `QuickLookStep.app` with a sample file can leave the app active without the viewer window visibly coming to the front. The user-visible result is "the UI does not load," even though process/window checks may report that the app exists.

## Expected Behavior

The exact launch command should show a frontmost `QuickLookStep` viewer window with the sample file loaded:

```bash
open -n -a "/Users/williamxu/Desktop/Projects/quicklook/build/Build/Products/Debug/QuickLookStep.app" --args \
  --selection-mode=connected \
  --sample "/Users/williamxu/Downloads/thor luminos adaptor.step"
```

## Diagnosis

Previous verification was too weak. It checked build success and sometimes process/window existence, but the screenshot showed `QuickLookStep` as the active menu-bar app while another window was visually in front. The first verifier then revealed the exact window frame was only `1x32`, so a passing process/top-owner check can still miss the real UI failure.

## Plan

- Strengthen app window activation after host-window creation.
- Restore the host window to a real minimum/default size if SwiftUI/AppKit collapses it.
- Add lifecycle logs for host-window visibility and key/fronting attempts.
- Add a reusable launch verification script that checks the top visible macOS window owner and size, not just process existence.
- Add a project skill requiring build + launch + screenshot/top-window verification after every build.

## Verification

- `xcodebuild ... build`
- `testing/scripts/verify_quicklook_ui_launch.sh`
- screenshot artifact under `/tmp/quicklook-ui-launch-check.png`

## Status

Fixed with app-side window front retries plus `testing/scripts/verify_quicklook_ui_launch.sh`. This workflow is now captured in `.codex/skills/quicklook-build-launch-verify/SKILL.md`.
