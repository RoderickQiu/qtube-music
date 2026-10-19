#!/bin/bash
# Build, check and package a QTube Music release; publish it to GitHub only when asked.
#
#   Scripts/release.sh 0.1.0               → dry run: everything local (tests, universal release build, bundle checks,
#                                            .dmg + .zip + SHA-256 sums in .build/release/0.1.0/, release notes from
#                                            CHANGELOG.md, local commit "Release 0.1.0" + tag v0.1.0). Nothing leaves
#                                            the machine.
#   Scripts/release.sh 0.1.0 --publish     → the same if it hasn't run yet (or reuses its artifacts when tag v0.1.0
#                                            and .build/release/0.1.0/ already exist), then: creates the public repo
#                                            RoderickQiu/qtube-music if there is no `origin` (asks you to type
#                                            "publish" first), pushes main and the tag, and creates the GitHub Release
#                                            with the .dmg, .zip and sums.
#
# Options:
#   --no-commit      package without committing, tagging or keeping the VERSION bump (for trying the script out)
#   --arm64-only     skip the universal (arm64 + x86_64) build
#   --skip-tests     don't run `swift test` (not allowed with --publish)
#   --developer-id   not available yet: prints what signing with a Developer ID needs, and stops
#
# Test-only environment (refused with --publish): QT_RELEASE_ANY_BRANCH=1 (run from a branch other than main),
# QT_RELEASE_ALLOW_MOCK=1 (don't fail on the demo catalog in the bundle — for trying the script before guest mode).
#
# Before running: write the version's section in CHANGELOG.md ("## 0.1.0") and commit it; be on main with a clean
# tree. Needs Xcode 27, and `gh` signed in for --publish.
#
# Signing: builds are ad-hoc signed (no Apple Developer ID yet), so users open the app once through System Settings ›
# Privacy & Security › Open Anyway (README › Install). Sparkle stays dormant: no SUFeedURL / SUPublicEDKey, automatic
# checks off — an ad-hoc app can't be updated safely. See `--developer-id` for the switch-over.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

REPO_SLUG="RoderickQiu/qtube-music"
APP_NAME="QTube Music"

usage() { sed -n '2,27p' "$0"; exit 2; }

VERSION=""; PUBLISH=0; COMMIT=1; UNIVERSAL=1; TESTS=1
for a in "$@"; do
  case "$a" in
    --publish) PUBLISH=1 ;;
    --no-commit) COMMIT=0 ;;
    --arm64-only) UNIVERSAL=0 ;;
    --skip-tests) TESTS=0 ;;
    --developer-id)
      cat >&2 <<'EOF'
Developer ID signing isn't set up yet. To switch over:
  1. Join the Apple Developer Program and create a "Developer ID Application" certificate (Xcode › Settings ›
     Accounts › Manage Certificates). Check: security find-identity -v -p codesigning
  2. In Scripts/build-app.sh, sign inside out with  codesign --force --options runtime --timestamp
     -s "Developer ID Application: <name> (<TEAMID>)"  instead of  -s -  (Sparkle's XPC services, Autoupdate,
     Updater.app, the framework, then the app), with an entitlements file if the hardened runtime needs one
     (WebKit JIT: com.apple.security.cs.allow-jit).
  3. Notarize and staple each artifact:
       xcrun notarytool store-credentials qtube --apple-id <id> --team-id <TEAMID>
       xcrun notarytool submit "QTube-Music-<v>.dmg" --keychain-profile qtube --wait
       xcrun stapler staple "QTube-Music-<v>.dmg"
  4. Turn Sparkle on: generate an EdDSA key with Sparkle's generate_keys, put SUPublicEDKey and
     SUFeedURL (https://github.com/RoderickQiu/qtube-music/releases/latest/download/appcast.xml) in Info.plist,
     set SUEnableAutomaticChecks to true, and add an appcast step here (Sparkle's generate_appcast over
     .build/release/<v>/, uploaded with the release).
  5. Drop the "Open Anyway" step from README › Install.
EOF
      exit 2 ;;
    -h|--help) usage ;;
    -*) echo "error: unknown option $a" >&2; usage ;;
    *) [[ -z "$VERSION" ]] || { echo "error: one version only" >&2; exit 2; }; VERSION="$a" ;;
  esac
