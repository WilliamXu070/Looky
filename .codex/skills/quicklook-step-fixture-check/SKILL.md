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

## 2026-07-03 Update

### Problem context
- GLB/glTF files can appear to load but render poorly when `SCNScene(url:)` fails and `SceneBuilder` falls back to the raw mesh-conversion path, because that path strips UV textures, normal maps, PBR material metadata, skins, and animation state.
- On the current macOS/Xcode runtime, `SCNScene(url:)` rejects both repo `.glb` and `.gltf` fixtures with `NSCocoaErrorDomain Code=259`, while `.obj` loads; the `AssetImportKit` branch is compile-guarded but not wired as a project dependency.
- A native probe on macOS 26.5.1 showed `MDLAsset.canImportFileExtension("glb") == false` and `MDLAsset.canImportFileExtension("gltf") == false`; `xcrun scntool --help` also omits GLB/glTF from supported formats. UTType recognition (`org.khronos.glb` / `org.khronos.gltf`) only proves file-type registration, not SceneKit or Model I/O importer support.

### What changed
- Added a triage note: for poor GLB/glTF rendering, first determine whether the app used `scenekit`, `asset-importkit`, or `mesh-conversion`, then inspect the asset layout for external texture folders such as a sibling `textures/` directory beside a `source/` model folder.
- Added loader metadata keys to watch for: `loadMethod`, `materialQuality`, `degradationReason`, `fallbackReason`, `texturedMaterialCount`, `normalMapMaterialCount`, `pbrMaterialCount`, `textureSlotCount`, and `textureResolutionHint`.
- Added the current root-cause rule: do not assume glTF/GLB registration means material-preserving import; verify `SCNScene(url:)` or an active importer actually accepts the file before debugging texture paths.
- Updated the fallback expectation: the Python/trimesh path should load GLB as a scene when possible, export separate mesh parts, preserve UVs, extract embedded diffuse and normal textures to temporary PNGs, and report `materialQuality=fallback-textured` rather than `degraded`.
- Added the importer-capability rule: before diagnosing a specific GLB asset as malformed, run a standalone Swift probe for `MDLAsset.canImportFileExtension`, `SCNSceneSource`, `SCNScene(url:)`, and a known-good OBJ control. If simple repo GLB/glTF fixtures fail too, treat native Apple GLB/glTF import as unavailable in that runtime.

### Why it helped
- Separates missing-resource/path issues from importer-fallback quality loss and prevents treating a visible mesh as a correct material import.
- Provides a practical material-preserving fallback when SceneKit and Model I/O reject glTF/GLB, while still making clear that skins, animation, and some PBR metadata are stripped.
- Avoids chasing Godzilla-specific material, texture, or skinning features when a minimal GLB with only triangle positions fails the same native import path.

### Validation
- Check app load metadata or logs for `SceneBuilder scene(for:)`, `Direct SceneKit load failed`, and `Loaded ... via mesh-conversion fallback`.
- Check `SceneBuilder import diagnostics` logs; `materialQuality=degraded` with `degradationReason=mesh-conversion-strips-uv-textures-normal-maps-pbr-skins-animation` confirms importer fallback quality loss rather than only a missing texture path.
- After the textured fallback fix, the Godzilla GLB should report `materialQuality=fallback-textured`, `texturedMaterialCount=8`, `normalMapMaterialCount=8`, `pbrMaterialCount=8`, and `textureSlotCount=16`.
- Compare import support quickly with a Swift probe against `testing/input/cube_hole_from_step.glb`, `testing/input/cube_hole_from_step.gltf`, and `testing/input/cube_hole_from_step.obj`; if only OBJ loads, fix the importer path before texture search.
- In the Swift probe, expect current-runtime native support evidence to look like: `mdlCan=false` for `glb`/`gltf`, `SCNScene(url)` fails with `NSCocoaErrorDomain Code=259`, `MDLAsset count 0`, and OBJ succeeds.
- Run `xcrun scntool --help`; if supported formats list only `dae`, `c3d`, `usda`, `usdc`, and `usdz`, do not plan around `scntool` as a GLB/glTF converter.
- Inspect the asset with `strings "<model.glb>" | rg "images|bufferView|uri|png|jpg"`; `bufferView` means embedded images, while `uri` means external texture lookup is required.
- Check texture sizes with `sips -g pixelWidth -g pixelHeight <texture-folder>/*`.

