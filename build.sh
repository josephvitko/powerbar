#!/bin/zsh
# Builds PowerBar.app and installs it to ~/Applications.
set -euo pipefail
cd "${0:A:h}"

APP="$HOME/Applications/PowerBar.app"
rm -rf build && mkdir -p build/PowerBar.app/Contents/MacOS
swiftc -O -target "$(uname -m)-apple-macos13.0" -o build/PowerBar.app/Contents/MacOS/PowerBar Sources/*.swift

cat > build/PowerBar.app/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PowerBar</string>
  <key>CFBundleIdentifier</key><string>io.vitko.powerbar</string>
  <key>CFBundleExecutable</key><string>PowerBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - build/PowerBar.app
pkill -x PowerBar 2>/dev/null || true
rm -rf "$APP" && mkdir -p "$HOME/Applications" && cp -R build/PowerBar.app "$APP"
open "$APP"
echo "Installed and launched $APP"
