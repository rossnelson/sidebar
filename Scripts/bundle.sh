#!/bin/zsh
# Builds Sidebar.app into ./build from the SwiftPM release binary.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Sidebar"
APP=build/Sidebar.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Sidebar"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.ross.sidebar</string>
  <key>CFBundleName</key><string>Sidebar</string>
  <key>CFBundleDisplayName</key><string>Sidebar</string>
  <key>CFBundleExecutable</key><string>Sidebar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Sidebar reads and switches your Google Chrome tabs.</string>
</dict>
</plist>
PLIST

# Signs with SIDEBAR_SIGN_IDENTITY when set; otherwise ad-hoc. macOS ties the
# Accessibility permission to the signature, so ad-hoc builds need it granted again.
codesign --force --sign "${SIDEBAR_SIGN_IDENTITY:--}" --identifier com.ross.sidebar "$APP"
echo "Built $APP"
