#!/usr/bin/env bash
# Regenerates the app icon (AppIcon.icns) and the menu-bar icon PNGs from their SVGs in Resources/.
# Run after editing either SVG.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == *CommandLineTools* && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc -O scripts/render-svg.swift -o "$WORK/render-svg"

ICONSET="$WORK/AppIcon.iconset"
mkdir "$ICONSET"
for size in 16 32 128 256 512; do
  "$WORK/render-svg" Resources/AppIcon.svg "$ICONSET/icon_${size}x${size}.png" "$size"
  "$WORK/render-svg" Resources/AppIcon.svg "$ICONSET/icon_${size}x${size}@2x.png" "$((size * 2))"
done
iconutil --convert icns "$ICONSET" --output Resources/AppIcon.icns

# Menu-bar icon: 18 pt, black on transparent (used as a template image that macOS tints).
"$WORK/render-svg" Resources/MenuBarIcon.svg Resources/MenuBarIcon.png 18
"$WORK/render-svg" Resources/MenuBarIcon.svg Resources/MenuBarIcon@2x.png 36
echo "Wrote Resources/AppIcon.icns and Resources/MenuBarIcon{,@2x}.png"
