#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
plan="$repo_root/testing/plans/surface-selection-visible.json"
output="$repo_root/testing/surface-selection/reports/visible-surface-overlay.json"
pixel_report="$repo_root/testing/surface-selection/reports/visible-surface-orange-pixels.json"

cd "$repo_root"

testing/scripts/run-testing.sh "$plan" "$output"

snapshot="$(python3 - "$output" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for report in data.get("reports", []):
    for event in report.get("events", []):
        if event.get("action") == "selectSurface" and event.get("snapshotPath"):
            print(event["snapshotPath"])
            raise SystemExit(0)
raise SystemExit("selectSurface snapshot not found")
PY
)"

if [[ ! -f "$snapshot" ]]; then
  echo "selectSurface snapshot missing: $snapshot" >&2
  exit 1
fi

swift testing/surface-selection/scripts/check_orange_pixels.swift "$snapshot" 0.008 "$pixel_report"
echo "visible surface screenshot: $snapshot"
echo "orange pixel report: $pixel_report"
