#!/bin/bash
# Read the system's Now Playing state (and drive our own app's player) — see Scripts/tools/qt-nowplaying.m.
#
#   Scripts/now-playing.sh clients                     every Now Playing client (one per app; WebKit's GPU
#                                                      process shows up as com.apple.WebKit.GPU/<bundle id>)
#   Scripts/now-playing.sh item                        the active player's item (title, elapsed, rate, artwork)
#   Scripts/now-playing.sh info                        the legacy info dictionary (may time out on newer macOS)
#   Scripts/now-playing.sh send <play|pause|toggle|next|previous> <bundle id>
#                                                      a real remote command, only if <bundle id> owns the active player
#
# Prints one JSON object. Never touches another app's playback.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SRC="$QT_REPO/Scripts/tools/qt-nowplaying.m"
LIB="$QT_TOOLS/qt-nowplaying.dylib"
mkdir -p "$QT_TOOLS"
if [[ ! -f "$LIB" || "$SRC" -nt "$LIB" ]]; then
  xcrun clang -dynamiclib -fobjc-arc -framework Foundation -o "$LIB" "$SRC" >&2
  codesign -f -s - "$LIB" >/dev/null 2>&1 || true
fi

MODE="${1:-clients}"
case "$MODE" in
  clients|info|item) QT_NP_MODE="$MODE" /usr/bin/perl -e 'use DynaLoader; DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();' "$LIB" ;;
  send)
    [[ $# -eq 3 ]] || { sed -n '2,12p' "$0"; exit 2; }
    QT_NP_MODE=send QT_NP_CMD="$2" QT_NP_BUNDLE="$3" \
      /usr/bin/perl -e 'use DynaLoader; DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();' "$LIB" ;;
  *) sed -n '2,12p' "$0"; exit 2 ;;
esac
