## Symptom

Clicking in the viewer often selects/highlights an edge in a completely different location. Some clicks also buffer for a long time before the UI responds.

## Expected behavior

A click should only select an edge close to the clicked surface point. In connected mode, the app may recover the connected edge/component after the local edge is chosen, but it should not search the whole model and jump to a far component. Blank/flat clicks away from any edge should do nothing quickly.

## Diagnosis

Confirmed in `QuickLookStep/QuickLookStep/SceneKitView.swift`:

- `nearestEdgeCandidates(for:in:)` starts from the hit triangle but traverses every neighbor without a locality cutoff, effectively scanning the whole mesh for every click.
- It calls `mesh.edgeChain(from:)` twice per visited edge while collecting candidates, so one click can repeatedly run line/arc/spline fitting across many edges.
- `resolveBestDownloadSelection(...)` then prefers downloadable candidates with more points/longer length rather than the closest candidate to the click.
- Connected mode falls back to `mesh.nearestFeatureEdge(to:)` globally with no max distance. If the click is not close enough to a real feature edge, it can still snap to a far feature/component.
- The current drawing change reduced the visible highlight size after selection, but it did not fix the upstream edge targeting or the heavy candidate scan.

## Plan

1. Keep hit testing and connected edge extraction intact, but constrain candidate discovery to a local triangle neighborhood around the clicked triangle.
2. Add a hard snap-distance threshold. If no nearby edge is within threshold, return no selection instead of picking a far component.
3. Stop ranking by longest/most-points. Rank by closest snap distance, preferring feature edges only within the local candidate set.
4. Compute connected component/chain only for the selected local candidate rather than repeatedly for all candidates across relaxation passes.
5. In connected mode, only use `nearestFeatureEdge` if it is within the same local threshold; otherwise reject the click.
6. Add timing/log evidence for candidate count and selection duration.
7. Build and run the exact command with `--selection-mode=connected --edge-probe ... --sample ...`; verify clicks no longer produce far `snapDistance` values and no crash occurs.

## Verification

Pending implementation.

## Status

Open.
