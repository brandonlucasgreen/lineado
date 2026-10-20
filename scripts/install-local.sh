#!/bin/bash
#
# Build Release, install to /Applications, and launch.
#
# Why /Applications and not a build folder: macOS keys Keychain ACLs and TCC
# decisions to a code signature *and* a path. Testing from DerivedData means
# testing a different install than the one you ship, and the difference shows up
# as a Keychain prompt you never saw in development.
#
# Usage: scripts/install-local.sh [--no-launch]
#
set -euo pipefail
cd "$(dirname "$0")/.."

LAUNCH=1
[ "${1:-}" = "--no-launch" ] && LAUNCH=0

echo "Generating project…"
xcodegen generate

echo "Building Release…"
xcodebuild -project Lineado.xcodeproj -scheme Lineado -configuration Release \
  -derivedDataPath build/Release build >/dev/null

APP="build/Release/Build/Products/Release/Lineado.app"
[ -d "$APP" ] || { echo "error: no app at $APP" >&2; exit 1; }

echo "Auditing…"
scripts/verify-bundle.sh "$APP"

if pgrep -f "Lineado.app" >/dev/null; then
  echo "Quitting the running copy…"
  pkill -f "Lineado.app" || true
  sleep 1
fi

echo "Installing to /Applications…"
rm -rf "/Applications/Lineado.app"
cp -R "$APP" /Applications/

if [ "$LAUNCH" -eq 1 ]; then
  echo "Launching…"
  open "/Applications/Lineado.app"
fi

echo "Done. Lineado is in your menu bar."
