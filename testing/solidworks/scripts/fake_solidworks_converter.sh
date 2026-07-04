#!/usr/bin/env bash
set -euo pipefail

input="${1:?input .sldprt path required}"
output_dir="${2:?output directory required}"

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
base="$(basename "$input")"
name="${base%.*}"
output="$output_dir/$name.obj"

mkdir -p "$output_dir"
cp "$repo_root/testing/input/cube_hole_from_step.obj" "$output"
printf '%s\n' "$output"
