#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
app_path="${1:-$repo_root/build/Build/Products/Debug/QuickLookStep.app}"
sample_path="${2:-/Users/williamxu/Downloads/thor luminos adaptor.step}"
screenshot_path="${3:-/tmp/quicklook-ui-launch-check.png}"

cleanup() {
  osascript -e 'tell application "QuickLookStep" to quit' >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

if [[ ! -d "$app_path" ]]; then
  echo "Missing app: $app_path" >&2
  exit 2
fi

if [[ ! -f "$sample_path" ]]; then
  echo "Missing sample: $sample_path" >&2
  exit 2
fi

osascript -e 'tell application "QuickLookStep" to quit' >/dev/null 2>&1 || true
for _ in {1..20}; do
  if ! pgrep -x QuickLookStep >/dev/null; then
    break
  fi
  sleep 0.1
done
rm -f /tmp/quicklookstep-lifecycle.log "$screenshot_path"

open -n -a "$app_path" --args \
  --selection-mode=connected \
  --sample "$sample_path"

for _ in {1..30}; do
  if pgrep -x QuickLookStep >/dev/null; then
    break
  fi
  sleep 0.2
done

if ! pgrep -x QuickLookStep >/dev/null; then
  echo "QuickLookStep process did not stay alive" >&2
  cat /tmp/quicklookstep-lifecycle.log 2>/dev/null || true
  exit 1
fi

for _ in {1..40}; do
  window_count="$(osascript \
    -e 'tell application "System Events"' \
    -e 'if exists process "QuickLookStep" then' \
    -e 'tell process "QuickLookStep" to get count of windows' \
    -e 'else' \
    -e 'return 0' \
    -e 'end if' \
    -e 'end tell' 2>/dev/null || echo 0)"
  if [[ "$window_count" != "0" ]]; then
    break
  fi
  sleep 0.25
done

if [[ "${window_count:-0}" == "0" ]]; then
  echo "QuickLookStep did not create a window" >&2
  cat /tmp/quicklookstep-lifecycle.log 2>/dev/null || true
  exit 1
fi

sleep 1.0
osascript \
  -e 'tell application "QuickLookStep" to activate' \
  -e 'tell application "System Events" to tell process "QuickLookStep" to set frontmost to true' \
  >/dev/null 2>&1 || true
sleep 0.25

top_window="$(swift -e '
import CoreGraphics
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
for window in windows {
    let layer = window[kCGWindowLayer as String] as? Int ?? 999
    let alpha = window[kCGWindowAlpha as String] as? Double ?? 0
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    let name = window[kCGWindowName as String] as? String ?? ""
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = bounds["Width"] as? Double ?? 0
    let height = bounds["Height"] as? Double ?? 0
    guard layer == 0, alpha > 0, !owner.isEmpty, width >= 900, height >= 600 else { continue }
    print("\(owner)\t\(name)\t\(Int(width))\t\(Int(height))")
    exit(0)
}
print("NONE")
exit(1)
')"

echo "top-window: $top_window"
cat /tmp/quicklookstep-lifecycle.log 2>/dev/null || true

IFS=$'\t' read -r top_owner top_name top_width top_height <<< "$top_window"

if [[ "$top_owner" != "QuickLookStep" ]]; then
  echo "Expected QuickLookStep to own the top visible window" >&2
  exit 1
fi

if (( top_width < 900 || top_height < 600 )); then
  echo "Expected QuickLookStep window to be at least 900x600, got ${top_width}x${top_height}" >&2
  exit 1
fi

screencapture -x "$screenshot_path"
echo "screenshot: $screenshot_path"

echo "QuickLookStep UI launch verified"
