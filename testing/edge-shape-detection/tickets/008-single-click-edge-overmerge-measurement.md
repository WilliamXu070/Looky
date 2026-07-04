## Symptom

Single-clicking one edge can highlight and measure a combined chain of adjacent feature edges. The measurement panel shows one "Single" selection with a long polyline label such as `line-segment -> line-segment`, length around `300 u`, and multiple points.

## Expected behavior

A normal single click should select and measure only the exact edge under the click. Multi-edge measurement should require explicit Shift/Cmd accumulation.

## Diagnosis

`EdgeSelectionCandidate` correctly carries a narrow `edgeSnap.selectedEdge`, but the user-facing measurement/highlight path reads `resolved.chainWorldPoints`. In fitted mode, `chainWorldPoints` may be an inferred feature chain, so one selected edge becomes a combined polyline in the panel and overlay.

## Plan

- Keep resolver/download/debug chain data intact.
- For normal fitted edge measurement/highlight, derive display points from `edgeSnap.selectedEdge` endpoints.
- Keep connected mode's explicit connected-chain behavior available behind `--selection-mode=connected`.
- Add a regression plan that asserts a one-click edge measurement length stays near a single edge length.

## Verification

- Build QuickLookStep.
- Run focused one-click measurement golden.
- Run multi-edge measurement detail golden.

## Status

Fixed.

Evidence:
- `xcodebuild -project QuickLookStep/QuickLookStep.xcodeproj -scheme QuickLookStep -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build`
- `QLS_FORCE_DIRECT_LAUNCH=1 QLS_SELECTION_DEBUG=1 testing/scripts/run-testing.sh testing/plans/measurement-single-edge-no-overmerge-cube-hole.json testing/results/measurement-single-edge-no-overmerge-cube-hole.json`
- `QLS_FORCE_DIRECT_LAUNCH=1 QLS_SELECTION_DEBUG=1 testing/scripts/run-testing.sh testing/plans/measurement-multi-edge-details-cube-hole.json testing/results/measurement-multi-edge-details-cube-hole.json`
