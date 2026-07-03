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

APP_ARGS=(
  "--test-plan"
  "$PLAN"
  "--test-output"
  "$OUTPUT"
  "--auto-quit"
)

wait_for_output() {
  local target="$1"
  local max_wait=120
  local elapsed=0

  while (( elapsed < max_wait )); do
    if [[ -f "$target" ]]; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  echo "Timed out waiting for output: $target"
  echo "Recent launch log: /tmp/quicklookstep-open.log"
  return 1
}

launch() {
  OPEN_LAUNCHED_WITH_OPEN=0

  if [[ "${QLS_FORCE_DIRECT_LAUNCH:-0}" == "1" ]]; then
    OPEN_LAUNCHED_WITH_OPEN=0
    "$APP" "${APP_ARGS[@]}"
    return
  fi

  if [[ -d "${APP_BUNDLE}" && -n "${APP_BUNDLE}" && -x /usr/bin/open ]]; then
    OPEN_LAUNCHED_WITH_OPEN=1
    if ! open -n "$APP_BUNDLE" --args "${APP_ARGS[@]}" >/tmp/quicklookstep-open.log 2>&1; then
      echo "open failed. This often means no active GUI session is available."
      if grep -q "NoExecutable" /tmp/quicklookstep-open.log; then
        echo "LaunchServices reports the app bundle executable is missing."
        echo "Current bundle: $APP_BUNDLE"
      fi
      if [[ "${QLS_FORCE_DIRECT_LAUNCH:-0}" == "1" ]]; then
        echo "Attempting direct launch because QLS_FORCE_DIRECT_LAUNCH=1"
        "$APP" "${APP_ARGS[@]}"
      else
        echo "Set QLS_FORCE_DIRECT_LAUNCH=1 to force direct binary launch."
        return 1
      fi
    fi
    return
  fi

  "$APP" "${APP_ARGS[@]}"
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

if failures:
    print("Selection debug expectation failure(s):", file=sys.stderr)
    for scenario, index, action, event_failures, event_path in failures:
        print(f"  - {scenario} action {index} {action}: {'; '.join(event_failures)}", file=sys.stderr)
        if event_path:
            print(f"    event: {event_path}", file=sys.stderr)
    sys.exit(1)
PY

echo "Wrote test results to: $OUTPUT"
