#!/bin/zsh
# Packs Shiftio.app into a styled installer image: the app on the left, an Applications shortcut on the right, a thin arrow
# between them on a plain light background picture (scripts/dmg-background.png; redraw it with make-dmg-background.py).
# The disk's icon is the app's icon. SetFile comes with the Xcode command line tools.
#
#   scripts/make-dmg.sh <path to Shiftio.app> <output .dmg>
#
# The window layout is set through Finder (AppleScript), so the first run may ask whether the terminal may control Finder.
set -euo pipefail
# Paths are made absolute first: the script changes into its own folder.
APP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
mkdir -p "$(dirname "$2")"
OUT="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
cd "$(dirname "$0")"
VOL="${DMG_VOLUME:-Shiftio}"
[[ -e "/Volumes/$VOL" ]] && { echo "A volume named $VOL is already mounted. Eject it first (Finder asks which disk to style by name)."; exit 1; }
STAGE="$(mktemp -d)"
RW="$(mktemp -u).dmg"

cp -R "$APP" "$STAGE/Shiftio.app"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp dmg-background.png "$STAGE/.background/background.png"

hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ "$RW" >/dev/null
DEVICE="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk '/Apple_HFS/ {print $1; exit}')"
sleep 2

osascript <<OSA
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 680, 420}
    set options to the icon view options of container window
    set arrangement of options to not arranged
    set icon size of options to 96
    set text size of options to 12
    set background picture of options to (POSIX file "/Volumes/$VOL/.background/background.png" as alias)
    set position of item "Shiftio.app" of container window to {130, 150}
    set position of item "Applications" of container window to {350, 150}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
OSA

# The mounted disk wears the app's icon instead of the generic drive.
cp "$APP/Contents/Resources/AppIcon.icns" "/Volumes/$VOL/.VolumeIcon.icns"
SetFile -a C "/Volumes/$VOL"
SetFile -a V "/Volumes/$VOL/.VolumeIcon.icns"

sync
hdiutil detach "$DEVICE" -quiet || { sleep 2; hdiutil detach "$DEVICE" -force -quiet; }
rm -f "$OUT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
rm -rf "$STAGE" "$RW"
