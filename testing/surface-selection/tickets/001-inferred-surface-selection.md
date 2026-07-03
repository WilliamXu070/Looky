## Symptom

Surface selection highlighted only a small rectangular triangle patch on the STEP sample instead of the whole CAD-like face.

## Expected behavior

Clicking or test-selecting a surface should recover the whole mesh surface represented by the clicked polygon region, including fragmented planar faces and smooth curved surfaces such as cylindrical or conical patches.

## Diagnosis

The previous surface path used connected triangle traversal only. That is too local for CAD-style face selection because a face can be split into multiple coplanar mesh islands, and curved surfaces need smooth patch growth rather than planar-only grouping.

## Plan

- Add inferred surface selection on `MeshTopology`.
- Use smooth patch growth bounded by sharp feature edges for curved surfaces.
- Expand planar smooth patches to all same-plane triangles to handle fragmented CAD tessellation.
- Preserve the edge-selection path and existing shape-detection tests.
- Add offline fixtures for fragmented planar, cylinder, and cone surfaces.
- Verify with the actual STEP screenshot orange overlay test.

## Verification

- `testing/surface-selection/scripts/run_surface_layer_test.sh`
- `testing/surface-selection/scripts/run_visible_surface_overlay_test.sh`
- `testing/scripts/verify_quicklook_ui_launch.sh`
- `testing/edge-shape-detection/scripts/run_shape_detection_loop.sh`
- `testing/edge-shape-detection/scripts/replay_surface_invariance.sh`

## Status

Implemented and verified.
