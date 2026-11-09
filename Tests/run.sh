#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_temp="$(mktemp -d /tmp/quickcrop-check.XXXXXX)"
module_cache="${QUICKCROP_MODULE_CACHE:-/tmp/quickcrop-module-cache-$UID}"
trap 'rm -rf "$test_temp"' EXIT
xcrun swiftc -module-cache-path "$module_cache" \
    "$project_dir/QuickCropLibrary.swift" "$project_dir/Tests/QuickCropLibraryTests.swift" \
    -o "$test_temp/QuickCropLibraryTests"
"$test_temp/QuickCropLibraryTests"
