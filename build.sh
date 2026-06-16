#!/bin/bash
# Generate, build, and launch xsaver.app
set -euo pipefail
cd "$(dirname "$0")"

echo "→ Generating Xcode project…"
xcodegen generate

echo "→ Building (Release)…"
xcodebuild -project xsaver.xcodeproj -scheme xsaver -configuration Release \
  -derivedDataPath build build | tail -n 20

APP="build/Build/Products/Release/xsaver.app"
echo "→ Launching $APP"
open "$APP"
echo "✓ xsaver is running — look for the ⬇ icon in your menu bar (top-right)."
