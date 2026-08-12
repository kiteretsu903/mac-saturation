#!/bin/bash
# Builds the satctl CLI and the Saturation.app menu bar app.
set -euo pipefail
cd "$(dirname "$0")"

echo "building satctl…"
swiftc -O -target arm64-apple-macos14.0 Sources/Shared/*.swift Sources/satctl/*.swift -o satctl

echo "building Saturation.app…"
swiftc -O -parse-as-library -target arm64-apple-macos14.0 Sources/Shared/*.swift Sources/SatMenu/*.swift -o satmenu

APP="Saturation.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mv satmenu "$APP/Contents/MacOS/Saturation"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>Saturation</string>
  <key>CFBundleDisplayName</key>     <string>Saturation</string>
  <key>CFBundleIdentifier</key>      <string>local.satctl.Saturation</string>
  <key>CFBundleVersion</key>         <string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleExecutable</key>      <string>Saturation</string>
  <!-- Menu bar only: no Dock icon, no app switcher entry. -->
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSUIElement</key>             <true/>
  <key>LSMinimumSystemVersion</key>  <string>14.0</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS will launch it locally without a developer ID.
codesign --force --sign - "$APP" 2>/dev/null || \
  echo "  (codesign unavailable — the app will still run)"

echo
echo "done:"
echo "  ./satctl list"
echo "  open $APP"
