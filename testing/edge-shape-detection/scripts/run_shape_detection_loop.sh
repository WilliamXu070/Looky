#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LAB="$ROOT/testing/edge-shape-detection"
EXPECTATIONS="${1:-$LAB/expectations/expected-shapes.json}"
REPORT="$LAB/reports/latest.json"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
HISTORY="$LAB/reports/history/shape-detection-$STAMP.json"
TICKET="$LAB/tickets/001-current-shape-detector-fragments-semicircle.md"

mkdir -p "$LAB/reports/history" "$LAB/tickets"
cd "$ROOT"

set +e
swift "$LAB/scripts/replay_shape_detection.swift" \
  --expectations "$EXPECTATIONS" \
  --report "$REPORT"
STATUS=$?
set -e

cp "$REPORT" "$HISTORY"

if [[ "$STATUS" -ne 0 ]]; then
  {
    printf '# Shape detection failure - %s\n\n' "$STAMP"
    printf '## Symptom\n\n'
    printf 'Saved edge polygon did not match its expected shape classification.\n\n'
    printf '## Expected behavior\n\n'
    printf 'Long edges should classify as `line`; curved regions should classify as one `semicircle`, not fragmented arc segments.\n\n'
    printf '## Scope Boundary\n\n'
    printf 'Do not change click detection, snapping, connected-edge detection, UI behavior, or the edge JSON producer. Diagnose and patch only the shape-detection layer that consumes existing `chainPoints`.\n\n'
    printf '## Evidence\n\n'
    printf '%s\n' "- Latest report: \`$REPORT\`"
    printf '%s\n\n' "- Archived report: \`$HISTORY\`"
    printf '## Required Diagnose Workflow\n\n'
    printf 'Use the `diagnose-fix` skill before changing shape detection. Identify whether this is unordered input interpretation, bad seed interpretation, bad circle fit, over-merge, under-merge, or bad expectation data.\n\n'
    printf '## Status\n\n'
    printf 'Open\n'
  } > "$TICKET"
fi

exit "$STATUS"
