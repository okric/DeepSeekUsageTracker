#!/bin/zsh
# Post-processes a create-dmg image: hides the .background folder, enforces the
# 800x470 window bounds with icons at (200,280) and (600,280), then repacks.
# Usage: postprocess-dmg.sh <path.dmg> <volname> [<background@2x.png>] [<app-item-name>]
set -euo pipefail

DMG="${1:?usage: postprocess-dmg.sh <path.dmg> <volname> [<background@2x.png>] [<app-item-name>]}"
APP_NAME="${2:?}"
BG2X="${3:-}"
APP_ITEM="${4:-${APP_NAME}.app}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; [ -n "${MOUNT_DIR:-}" ] && hdiutil detach "$MOUNT_DIR" -force 2>/dev/null || true' EXIT

echo "== convert to RW for editing =="
RAW="$WORK/rw.dmg"
hdiutil convert "$DMG" -format UDRW -o "$RAW" -quiet
MOUNT_DIR=$(hdiutil attach "$RAW" | awk -F'\t' '/Volumes/{print $NF}')
echo "mounted at: $MOUNT_DIR"
[ -n "$MOUNT_DIR" ] && [ -d "$MOUNT_DIR" ]
# give Finder time to register the volume, else tell disk fails (-1728)
sleep 5
VOLNAME="${MOUNT_DIR##*/}"   # last path segment of the mount dir is the volume name

echo "== hide .background =="
/usr/bin/chflags hidden "$MOUNT_DIR/.background" 2>/dev/null || true
/usr/bin/SetFile -a V "$MOUNT_DIR/.background" 2>/dev/null || true
if [ -n "$BG2X" ] && [ -f "$BG2X" ]; then
    cp "$BG2X" "$MOUNT_DIR/.background/background@2x.png"
    /usr/bin/SetFile -a V "$MOUNT_DIR/.background/background@2x.png"
fi

echo "== enforce window geometry + icon layout =="
/usr/bin/osascript <<EOF
tell application "Finder"
	tell disk "$VOLNAME"
		open
		set current view of container window to icon view
		set toolbar visible of container window to false
		set statusbar visible of container window to false
		set the bounds of container window to {400, 200, 1200, 670}
		set viewOptions to the icon view options of container window
		set arrangement of viewOptions to not arranged
		set icon size of viewOptions to 128
		set position of item "$APP_ITEM" of container window to {200, 280}
		set position of item "Applications" of container window to {600, 280}
		close
		open
		update without registering applications
	end tell
end tell
EOF

echo "== let Finder flush .DS_Store =="
sleep 4
sync
hdiutil detach "$MOUNT_DIR" -quiet

echo "== repack =="
FINAL="$WORK/final.dmg"
hdiutil convert "$RAW" -quiet -format UDZO -o "$FINAL"
mv "$FINAL" "$DMG"
echo "postprocessed $DMG"
