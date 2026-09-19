#!/bin/bash
# Assemble Celeritas.app around the SwiftPM binary.
#
# The bundle is not a nicety. macOS grants Automation, Calendar and Reminders
# access to a bundle identifier, so a bare executable gets refused with no prompt
# and no explanation.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/Celeritas.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Celeritas" "$APP/Contents/MacOS/Celeritas"
# SwiftPM emits resources as a bundle beside the binary; it has to travel too.
cp -R "$BIN/Celeritas_CeleritasKit.bundle" "$APP/Contents/Resources/" 2>/dev/null || true
# LSUIElement keeps us out of the Dock, and the icon still shows in Spotlight,
# Finder and every Open With menu. Without it macOS draws a blank white tile.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Celeritas</string>
  <key>CFBundleDisplayName</key><string>Celeritas</string>
  <key>CFBundleIdentifier</key><string>co.celeritylabs.celeritas</string>
  <key>CFBundleExecutable</key><string>Celeritas</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- No Dock icon: Celeritas lives in the menu bar. -->
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Celeritas runs the action you asked for in Mail, Calendar, Notes, Reminders and Finder.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>Celeritas reads and creates events when you ask it to.</string>
  <key>NSRemindersUsageDescription</key>
  <string>Celeritas reads and creates reminders when you ask it to.</string>
</dict>
</plist>
PLIST

# An ad-hoc signature is enough for a local run, and without one macOS reissues
# the permission prompts on every rebuild because the identity keeps changing.
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (unsigned)"

# LaunchServices caches an icon against the bundle id and will keep serving the
# blank tile from before the icon existed. Re-registering is what clears it.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$PWD/$APP" 2>/dev/null || true
echo "built $APP"
