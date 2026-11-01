#!/bin/bash
# An invisible test display, for screenshots while someone is using the Mac (no second monitor needed).
#
#   Scripts/virtual-display.sh start   → creates "QT Virtual" (1920×1080), diagonally off the main display's bottom-right
#                                        corner, and prints its name; then: QT_SCREEN="QT Virtual" Scripts/shoot.sh …
#   Scripts/virtual-display.sh stop    → removes it
#   Scripts/virtual-display.sh status
#
# Uses CoreGraphics' private CGVirtualDisplay API (Scripts/tools/qt-virtual-display.{swift,h}); the display lives as
# long as the helper process. Windows launched there with `open -g` never come to the front of the real screen.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

PIDFILE="$QT_REPO/.build/qt-tools/qt-virtual-display.pid"
BIN="$QT_TOOLS/qt-virtual-display"
SRC="$QT_REPO/Scripts/tools/qt-virtual-display.swift"
HDR="$QT_REPO/Scripts/tools/qt-virtual-display.h"

running() { [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

case "${1:-}" in
  start)
    if running; then echo "QT Virtual"; exit 0; fi
    mkdir -p "$QT_TOOLS"
    if [[ ! -x "$BIN" || "$SRC" -nt "$BIN" || "$HDR" -nt "$BIN" ]]; then
      xcrun swiftc -O -import-objc-header "$HDR" "$SRC" -o "$BIN" >&2
    fi
    OUT="$(mktemp -t qtvd)"
    nohup "$BIN" >"$OUT" 2>&1 &
    echo $! > "$PIDFILE"
    for _ in $(seq 1 20); do [[ -s "$OUT" ]] && break; sleep 0.25; done
    [[ "$(head -1 "$OUT")" =~ ^[0-9]+$ ]] || { cat "$OUT" >&2; rm -f "$OUT"; exit 1; }
    rm -f "$OUT"
    echo "QT Virtual" ;;
  stop)
    if running; then kill "$(cat "$PIDFILE")"; fi
    rm -f "$PIDFILE" ;;
  status)
    running && echo "running (pid $(cat "$PIDFILE"))" || echo "not running" ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac
