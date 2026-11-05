#!/bin/bash
# Build, check and package a QTube Music release; publish it to GitHub only when asked.
#
#   Scripts/release.sh 0.1.0               → dry run: everything local (tests, universal release build, bundle checks,
#                                            .dmg + .zip + SHA-256 sums + the signed Sparkle appcast.xml in
#                                            .build/release/0.1.0/, release notes from
#                                            CHANGELOG.md, local commit "Release 0.1.0" + tag v0.1.0). Nothing leaves
#                                            the machine.
#   Scripts/release.sh 0.1.0 --publish     → the same if it hasn't run yet (or reuses its artifacts when tag v0.1.0
#                                            and .build/release/0.1.0/ already exist), then: creates the public repo
#                                            RoderickQiu/qtube-music if there is no `origin` (asks you to type
#                                            "publish" first), pushes main and the tag, and creates the GitHub Release
#                                            with the .dmg, .zip, sums and appcast.xml. Installed copies find the
#                                            update through releases/latest/download/appcast.xml.
#
# Options:
#   --no-commit      package without committing, tagging or keeping the VERSION bump (for trying the script out)
#   --arm64-only     skip the universal (arm64 + x86_64) build
#   --skip-tests     don't run `swift test` (not allowed with --publish)
#   --ad-hoc         sign ad-hoc and skip notarization, for trying the script on a Mac without the Developer ID
#                    (not allowed with --publish)
#
# Test-only environment (refused with --publish): QT_RELEASE_ANY_BRANCH=1 (run from a branch other than main),
# QT_RELEASE_ALLOW_MOCK=1 (don't fail on the demo catalog in the bundle — for trying the script before guest mode),
# QT_FEED_URL=<url> and QT_FEED_DOWNLOAD_PREFIX=<url/> (another appcast URL baked into the app and another download
# location in the appcast, for an end-to-end update test against a local feed).
#
# Before running: write the version's section in CHANGELOG.md ("## 0.1.0") and commit it; be on main with a clean
# tree. Needs Xcode 27, and `gh` signed in for --publish.
#
# Signing and notarization: the app is signed with the "Developer ID Application" identity in the login keychain
# (hardened runtime, Scripts/QTubeMusic.entitlements; Scripts/build-app.sh with QT_SIGN_ID), then notarized once (as
# a zip) and the ticket stapled to it; the .dmg is built from the stapled app and signed. The image itself isn't
# notarized: Gatekeeper judges the app at launch, not the image at mount, and one submission is one wait in Apple's
# queue (2026-11-04: 25 min for the app, hours for the image).
# notarytool reads its credentials from the keychain profile "qtube" (QT_NOTARY_PROFILE), stored once with
#   xcrun notarytool store-credentials qtube --apple-id <Apple ID> --team-id <TEAMID>   (an app-specific password)
# Updates come through Sparkle: the zip and the appcast are EdDSA-signed with the key in the login keychain (account
# "qtube-music"; Sparkle's generate_keys). Apple's signature and Sparkle's are independent: the EdDSA key never changes.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

REPO_SLUG="RoderickQiu/qtube-music"
APP_NAME="QTube Music"

usage() { sed -n '2,27p' "$0"; exit 2; }

VERSION=""; PUBLISH=0; COMMIT=1; UNIVERSAL=1; TESTS=1; ADHOC=0
for a in "$@"; do
  case "$a" in
    --publish) PUBLISH=1 ;;
    --no-commit) COMMIT=0 ;;
    --arm64-only) UNIVERSAL=0 ;;
    --skip-tests) TESTS=0 ;;
    --ad-hoc) ADHOC=1 ;;
    -h|--help) usage ;;
    -*) echo "error: unknown option $a" >&2; usage ;;
    *) [[ -z "$VERSION" ]] || { echo "error: one version only" >&2; exit 2; }; VERSION="$a" ;;
  esac
done
[[ -n "$VERSION" ]] || usage
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must look like 0.1.0" >&2; exit 2; }
(( PUBLISH == 0 || TESTS == 1 )) || { echo "error: --publish always runs the tests" >&2; exit 2; }
(( PUBLISH == 0 || COMMIT == 1 )) || { echo "error: --publish needs the release commit and tag" >&2; exit 2; }
(( PUBLISH == 0 || ADHOC == 0 )) || { echo "error: a published release is Developer ID-signed and notarized (no --ad-hoc)" >&2; exit 2; }
ANY_BRANCH="${QT_RELEASE_ANY_BRANCH:-0}"; ALLOW_MOCK="${QT_RELEASE_ALLOW_MOCK:-0}"
if (( PUBLISH == 1 )) && [[ "$ANY_BRANCH" == 1 || "$ALLOW_MOCK" == 1 || -n "${QT_FEED_URL:-}${QT_FEED_DOWNLOAD_PREFIX:-}" ]]; then
  echo "error: QT_RELEASE_ANY_BRANCH / QT_RELEASE_ALLOW_MOCK / QT_FEED_URL / QT_FEED_DOWNLOAD_PREFIX are for local tries only, not with --publish" >&2
  exit 2
