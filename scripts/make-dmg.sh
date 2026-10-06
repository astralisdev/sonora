#!/bin/bash
# Builds build/Sonora-<version>.dmg: a drag-to-Applications disk image with a
# background, laid out by Finder. Expects build/Sonora.app to exist.
set -euo pipefail
VERSION="${1:?usage: make-dmg.sh <version>}"
APP=build/Sonora.app
WORK=build/dmg
STAGE="$WORK/stage"
RW="$WORK/rw.dmg"
OUT="build/Sonora-$VERSION.dmg"
VOL="Sonora"

rm -rf "$STAGE" "$RW" "$OUT"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

clang -fobjc-arc -framework AppKit assets/make-dmg-background.m -o "$WORK/make-bg"
"$WORK/make-bg" "$STAGE/.background/background.png"
sips -s dpiWidth 144 -s dpiHeight 144 "$STAGE/.background/background.png" >/dev/null # show the 2x image at 660x440

hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
# Detach a leftover volume with the same name, then mount ours.
hdiutil detach "/Volumes/$VOL" -quiet 2>/dev/null || true
MOUNT=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF}')

# Finder writes the window layout into the volume's .DS_Store.
if ! osascript <<OSA
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 588}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set text size of opts to 13
        set background picture of opts to file ".background:background.png"
        set position of item "Sonora.app" of container window to {170, 220}
        set position of item "Applications" of container window to {490, 220}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
OSA
then
    echo "warning: Finder layout failed (Automation permission?); the disk image will use Finder's default layout" >&2
fi

chmod -Rf go-w "$MOUNT" || true
sync
hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
rm -f "$RW"
echo "$OUT"
