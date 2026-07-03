#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
plan="${1:-$repo_root/testing/plans/surface-selection-visible.json}"
output="${2:-$repo_root/testing/surface-selection/reports/visible-surface-overlay.json}"
pixel_report="${3:-$repo_root/testing/surface-selection/reports/visible-surface-orange-pixels.json}"

if [[ ! -f "$plan" ]]; then
  echo "visible surface plan not found: $plan" >&2
  exit 1
fi

python3 - "$plan" "$repo_root" <<'PY'
import json
import os
import sys

plan_path, repo_root = sys.argv[1:3]
with open(plan_path) as f:
    plan = json.load(f)

plan_dir = os.path.dirname(os.path.abspath(plan_path))
missing = []
for scenario in plan.get("scenarios", []):
    raw = scenario.get("file")
    if not raw:
        missing.append(f"{scenario.get('name', '<unnamed>')}: missing file field")
        continue
    candidates = [raw] if os.path.isabs(raw) else [
        os.path.normpath(os.path.join(plan_dir, raw)),
        os.path.normpath(os.path.join(repo_root, raw)),
    ]
    if not any(os.path.isfile(candidate) for candidate in candidates):
        missing.append(f"{scenario.get('name', '<unnamed>')}: {raw}")

if missing:
    print("visible surface plan references missing file(s):", file=sys.stderr)
    for item in missing:
        print(f"  - {item}", file=sys.stderr)
    print("Use a repo-local fixture such as ../input/cube_hole.step from testing/plans/.", file=sys.stderr)
    sys.exit(1)
PY

cd "$repo_root"

if ! testing/scripts/run-testing.sh "$plan" "$output"; then
  cat >&2 <<EOF
visible surface overlay test did not complete.

This smoke requires a built QuickLookStep app and an active macOS GUI session.
Build first if needed:
  xcodebuild -project QuickLookStep/QuickLookStep.xcodeproj -scheme QuickLookStep -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build

If LaunchServices/open does not deliver the test plan, retry with:
  QLS_FORCE_DIRECT_LAUNCH=1 $0 "$plan" "$output" "$pixel_report"
EOF
  exit 1
fi

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
