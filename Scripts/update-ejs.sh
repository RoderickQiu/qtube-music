#!/bin/bash
# Vendors yt-dlp's EJS signature/n solver (github.com/yt-dlp/ejs, Unlicense; bundles meriyah (ISC) and astring (MIT),
# whose notices stay in the file header) into Sources/QTPlayback/Resources/EJS for the native Premium engine.
#
#   Scripts/update-ejs.sh            → re-download the pinned version (Resources/EJS/VERSION), check its checksums
#   Scripts/update-ejs.sh 0.9.0      → move the pin to 0.9.0, download it and record the new checksums
#
# After moving the pin: `swift test --filter NativeEngine`, a live check (`swift run QTNativeSpike cipher
# --signed-in`), then commit VERSION, CHECKSUMS and both .js files together. YouTube ships a new player every few
# weeks; when the native engine falls back with a solver error, a newer EJS release is usually the fix.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

DIR="$QT_REPO/Sources/QTPlayback/Resources/EJS"
FILES=(yt.solver.lib.js yt.solver.core.js)
PINNED="$(cat "$DIR/VERSION" 2>/dev/null || true)"
VERSION="${1:-$PINNED}"
[[ -n "$VERSION" ]] || { echo "error: no version given and no $DIR/VERSION" >&2; exit 2; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must look like 0.8.0" >&2; exit 2; }

WORK="$(mktemp -d -t qtejs)"
trap 'rm -rf "$WORK"' EXIT
for f in "${FILES[@]}"; do
  curl -fsSL "https://github.com/yt-dlp/ejs/releases/download/$VERSION/$f" -o "$WORK/$f"
  head -c 200 "$WORK/$f" | grep -q "SPDX-License-Identifier: Unlicense" \
    || { echo "error: $f has no Unlicense header; not vendoring it" >&2; exit 1; }
done
(cd "$WORK" && shasum -a 256 "${FILES[@]}") > "$WORK/CHECKSUMS"

if [[ "$VERSION" == "$PINNED" && -f "$DIR/CHECKSUMS" ]]; then
  if ! diff -q "$WORK/CHECKSUMS" "$DIR/CHECKSUMS" >/dev/null; then
    echo "error: the $VERSION release no longer matches the recorded checksums:" >&2
    diff "$DIR/CHECKSUMS" "$WORK/CHECKSUMS" >&2 || true
    exit 1
  fi
  (cd "$DIR" && shasum -a 256 -c CHECKSUMS)
  echo "EJS $VERSION: the vendored files match the release"
  exit 0
fi

mkdir -p "$DIR"
for f in "${FILES[@]}"; do cp "$WORK/$f" "$DIR/$f"; done
cp "$WORK/CHECKSUMS" "$DIR/CHECKSUMS"
echo "$VERSION" > "$DIR/VERSION"
echo "EJS pinned to $VERSION (was ${PINNED:-none}):"
cat "$DIR/CHECKSUMS"