fi

cd "$QT_REPO"
TAG="v$VERSION"
OUT="$QT_REPO/.build/release/$VERSION"
DMG="$OUT/QTube-Music-$VERSION.dmg"
ZIP="$OUT/QTube-Music-$VERSION.zip"
SUMS="$OUT/SHA256SUMS.txt"
APPCAST="$OUT/appcast.xml"
SPARKLE_BIN="$QT_REPO/.build/artifacts/sparkle/Sparkle/bin"
SPARKLE_ACCOUNT="qtube-music"
FEED_URL="${QT_FEED_URL:-https://github.com/$REPO_SLUG/releases/latest/download/appcast.xml}"
NOTES="$OUT/RELEASE_NOTES.md"
APP="$QT_REPO/.build/apps/$APP_NAME.app"
NOTARY_PROFILE="${QT_NOTARY_PROFILE:-qtube}"
SIGN_ID="-"

step() { printf '\n==> %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }

# MARK: Already built? (--publish after a dry run)

ALREADY_BUILT=0
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  if (( PUBLISH == 1 )) && [[ -f "$DMG" && -f "$ZIP" && -f "$SUMS" && -f "$NOTES" && -f "$APPCAST" ]]; then
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
  [[ -x "$SPARKLE_BIN/generate_appcast" ]] || fail "Sparkle's tools are missing from $SPARKLE_BIN (run swift package resolve)"
  ED_PUBLIC="$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p 2>/dev/null)" \
    || fail "no Sparkle EdDSA key for account $SPARKLE_ACCOUNT in the login keychain (import the backup: generate_keys --account $SPARKLE_ACCOUNT -f <file>)"
  grep -qF "SPARKLE_PUBLIC_KEY=\"$ED_PUBLIC\"" Scripts/build-app.sh \
    || fail "the keychain's EdDSA public key ($ED_PUBLIC) isn't the one in Scripts/build-app.sh; updates would be refused"
  if (( ADHOC == 0 )); then
    SIGN_ID="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
    [[ -n "$SIGN_ID" ]] || fail "no 'Developer ID Application' identity in the keychain (Xcode › Settings › Accounts › Manage Certificates), or pass --ad-hoc for a local try"
    TEAM_ID="$(sed -n 's/.*(\([A-Z0-9]*\))$/\1/p' <<<"$SIGN_ID")"
    echo "signing as $SIGN_ID"
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
      || fail "notarytool has no keychain profile '$NOTARY_PROFILE'; store it once:  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <Apple ID> --team-id ${TEAM_ID:-<TEAMID>}  (with an app-specific password from account.apple.com)"
  else
    echo "--ad-hoc: ad-hoc signature, no notarization (local try only)"
  fi

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
  QT_VARIANT="" QT_CONFIG=release QT_ARCHS="$ARCHS" QT_SCRATCH="$QT_REPO/.build/release-scratch" QT_FEED_URL="$FEED_URL" \
    QT_SIGN_ID="$SIGN_ID" "$QT_REPO/Scripts/build-app.sh" >"$QT_REPO/.build/release-build.log" 2>&1 \
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
  # (Output goes through a variable: with pipefail, `codesign | grep -q` fails on grep's early exit.)
  sig_info() { codesign -dvv "$1" 2>&1 || true; }
  if (( ADHOC == 0 )); then
    INFO="$(sig_info "$APP")"
    grep -qF "Authority=$SIGN_ID" <<<"$INFO" || fail "the app isn't signed by $SIGN_ID"
    grep -q "^CodeDirectory .*flags=0x[0-9a-f]*(.*runtime" <<<"$INFO" || fail "the app lacks the hardened runtime"
    # Every Mach-O in the bundle must carry the hardened runtime too, or notarization rejects the whole app.
    while IFS= read -r -d '' f; do
      [[ "$(file -b "$f")" == *Mach-O* ]] || continue
      grep -q "flags=0x[0-9a-f]*(.*runtime" <<<"$(sig_info "$f")" || fail "no hardened runtime on $f"
    done < <(find "$APP" -type f -perm -u+x -print0)
  fi
  [[ "$(plist SUFeedURL)" == "$FEED_URL" ]] || fail "Info.plist SUFeedURL isn't $FEED_URL"
  [[ "$(plist SUPublicEDKey)" == "$ED_PUBLIC" ]] || fail "Info.plist SUPublicEDKey doesn't match the signing key"
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

  # MARK: Notarize the app

  notarize() {  # notarize <file>: submit, wait, fail with Apple's log on anything but Accepted
    local f="$1" out id status
    out="$(xcrun notarytool submit "$f" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 3h 2>&1)" || true
    id="$(sed -n 's/^ *id: \([0-9a-f-]*\)$/\1/p' <<<"$out" | head -1)"
    status="$(sed -n 's/^ *status: \(.*\)$/\1/p' <<<"$out" | tail -1)"
    if [[ "$status" != Accepted ]]; then
      echo "$out" >&2
      [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
      fail "notarization of $(basename "$f") ended with '${status:-no status}'"
    fi
    echo "notarized $(basename "$f") (submission $id)"
  }

  rm -rf "$OUT"; mkdir -p "$OUT"
  if (( ADHOC == 0 )); then
    step "Notarizing the app"
    NOTARY_ZIP="$OUT/notarize-app.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARY_ZIP"
    notarize "$NOTARY_ZIP"
    rm -f "$NOTARY_ZIP"
    xcrun stapler staple -q "$APP" || fail "stapler couldn't staple the app"
    VERDICT="$(spctl --assess --type execute -vv "$APP" 2>&1 || true)"
    grep -q "source=Notarized Developer ID" <<<"$VERDICT" || { echo "$VERDICT" >&2; fail "Gatekeeper doesn't see the app as notarized (spctl --assess)"; }
    echo "stapled; Gatekeeper: Notarized Developer ID"
  fi

  # MARK: Package

  step "Packaging"
  STAGE="$(mktemp -d -t qtrelease)"
  ditto "$APP" "$STAGE/$APP_NAME.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 \
    -ov "$DMG" >/dev/null
  rm -rf "$STAGE"
  hdiutil verify "$DMG" >/dev/null 2>&1 || fail "hdiutil verify failed for the .dmg"
  if (( ADHOC == 0 )); then
    codesign --force --timestamp -s "$SIGN_ID" "$DMG" || fail "couldn't sign the .dmg"
  fi
  MNT="$(mktemp -d -t qtdmg)"
  hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MNT" "$DMG" >/dev/null
  ok=1
  codesign --verify --deep --strict "$MNT/$APP_NAME.app" || ok=0
  if (( ADHOC == 0 )); then xcrun stapler validate -q "$MNT/$APP_NAME.app" || ok=0; fi
  [[ -L "$MNT/Applications" ]] || ok=0
  hdiutil detach "$MNT" -quiet || hdiutil detach "$MNT" -force -quiet
  rmdir "$MNT" 2>/dev/null || true
  (( ok == 1 )) || fail "the mounted .dmg doesn't hold a valid, stapled app and an Applications link"
  # The Sparkle zip holds the stapled app, so an update passes Gatekeeper without a network round trip.
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  (cd "$OUT" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")") > "$SUMS"

  # Sparkle appcast: one item (this version) pointing at the release's zip, EdDSA-signed along with the feed itself
  # (SURequireSignedFeed). Release notes are the CHANGELOG section, embedded as Markdown.
  FEED_DIR="$(mktemp -d -t qtappcast)"
  cp "$ZIP" "$FEED_DIR/"
  awk -v v="## $VERSION" '$0 == v {on = 1; next} on && /^## / {exit} on' CHANGELOG.md | sed -e '/./,$!d' \
    > "$FEED_DIR/$(basename "$ZIP" .zip).md"
  "$SPARKLE_BIN/generate_appcast" --account "$SPARKLE_ACCOUNT" --embed-release-notes \
    --download-url-prefix "${QT_FEED_DOWNLOAD_PREFIX:-https://github.com/$REPO_SLUG/releases/download/$TAG/}" \
    --link "https://github.com/$REPO_SLUG" -o "$FEED_DIR/appcast.xml" "$FEED_DIR" >/dev/null \
    || fail "generate_appcast failed"
  cp "$FEED_DIR/appcast.xml" "$APPCAST"
  rm -rf "$FEED_DIR"
  grep -q 'sparkle:edSignature=' "$APPCAST" || fail "the appcast item has no EdDSA signature"
  grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST" || fail "the appcast isn't for $VERSION"

  # Release notes: the CHANGELOG section, plus how to install.
  {
    awk -v v="## $VERSION" '$0 == v {on = 1; next} on && /^## / {exit} on' CHANGELOG.md | sed -e '/./,$!d'
    cat <<EOF

### Install

Requires macOS 15 or later ($( (( UNIVERSAL == 1 )) && echo "Apple silicon and Intel" || echo "Apple silicon")).
Download \`$(basename "$DMG")\`, open it and drag **$APP_NAME** to Applications. The app is signed with a Developer
ID and notarized by Apple, so it opens like any other app. After that, it updates itself
(**QTube Music › Check for Updates…**).

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
# An unversioned copy too: qtube.r-q.name/download points at releases/latest/download/QTube-Music.dmg, so the
# website never names a version.
LATEST_DMG="$(dirname "$DMG")/QTube-Music.dmg"
cp "$DMG" "$LATEST_DMG"
gh release create "$TAG" "$DMG" "$LATEST_DMG" "$ZIP" "$SUMS" "$APPCAST" --repo "$REPO_SLUG" --title "$APP_NAME $VERSION" --notes-file "$NOTES"
echo "Published: https://github.com/$REPO_SLUG/releases/tag/$TAG"
