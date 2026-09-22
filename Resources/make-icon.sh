#!/bin/sh
# Regenerates AppIcon.icns from AppIcon.svg and MenuBarIcon.png from MenuBarIcon.svg. Needs rsvg-convert (brew install librsvg).
set -e
cd "$(dirname "$0")"

SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
    rsvg-convert -w "$s" -h "$s" AppIcon.svg -o "$SET/icon_${s}x${s}.png"
    rsvg-convert -w $((s * 2)) -h $((s * 2)) AppIcon.svg -o "$SET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$SET" -o AppIcon.icns
rsvg-convert -w 36 -h 36 MenuBarIcon.svg -o MenuBarIcon.png
echo "Wrote Resources/AppIcon.icns and Resources/MenuBarIcon.png"
