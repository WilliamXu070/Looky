---
name: quicklook-build-pipeline
description: Use this skill for normal local builds, compiler errors, and Fast iteration in QuickLookStep.
---

# QuickLookStep build pipeline

Use when the task is about compiling the app, rebuilding bindings, or fixing routine build failures.

## Repository entrypoint
- `cd /Users/williamxu/Desktop/Projects/quicklook`
- Primary Makefile targets are at repo root:
  - `make foxtrot.h`
  - `make libfoxtrot_universal.a`
  - `make test-foxtrot`
  - `make xcodebuild`

## Full deterministic build sequence
Run this when moving between Rust/C++ header changes and Swift rebuilds:

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

Use this fast local variant for daily iteration (no full archive assumptions):
```bash
xcodebuild \
  -project QuickLookStep/QuickLookStep.xcodeproj \
  -scheme QuickLookStep \
  -configuration Debug \
  -derivedDataPath build \
  build
```

## Useful validation after build
- Confirm native binary exists:
  - `ls -l build/Build/Products/Debug/QuickLookStep.app/Contents/MacOS/QuickLookStep`
  - `ls -l build/Build/Products/Release/QuickLookStep.app/Contents/MacOS/QuickLookStep`
- Smoke launch (windowed mode) after rebuild:
  - `./build/Build/Products/Debug/QuickLookStep.app/Contents/MacOS/QuickLookStep --sample "/Users/williamxu/Downloads/thor luminos adaptor.step"`
- Clear stale artifacts when cache state is weird:
  - `rm -rf build`
  - rerun the full sequence above.

## Typical failures and direct remediations
- **Rust symbols missing in Swift**
  - Run `make foxtrot.h` first, then rerun Rust lib + Xcode build.
- **Undefined symbols / architecture mismatch**
  - Verify x86_64 + aarch64 targets are available:
    `rustup target list --installed | grep -E 'x86_64-apple-darwin|aarch64-apple-darwin'`
  - Rebuild universal lib: `make libfoxtrot_universal.a`
- **Xcode build cache dead**
  - `rm -rf build`
  - delete derived data for this scheme if needed, rerun build.
- **Cannot find Swift package or SPM state oddities**
  - Clean then build with `-derivedDataPath build` above so plugin/framework cache is predictable.

## Direct test hooks this skill usually chains into
- `testing/scripts/run-sample.sh <sample_file>`
- `testing/scripts/run-testing.sh <plan_json> <output_json>`
- `testing/scripts/register-file-types.sh`

## 2026-07-03 Update

### Problem context
- Adding app-only Swift files under `QuickLookStep/QuickLookStep` can look like it requires manual `project.pbxproj` source-phase edits.

### What changed
- Documented that the app target uses a `PBXFileSystemSynchronizedRootGroup` for `QuickLookStep/QuickLookStep`, so new Swift files in that folder are picked up by the `QuickLookStep` target without explicit build-file entries.

### Why it helped
- Avoids unnecessary project-file churn and reduces worktree conflict risk when adding production app Swift files.

### Validation
- Add the Swift file under `QuickLookStep/QuickLookStep`, then run `xcodebuild -project QuickLookStep/QuickLookStep.xcodeproj -scheme QuickLookStep -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build`.
- If the build logs show `SwiftCompile ... <NewFile>.swift`, no manual `project.pbxproj` edit is needed.

## 2026-07-02 Update

### Problem context
- Project execution now spans Rust FFI rebuilds, Xcode app builds, direct `.app` launch, and GUI-backed test scripts; using only `xcodebuild` misses the real runtime path.

### What changed
- Added the current execution map: rebuild `foxtrot.h` and `libfoxtrot_universal.a` for Rust/C header changes, build `QuickLookStep` with `-derivedDataPath build`, then validate with direct app launch or `testing/scripts/verify_quicklook_ui_launch.sh`.

### Why it helped
- Keeps build troubleshooting tied to the actual repo entrypoints and prevents false confidence from a compile-only pass.

### Validation
- `make foxtrot.h`
- `make libfoxtrot_universal.a`
- `xcodebuild -project QuickLookStep/QuickLookStep.xcodeproj -scheme QuickLookStep -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build`
- `testing/scripts/verify_quicklook_ui_launch.sh`

## 2026-07-03 Update

### Problem context
- Adding Metal compute support raised the question of whether a new `.metal` file needs manual `project.pbxproj` target membership edits.

### What changed
- Documented that `.metal` files placed under `QuickLookStep/QuickLookStep` are included by the same file-system synchronized app group as Swift files and should compile into `Contents/Resources/default.metallib`.

### Why it helped
- Prevents unnecessary Xcode project churn while giving a concrete packaging check for runtime kernel-loading failures.

### Validation
- `xcodebuild -project QuickLookStep/QuickLookStep.xcodeproj -scheme QuickLookStep -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build`
- `find build/Build/Products/Debug/QuickLookStep.app/Contents/Resources -maxdepth 1 -name '*.metallib' -print -exec ls -lh {} \;`
- If `SelectionMetalAccelerator` logs that the kernel is missing, first confirm `default.metallib` exists in the app bundle before editing `project.pbxproj`.

## 2026-07-04 Update

### Problem context
- Commit-time build verification was manual and easy to skip during fast iteration, so QuickLook commits could land without rebuilding Spotlight and app targets.

### What changed
- Added the repo-level pre-commit flow using `.githooks/pre-commit` and Makefile targets:
  - `quicklook-commit-build`
  - `install-quicklook-hooks`
- The commit hook runs `make quicklook-commit-build` before allowing `git commit`, and can be bypassed with `SKIP_QUICKLOOK_PRECOMMIT=1`.
- `quicklook-commit-build` executes `make foxtrot.h`, `make libfoxtrot_universal.a`, and Debug `xcodebuild` for `QuickLookStep` with signing disabled.

### Why it helped
- Keeps Swift/Foxtrot/Rust-linked QuickLook app path consistent on every commit without relying on memory.
- Reduces the chance of shipping commits that do not compile for local preview/extension workflows.

### Validation
- Run `make install-quicklook-hooks` once.
- Run `make quicklook-commit-build` manually at least once.
- Confirm commit path logs: `QuickLookStep pre-commit build guard: running make quicklook-commit-build`.
- Use `SKIP_QUICKLOOK_PRECOMMIT=1 git commit ...` for intentional emergency bypasses.
