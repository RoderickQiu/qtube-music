#!/bin/bash
# Launch the built app in the background on U270CA, wait until it's ready, capture windows, quit, restore focus.
#
#   Scripts/shoot.sh <outname> [--window main|mini|desktopLyrics|menuBarPopover|settings]… [launch args…]
#
#   Scripts/shoot.sh window-home-en -qt.lang en-US
#   Scripts/shoot.sh stage-vinyl -qt.surface stage -qt.stageBackground vinyl -qt.paused YES
#   Scripts/shoot.sh desktop-mini --window mini --window desktopLyrics -qt.time 40
#
# The first --window (default main) is saved as screenshots/<outname>.png, further ones as <outname>-<window>.png,
# always in the MAIN checkout's screenshots/ folder. Uses the app for $QT_VARIANT (build it first with
# Scripts/build-app.sh, or set QT_BUILD=1). Env: QT_SCREEN (default U270CA), QT_TIMEOUT (seconds, default 45),
# QT_KEEP=1 to leave the instance running.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[[ $# -ge 1 ]] || { sed -n '2,15p' "$0"; exit 2; }
OUT="$1"; shift
[[ "$OUT" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "error: outname must be a plain file name" >&2; exit 2; }

KINDS=()
ARGS=()
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--window" ]]; then KINDS+=("$2"); shift 2; else ARGS+=("$1"); shift; fi
done
[[ ${#KINDS[@]} -gt 0 ]] || KINDS=(main)

SHOW=()
for k in "${KINDS[@]}"; do
  case "$k" in
    main) ;;
    mini|desktopLyrics|menuBarPopover|settings) SHOW+=("$k") ;;
    *) echo "error: unknown window '$k'" >&2; exit 2 ;;
  esac
done

[[ "${QT_BUILD:-0}" == "1" ]] && "$QT_REPO/Scripts/build-app.sh" >/dev/null
APP="$(qt_app_path)"
[[ -x "$APP/Contents/MacOS/QTubeMusic" ]] || { echo "error: $APP not built (run Scripts/build-app.sh)" >&2; exit 1; }
WINDOW_ID_TOOL="$(qt_tool qt-window-id)"
mkdir -p "$QT_SCREENSHOTS"

FRONT_BEFORE="$(qt_frontmost_bundle)"
EXE="$APP/Contents/MacOS/QTubeMusic"
# One instance of this variant at a time.
pkill -f "^$EXE" 2>/dev/null || true
for _ in $(seq 1 50); do pgrep -f "^$EXE" >/dev/null || break; sleep 0.1; done

READY="$(mktemp -t qtshoot).json"; rm -f "$READY"
LAUNCH=(-ApplePersistenceIgnoreState YES -qt.screen "${QT_SCREEN:-U270CA}" -qt.readyFile "$READY")
if [[ ${#SHOW[@]} -gt 0 ]]; then LAUNCH+=(-qt.show "$(IFS=,; echo "${SHOW[*]}")"); fi
open -g -n "$APP" --args "${LAUNCH[@]}" ${ARGS[@]+"${ARGS[@]}"}

DEADLINE=$(( $(date +%s) + ${QT_TIMEOUT:-45} ))
until [[ -s "$READY" ]]; do
  if (( $(date +%s) > DEADLINE )); then echo "error: app did not become ready" >&2; pkill -f "^$EXE" || true; exit 1; fi
  sleep 0.1
done
PID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$READY")"

title_for() {
  case "$1" in
    main) echo "QTube Music" ;;
    mini) echo "QTube Music Mini Player" ;;
    desktopLyrics) echo "QTube Music Desktop Lyrics" ;;
    menuBarPopover) echo "QTube Music Menu Bar" ;;
    settings) echo "" ;;
  esac
}
ready_window() {  # window number from the ready file by NSWindow identifier
  python3 -c 'import json,sys
for w in json.load(open(sys.argv[1]))["windows"]:
    if w["identifier"] == sys.argv[2]: print(w["number"]); break' "$READY" "qt.window.$1"
}

STATUS=0
FIRST=1
for k in "${KINDS[@]}"; do
  ID=""
  T="$(title_for "$k")"
  if [[ -n "$T" ]]; then ID="$("$WINDOW_ID_TOOL" --pid "$PID" --title "$T" --wait 5 2>/dev/null || true)"; fi
  [[ -n "$ID" ]] || ID="$(ready_window "$k")"
  if [[ "$k" == settings && -z "$ID" ]]; then  # SwiftUI owns the Settings window; take the pid's other titled window
    ID="$("$WINDOW_ID_TOOL" --pid "$PID" --title "Settings" --wait 3 2>/dev/null || "$WINDOW_ID_TOOL" --pid "$PID" --title "设置" --wait 2 2>/dev/null || true)"
  fi
  if [[ -z "$ID" ]]; then echo "error: no '$k' window" >&2; STATUS=1; continue; fi
  if [[ $FIRST == 1 ]]; then FILE="$QT_SCREENSHOTS/$OUT.png"; FIRST=0; else FILE="$QT_SCREENSHOTS/$OUT-$k.png"; fi
  # Stage Manager can shrink an inactive window to a ~144x134 thumbnail mid-capture; retry until full size.
  for attempt in $(seq 1 12); do
    screencapture -l"$ID" -o -x "$FILE"
    W="$(sips -g pixelWidth "$FILE" 2>/dev/null | awk '/pixelWidth/ {print $2}')"
    [[ -n "$W" && "$W" -ge 300 ]] && break
    sleep 0.5
  done
  echo "$FILE"
done

if [[ "${QT_KEEP:-0}" != "1" ]]; then
  kill "$PID" 2>/dev/null || true
  for _ in $(seq 1 50); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
  kill -9 "$PID" 2>/dev/null || true
fi
rm -f "$READY"

FRONT_AFTER="$(qt_frontmost_bundle)"
# Only hand focus back if *we* took it; if the user switched apps themselves, leave them where they are.
if [[ -n "$FRONT_BEFORE" && "$FRONT_AFTER" != "$FRONT_BEFORE" && "$FRONT_AFTER" == com.roderickqiu.qtube* ]]; then
  echo "warning: frontmost changed ($FRONT_BEFORE → $FRONT_AFTER); restoring" >&2
  osascript -e "tell application id \"$FRONT_BEFORE\" to activate" >/dev/null 2>&1 || true
fi
exit $STATUS
