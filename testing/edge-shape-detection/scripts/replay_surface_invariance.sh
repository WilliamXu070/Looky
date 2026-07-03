#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
top_source="${1:-/tmp/quicklook-edge-download/edge-download-2026-06-05T15-26-14Z.json}"
side_source="${2:-/tmp/quicklook-edge-download/edge-download-2026-06-05T15-26-15Z.json}"
report_dir="${3:-$repo_root/testing/edge-shape-detection/reports}"

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
