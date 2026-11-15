#!/bin/bash
# build.sh <dest.app> — compile main.swift into a menu-bar app bundle and sign it ad hoc.
# Needs the Xcode Command Line Tools (xcode-select --install). No Xcode project, no dependencies.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="${1:?usage: build.sh <path/Mac mini VPN.app> [bundle-id]}"
BUNDLE_ID="${2:-com.macminivpn.app}"
VERSION="1.0"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O "$HERE/main.swift" -o "$APP/Contents/MacOS/MacminiVPN"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>MacminiVPN</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Mac mini VPN</string>
  <key>CFBundleDisplayName</key><string>Mac mini VPN</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "built $APP"
