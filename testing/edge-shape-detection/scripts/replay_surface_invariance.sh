#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
fixture_source="$repo_root/testing/edge-shape-detection/polygons/saved/thor-connected-edge-semicircle.json"

top_source="${1:-${QLS_SURFACE_INVARIANCE_TOP:-$fixture_source}}"
side_source="${2:-${QLS_SURFACE_INVARIANCE_SIDE:-$fixture_source}}"
report_dir="${3:-$repo_root/testing/edge-shape-detection/reports}"

validate_source() {
  local label="$1"
  local source="$2"

  if [[ -f "$source" ]]; then
    return
  fi

  cat >&2 <<EOF
surface invariance ${label} input not found: $source

Use the checked-in deterministic fixture:
  $0

Or replay fresh top/side probe downloads:
  $0 /path/to/top-edge-download.json /path/to/side-edge-download.json [report-dir]

Fresh downloads are usually written by QuickLookStep with --edge-probe-output, for example:
  /tmp/quicklook-edge-download/edge-download-*.json
EOF
  exit 1
}

validate_source "top" "$top_source"
validate_source "side" "$side_source"

if [[ "$top_source" == "$fixture_source" && "$side_source" == "$fixture_source" ]]; then
  cat >&2 <<EOF
Using checked-in single-fixture surface invariance replay:
  $fixture_source

Pass explicit top and side edge-download JSON files to validate a newly captured live click pair.
EOF
fi

mkdir -p "$report_dir"

top_report="$report_dir/latest-top-surface-capsule.json"
side_report="$report_dir/latest-side-surface-capsule.json"

swift "$repo_root/testing/edge-shape-detection/scripts/replay_shape_sequence.swift" \
  "$top_source" \
  "$top_report"

swift "$repo_root/testing/edge-shape-detection/scripts/replay_shape_sequence.swift" \
  "$side_source" \
  "$side_report"

swift "$repo_root/testing/edge-shape-detection/scripts/check_surface_congruence.swift" \
  "$top_report" \
  "$side_report"

printf 'surface invariance passed\n'
