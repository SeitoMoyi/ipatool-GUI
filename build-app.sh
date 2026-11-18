#!/bin/bash
set -euo pipefail

macos_dir="$(cd "$(dirname "$0")" && pwd)"
build_dir="$macos_dir/.build"
app_dir="$build_dir/ipatool.app"
mkdir -p "$build_dir"
staging_dir="$(mktemp -d "$build_dir/app.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
staged_app="$staging_dir/ipatool.app"

mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macosx14.0" -parse-as-library -O -whole-module-optimization \
    -module-cache-path "$build_dir/ModuleCache" "$@" "$macos_dir"/Sources/IPAToolDesktop/*.swift \
    -o "$staged_app/Contents/MacOS/IPAToolDesktop"
cp "$macos_dir/Info.plist" "$staged_app/Contents/"
cp "$macos_dir/LICENSE" "$staged_app/Contents/Resources/"
codesign --force --sign - "$staged_app"
rm -rf "$app_dir"
mv "$staged_app" "$app_dir"
printf '%s\n' "$app_dir"
