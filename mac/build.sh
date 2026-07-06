#!/bin/bash
# Build StickyPrompter.app from source. Requires Xcode Command Line Tools.
#   ./build.sh           build only (app stays in this folder)
#   ./build.sh install   build + install to /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP="StickyPrompter.app"

# app icon — built from icon-source.png (the sticky-note logo). Delete
# AppIcon.icns to force a rebuild. Falls back to the programmatic
# make-icon.swift generator only if no source image is present.
if [ ! -f AppIcon.icns ]; then
  echo "Generating app icon…"
  if [ -f icon-source.png ]; then
    cp icon-source.png icon_1024.png
    sips -z 1024 1024 icon_1024.png >/dev/null   # normalize to 1024²
  else
    swiftc -O make-icon.swift -o .make-icon
    ./.make-icon icon_1024.png
    rm -f .make-icon
  fi
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

# sign with the stable local identity when present (see dev-signing.sh) so
# mic/speech permissions survive rebuilds; ad-hoc otherwise
DEV_KEYCHAIN="$HOME/Library/Keychains/sticky-prompter-dev.keychain-db"
DEV_IDENTITY="Sticky Prompter Dev"
if [ -f "$DEV_KEYCHAIN" ] && security find-identity -v -p codesigning "$DEV_KEYCHAIN" 2>/dev/null | grep -q "$DEV_IDENTITY"; then
  security unlock-keychain -p "sticky-prompter-local" "$DEV_KEYCHAIN"
  codesign --force --deep --keychain "$DEV_KEYCHAIN" -s "$DEV_IDENTITY" "$APP"
  echo "✅ Built $APP (signed: $DEV_IDENTITY)"
else
  codesign --force --deep -s - "$APP"
  echo "✅ Built $APP (ad-hoc signed — run ./dev-signing.sh once to stop permission re-prompts)"
fi

if [ "${1:-}" = "install" ]; then
  pkill -f "StickyPrompter.app/Contents/MacOS/StickyPrompter" 2>/dev/null || true
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  touch "/Applications/$APP"
  echo "✅ Installed to /Applications — find it in Spotlight or Launchpad as “Sticky Prompter”"
fi
