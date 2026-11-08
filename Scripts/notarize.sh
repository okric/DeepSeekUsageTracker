#!/bin/zsh
# Sign, notarize, staple, and publish the DeepseekUsageTracker release DMG.
# Requires: the Developer ID Application identity in the keychain and
# `xcrun notarytool store-credentials "okric-notary"` (see project README).
set -euo pipefail

APP_NAME="DeepseekUsageTracker"
IDENTITY="Developer ID Application: Ricardo Oliveira (2SD8E9M8T7)"
KEYCHAIN_PROFILE="okric-notary"
REPO="okric/${APP_NAME}"
# Sparkle: account name of the EdDSA key in the login keychain, and the
# tools from https://github.com/sparkle-project/Sparkle/releases.
SPARKLE_ACCOUNT="okric"
SPARKLE_BIN="${SPARKLE_BIN:-$HOME/.local/share/sparkle/2.10.1/bin}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PBXPROJ="$ROOT/${APP_NAME}.xcodeproj/project.pbxproj"
# Version tracks the project's MARKETING_VERSION, bumped by 0.0.1 on each
# publish. Set VERSION_OVERRIDE to publish an exact version (e.g. a minor bump).
old="$(sed -n 's/^[[:space:]]*MARKETING_VERSION = //p' "$PBXPROJ" | head -1 | tr -d " ;")"
[ -n "$old" ] || { echo "MARKETING_VERSION not found"; exit 1; }
if [ -n "${VERSION_OVERRIDE:-}" ]; then
  VERSION="$VERSION_OVERRIDE"
else
  major=${old%%.*}; minor_patch=${old#*.}
  minor=${minor_patch%%.*}; patch=${minor_patch#*.}
  VERSION="${major}.${minor}.$((patch + 1))"
fi
# Sparkle compares CFBundleVersion, so it must increase with every release.
IFS=. read -r v_major v_minor v_patch <<< "$VERSION"
BUILD=$((v_major * 10000 + v_minor * 100 + v_patch))
/usr/bin/sed -i '' "s/MARKETING_VERSION = ${old};/MARKETING_VERSION = ${VERSION};/g" "$PBXPROJ"
/usr/bin/sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9][0-9]*;/CURRENT_PROJECT_VERSION = ${BUILD};/g" "$PBXPROJ"
echo "Version: ${old} -> ${VERSION} (build ${BUILD})"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== build Release =="
xcodebuild -project "$ROOT/${APP_NAME}.xcodeproj" \
  -scheme "$APP_NAME" -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$ROOT/build/release" build \
  | tail -1

APP="$ROOT/build/release/Build/Products/Release/${APP_NAME}.app"
STAGE="$WORK/${APP_NAME}"
cp -R "$APP" "$STAGE"

echo "== Developer ID sign =="
# Sign inside-out with --deep. Sparkle ships a framework signed by the Sparkle
# team; every nested helper (Autoupdate, Updater.app, XPC services) must end up
# signed by us, or Gatekeeper reports "Unnotarized Developer ID" even though
# the ticket is valid. Manual per-item signing was not enough here.
codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$STAGE"
codesign --verify --deep --strict "$STAGE"

echo "== notarize (submit + wait) =="
ditto -c -k --keepParent "$STAGE" "$WORK/submit.zip"
xcrun notarytool submit "$WORK/submit.zip" --keychain-profile "$KEYCHAIN_PROFILE" --wait

echo "== staple =="
xcrun stapler staple "$STAGE"
# Hard gate: never publish an app that Gatekeeper rejects.
spctl -a -t exec -vv "$STAGE"

echo "== DMG =="
STAGE_DIR="$WORK/${APP_NAME} ${VERSION}"
mkdir -p "$STAGE_DIR"
mv "$STAGE" "$STAGE_DIR/${APP_NAME}.app"
DMG="$WORK/${APP_NAME}-${VERSION}.dmg"
create-dmg \
  --volname "${APP_NAME} ${VERSION}" \
  --background "$ROOT/Scripts/dmg-background.png" \
  --window-size 800 470 \
  --icon-size 128 \
  --icon "${APP_NAME}.app" 200 280 \
  --app-drop-link 600 280 \
  --hide-extension "${APP_NAME}.app" \
  "$DMG" "$STAGE_DIR"
"$ROOT/Scripts/postprocess-dmg.sh" "$DMG" "${APP_NAME} ${VERSION}" "$ROOT/Scripts/dmg-background@2x.png" "${APP_NAME}.app"

echo "== cleanup staging =="
rm -rf "$STAGE_DIR"
shasum -a 256 "$DMG"

echo "== publish =="
if ! gh release view "v${VERSION}" --repo "$REPO" >/dev/null 2>&1; then
    gh release create "v${VERSION}" \
        --repo "$REPO" \
        --title "${APP_NAME} ${VERSION}" \
        --notes "Universal binary, hardened runtime, Developer ID signed and Apple-notarized. Staged manually, see release notes below."
fi
gh release upload "v${VERSION}" --repo "$REPO" "$DMG" --clobber

echo "== appcast =="
# Sparkle reads SUFeedURL, which points at the newest release's appcast:
#   https://github.com/$REPO/releases/latest/download/appcast.xml
APPDIR="$WORK/appcast"
mkdir -p "$APPDIR"
cp "$DMG" "$APPDIR/"
"$SPARKLE_BIN/generate_appcast" \
  --account "$SPARKLE_ACCOUNT" \
  --download-url-prefix "https://github.com/${REPO}/releases/download/v${VERSION}/" \
  --link "https://github.com/${REPO}" \
  "$APPDIR"
gh release upload "v${VERSION}" --repo "$REPO" "$APPDIR/appcast.xml" --clobber

echo "Done: https://github.com/$REPO/releases/tag/v${VERSION}"

echo "== cleanup =="
rm -rf "$ROOT/build"   # Release build + any DMG staging/tmp leftovers under build/
# Xcode's own build cache for this project (created by xcodebuild -list, IDE runs)
rm -rf "$HOME/Library/Developer/Xcode/DerivedData/${APP_NAME}-"*
