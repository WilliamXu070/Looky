#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLAN="${1:-$ROOT/testing/plans/orientation-zoom.json}"
OUTPUT="${2:-$ROOT/testing/results/quicklookstep-test-$(date +%Y%m%d-%H%M%S).json}"

APP_CANDIDATES=(
  "$ROOT/build/Build/Products/Debug/QuickLookStep.app/Contents/MacOS/QuickLookStep"
  "$ROOT/build/Build/Products/Release/QuickLookStep.app/Contents/MacOS/QuickLookStep"
  "/private/tmp/quicklook-dd/Build/Products/Release/QuickLookStep.app/Contents/MacOS/QuickLookStep"
  "/private/tmp/quicklook-dd/Build/Products/Debug/QuickLookStep.app/Contents/MacOS/QuickLookStep"
)

APP=""
APP_BUNDLE=""
for candidate in "${APP_CANDIDATES[@]}"; do
  if [[ -x "$candidate" ]]; then
    APP="$candidate"
    APP_BUNDLE="$(dirname "$(dirname "$(dirname "$candidate")")")"
    break
  fi
done

if [[ -z "$APP" ]]; then
  echo "QuickLookStep binary not found: $APP"
  echo "Build first with:"
  echo "  xcodebuild -project QuickLookStep/QuickLookStep.xcodeproj -scheme QuickLookStep -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=\"\" build"
  exit 1
fi

if [[ ! -f "$PLAN" ]]; then
  echo "Test plan not found: $PLAN"
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"

export QLS_TEST_PLAN="$PLAN"
export QLS_TEST_OUTPUT="$OUTPUT"
export QLS_TEST_AUTO_QUIT="1"
export QLS_TEST_FILE=""
export QLS_BACKGROUND_TEST="1"

APP_ARGS=(
  "--test-plan"
  "$PLAN"
  "--test-output"
  "$OUTPUT"
  "--auto-quit"
  "--background-test"
)

APP_PID=""
cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    for _ in {1..20}; do
      kill -0 "$APP_PID" 2>/dev/null || break
      sleep 0.05
    done
    kill -9 "$APP_PID" 2>/dev/null || true
  fi
  if [[ -n "$APP_PID" ]]; then
    wait "$APP_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

wait_for_output() {
  local target="$1"
  local max_wait=120
  local elapsed=0

  while (( elapsed < max_wait )); do
    if [[ -f "$target" ]]; then
      return 0
    fi
    if [[ -n "${APP_PID:-}" ]] && ! kill -0 "$APP_PID" 2>/dev/null; then
      echo "QuickLookStep exited before writing output: $target"
      tail -80 /tmp/quicklookstep-open.log 2>/dev/null || true
      return 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  echo "Timed out waiting for output: $target"
  echo "Recent launch log: /tmp/quicklookstep-open.log"
  return 1
}

launch() {
  : > /tmp/quicklookstep-open.log
  "$APP" "${APP_ARGS[@]}" >/tmp/quicklookstep-open.log 2>&1 &
  APP_PID=$!
}

if ! launch; then
  echo "Unable to start QuickLookStep test run."
  if [[ -s /tmp/quicklookstep-open.log ]]; then
    cat /tmp/quicklookstep-open.log
  fi
  exit 1
fi

wait_for_output "$OUTPUT"

python3 - "$OUTPUT" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path) as f:
    data = json.load(f)

failures = []
for report in data.get("reports", []):
    scenario = report.get("scenario", "<unknown>")
    for event in report.get("events", []):
        event_failures = event.get("selectionDebugExpectationFailures") or []
        if event_failures:
            failures.append(
                (
                    scenario,
                    event.get("actionIndex"),
                    event.get("action"),
                    event_failures,
                    (event.get("selectionDebugSummary") or {}).get("eventPath"),
                )
            )
        measurement_failures = event.get("measurementExpectationFailures") or []
        if measurement_failures:
            failures.append(
                (
                    scenario,
                    event.get("actionIndex"),
                    event.get("action"),
                    measurement_failures,
                    None,
                )
            )
        hover_failures = event.get("hoverExpectationFailures") or []
        if hover_failures:
            failures.append(
                (
                    scenario,
                    event.get("actionIndex"),
                    event.get("action"),
                    hover_failures,
                    None,
                )
            )

if failures:
    print("Testing expectation failure(s):", file=sys.stderr)
    for scenario, index, action, event_failures, event_path in failures:
        print(f"  - {scenario} action {index} {action}: {'; '.join(event_failures)}", file=sys.stderr)
        if event_path:
            print(f"    event: {event_path}", file=sys.stderr)
    sys.exit(1)
PY

echo "Wrote test results to: $OUTPUT"
