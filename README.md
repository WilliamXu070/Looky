# QuickLookStep

QuickLookStep is a macOS 14.6+ model viewer, Finder Quick Look preview, and
thumbnail extension built with Swift, SwiftUI, SceneKit, Metal, and
[Foxtrot](https://github.com/Formlabs/foxtrot).

The application now includes finite edge and surface selection, measurement,
selection diagnostics, and replayable click tests. Rendering uses SceneKit on
Metal. Selection uses a CPU BVH by default; the optional Metal distance backend
can be enabled for benchmark comparison.

## Format Support

| Format | Primary importer | Fallback | Notes |
| --- | --- | --- | --- |
| STEP, STP | Foxtrot | None | Geometry only; source units are currently unknown because the FFI does not expose them. |
| GLB, glTF | GLTFKit2 | Model I/O, then SceneKit | GLTFKit2 is the material-preserving path. External glTF resources must be resolvable from the asset URL. |
| OBJ | SceneKit | Model I/O | Materials depend on referenced MTL and texture files. |
| STL | SceneKit | Model I/O | Mesh geometry only. |
| 3MF | Native package parser | SceneKit, then Model I/O | Object/component metadata is retained where available. |
| SLDPRT, SLDASM | Sidecar resolver | None | Native SolidWorks B-rep import is not available. A same-named STEP/STL/OBJ/3MF/GLB sidecar is required. |

Production import does not invoke Python, trimesh, FreeCAD, or AssetImportKit.

## Architecture

```text
ModelImportPipeline
  -> format-specific ModelImporter
  -> ImportedScene + diagnostics + source transform
  -> SceneComposer
  -> SceneKitMeshAdapter / MeshSnapshot
  -> shared selection and measurement state
```

- `QuickLookStep/Shared/Import` owns format routing and loading.
- `Packages/QuickLookCore` owns canonical geometry, BVH queries, typed selection
  results, deterministic primitive fitting, and measurement math.
- `SceneKitViewport` forwards native camera/input events.
- `SelectionController` performs click transactions.
- `SceneSelectionEngine` owns one canonical snapshot and derives the finite-edge
  fitting index from that topology.
- `SelectionOverlayRenderer` draws separate overlay nodes and never replaces
  source model geometry.
- `ViewerSession` owns loaded scene, diagnostics, measurement, and debug UI state.
- `SelectionDebugRecorder` writes session JSON and screenshots off the resolver path.

Source-to-scene normalization is recorded on each scene. Measurements invert
that transform so model-unit values do not change when display normalization
changes.

## Build

```sh
make foxtrot.h
make libfoxtrot_universal.a
xcodebuild \
  -project QuickLookStep/QuickLookStep.xcodeproj \
  -scheme QuickLookStep \
  -configuration Debug \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build
```

Install the commit build guard once per workspace:

```sh
make install-quicklook-hooks
```

## Run

```sh
open build/Build/Products/Debug/QuickLookStep.app --args \
  --sample "$PWD/testing/input/cube_hole.step"
```

Selection diagnostics:

```sh
open build/Build/Products/Debug/QuickLookStep.app --args \
  --sample "$PWD/testing/input/cube_hole.step" \
  --selection-debug \
  --selection-debug-hud=1 \
  --selection-debug-output /tmp/quicklook-selection-debug
```

Use `QLS_ENABLE_SELECTION_METAL=1` to benchmark the Metal distance backend, or
`QLS_DISABLE_SELECTION_METAL=1` to force CPU BVH behavior.

## Test

```sh
swift test --package-path Packages/QuickLookCore
testing/surface-selection/scripts/run_surface_layer_test.sh
swift testing/selection-engine/scripts/replay_selection_engine.swift \
  testing/selection-engine/reports/latest.json
testing/edge-shape-detection/scripts/run_shape_detection_loop.sh
testing/surface-selection/scripts/run_visible_surface_overlay_test.sh
```

See [testing/README.md](testing/README.md) for automated viewport actions,
measurement expectations, debug sessions, and replay promotion.

## Quick Look Registration

After replacing the app in `/Applications`, refresh the extensions if Finder
still uses an older build:

```sh
pluginkit -r -u com.johnboiles.QuickLookStep.StepThumbnail
pluginkit -r -u com.johnboiles.QuickLookStep.StepPreview
pluginkit -r -a /Applications/QuickLookStep.app
qlmanage -r
qlmanage -r cache
pluginkit -e use -i com.johnboiles.QuickLookStep.StepThumbnail
pluginkit -e use -i com.johnboiles.QuickLookStep.StepPreview
killall QuickLookUIService
killall Finder
```

QuickLookStep is licensed under the MIT License.
