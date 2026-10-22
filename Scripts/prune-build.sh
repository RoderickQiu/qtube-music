#!/bin/bash
# Keep .build/ from growing without bound. Every agent builds into its own SwiftPM scratch folder
# (.build/<you>, ~0.5–1 GB each) and leaves a variant app; after a night of agents that was 18 GB.
# Scripts/build-app.sh runs this after every build; run it by hand any time.
#
#   Scripts/prune-build.sh            → prune, print what went
#   Scripts/prune-build.sh --dry-run  → print what would go
#
# Rules (the main scratch .build/default, the main app, release/ and qt-tools are always kept):
#  1. a scratch folder idle for QT_PRUNE_IDLE_HOURS (default 24) goes;
#  2. then, while the scratch folders together exceed QT_BUILD_CAP_GB (default 6), the least recently used one
#     idle for at least an hour goes;
#  3. a variant app ("QTube Music <variant>.app") not rebuilt for 3 days goes.
# Nothing a running process uses is touched (a swift build with that scratch path, a running variant app).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1
BUILD="$QT_REPO/.build"
[[ -d "$BUILD" ]] || exit 0
IDLE_S=$(( ${QT_PRUNE_IDLE_HOURS:-24} * 3600 ))
CAP_KB=$(( ${QT_BUILD_CAP_GB:-6} * 1024 * 1024 ))
NOW=$(date +%s)

in_use() { pgrep -f -- "$1" >/dev/null 2>&1; }
remove() {
  local what="$1" kb
  kb=$(du -sk "$what" 2>/dev/null | cut -f1)
  echo "prune: ${what#"$QT_REPO/"} ($(( ${kb:-0} / 1024 )) MB)" >&2
  (( DRY )) || rm -rf "$what"
}
# Last use of a scratch folder: SwiftPM rewrites .lock (and the manifest) on every build.
last_used() {
  local t=0 f m
  for f in "$1/.lock" "$1/manifest.pif" "$1/workspace-state.json" "$1"; do
    [[ -e "$f" ]] || continue
    m=$(stat -f %m "$f")
    (( m > t )) && t=$m
  done
  echo "$t"
}

# Scratch folders: .build/<name>/ holding SwiftPM's workspace state, oldest first.
LIST=""
for d in "$BUILD"/*/; do
  d="${d%/}"
  [[ "$(basename "$d")" == default ]] && continue
  [[ -f "$d/workspace-state.json" || -f "$d/CACHEDIR.TAG" ]] || continue
  in_use "$d" && continue
  LIST+="$(last_used "$d") $d"$'\n'
done
LIST="$(printf '%s' "$LIST" | sort -n)"

TOTAL_KB=0
KEPT=""
while read -r t d; do
  [[ -n "${d:-}" ]] || continue
  if (( NOW - t > IDLE_S )); then
    remove "$d"
  else
    TOTAL_KB=$(( TOTAL_KB + $(du -sk "$d" | cut -f1) ))
    KEPT+="$t $d"$'\n'
  fi
done <<< "$LIST"

while read -r t d; do
  [[ -n "${d:-}" ]] || continue
  (( TOTAL_KB > CAP_KB )) || break
  (( NOW - t > 3600 )) || continue
  kb=$(du -sk "$d" | cut -f1)
  remove "$d"
  TOTAL_KB=$(( TOTAL_KB - kb ))
done <<< "$KEPT"

for app in "$BUILD"/apps/"QTube Music "*.app; do
  [[ -d "$app" ]] || continue
  (( NOW - $(stat -f %m "$app") > 3 * 86400 )) || continue
  in_use "$app/Contents/MacOS" && continue
  remove "$app"
done
exit 0
