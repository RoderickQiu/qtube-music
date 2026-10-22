#!/bin/bash
# Build "QTube Music.app" (ad-hoc signed) from the SwiftPM package.
#
#   Scripts/build-app.sh              → .build/apps/QTube Music.app
#   QT_VARIANT=stage Scripts/build-app.sh → .build/apps/QTube Music stage.app, bundle id com.roderickqiu.qtube.dev-stage
#   Scripts/build-app.sh --print-path → just print the app path for the current QT_VARIANT
#
# Env: QT_VARIANT (letters, digits, '-'), QT_CONFIG=debug|release (default debug),
#      QT_SCRATCH (SwiftPM scratch path, default .build/<variant or "default">),
#      QT_ARCHS ("arm64 x86_64" for a universal binary; default: the host architecture only).
# The marketing version comes from VERSION at the repo root; the build number is the commit count.
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

ARCH_FLAGS=()
for a in ${QT_ARCHS:-}; do
  [[ "$a" == arm64 || "$a" == x86_64 ]] || { echo "error: QT_ARCHS takes arm64 and/or x86_64, got '$a'" >&2; exit 2; }
  ARCH_FLAGS+=(--arch "$a")
done
VERSION="$(tr -d '[:space:]' < "$QT_REPO/VERSION" 2>/dev/null || true)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: VERSION must hold a version like 0.1.0" >&2; exit 2; }

cd "$QT_REPO"
swift build -c "$CONFIG" --scratch-path "$SCRATCH" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product QTubeMusic >&2
BIN="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

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

# Sparkle.framework (approved dependency) goes in Contents/Frameworks; the executable finds it through
# @executable_path/../Frameworks instead of the build folder's PackageFrameworks rpath.
SPARKLE_FW=""
for f in "$BIN/Sparkle.framework" "$BIN/PackageFrameworks/Sparkle.framework"; do
  [[ -d "$f" ]] && { SPARKLE_FW="$f"; break; }
done
if [[ -n "$SPARKLE_FW" ]]; then
  mkdir -p "$APP/Contents/Frameworks"
  ditto "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/QTubeMusic" 2>/dev/null || true
  for rp in "$BIN/PackageFrameworks" "$BIN"; do
    install_name_tool -delete_rpath "$rp" "$APP/Contents/MacOS/QTubeMusic" 2>/dev/null || true
  done
else
  echo "warning: Sparkle.framework not found in $BIN; the app won't launch" >&2
fi

# App resources from Sources/QTubeMusicApp/Resources (excluded from SwiftPM): AppleScript terminology, and the
# App Intents String Catalogs compiled to .strings (Shortcuts reads them from the bundle, out of process).
APP_RES="$QT_REPO/Sources/QTubeMusicApp/Resources"
cp "$APP_RES/QTubeMusic.sdef" "$APP/Contents/Resources/QTubeMusic.sdef"
for cat in AppIntents AppShortcuts; do
  xcrun xcstringstool compile "$APP_RES/$cat.xcstrings" --output-directory "$APP/Contents/Resources" >/dev/null \
    || echo "warning: couldn't compile $cat.xcstrings" >&2
done

# App Intents metadata (Metadata.appintents) — what Xcode's "Extract App Intents Metadata" phase does: Swift const
# values for the app module, then appintentsmetadataprocessor. Without it Shortcuts doesn't list the intents.
intents_metadata() {
  local work sdk toolchain xcv
  work="$(mktemp -d -t qtintents)"
  sdk="$(xcrun --sdk macosx --show-sdk-path)"
  toolchain="$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")"
  xcv="$(xcodebuild -version 2>/dev/null | awk '/Build version/{print $3}')"
  printf '%s' '["AppIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider","EntityStringQuery","EntityPropertyQuery","IntentValueQuery","_IntentValueRepresentable","_AssistantIntentsProvider","_GenerativeFunctionExtractable"]' > "$work/protocols.json"
  ls "$QT_REPO"/Sources/QTubeMusicApp/*.swift > "$work/sources.txt"
  # C modules of dependencies (SwiftyOpenCC's copencc) aren't in the bin folder; QTLyrics imports them.
  local cmods=() m
  while IFS= read -r m; do cmods+=(-I "$(dirname "$m")"); done < <(find "$SCRATCH/checkouts" -path "*/include/module.modulemap" 2>/dev/null)
  # shellcheck disable=SC2046
  xcrun swiftc -typecheck -parse-as-library -swift-version 6 -module-name QTubeMusicApp -target "arm64-apple-macos${MIN_OS:-15.0}" \
    -sdk "$sdk" -I "$BIN" ${cmods[@]+"${cmods[@]}"} -F "$BIN" -F "$BIN/PackageFrameworks" -wmo $(cat "$work/sources.txt") \
    -emit-const-values-path "$work/QTubeMusicApp.swiftconstvalues" \
    -Xfrontend -const-gather-protocols-file -Xfrontend "$work/protocols.json" >/dev/null 2>&1 || { rm -rf "$work"; return 1; }
  echo "$work/QTubeMusicApp.swiftconstvalues" > "$work/consts.txt"
  xcrun appintentsmetadataprocessor --output "$APP/Contents/Resources" --toolchain-dir "$toolchain" \
    --module-name QTubeMusicApp --sdk-root "$sdk" --xcode-version "${xcv:-17A1}" --platform-family macOS \
    --deployment-target "${MIN_OS:-15.0}" --target-triple "arm64-apple-macos${MIN_OS:-15.0}" \
    --source-file-list "$work/sources.txt" --swift-const-vals-list "$work/consts.txt" \
    --binary-file "$APP/Contents/MacOS/QTubeMusic" >/dev/null 2>&1
  local rc=$?
  rm -rf "$work"
  [[ $rc -eq 0 && -d "$APP/Contents/Resources/Metadata.appintents" ]]
}
intents_metadata || echo "warning: App Intents metadata not extracted; Shortcuts won't list QTube Music's actions" >&2

