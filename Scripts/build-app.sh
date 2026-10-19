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
# Linked-on SDK. SwiftPM's default build system (swiftbuild) stamps LC_BUILD_VERSION with sdk = the deployment
# target (15.0) instead of the SDK it compiled against (the deprecated native build system stamps it right).
# AppKit and SwiftUI choose the macOS 26+ design — Liquid Glass sidebar, toolbar, search field, controls,
# popovers — from the linked-on SDK, so a "15.0 SDK" binary runs in the old look on Tahoe. Restamp it with the
# real SDK version (minos stays 15.0).
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
MIN_OS="$(otool -l "$APP/Contents/MacOS/QTubeMusic" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
xcrun vtool -set-build-version macos "${MIN_OS:-15.0}" "$SDK_VERSION" -replace \
  -output "$APP/Contents/MacOS/QTubeMusic.stamped" "$APP/Contents/MacOS/QTubeMusic" 2>/dev/null
mv "$APP/Contents/MacOS/QTubeMusic.stamped" "$APP/Contents/MacOS/QTubeMusic"
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

# App icon (Scripts/make-app-icon.sh renders both when missing):
#  - Assets/AppIcon.icon → Assets.car via actool: the macOS 26+ Liquid Glass icon (CFBundleIconName), so Tahoe
#    doesn't shrink a legacy icon into its grey container;
#  - Assets/AppIcon.icns: the hand-drawn legacy squircle for macOS 15–25 (CFBundleIconFile).
ICON_KEY=""
if [[ ! -f "$QT_REPO/Assets/AppIcon.icns" || ! -f "$QT_REPO/Assets/AppIcon.icon/Assets/record.png" ]]; then
  "$QT_REPO/Scripts/make-app-icon.sh" >&2 || true
fi
if [[ -f "$QT_REPO/Assets/AppIcon.icns" ]]; then
  cp "$QT_REPO/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi
if [[ -d "$QT_REPO/Assets/AppIcon.icon" ]]; then
  ICON_WORK="$(mktemp -d -t qticoncar)"
  if xcrun actool "$QT_REPO/Assets/AppIcon.icon" --compile "$ICON_WORK" --platform macosx \
       --minimum-deployment-target 15.0 --app-icon AppIcon --output-partial-info-plist "$ICON_WORK/partial.plist" \
       >/dev/null 2>&1 && [[ -f "$ICON_WORK/Assets.car" ]]; then
    cp "$ICON_WORK/Assets.car" "$APP/Contents/Resources/Assets.car"
    ICON_KEY="$ICON_KEY<key>CFBundleIconName</key><string>AppIcon</string>"
  else
    echo "warning: actool couldn't compile Assets/AppIcon.icon; using the legacy .icns only" >&2
  fi
  rm -rf "$ICON_WORK"
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
