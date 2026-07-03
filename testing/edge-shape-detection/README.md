# Edge Shape Detection Lab

This folder tests the shape-detection layer that consumes the existing edge JSON output from QuickLookStep.

## Boundary

Allowed:
- read `chainPoints`, `snappedWorldPoint`, `selectedEdge`, and log context from existing edge-download artifacts
- classify the detected edge shape as `line`, `semicircle`, `arc`, `circle`, `fragmented`, or `unknown`
- reorder or interpret `chainPoints` inside the shape-detection layer
- write reports and diagnosis tickets

Not allowed:
- changing click hit testing
- changing nearest-edge detection
- changing connected-edge extraction
- changing UI click behavior
- changing the current edge JSON producer just to make the shape detector easier

## Run

```bash
testing/edge-shape-detection/scripts/run_shape_detection_loop.sh
```

Or with a custom expectation file:

```bash
testing/edge-shape-detection/scripts/run_shape_detection_loop.sh \
  testing/edge-shape-detection/expectations/expected-shapes.json
```

## Outputs

- latest report: `testing/edge-shape-detection/reports/latest.json`
- latest sequence report: `testing/edge-shape-detection/reports/latest-sequence.json`
- archived reports: `testing/edge-shape-detection/reports/history/`
- failure ticket: `testing/edge-shape-detection/tickets/001-current-shape-detector-fragments-semicircle.md`

GUI clicks now also write shape information into each edge download JSON:

- `shapeDetection.rawOrderShape`
- `shapeDetection.detectedShape`
- `shapeDetection.sequence`
- `shapeDetection.segments`

## Current Seed Case

The first seed case uses:

`/tmp/quicklook-edge-download/edge-download-2026-06-05T13-21-40Z.json`

Expected:
- raw saved order should be `fragmented`
- primitive sequence should be `line -> semicircle -> line -> semicircle`

This proves the upstream edge detector can stay unchanged while the shape detector learns to recover the intended primitive sequence from the existing polygon output.

Run the primitive sequence replay directly:

```bash
swift testing/edge-shape-detection/scripts/replay_shape_sequence.swift \
  /tmp/quicklook-edge-download/edge-download-2026-06-05T13-21-40Z.json \
  testing/edge-shape-detection/reports/latest-sequence.json
```
