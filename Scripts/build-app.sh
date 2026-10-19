#!/bin/bash
# Build "QTube Music.app" (ad-hoc signed) from the SwiftPM package.
#
#   Scripts/build-app.sh              → .build/apps/QTube Music.app
#   QT_VARIANT=stage Scripts/build-app.sh → .build/apps/QTube Music stage.app, bundle id com.roderickqiu.qtube.dev-stage
#   Scripts/build-app.sh --print-path → just print the app path for the current QT_VARIANT
#
# Env: QT_VARIANT (letters, digits, '-'), QT_CONFIG=debug|release (default debug),
#      QT_SCRATCH (SwiftPM scratch path, default .build/<variant or "default">).
# Works from a git worktree: git-ignored inputs (mock catalog) come from the main checkout.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

if [[ -n "${QT_VARIANT:-}" && ! "$QT_VARIANT" =~ ^[A-Za-z0-9-]+$ ]]; then
  echo "error: QT_VARIANT must match [A-Za-z0-9-]+" >&2; exit 2
fi
APP="$(qt_app_path)"
if [[ "${1:-}" == "--print-path" ]]; then echo "$APP"; exit 0; fi

CONFIG="${QT_CONFIG:-debug}"
SCRATCH="${QT_SCRATCH:-$QT_REPO/.build/${QT_VARIANT:-default}}"
NAME="$(qt_variant_name)"
BUNDLE_ID="$(qt_bundle_id)"

cd "$QT_REPO"
swift build -c "$CONFIG" --scratch-path "$SCRATCH" --product QTubeMusic >&2
BIN="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/QTubeMusic" "$APP/Contents/MacOS/QTubeMusic"
# SwiftPM resource bundles (Bundle.module looks in Contents/Resources first).
for b in "$BIN"/*.bundle; do
  [[ -e "$b" && "$b" != *Tests.bundle ]] && cp -R "$b" "$APP/Contents/Resources/"
done

# Localizations the app declares, so macOS localizes system-provided menus too.
for l in en zh-Hans; do
  mkdir -p "$APP/Contents/Resources/$l.lproj"
  printf '"CFBundleName" = "%s";\n"CFBundleDisplayName" = "%s";\n' "$NAME" "$NAME" > "$APP/Contents/Resources/$l.lproj/InfoPlist.strings"
done

# Mock catalog (git-ignored): this checkout, else the main checkout, else generate it into the main checkout.
CATALOG=""
for c in "$QT_REPO/Generated/MockCatalog" "$QT_MAIN/Generated/MockCatalog"; do
  [[ -f "$c/catalog.json" ]] && { CATALOG="$c"; break; }
done
if [[ -z "$CATALOG" ]] && "$QT_REPO/Scripts/make-mock-catalog.py" >&2; then CATALOG="$QT_MAIN/Generated/MockCatalog"; fi
if [[ -n "$CATALOG" ]]; then
  cp -R "$CATALOG" "$APP/Contents/Resources/MockCatalog"
else
  echo "warning: no mock catalog; the app will start empty" >&2
fi

# App icon (builder "desktop" adds Assets/AppIcon.icns).
ICON_KEY=""
if [[ -f "$QT_REPO/Assets/AppIcon.icns" ]]; then
  cp "$QT_REPO/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

BUILD_NUMBER="$(git -C "$QT_REPO" rev-list --count HEAD 2>/dev/null || echo 1)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>QTubeMusic</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>QTube Music</string>
  $ICON_KEY
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --deep -s - "$APP" >&2
echo "$APP"
