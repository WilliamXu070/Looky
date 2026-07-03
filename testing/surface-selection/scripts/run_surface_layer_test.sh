#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
output_path="${1:-$repo_root/testing/surface-selection/reports/latest.json}"

cd "$repo_root"
swift testing/surface-selection/scripts/replay_surface_layer.swift "$output_path"