# SwiftPM resource bundles (Bundle.module looks in Contents/Resources first).
for b in "$BIN"/*.bundle; do
  [[ -e "$b" && "$b" != *Tests.bundle ]] && cp -R "$b" "$APP/Contents/Resources/"
done

# Localizations the app declares, so macOS localizes system-provided menus too.
for l in en zh-Hans; do
  mkdir -p "$APP/Contents/Resources/$l.lproj"
  printf '"CFBundleName" = "%s";\n"CFBundleDisplayName" = "%s";\n' "$NAME" "$NAME" > "$APP/Contents/Resources/$l.lproj/InfoPlist.strings"
done

# Mock catalog (git-ignored), DEBUG builds only: demo data never ships (release builds wouldn't read it anyway,
# QTBuild.allowsDemoData). This checkout, else the main checkout, else generate it into the main checkout.
if [[ "$CONFIG" == "debug" ]]; then
  CATALOG=""
  for c in "$QT_REPO/Generated/MockCatalog" "$QT_MAIN/Generated/MockCatalog"; do
    [[ -f "$c/catalog.json" ]] && { CATALOG="$c"; break; }
  done
  if [[ -z "$CATALOG" ]] && "$QT_REPO/Scripts/make-mock-catalog.py" >&2; then CATALOG="$QT_MAIN/Generated/MockCatalog"; fi
  if [[ -n "$CATALOG" ]]; then
    cp -R "$CATALOG" "$APP/Contents/Resources/MockCatalog"
  else
    echo "warning: no mock catalog; -qt.catalog mock will start empty" >&2
  fi
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
# The commit, for Help › Report a Problem…'s diagnostics ("+": built with uncommitted changes).
GIT_COMMIT="$(git -C "$QT_REPO" rev-parse --short=10 HEAD 2>/dev/null || echo unknown)"
git -C "$QT_REPO" diff --quiet HEAD 2>/dev/null || GIT_COMMIT="$GIT_COMMIT+"
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
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>QTGitCommit</key><string>$GIT_COMMIT</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Tianrun Qiu</string>
  <key>NSAppleScriptEnabled</key><true/>
  <key>OSAScriptingDefinition</key><string>QTubeMusic.sdef</string>
  <!-- Sparkle: dormant until there is a Developer ID (no SUFeedURL, no SUPublicEDKey → never checks, and would
       refuse unsigned updates). See docs/architecture.md › Updates. -->
  <key>SUEnableAutomaticChecks</key><false/>
  <key>SUAutomaticallyUpdate</key><false/>
  <key>SUAllowsAutomaticUpdates</key><false/>
  <key>SUEnableSystemProfiling</key><false/>
  $ICON_KEY
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Ad-hoc signing, inside out: Sparkle's helpers (XPC services, Autoupdate, Updater.app), the framework, the app.
if [[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]]; then
  FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  for nested in "$FW"/XPCServices/*.xpc "$FW/Autoupdate" "$FW/Updater.app"; do
    [[ -e "$nested" ]] && codesign --force -s - "$nested" >&2
  done
  codesign --force -s - "$APP/Contents/Frameworks/Sparkle.framework" >&2
fi
codesign --force -s - "$APP" >&2
# Old agents' scratch folders and variant apps (see the script); never fails the build.
"$QT_REPO/Scripts/prune-build.sh" || true
echo "$APP"
