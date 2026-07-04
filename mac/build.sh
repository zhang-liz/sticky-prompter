#!/bin/bash
# Build StickyPrompter.app from source. Requires Xcode Command Line Tools.
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

swiftc -O \
  -o "$APP/Contents/MacOS/StickyPrompter" \
  main.swift

# ad-hoc sign so macOS associates mic/speech permissions with the bundle
codesign --force --deep -s - "$APP"

echo "✅ Built $APP — run with: open $APP"