done
[[ -n "$VERSION" ]] || usage
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must look like 0.1.0" >&2; exit 2; }
(( PUBLISH == 0 || TESTS == 1 )) || { echo "error: --publish always runs the tests" >&2; exit 2; }
(( PUBLISH == 0 || COMMIT == 1 )) || { echo "error: --publish needs the release commit and tag" >&2; exit 2; }
ANY_BRANCH="${QT_RELEASE_ANY_BRANCH:-0}"; ALLOW_MOCK="${QT_RELEASE_ALLOW_MOCK:-0}"
if (( PUBLISH == 1 )) && [[ "$ANY_BRANCH" == 1 || "$ALLOW_MOCK" == 1 ]]; then
  echo "error: QT_RELEASE_ANY_BRANCH / QT_RELEASE_ALLOW_MOCK are for local tries only, not with --publish" >&2; exit 2
fi

cd "$QT_REPO"
TAG="v$VERSION"
OUT="$QT_REPO/.build/release/$VERSION"
DMG="$OUT/QTube-Music-$VERSION.dmg"
ZIP="$OUT/QTube-Music-$VERSION.zip"
SUMS="$OUT/SHA256SUMS.txt"
NOTES="$OUT/RELEASE_NOTES.md"
APP="$QT_REPO/.build/apps/$APP_NAME.app"

