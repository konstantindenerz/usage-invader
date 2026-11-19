#!/usr/bin/env bash
# Builds build/Agents.app (release, ad-hoc signed with the hardened runtime).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME=Agents
APP="build/${APP_NAME}.app"
RES_BUNDLE="${APP_NAME}_${APP_NAME}.bundle"

echo "==> swift build -c release"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> assembling ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# SwiftPM's Bundle.module checks Bundle.main.resourceURL first → Contents/Resources.
if [ -d "$BIN_DIR/$RES_BUNDLE" ]; then
  cp -R "$BIN_DIR/$RES_BUNDLE" "$APP/Contents/Resources/"
else
  echo "warning: $RES_BUNDLE not found in $BIN_DIR" >&2
fi

VERSION="${VERSION:-0.1.0}"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.kode.agents</string>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> codesign (ad-hoc, hardened runtime)"
codesign --force --deep --options runtime -s - "$APP"
codesign --verify --deep --strict "$APP" && echo "==> OK: $APP"
