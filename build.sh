#!/bin/zsh
# Development build: builds PowerBar.app, installs it to ~/Applications, and relaunches it.
set -euo pipefail
cd "${0:A:h}"

APP="$HOME/Applications/PowerBar.app"
scripts/build-app.sh
pkill -x PowerBar 2>/dev/null && sleep 0.5 || true
rm -rf "$APP" && mkdir -p "$HOME/Applications" && cp -R build/PowerBar.app "$APP"
open "$APP"
echo "Installed and launched $APP"
