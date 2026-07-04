---
name: quicklook-plugin-troubleshoot
description: Use this skill for QuickLook/QuickLookStep plugin refresh issues, cache problems, and Finder extension not showing up.
---

# QuickLookStep plugin troubleshooting

Use when `QuickLookStep` previews or thumbnails do not appear, or Finder extension registration seems stale.

## Goal
Ensure `.step/.stp/.obj/.stl/.gltf/.glb/.3mf/.sldprt/.sldasm` are claimed by the rebuilt QuickLookStep extensions and Finder/Quick Look reflects the latest binary.

## 0) Identify which app you're resetting
Most recent bundle path in this workspace:

- Built app: `build/Build/Products/Debug/QuickLookStep.app`
- Installed app example: `/Applications/QuickLookStep.app`

Extension bundle IDs from this project:
- Thumbnail: `com.johnboiles.QuickLookStep.StepThumbnail`
- Preview: `com.johnboiles.QuickLookStep.StepPreview`

## 1) Hard refresh path (use after builds, signature mismatch, stale extension behavior)
```bash
APP_BUNDLE="/Users/williamxu/Desktop/Projects/quicklook/build/Build/Products/Debug/QuickLookStep.app"

pluginkit -r -u com.johnboiles.QuickLookStep.StepThumbnail
pluginkit -r -u com.johnboiles.QuickLookStep.StepPreview
pluginkit -r -a "$APP_BUNDLE"

qlmanage -r
qlmanage -r cache

pluginkit -e use -i com.johnboiles.QuickLookStep.StepThumbnail
pluginkit -e use -i com.johnboiles.QuickLookStep.StepPreview

killall QuickLookUIService || true
killall Finder || true
```

## 2) Verification flow
- Re-open a file with space bar preview:
  - `qlmanage -t -s 512 -o /tmp/ql-test "/Users/williamxu/Downloads/thor luminos adaptor.step"`
  - check `/tmp/ql-test` for generated thumbnail/preview artifacts.
- Confirm quick look extensions are registered:
  - `pluginkit -m | grep -i "QuickLookStep"`
- Confirm plugin IDs are selected:
  - `pluginkit -e use -i com.johnboiles.QuickLookStep.StepThumbnail`
  - `pluginkit -e use -i com.johnboiles.QuickLookStep.StepPreview`
- If still stale previews:
  - make sure old app bundles in Trash are removed (macOS can keep old plugin registrations).
  - reboot once if `pluginkit` state is still stale.

## 3) File-type binding verification
From this repo, use the provided register helper (keeps supported UTI coverage aligned):
```bash
/Users/williamxu/Desktop/Projects/quicklook/testing/scripts/register-file-types.sh "$APP_BUNDLE"
```

Then rerun a probe:
```bash
open -a "$APP_BUNDLE" --args --sample "/Users/williamxu/Downloads/thor luminos adaptor.step"
```

If launch via `open` fails in CI/headless contexts, run direct binary as a fallback:
```bash
/Users/williamxu/Desktop/Projects/quicklook/build/Build/Products/Debug/QuickLookStep.app/Contents/MacOS/QuickLookStep --sample "/Users/williamxu/Downloads/thor luminos adaptor.step"
```

## 4) Fast escalation checks
- For logs:
  - `/tmp/quicklookstep-lifecycle.log`
  - `/tmp/quicklook-test-logs/quicklook-*` if test mode is active
- For extension registration issues after update channel changes:
  - compare `com.johnboiles.QuickLookStep` bundle IDs in `QuickLookStep/QuickLookStep.xcodeproj/project.pbxproj`
  - rebuild + rerun this skill.

## 2026-07-03 Update

### Problem context
- QuickLook preview for some STEP/STP models still behaved like legacy handling after rebuilds, while direct host launch showed the new app but extension routing still skipped newer registration paths.

### What changed
- Extended `/Users/williamxu/Desktop/Projects/quicklook/testing/scripts/register-file-types.sh` to include STEP/STP identifiers:
  - `public.step`, `com.shapr3d.step`, `com.shapr3d.stp`, `a360.step`, `com.johnboiles.step`.
- Used this after syncing `/Applications/QuickLookStep.app` and `qlmanage` cache reset.

### Why it helped
- Helps avoid QuickLook claiming old/partial handlers for STEP-family formats and forces explicit QuickLookStep binding in the registration step.

### Validation
- `testing/scripts/register-file-types.sh /Applications/QuickLookStep.app`
- `qlmanage -r && qlmanage -r cache`
- `killall QuickLookUIService Finder || true`
- `open -a /Applications/QuickLookStep.app --args --sample /path/to/model.glb`

```text
content change: expanded STEP/STP coverage in register-file-types.sh.
example usage: run immediately after each rebuild to avoid stale handler claims for STEP/STP previews.
```

## 2026-07-04 Update

### Problem context
- Adding SolidWorks `.SLDPRT/.SLDASM` accommodation requires Finder/QuickLook to route those proprietary file extensions to QuickLookStep; otherwise the app can load the file directly but space-bar preview may stay with another handler or no handler.

### What changed
- Added SolidWorks content types to the supported registration guidance and `testing/scripts/register-file-types.sh`: `com.solidworks.part` and `com.solidworks.assembly`.

### Why it helped
- Keeps installed app refreshes aligned with the new `Info.plist` declarations so `.sldprt/.sldasm` files reach the QuickLookStep preview/thumbnail extensions.

### Validation
- `testing/scripts/register-file-types.sh /Applications/QuickLookStep.app`
- `qlmanage -r && qlmanage -r cache`
- `open -a /Applications/QuickLookStep.app --args --sample "/Users/williamxu/Downloads/spur-gear-415.snapshot.1/Gear.SLDPRT"`

```text
content change: registered SolidWorks part/assembly content types for QuickLookStep refresh workflows.
example usage: after installing a build with SLDPRT support, run the helper so Finder routes Gear.SLDPRT into QuickLookStep instead of showing stale no-preview behavior.
```
