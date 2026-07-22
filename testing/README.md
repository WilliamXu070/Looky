# QuickLookStep Testing

The test harness drives the real macOS application, records camera and
selection telemetry, and writes generated output under `testing/results`.

## Test Plans

Plans contain scenarios with a model path and ordered actions:

```json
{
  "scenarios": [
    {
      "name": "cube-hole-edge",
      "file": "testing/input/cube_hole.step",
      "actions": [
        { "kind": "rotateY", "value": 25, "durationMs": 120 },
        {
          "kind": "selectAt",
          "x": 0.42,
          "y": 0.61,
          "coordinateSpace": "normalizedViewport",
          "expect": { "kind": "edge" }
        }
      ]
    }
  ]
}
```

Supported actions:

- `rotateX`, `rotateY`, `rotateZ`: degrees in `value`.
- `zoom`: field-of-view delta in `value`.
- `wait`: delay from `durationMs`.
- `selectSurface`: legacy surface-overlay smoke action.
- `selectAt`: real click resolution using normalized or viewport coordinates.

`selectAt` accepts `modifiers: ["shift"]` to add an edge or
`modifiers: ["command"]` to toggle an edge. Surface selection replaces the
current selection. A blank unmodified click clears it.

Selection expectations support `kind`, exact/min/max surface triangle counts,
forbidden labels, and rejected-alternative requirements. Measurement
expectations support kind, entity count, length/distance/area/perimeter ranges,
and unit mode.

## Commands

Run any plan:

```sh
testing/scripts/run-testing.sh \
  testing/plans/selection-debug-cube-hole.json \
  /tmp/selection-debug-cube-hole.json
```

Run one model through a temporary plan:

```sh
testing/scripts/run-sample.sh \
  testing/input/cube_hole.step \
  /tmp/cube-hole-sample.json
```

Run focused regression layers:

```sh
swift test --package-path Packages/QuickLookCore
testing/surface-selection/scripts/run_surface_layer_test.sh
swift testing/selection-engine/scripts/replay_selection_engine.swift \
  testing/selection-engine/reports/latest.json
testing/edge-shape-detection/scripts/run_shape_detection_loop.sh
testing/surface-selection/scripts/run_visible_surface_overlay_test.sh
```

Measurement plans:

```sh
QLS_FORCE_DIRECT_LAUNCH=1 QLS_SELECTION_DEBUG=1 \
  testing/scripts/run-testing.sh \
  testing/plans/measurement-single-edge-no-overmerge-cube-hole.json \
  /tmp/measurement-single-edge.json

QLS_FORCE_DIRECT_LAUNCH=1 QLS_SELECTION_DEBUG=1 \
  testing/scripts/run-testing.sh \
  testing/plans/measurement-multi-edge-details-cube-hole.json \
  /tmp/measurement-multi-edge.json
```

## Debug Sessions and Replay

Live debug mode writes one event per click plus an ordered session manifest:

```sh
QLS_SELECTION_DEBUG=1 \
QLS_SELECTION_DEBUG_OUTPUT=/tmp/quicklook-selection-debug \
testing/scripts/run-testing.sh \
  testing/plans/selection-debug-cube-hole.json \
  /tmp/selection-debug-run.json
```

Replay a captured session:

```sh
swift testing/selection-debug/replay_selection_session.swift \
  /tmp/quicklook-selection-debug/selection-debug-session.json \
  /tmp/selection-debug-replay.json
```

Promote one captured event into a regression plan:

```sh
python3 testing/selection-debug/promote_debug_event.py \
  /tmp/quicklook-selection-debug/<event-id>.json \
  /tmp/promoted-selection-plan.json
```

Generated reports, logs, and screenshots are ignored. Keep reusable input
models under `testing/input` and curated plans under `testing/plans`.
