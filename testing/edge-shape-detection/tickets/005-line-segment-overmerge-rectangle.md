## Symptom

When clicking a straight perimeter edge, the UI highlights the whole rectangular connected component instead of only the selected line segment.

## Fresh Repro Artifacts

Downloads:

- `/tmp/quicklook-edge-download/edge-download-2026-06-05T14-41-39Z.json`
- `/tmp/quicklook-edge-download/edge-download-2026-06-05T14-41-44Z.json`

Probes:

- `/tmp/quicklook-edge-probe/_Users_williamxu_Downloads_thor_luminos_adaptor.step-edge-probe-2026-06-05T14-41-39Z.json`
- `/tmp/quicklook-edge-probe/_Users_williamxu_Downloads_thor_luminos_adaptor.step-edge-probe-2026-06-05T14-41-44Z.json`

The second click is the target failure:

- selected edge: `[1064, 1065]`
- connected feature segments: `[1064,1067]`, `[1066,1067]`, `[1065,1066]`, `[1064,1065]`
- connected feature vertices form a 4-corner rectangle on one plane
- `chainPoints.count = 4`
- `snapDistance = 0.0015969202`
- `shapeDetection.detectedShape = semicircle`
- expected visible highlight: only selected line segment `[1064, 1065]`, not the whole rectangle

## Diagnosis

The click/nearest-edge layer is local and correct for the second artifact: it selected edge `[1064,1065]` with a very small snap distance.

The failure is in the post-selection shape/overlay layer:

- a 4-point connected rectangle is not a capsule
- `capsulePrimitiveGroups(...)` rejects it because it has fewer than 12 points
- fallback circle fitting can classify four rectangle corner points as a broad `semicircle`
- `selectedPrimitivePoints(...)` returns nil
- connected-mode overlay falls back to `makeConnectedComponentNode(...)`, drawing all four rectangle edges

## Plan

1. Keep upstream hit testing and connected extraction unchanged.
2. Add a selected-edge-first primitive path for connected-mode overlay:
   - if the recovered component is a polygon made of straight feature segments
   - and the selected edge is one of those component segments
   - draw only the selected segment, or its collinear continuation only when it does not pass through a corner
3. Make shape detection reject `semicircle` classification for tiny polygon corner sets:
   - 4-point rectangle loops should classify as `line-segments` or `polygon`
   - circle fitting should require enough arc samples before reporting `arc` or `semicircle`
4. Add a local replay script or extend the shape replay to read the second artifact and assert:
   - selected primitive is one line segment
   - sequence is not `semicircle`
   - rectangle/perimeter connected components do not draw as one merged line group
5. Build after edits.
6. Re-run the exact connected/probe sample workflow and click the same rectangle edge.
7. Verify:
   - latest JSON still has small `snapDistance`
   - shape detection no longer says `semicircle` for the rectangle artifact
   - overlay highlight draws only one selected line segment
   - no crash or long buffering

## Verification

Implemented:

- connected overlay now draws only the selected mesh edge when shape detection reports line-segment primitives
- shape fallback no longer classifies under-sampled polygon/rectangle components as arcs or semicircles
- bad circle fits with high residual become explicit `line-segment` primitives
- added `testing/edge-shape-detection/scripts/replay_line_segment_selection.swift`

Captured artifact checks:

- `/tmp/quicklook-edge-download/edge-download-2026-06-05T14-41-44Z.json` passed with 4 `line-segment` primitives and selected primitive point count 2
- `/tmp/quicklook-edge-download/edge-download-2026-06-05T14-41-39Z.json` passed with 8 `line-segment` primitives and selected primitive point count 2

Live post-fix check:

- `/tmp/quicklook-edge-download/edge-download-2026-06-05T15-26-16Z.json`
- `selectedEdge: [1066, 1067]`
- `snapDistance: 0.0013472103`
- `shapeDetection.sequence: line-segment -> line-segment -> line-segment -> line-segment`
- replay report passed with selected primitive point count 2

Regression check after concern that circle logic broke:

- rectangle/perimeter line-segment replay still passed:
  - `/tmp/quicklook-edge-download/edge-download-2026-06-05T15-26-16Z.json`
  - sequence: `line-segment -> line-segment -> line-segment -> line-segment`
  - selected primitive point count: 2
- rounded-slot capsule replay still passed:
  - `/tmp/quicklook-edge-download/edge-download-2026-06-05T15-28-24Z.json`
  - sequence: `line -> semicircle -> line -> semicircle`
  - semicircle coverage: about 179.85 degrees
- circular hole captures still reported `circle`:
  - `/tmp/quicklook-edge-download/edge-download-2026-06-05T15-28-09Z.json`
  - `/tmp/quicklook-edge-download/edge-download-2026-06-05T15-28-11Z.json`
  - `/tmp/quicklook-edge-download/edge-download-2026-06-05T15-28-16Z.json`

## Status

Verified.
