#!/bin/bash
# One captioned PNG from several screenshots, saved in the main checkout's screenshots/ folder.
#
#   Scripts/contact-sheet.sh <outname> [--title T] [--columns N] [--width PX] <image> <caption> [<image> <caption>]…
#
# Images may be paths or names in screenshots/ (with or without .png).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
[[ $# -ge 3 ]] || { sed -n '2,6p' "$0"; exit 2; }
OUT="$1"; shift
OPTS=()
while [[ $# -gt 0 && "$1" == --* ]]; do OPTS+=("$1" "$2"); shift 2; done
PAIRS=()
while [[ $# -ge 2 ]]; do
  IMG="$1"
  [[ -f "$IMG" ]] || IMG="$QT_SCREENSHOTS/${1%.png}.png"
  PAIRS+=("$IMG" "$2"); shift 2
done
TOOL="$(qt_tool qt-contact-sheet)"
"$TOOL" --out "$QT_SCREENSHOTS/$OUT.png" ${OPTS[@]+"${OPTS[@]}"} "${PAIRS[@]}"
