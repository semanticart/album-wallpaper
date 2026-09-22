#!/bin/sh
# Builds AlbumArtWallpaper.app (a menu bar app) next to this script.
set -e
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/AlbumArtWallpaper"

APP=AlbumArtWallpaper.app
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/AlbumArtWallpaper"

# AppIcon.icns and MenuBarIcon.png are checked in; regenerate them from the SVGs with Resources/make-icon.sh.
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns Resources/MenuBarIcon.png "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.semanticart.AlbumArtWallpaper</string>
    <key>CFBundleName</key><string>AlbumArtWallpaper</string>
    <key>CFBundleExecutable</key><string>AlbumArtWallpaper</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>AlbumArtWallpaper asks Music which song is playing so it can use the album art as your wallpaper.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP — run with: open $APP"
