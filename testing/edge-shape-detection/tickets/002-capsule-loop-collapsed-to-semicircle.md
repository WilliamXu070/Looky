# Capsule Loop Collapsed To Semicircle

## Symptom

The sequence replay for `/tmp/quicklook-edge-download/edge-download-2026-06-05T13-21-40Z.json` returned one `semicircle` segment for all 64 points.

## Expected behavior

Walking around the saved polygon should produce this sequence:

```text
line -> semicircle -> line -> semicircle
```

## Diagnosis

Confirmed facts:

- The saved polygon has 64 points.
- The bounding dimensions are about `45.416 x 9.714`.
- There are top and bottom straight spans with endpoints around `x=2.268` and `x=37.982`, giving straight length about `35.714`.
- The prior whole-shape detector fit one broad circle and reported `semicircle`, which hides the two straight spans.

Root cause:

The first shape detector only asked for one global shape. It did not detect repeated local primitives around a closed capsule-like loop.

## Scope Boundary

Patch only the offline shape-detection layer. Do not change hit testing, snapping, connected-edge detection, UI behavior, or edge JSON production.

## Plan

1. Keep the saved polygon input unchanged.
2. Add capsule-loop sequence detection in `replay_shape_sequence.swift`.
3. Use PCA/local 2D coordinates so rotated models still work.
4. Split the loop into top line, one end cap, bottom line, and the other end cap.
5. Verify `detectedSequence == ["line", "semicircle", "line", "semicircle"]`.

## Verification

Run:

```bash
swift testing/edge-shape-detection/scripts/replay_shape_sequence.swift \
  /tmp/quicklook-edge-download/edge-download-2026-06-05T13-21-40Z.json \
  testing/edge-shape-detection/reports/latest-sequence.json
```

## Status

Resolved for the saved seed artifact. The sequence replay now returns:

```text
line -> semicircle -> line -> semicircle
```

Evidence:

- `testing/edge-shape-detection/reports/latest-sequence.json`
- line spans are about `36.697`
- semicircle radii are about `4.857`
- semicircle coverage is about `179.853` degrees each
