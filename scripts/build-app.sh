#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="$PWD/build/Mac Jams.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
./scripts/build-icon.sh
cp "$PWD/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp Assets/AppIcon.png "$APP/Contents/Resources/LooperArtwork.png"
# Replace the executable atomically. A running app keeps its original inode;
# overwriting that mapped executable in place can invalidate its code pages.
cp "$BIN/MacLooper" "$APP/Contents/MacOS/MacLooper.next"
chmod 755 "$APP/Contents/MacOS/MacLooper.next"
mv -f "$APP/Contents/MacOS/MacLooper.next" "$APP/Contents/MacOS/MacLooper"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MacLooper</string>
<key>CFBundleIdentifier</key><string>local.thoppe.maclooper</string>
<key>CFBundleName</key><string>Mac Jams</string>
<key>CFBundleDisplayName</key><string>Mac Jams</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>6</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSMicrophoneUsageDescription</key><string>Mac Jams listens to your AM4 guitar input to trigger and capture a loop. Live input is never monitored through the app.</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
# Stable local identity avoids asking for microphone permission on every rebuild.
codesign --force --sign - --identifier local.thoppe.maclooper \
    --requirements '=designated => identifier "local.thoppe.maclooper"' "$APP"
printf '\nBuilt: %s\n' "$APP"
