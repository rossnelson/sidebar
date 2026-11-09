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

# macOS ties the Accessibility permission to the signature. A stable certificate
# keeps the permission across rebuilds; an ad-hoc signature changes every build.
# Order: SIDEBAR_SIGN_IDENTITY, then a local "Sidebar Local Signing" certificate
# (see README), then ad-hoc.
IDENTITY="${SIDEBAR_SIGN_IDENTITY:-}"
if [[ -z $IDENTITY ]]; then
  IDENTITY=$(security find-identity -p codesigning 2>/dev/null \
    | awk '/"Sidebar Local Signing"/ { print $2; exit }')
fi
codesign --force --sign "${IDENTITY:--}" --identifier com.ross.sidebar "$APP"
[[ -n $IDENTITY ]] && echo "Signed with $IDENTITY" || echo "Signed ad-hoc"
echo "Built $APP"
