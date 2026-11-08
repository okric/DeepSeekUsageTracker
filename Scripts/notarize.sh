#!/bin/zsh
# Sign, notarize, staple, and publish the DeepseekUsageTracker release DMG.
# Requires: the Developer ID Application identity in the keychain and
# `xcrun notarytool store-credentials "okric-notary"` (see project README).
set -euo pipefail

APP_NAME="DeepseekUsageTracker"
IDENTITY="Developer ID Application: Ricardo Oliveira (2SD8E9M8T7)"
KEYCHAIN_PROFILE="okric-notary"
REPO="okric/${APP_NAME}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Version tracks the project's MARKETING_VERSION.
VERSION="$(sed -n 's/^[[:space:]]*MARKETING_VERSION = //p' "$ROOT/${APP_NAME}.xcodeproj/project.pbxproj" | head -1 | tr -d " ;")"
[ -n "$VERSION" ] || { echo "MARKETING_VERSION not found"; exit 1; }
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
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$STAGE"
codesign --verify --deep --strict "$STAGE"

echo "== notarize (submit + wait) =="
ditto -c -k --keepParent "$STAGE" "$WORK/submit.zip"
xcrun notarytool submit "$WORK/submit.zip" --keychain-profile "$KEYCHAIN_PROFILE" --wait

echo "== staple =="
xcrun stapler staple "$STAGE"
spctl -a -t exec -vv "$STAGE"

echo "== DMG =="
STAGE_DIR="$WORK/${APP_NAME} ${VERSION}"
mkdir -p "$STAGE_DIR"
mv "$STAGE" "$STAGE_DIR/${APP_NAME}.app"
ln -s /Applications "$STAGE_DIR/Applications"
DMG="$WORK/${APP_NAME}-${VERSION}.dmg"
hdiutil create -quiet -volname "${APP_NAME} ${VERSION}" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG"
shasum -a 256 "$DMG"

echo "== publish =="
if ! gh release view "v${VERSION}" --repo "$REPO" >/dev/null 2>&1; then
    gh release create "v${VERSION}" \
        --repo "$REPO" \
        --title "${APP_NAME} ${VERSION}" \
        --notes "Universal binary, hardened runtime, Developer ID signed and Apple-notarized. Staged manually, see release notes below."
fi
gh release upload "v${VERSION}" --repo "$REPO" "$DMG" --clobber
echo "Done: https://github.com/$REPO/releases/tag/v${VERSION}"
rm -rf "$ROOT/build/release"
