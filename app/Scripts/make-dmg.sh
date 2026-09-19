#!/bin/bash
# Build a disk image somebody can download and drag to Applications.
#
#     ./Scripts/make-dmg.sh [version]
#
# The window has a background picture, a volume icon and the two icons placed
# where the arrow in the picture points. Finder stores all of that in a
# .DS_Store inside the image, which is why the image has to be made writable,
# mounted, arranged by AppleScript and only then compressed.
#
# The app inside is ad-hoc signed, because notarising needs a paid Apple
# Developer ID and there is not one. macOS refuses to open it on the first
# attempt, so the background picture says so and the readme says how to get
# past it. An installer that quietly fails is worse than no installer.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Celeritas.app"
VERSION="${1:-$(date +%Y.%m.%d)}"
VOLUME="Celeritas"
STAGE="build/dmg"
TEMP="build/Celeritas-rw.dmg"
OUT="build/Celeritas-$VERSION.dmg"
BACKGROUND="Resources/dmg-background.tiff"

# Icon centres in the 660 by 400 window. These match the ones in
# Scripts/make-dmg-background.py, where the arrow between them is drawn.
APP_X=180
APP_Y=168
DEST_X=480
DEST_Y=168

[ -d "$APP" ] || { echo "no app at $APP. Run ./Scripts/build-app.sh first."; exit 1; }
[ -f "$BACKGROUND" ] || { echo "no background. Run ./Scripts/make-dmg-background.py first."; exit 1; }

# A half-mounted image from a failed run holds the name and makes the next run
# mount as "Celeritas 1", which lays the icons out in the wrong window.
hdiutil detach "/Volumes/$VOLUME" -force >/dev/null 2>&1 || true
rm -rf "$STAGE" "$TEMP" "$OUT"

mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
cp "$BACKGROUND" "$STAGE/.background/background.tiff"

# The drop target. A symlink was the obvious way to do this and Finder drew it
# as an empty dashed square, because a symlink cannot carry an icon of its own:
# setting one writes to /Applications instead. An alias is a real file, so it
# can hold the system's Applications icon and look like the thing it is.
osascript <<ALIAS >/dev/null
tell application "Finder"
  set made to make alias file to POSIX file "/Applications" at POSIX file "$(cd "$STAGE" && pwd)"
  set name of made to "Applications"
end tell
ALIAS
./Scripts/set-icon.swift \
  /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns \
  "$STAGE/Applications"

# Room for the app plus the .DS_Store Finder is about to write. Sizing this
# exactly is what makes hdiutil fail with "no space left" halfway through.
SIZE=$(( $(du -sk "$STAGE" | cut -f1) + 20000 ))
hdiutil create -volname "$VOLUME" -srcfolder "$STAGE" -ov \
  -fs HFS+ -format UDRW -size "${SIZE}k" -quiet "$TEMP"

# awk, not cut: hdiutil pads the device column with spaces and a padded
# name makes the detach at the end fail.
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP" | grep '^/dev/' | head -1 | awk '{print $1}')
sleep 2

osascript <<SCRIPT
tell application "Finder"
  tell disk "$VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    -- 660 by 400 of picture, plus 28 points of title bar. Finder adds a path
    -- bar on top of that if the reader has one turned on, which takes another
    -- 24 points off the bottom, so nothing important sits below y=370 in the
    -- background picture.
    set the bounds of container window to {200, 120, 860, 548}
    set options to the icon view options of container window
    set arrangement of options to not arranged
    set icon size of options to 128
    set text size of options to 12
    set background picture of options to file ".background:background.tiff"
    set position of item "Celeritas.app" of container window to {$APP_X, $APP_Y}
    set position of item "Applications" of container window to {$DEST_X, $DEST_Y}
    close
    open
    update without registering applications
    delay 2
  end tell
end tell
SCRIPT

# The volume icon, so the thing on the desktop and in the sidebar is the app
# and not a grey disk. This has to happen on the mounted volume: a
# .VolumeIcon.icns placed in the staging folder does not survive hdiutil.
cp Resources/AppIcon.icns "/Volumes/$VOLUME/.VolumeIcon.icns"
SetFile -a C "/Volumes/$VOLUME"

chmod -Rf go-w "/Volumes/$VOLUME" 2>/dev/null || true
sync
hdiutil detach "$DEVICE" -quiet
hdiutil convert "$TEMP" -format UDZO -imagekey zlib-level=9 -o "$OUT" -quiet
rm -rf "$STAGE" "$TEMP"

# Sign and notarise, when there is an account to do it with. Without this the
# reader gets "Apple could not verify Celeritas is free of malware" and one
# Done button, and has to go to System Settings to get past it. With it they
# get "Apple checked it for malicious software and none was detected" and an
# Open button, because the notary service scanned the file and the ticket
# stapled below is Apple's receipt travelling inside the download.
#
#     SIGN_IDENTITY="Developer ID Application: <Entity> (TEAMID)" \
#     NOTARY_PROFILE=celerity ./Scripts/make-dmg.sh
#
# Store the profile once, so no password is ever on a command line:
#
#     xcrun notarytool store-credentials celerity \
#       --apple-id <apple id> --team-id <TEAMID> --password <app-specific password>
#
# The app inside has to be signed too, with the hardened runtime and a
# timestamp. build-app.sh does that when SIGN_IDENTITY is set, and the notary
# service rejects the submission if it was not.
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$OUT"
  echo "  signed the disk image"
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "  submitting to Apple, this takes a few minutes"
  xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUT"
  xcrun stapler validate "$OUT"
fi

echo
echo "  $OUT"
echo "  $(du -h "$OUT" | cut -f1)"
echo "  sha256 $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
echo
codesign -dv "$APP" 2>&1 | grep -E "Signature|TeamIdentifier" | sed 's/^/  /'
echo "  Gatekeeper: $(spctl -a -vv "$APP" 2>&1 | tail -1 | tr -d '\n')"
echo
if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "  Notarised. The first open offers Open, with no trip to System Settings."
else
  echo "  Ad-hoc signed, so macOS blocks the first open. The only route on"
  echo "  macOS 26 is System Settings, Privacy & Security, Open Anyway, after"
  echo "  an open has already been refused once."
  echo "  Set SIGN_IDENTITY and NOTARY_PROFILE to change that."
fi
