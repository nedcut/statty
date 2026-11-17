#!/bin/bash
# Builds Statty.app into build/ and, with --install, copies it to ~/Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/Statty.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Statty "$APP/Contents/MacOS/Statty"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Statty</string>
  <key>CFBundleDisplayName</key><string>Statty</string>
  <key>CFBundleIdentifier</key><string>dev.statty.Statty</string>
  <key>CFBundleExecutable</key><string>Statty</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Statty || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Statty.app"
  cp -R "$APP" "$HOME/Applications/"
  open "$HOME/Applications/Statty.app"
  echo "Installed and launched ~/Applications/Statty.app"
fi
