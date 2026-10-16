#!/bin/zsh
# Builds Resources/AppIcon.icns from square artwork: scripts/make-icon.sh <art.png|webp>
# (rounded-square body + shadow via make-icon.swift, then every size macOS uses).
set -euo pipefail
cd "$(dirname "$0")/.."
ART="$1"; W=Resources/icon; mkdir -p $W
sips -s format png "$ART" --out $W/art.png >/dev/null
swift scripts/make-icon.swift $W/art.png $W/AppIcon-1024.png
rm -rf $W/AppIcon.iconset && mkdir $W/AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s $W/AppIcon-1024.png --out $W/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) $W/AppIcon-1024.png --out $W/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $W/AppIcon.iconset -o Resources/AppIcon.icns
echo "Built Resources/AppIcon.icns — run scripts/build-app.sh to use it"
