#!/bin/bash
# Render Resources/AppIcon.svg into Resources/AppIcon.icns.
#
# Kept in the repo because the .icns is a binary nobody can edit or regenerate
# without knowing the recipe. Needs librsvg: brew install librsvg.
set -euo pipefail
cd "$(dirname "$0")/.."

SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  rsvg-convert -w "$s"           -h "$s"           Resources/AppIcon.svg -o "$SET/icon_${s}x${s}.png"
  rsvg-convert -w "$((s * 2))"   -h "$((s * 2))"   Resources/AppIcon.svg -o "$SET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "built Resources/AppIcon.icns"
