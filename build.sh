#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
output_app="${1:-$project_dir/build/QuickCrop-1.6.0.app}"
webp_dir="${QUICKCROP_WEBP_DIR:-/opt/homebrew/opt/webp}"
build_temp="$(mktemp -d /tmp/quickcrop-build.XXXXXX)"
module_cache="${QUICKCROP_MODULE_CACHE:-/tmp/quickcrop-module-cache-$UID}"
trap 'rm -rf "$build_temp"' EXIT

xcrun clang -O2 -mmacosx-version-min=13.0 -I "$webp_dir/include" \
    -c "$project_dir/WebPAnimBridge.c" -o "$build_temp/WebPAnimBridge.o"
xcrun swiftc -O -target arm64-apple-macosx13.0 \
    -module-cache-path "$module_cache" \
    -import-objc-header "$project_dir/WebPAnimBridge.h" \
    "$project_dir/QuickCrop.swift" "$project_dir/QuickCropLibrary.swift" \
    "$build_temp/WebPAnimBridge.o" -L "$webp_dir/lib" -lwebpdemux -lwebp \
    -o "$build_temp/QuickCrop"

mkdir -p "$output_app/Contents/MacOS" "$output_app/Contents/Resources"
cp "$build_temp/QuickCrop" "$output_app/Contents/MacOS/QuickCrop"
cp "$project_dir/Info.plist" "$output_app/Contents/Info.plist"
cp "$project_dir/QuickCrop.icns" "$output_app/Contents/Resources/QuickCrop.icns"
/usr/bin/codesign --force --sign - "$output_app"
printf 'Built %s\n' "$output_app"
