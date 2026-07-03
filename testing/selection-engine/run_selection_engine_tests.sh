#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
output_path="${1:-$repo_root/testing/selection-engine/reports/latest.json}"

cd "$repo_root"
swift testing/selection-engine/scripts/replay_selection_engine.swift "$output_path"
