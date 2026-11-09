#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_temp="$(mktemp -d /tmp/quickcrop-viewer-check.XXXXXX)"
module_cache="${QUICKCROP_MODULE_CACHE:-/tmp/quickcrop-module-cache-$UID}"
webp_dir="${QUICKCROP_WEBP_DIR:-/opt/homebrew/opt/webp}"
trap 'rm -rf "$test_temp"' EXIT
xcrun clang -O2 -I "$webp_dir/include" -c "$project_dir/WebPAnimBridge.c" -o "$test_temp/WebPAnimBridge.o"
xcrun swiftc -D QUICKCROP_TESTING -module-cache-path "$module_cache" \
    -import-objc-header "$project_dir/WebPAnimBridge.h" \
    "$project_dir/QuickCrop.swift" "$project_dir/QuickCropLibrary.swift" \
    "$project_dir/Tests/QuickCropViewerTests.swift" "$test_temp/WebPAnimBridge.o" \
    -L "$webp_dir/lib" -lwebpdemux -lwebp -o "$test_temp/QuickCropViewerTests"
"$test_temp/QuickCropViewerTests"