step() { printf '\n==> %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }

# MARK: Already built? (--publish after a dry run)

ALREADY_BUILT=0
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  if (( PUBLISH == 1 )) && [[ -f "$DMG" && -f "$ZIP" && -f "$SUMS" && -f "$NOTES" ]]; then
    ALREADY_BUILT=1
    step "Tag $TAG and its artifacts exist; publishing them"
    (cd "$OUT" && shasum -a 256 -c "$SUMS") || fail "artifacts in $OUT don't match SHA256SUMS.txt; rebuild"
  else
    fail "tag $TAG already exists (delete it with 'git tag -d $TAG' to rebuild, or pass --publish to publish it)"
  fi
fi

if (( ALREADY_BUILT == 0 )); then
  # MARK: Checks

  step "Checking the repository"
  BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo detached)"
  [[ "$BRANCH" == main || "$ANY_BRANCH" == 1 ]] || fail "releases are cut from main (on $BRANCH)"
  [[ -z "$(git status --porcelain)" ]] || fail "the working tree isn't clean; commit or stash first"
  grep -q "^## $VERSION\$" CHANGELOG.md || fail "CHANGELOG.md has no '## $VERSION' section"
  [[ -f LICENSE && -f THIRD_PARTY_NOTICES.md ]] || fail "LICENSE or THIRD_PARTY_NOTICES.md missing"

  if (( TESTS == 1 )); then
    step "Running the tests"
    # --disable-xctest: every suite is Swift Testing; the empty XCTest pass hangs on some hosts (docs/development.md).
    swift test --scratch-path "$QT_REPO/.build/release-tests" --disable-xctest >"$QT_REPO/.build/release-tests.log" 2>&1 \
      || { tail -30 "$QT_REPO/.build/release-tests.log" >&2; fail "tests failed (log: .build/release-tests.log)"; }
    grep -E "Test run with .* (passed|failed)" "$QT_REPO/.build/release-tests.log" | tail -1
  fi

  # MARK: Build

  OLD_VERSION="$(tr -d '[:space:]' < VERSION)"
  restore_version() { if (( COMMIT == 0 )); then echo "$OLD_VERSION" > VERSION; fi; }
  trap restore_version EXIT
  echo "$VERSION" > VERSION

  ARCHS="arm64"; KIND="release, arm64"
  if (( UNIVERSAL == 1 )); then ARCHS="arm64 x86_64"; KIND="release, universal"; fi
  step "Building $APP_NAME $VERSION ($KIND)"
  QT_VARIANT="" QT_CONFIG=release QT_ARCHS="$ARCHS" QT_SCRATCH="$QT_REPO/.build/release-scratch" \
    "$QT_REPO/Scripts/build-app.sh" >"$QT_REPO/.build/release-build.log" 2>&1 \
    || { tail -30 "$QT_REPO/.build/release-build.log" >&2; fail "build failed (log: .build/release-build.log)"; }
  # build-app.sh warnings that mean an incomplete bundle (Shortcuts actions, updates framework, icon, strings).
  BAD='^warning: (App Intents metadata|Sparkle.framework not found|actool|couldn.t compile)'
  if grep -Eq "$BAD" "$QT_REPO/.build/release-build.log"; then
    grep -E "$BAD" "$QT_REPO/.build/release-build.log" >&2
    fail "build-app.sh warned (above); a release bundle must be complete"
  fi

  # MARK: Bundle checks

  step "Checking the app bundle"
  RES="$APP/Contents/Resources"
  EXE="$APP/Contents/MacOS/QTubeMusic"
  plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
  [[ "$(plist CFBundleShortVersionString)" == "$VERSION" ]] || fail "Info.plist version isn't $VERSION"
  [[ "$(plist CFBundleIdentifier)" == "com.roderickqiu.qtube" ]] || fail "bundle id isn't com.roderickqiu.qtube"
  codesign --verify --deep --strict "$APP" || fail "codesign --verify failed"
  for a in $ARCHS; do
    lipo -archs "$EXE" | tr ' ' '\n' | grep -qx "$a" || fail "the executable has no $a slice"
  done
  # Demo data must never ship (git-ignored covers and lyrics; guest mode replaces it in release builds).
  if [[ -e "$RES/MockCatalog" ]]; then
    [[ "$ALLOW_MOCK" == 1 ]] || fail "the release bundle contains the demo catalog (Contents/Resources/MockCatalog)"
    echo "warning: demo catalog in the bundle, allowed by QT_RELEASE_ALLOW_MOCK=1 (local try only)" >&2
  fi
  for need in "QTubeMusic_QTCore.bundle" "QTubeMusic_QTPlayback.bundle/Contents/Resources/EJS/yt.solver.lib.js" \
              "QTubeMusic_QTPlayback.bundle/Contents/Resources/EJS/yt.solver.core.js" "SwiftyOpenCC_OpenCC.bundle/Contents/Resources/Dictionary/STPhrases.ocd2" \
              "Metadata.appintents" "QTubeMusic.sdef" "AppIcon.icns" "Assets.car"; do
    [[ -e "$RES/$need" ]] || fail "missing from Contents/Resources: $need"
  done
  [[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]] || fail "Sparkle.framework is missing"
  # DEBUG-only code must be compiled out (debug hooks, the shared dev Keychain session, the dev session import).
  for marker in "com.roderickqiu.qtube.debug.playback" "qt.playback.statusFile" "youtube-music-session.dev" \
                "QTDevSharedKeychainStore"; do
    if strings -a "$EXE" | grep -qF "$marker"; then fail "DEBUG-only code in the release binary ($marker)"; fi
  done
  echo "ok: $(lipo -archs "$EXE"), $(du -sh "$APP" | cut -f1), version $VERSION ($(plist CFBundleVersion))"

  # MARK: Package

  step "Packaging"
  rm -rf "$OUT"; mkdir -p "$OUT"
  STAGE="$(mktemp -d -t qtrelease)"
  ditto "$APP" "$STAGE/$APP_NAME.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 \
    -ov "$DMG" >/dev/null
  rm -rf "$STAGE"
  hdiutil verify "$DMG" >/dev/null 2>&1 || fail "hdiutil verify failed for the .dmg"
  MNT="$(mktemp -d -t qtdmg)"
  hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MNT" "$DMG" >/dev/null
  ok=1
  codesign --verify --deep --strict "$MNT/$APP_NAME.app" || ok=0
  [[ -L "$MNT/Applications" ]] || ok=0
  hdiutil detach "$MNT" -quiet || hdiutil detach "$MNT" -force -quiet
  rmdir "$MNT" 2>/dev/null || true
  (( ok == 1 )) || fail "the mounted .dmg doesn't hold a valid app and an Applications link"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  (cd "$OUT" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")") > "$SUMS"

  # Release notes: the CHANGELOG section, plus how to open an unsigned app.
  {
    awk -v v="## $VERSION" '$0 == v {on = 1; next} on && /^## / {exit} on' CHANGELOG.md | sed -e '/./,$!d'
    cat <<EOF

### Install

Requires macOS 15 or later ($( (( UNIVERSAL == 1 )) && echo "Apple silicon and Intel" || echo "Apple silicon")).
Download \`$(basename "$DMG")\`, open it and drag **$APP_NAME** to Applications. The app isn't notarized: the first
time, open **System Settings › Privacy & Security** and click **Open Anyway** (or run
\`xattr -dr com.apple.quarantine "/Applications/$APP_NAME.app"\`).

SHA-256:
\`\`\`
$(cat "$SUMS")
\`\`\`
EOF
  } > "$NOTES"
  ls -lh "$OUT" | awk 'NR > 1 {print "  " $5 "  " $9}'

  # MARK: Commit + tag

  if (( COMMIT == 1 )); then
    step "Committing and tagging $TAG"
    if ! git diff --quiet -- VERSION; then
      git add VERSION
      git commit -q -m "Release $VERSION"
    fi
    git tag -a "$TAG" -m "$APP_NAME $VERSION"
    trap - EXIT
    echo "commit $(git rev-parse --short HEAD), tag $TAG (local only)"
  else
    echo "(--no-commit: no commit, no tag; VERSION restored)"
  fi
fi

# MARK: Publish

if (( PUBLISH == 0 )); then
  step "Done — nothing was published"
  echo "Artifacts: $OUT"
  if (( COMMIT == 1 )); then echo "Next, to publish:  Scripts/release.sh $VERSION --publish"; fi
  exit 0
fi

step "Publishing $TAG to github.com/$REPO_SLUG"
command -v gh >/dev/null || fail "the GitHub CLI (gh) isn't installed"
gh auth status >/dev/null 2>&1 || fail "gh isn't signed in (run: gh auth login)"
if ! git remote get-url origin >/dev/null 2>&1; then
  COMMITS="$(git rev-list --count HEAD)"
  echo "There is no 'origin'. This creates the PUBLIC repository $REPO_SLUG and pushes main with all $COMMITS"
  echo "commits of history, the tag $TAG, and the release files. Anyone will be able to read all of it."
  read -r -p "Type 'publish' to continue: " answer
  [[ "$answer" == publish ]] || fail "stopped; nothing was published"
  if gh repo view "$REPO_SLUG" >/dev/null 2>&1; then
    git remote add origin "https://github.com/$REPO_SLUG.git"
  else
    gh repo create "$REPO_SLUG" --public --source . --remote origin \
      --description "A native macOS app for YouTube Music (unofficial)"
  fi
fi
git push origin main
git push origin "$TAG"
gh release create "$TAG" "$DMG" "$ZIP" "$SUMS" --repo "$REPO_SLUG" --title "$APP_NAME $VERSION" --notes-file "$NOTES"
echo "Published: https://github.com/$REPO_SLUG/releases/tag/$TAG"
