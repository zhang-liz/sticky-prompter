#!/bin/bash
# Build StickyPrompter.app from source. Requires Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

APP="StickyPrompter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Info.plist "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

swiftc -O \
  -o "$APP/Contents/MacOS/StickyPrompter" \
  main.swift

# ad-hoc sign so macOS associates mic/speech permissions with the bundle
codesign --force --deep -s - "$APP"

echo "✅ Built $APP — run with: open $APP"
