#!/bin/bash
# Render the app icon with CoreGraphics (Scripts/tools/qt-make-icon.swift):
#   Assets/AppIcon.icns            legacy squircle icon, all sizes (16 pt … 512 pt @2x) — macOS 15–25
#   Assets/AppIcon.icon/Assets/    Icon Composer layers (full-bleed background + record) — macOS 26+ Liquid Glass
#                                  icon; Scripts/build-app.sh compiles AppIcon.icon into Assets.car with actool.
#
#   Scripts/make-app-icon.sh            → both
#   Scripts/make-app-icon.sh --png F    → also a 1024 px PNG preview of the legacy icon at F
set -euo pipefail
source "$(dirname "$0")/lib.sh"
TOOL="$(qt_tool qt-make-icon)"
WORK="$(mktemp -d -t qticon)"
trap 'rm -rf "$WORK"' EXIT
"$TOOL" --iconset "$WORK/AppIcon.iconset"
mkdir -p "$QT_REPO/Assets/AppIcon.icon/Assets"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$QT_REPO/Assets/AppIcon.icns"
"$TOOL" --layers "$QT_REPO/Assets/AppIcon.icon/Assets"
if [[ "${1:-}" == "--png" && -n "${2:-}" ]]; then "$TOOL" --png "$2"; fi
echo "$QT_REPO/Assets/AppIcon.icns"
echo "$QT_REPO/Assets/AppIcon.icon"
