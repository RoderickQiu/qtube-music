#!/bin/bash
# Like Scripts/shoot.sh, but captures the SCREEN region around one window (with its real backdrop), for
# translucent floating panels — Liquid Glass / vibrancy is empty in a bare window capture.
#
#   Scripts/shoot-region.sh <outname> <window title substring> [--margin 40] [launch args…]
#   Scripts/shoot-region.sh desktop-mini-glass "Mini Player" -qt.surface mini -qt.time 40
#
# Only ever on the test display: QT_SCREEN, else U270CA when connected, else the built-in display (Scripts/lib.sh
# qt_screen; a QT_SCREEN that isn't connected stops the run). Saves screenshots/<outname>.png in the main checkout.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
[[ $# -ge 2 ]] || { sed -n '2,8p' "$0"; exit 2; }
OUT="$1"; TITLE="$2"; shift 2
[[ "$OUT" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "error: outname must be a plain file name" >&2; exit 2; }
MARGIN=40
if [[ "${1:-}" == "--margin" ]]; then MARGIN="$2"; shift 2; fi

APP="$(qt_app_path)"
EXE="$APP/Contents/MacOS/QTubeMusic"
[[ -x "$EXE" ]] || { echo "error: $APP not built" >&2; exit 1; }
TOOL="$(qt_tool qt-window-id)"
SCREEN="$(qt_screen)" || exit 1
FRONT_BEFORE="$(qt_frontmost_bundle)"
pkill -f "^$EXE" 2>/dev/null || true
for _ in $(seq 1 50); do pgrep -f "^$EXE" >/dev/null || break; sleep 0.1; done

READY="$(mktemp -t qtshoot).json"; rm -f "$READY"
open -g -n "$APP" --args -ApplePersistenceIgnoreState YES -qt.screen "$SCREEN" -qt.readyFile "$READY" "$@"
DEADLINE=$(( $(date +%s) + ${QT_TIMEOUT:-45} ))
until [[ -s "$READY" ]]; do
  (( $(date +%s) > DEADLINE )) && { echo "error: not ready" >&2; pkill -f "^$EXE" || true; exit 1; }
  sleep 0.1
done
if qt_ready_error "$READY" >&2; then rm -f "$READY"; exit 1; fi
sleep "${QT_SETTLE:-0.6}"
PID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$READY")"
BOUNDS="$("$TOOL" --pid "$PID" --list | awk -F'\t' -v t="$TITLE" 'index($5, t) && $3=="onScreen=true" {print $4; exit}')"
STATUS=0
if [[ -z "$BOUNDS" ]]; then
  echo "error: no window titled ~$TITLE" >&2; STATUS=1
else
  # "x,y WxH" in global CG coordinates
  read -r X Y W H < <(echo "$BOUNDS" | sed -E 's/([-0-9]+),([-0-9]+) ([0-9]+)x([0-9]+)/\1 \2 \3 \4/')
  FILE="$QT_SCREENSHOTS/$OUT.png"
  # Clamp to the test display so a margin never reaches into another display (the user's main screen).
  RX=$((X - MARGIN)); RY=$((Y - MARGIN)); RX2=$((X + W + MARGIN)); RY2=$((Y + H + MARGIN))
  if read -r DX DY DW DH < <("$TOOL" --display-bounds "$SCREEN"); then
    (( RX < DX )) && RX=$DX; (( RY < DY )) && RY=$DY
    (( RX2 > DX + DW )) && RX2=$((DX + DW)); (( RY2 > DY + DH )) && RY2=$((DY + DH))
  else
    echo "error: display $SCREEN not found; not capturing" >&2; STATUS=1; RX2=$RX
  fi
  if (( RX2 > RX && RY2 > RY )); then
    screencapture -x -R"$RX,$RY,$((RX2 - RX)),$((RY2 - RY))" "$FILE"
    echo "$FILE"
  fi
fi
kill "$PID" 2>/dev/null || true
rm -f "$READY"
FRONT_AFTER="$(qt_frontmost_bundle)"
if [[ -n "$FRONT_BEFORE" && "$FRONT_AFTER" != "$FRONT_BEFORE" ]]; then
  osascript -e "tell application id \"$FRONT_BEFORE\" to activate" >/dev/null 2>&1 || true
fi
exit $STATUS
