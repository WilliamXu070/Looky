---
name: quicklook-release-readiness
description: Use this skill to prepare a confidence checklist before tagging, packaging, or sharing a QuickLookStep build.
---

# QuickLookStep release readiness

Use when preparing a release candidate, checking if the app is safe to share, or validating that Finder preview behavior matches the current codebase.

## Scope
- Main app bundle: `QuickLookStep`
- Preview extension: `StepPreview`
- Thumbnail extension: `StepThumbnail`
- Supported formats in current repo: `.step`, `.stp`, `.obj`, `.stl`, `.gltf`, `.glb`, `.3mf`

## Required build gate
Run the release build from repo root:

```bash
cd /Users/williamxu/Desktop/Projects/quicklook
make foxtrot.h
make libfoxtrot_universal.a
xcodebuild \
  -project QuickLookStep/QuickLookStep.xcodeproj \
  -scheme QuickLookStep \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build
```

## Required automated validation
Run both of these:

```bash
cd /Users/williamxu/Desktop/Projects/quicklook
testing/scripts/run-sample.sh "testing/input/cube_hole.step"
testing/scripts/run-testing.sh "testing/plans/multi-format-orientation-speed.json"
```

What to check in the generated JSON:
- every scenario has a non-empty `loaderMethod`
- `loadTimeMs` is populated
- `events` exist after load and after actions
- screenshots were written into `testing/results/screenshots/...`

## Required manual validation
Launch the app directly against a known user sample:

```bash
/Users/williamxu/Desktop/Projects/quicklook/build/Build/Products/Release/QuickLookStep.app/Contents/MacOS/QuickLookStep \
  --sample "/Users/williamxu/Downloads/thor luminos adaptor.step"
```

Then verify:
- the host window opens
- the model renders with expected initial orientation
- orbit and zoom behave normally
- a click still produces selection overlay if selection work is in scope

## Finder and Quick Look readiness
If the build is meant to be shared as an app bundle, refresh registration:

```bash
/Users/williamxu/Desktop/Projects/quicklook/testing/scripts/register-file-types.sh \
  "/Users/williamxu/Desktop/Projects/quicklook/build/Build/Products/Release/QuickLookStep.app"
```

Then run:

```bash
pluginkit -m | grep -i QuickLookStep
qlmanage -r
qlmanage -r cache
```

## Ship checklist
- `git status --short` reviewed for unintended changes
- no stale debug-only logging or temporary probe paths accidentally left on
- release app exists at `build/Build/Products/Release/QuickLookStep.app`
- supported file claims still match the current `Info.plist` declarations
- if `.obj`/`.stl`/`.3mf` handling changed, do one Finder-side validation after registration refresh

## Known failure buckets
- Rust bridge stale: rerun `make foxtrot.h` and `make libfoxtrot_universal.a`
- App launches but Finder still uses wrong viewer: rerun `testing/scripts/register-file-types.sh`
- Scene loads in app but not in Quick Look: treat as extension registration/cache problem first
- STEP fails in both app and Foxtrot CLI: treat as parser/input issue, not host UI issue
