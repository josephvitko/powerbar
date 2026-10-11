#!/bin/zsh
# Builds build/PowerBar.app.
#   VERSION        version string (default: 0.0.0-dev)
#   SIGN_IDENTITY  codesign identity (default: "-", ad-hoc). A real identity also enables
#                  the hardened runtime and a secure timestamp, as notarization requires.
set -euo pipefail
cd "${0:A:h}/.."

VERSION="${VERSION:-0.0.0-dev}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP=build/PowerBar.app

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -target "arm64-apple-macos13.0" -o "$APP/Contents/MacOS/PowerBar" Sources/*.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PowerBar</string>
  <key>CFBundleDisplayName</key><string>PowerBar</string>
  <key>CFBundleIdentifier</key><string>io.vitko.powerbar</string>
  <key>CFBundleExecutable</key><string>PowerBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Joseph Vitko. MIT License.</string>
</dict>
</plist>
PLIST

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP ($VERSION, build $BUILD_NUMBER)"
