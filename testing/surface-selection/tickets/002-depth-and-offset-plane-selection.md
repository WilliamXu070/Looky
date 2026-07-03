## Symptom

Surface selection has two visible regressions on the thor STEP sample:

- The orange selected-surface overlay renders through occluding model geometry while rotating.
- Selecting a top planar face can include a nearby lower or recessed parallel plane.

## Expected Behavior

- Selected surfaces should be hidden by geometry in front of them.
- Planar surface expansion should include true same-plane face islands, but not nearby offset planes.

## Diagnosis

- `surfaceSelectionMaterial()` disabled depth reads in the duplicate-overlay path, so the orange overlay was always composited on top of the model.
- Enabling depth reads on the duplicate overlay made the selected surface disappear in SceneKit, because depth-tested duplicate coplanar geometry is not reliable for this use case.
- The planar expansion tolerance uses a loose `0.03` floor, which can group lower parallel triangles into the seed surface.

## Plan

- Replace the duplicate selected-surface overlay with a real mesh tint: rebuild the selected node geometry into base and selected material elements, then restore the original geometry on the next selection clear.
- Seed automated visible-surface tests from the frontmost camera ray hit so screenshots validate a visible surface instead of a hidden back face.
- Tighten the shared planar tolerance used by `isPlanarSurface` and `coplanarSurfaceTriangles`.
- Add an offline regression fixture where a nearby offset plane must not be selected with the top plane.
- Rebuild and run surface layer, visible orange overlay, UI launch, and edge regression tests.

## Verification

- `xcodebuild -project QuickLookStep/QuickLookStep.xcodeproj -scheme QuickLookStep -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build` passed.
- `testing/surface-selection/scripts/run_surface_layer_test.sh` passed, including `nearby-offset-plane-does-not-join-top-surface`.
- `testing/surface-selection/scripts/run_visible_surface_overlay_test.sh` passed with `orangeRatio=0.05558`.
- Visual screenshot shows the visible top face tinted orange while holes/slots remain untinted/visible.
- `testing/edge-shape-detection/scripts/run_shape_detection_loop.sh` passed.
- `testing/edge-shape-detection/scripts/replay_surface_invariance.sh` passed.
- `testing/scripts/verify_quicklook_ui_launch.sh` passed with top window `QuickLookStep 1200x832`.

## Status

Fixed and verified.
