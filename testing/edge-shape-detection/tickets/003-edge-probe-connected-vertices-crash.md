# Edge Probe Connected Vertices Crash

## Symptom

Launching with `--edge-probe` loads the STEP file, handles a click/selection, saves an edge JSON, then crashes with:

```text
Swift/ContiguousArrayBuffer.swift:692: Fatal error: Index out of range
```

## Expected behavior

The app should stay open after a click and should write both the edge download JSON and the edge probe JSON.

## Reproduction

```bash
/Users/williamxu/Desktop/Projects/quicklook/build/Build/Products/Debug/QuickLookStep.app/Contents/MacOS/QuickLookStep \
  --selection-mode=connected \
  --edge-probe \
  --edge-probe-output /tmp/quicklook-edge-probe \
  --sample "/Users/williamxu/Downloads/thor luminos adaptor.step"
```

## Diagnosis

The crash is in the probe-only path. `MeshTopology.connectedFeatureVertices(componentEdges:)` declared a local variable named `vertices`, shadowing the mesh's `vertices` property. The function then attempted `vertices[edgeKey.a]` on the empty local array.

This happens after selection and shape detection have already succeeded.

## Fix

Rename the local output array to `outputVertices` so indexing reads from the mesh `vertices` property.

## Verification

Rebuild with signing disabled, launch the same command, perform a click, and verify:

- app remains alive
- newest edge JSON includes `shapeDetection`
- `/tmp/quicklook-edge-probe/*.json` is written

## Status

Fixed in code, pending rerun verification.
