#!/bin/bash
# Builds Reclaim.app with only the Command Line Tools (no Xcode needed).
# Usage: ./scripts/build_app.sh          then: open Reclaim.app
set -euo pipefail
cd "$(dirname "$0")/.."

APP="Reclaim.app"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Reclaim"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Reclaim"

# App icon
ICON_DIR="$(mktemp -d)"
if swift scripts/make_icon.swift "$ICON_DIR/icon.png" 2>/dev/null; then
    mkdir "$ICON_DIR/AppIcon.iconset"
    for s in 16 32 64 128 256 512; do
        sips -z $s $s "$ICON_DIR/icon.png" --out "$ICON_DIR/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
        d=$((s * 2))
        sips -z $d $d "$ICON_DIR/icon.png" --out "$ICON_DIR/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICON_DIR/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns" || true
fi
rm -rf "$ICON_DIR"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Reclaim</string>
    <key>CFBundleDisplayName</key><string>Reclaim</string>
    <key>CFBundleIdentifier</key><string>com.craigarmitage.reclaim</string>
    <key>CFBundleExecutable</key><string>Reclaim</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>When uninstalling an app that macOS protects, Reclaim asks Finder to move it to the Trash so macOS can request your administrator password.</string>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>Reclaim looks for near-identical photos in your library. It only reads photos already on this Mac, and deletes nothing without your approval in Reclaim and in Photos.</string>
</dict>
</plist>
PLIST

# Sign with the permanent local identity when it exists, so macOS keeps Full Disk Access across rebuilds.
# (Ad-hoc signatures change on every build, and TCC silently drops the grant each time.)
IDENTITY="Reclaim Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    codesign --force --options runtime --timestamp=none --entitlements scripts/Reclaim.entitlements --sign "$IDENTITY" "$APP"
    echo "Signed with $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "WARNING: '$IDENTITY' identity not found; signed ad hoc (permissions will reset on rebuild)"
fi
# Keep a copy on the internal drive so the app still opens when the external drive is unplugged.
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/$APP"
cp -R "$APP" "$HOME/Applications/$APP"
echo "Built $(pwd)/$APP and installed ~/Applications/$APP"