## 2026-07-04 Update

### Problem context
- SolidWorks `.SLDPRT/.SLDASM` files are proprietary CAD containers; the local macOS stack does not expose native B-rep geometry for `Gear.SLDPRT`, and probes showed `MDLAsset.canImportFileExtension("sldprt") == false` plus SceneKit `NSCocoaErrorDomain Code=259`.

### What changed
- Documented the QuickLookStep SolidWorks accommodation path: `SceneBuilder` registers `sldprt/sldasm`, tries Model I/O and SceneKit, then searches for same-name sidecar exports (`step/stp/3mf/glb/gltf/obj/stl`).

### Why it helped
- Lets downloaded SolidWorks snapshots open in the viewer only when they include exported 3D geometry, while avoiding false success from rendering a sibling preview image as a flat plane.

### Validation
- `swift` probe: verify Model I/O reports `false` and SceneKit fails for `/Users/williamxu/Downloads/spur-gear-415.snapshot.1/Gear.SLDPRT`.
- With no sidecar, check app logs for `SolidWorks .SLDPRT requires an exported STEP/STL/OBJ/3MF/GLB sidecar`.
- With a same-name sidecar, check app logs for `loadMethod = "solidworks-sidecar-..."`.

## 2026-07-04 Update

### Problem context
- `Gear.SLDPRT` appeared to open, but it was only the sibling `Gear.JPG` rendered as a flat SceneKit plane, not real SolidWorks geometry.

### What changed
- Removed the `solidworks-preview-image` fallback and deleted the preview image plane loader from `SceneBuilder`; SolidWorks files now require native import or an actual 3D sidecar export.

### Why it helped
- Prevents a 2D preview from masquerading as a loaded CAD model, which would break rotation, selection, measurement, and user trust.

### Validation
- Launch `/Users/williamxu/Downloads/spur-gear-415.snapshot.1/Gear.SLDPRT` without a sidecar and confirm the app reports a sidecar-required conversion failure instead of rendering `Gear.JPG`.
- Add a same-name `Gear.step`, `Gear.stp`, `Gear.3mf`, `Gear.glb`, `Gear.gltf`, `Gear.obj`, or `Gear.stl` beside the `.SLDPRT` and confirm the app reports `solidworks-sidecar`.

## 2026-07-04 Update

### Problem context
- A fake local `.SLDPRT` converter proved the converter plumbing but rendered the cube-hole fixture as `Gear.obj`, creating a misleading success state for `Gear.SLDPRT`.

### What changed
- Documented the guardrail: do not add or configure fake converter outputs for SolidWorks fixtures. For `.SLDPRT/.SLDASM`, either require a real same-name 3D sidecar (`step/stp/3mf/glb/gltf/obj/stl`) or fail honestly.

### Why it helped
- Prevents wasting implementation time on infrastructure that cannot produce real gear geometry and avoids presenting non-gear meshes as successful SolidWorks import.

### Validation
- Open `/Users/williamxu/Downloads/spur-gear-415.snapshot.1/Gear.SLDPRT` without a real sidecar and confirm no cached fake `Gear.obj` appears under `~/Library/Caches/QuickLookStep/SolidWorksConversions`.
- Confirm logs show Model I/O / SceneKit native import failure instead of `solidworks-local-converter`.

## 2026-07-04 Update

### Problem context
- A local `.SLDPRT` to `.STEP` cache test for `/Users/williamxu/Downloads/spur-gear-415.snapshot.1/Gear.SLDPRT` could not run because no real CAD Exchanger `ExchangerConv` binary was installed.

### What changed
- Documented the real conversion gate: do not implement or test `.SLDPRT` conversion unless `ExchangerConv` or an equivalent real SolidWorks-capable converter is present. CAD Assistant / OpenCascade-style open-format tools are not enough for this fixture.

### Why it helped
- Prevents repeating a fake or impossible conversion path and makes the next step explicit: install/configure a real converter, then cache the produced `.step` and render that.

### Validation
- Local harness result: `missing_converter=ExchangerConv`.
- A valid test must first find `CADEX_CONVERTER` or a bundled CAD Exchanger Lab `ExchangerConv`, then produce a non-empty `Gear.step` before launching QuickLookStep.
