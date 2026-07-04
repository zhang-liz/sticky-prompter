#!/bin/bash
# Build StickyPrompter.app from source. Requires Xcode Command Line Tools.
#   ./build.sh           build only (app stays in this folder)
#   ./build.sh install   build + install to /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP="StickyPrompter.app"

# app icon — generated once; delete AppIcon.icns to force a redesign rebuild
if [ ! -f AppIcon.icns ]; then
  echo "Generating app icon…"
  swiftc -O make-icon.swift -o .make-icon
  ./.make-icon icon_1024.png
  rm -f .make-icon
  rm -rf AppIcon.iconset && mkdir AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" icon_1024.png --out "AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "$d" "$d" icon_1024.png --out "AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns AppIcon.iconset -o AppIcon.icns
  rm -rf AppIcon.iconset icon_1024.png
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

# universal binary so the app runs on both Apple Silicon and Intel Macs
swiftc -O -target arm64-apple-macos13 -o .sp-arm64 main.swift
swiftc -O -target x86_64-apple-macos13 -o .sp-x86_64 main.swift
lipo -create .sp-arm64 .sp-x86_64 -output "$APP/Contents/MacOS/StickyPrompter"
rm -f .sp-arm64 .sp-x86_64

# ad-hoc sign so macOS associates mic/speech permissions with the bundle
codesign --force --deep -s - "$APP"
echo "✅ Built $APP"

if [ "${1:-}" = "install" ]; then
  pkill -f "StickyPrompter.app/Contents/MacOS/StickyPrompter" 2>/dev/null || true
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  touch "/Applications/$APP"
  echo "✅ Installed to /Applications — find it in Spotlight or Launchpad as “Sticky Prompter”"
fi
