#!/usr/bin/env bash
#
# Build a Release IRIS.app and install it to /Applications so you can run it like
# a normal Mac app -- double-click / Spotlight / Login Items, no Xcode to launch.
#
# Building needs Xcode (the full app) + xcodegen. RUNNING the installed app needs
# neither -- macOS ships the Swift runtime. So this is for whoever builds; people
# you share a built .app with don't need any of this.
#
# Usage:  ./scripts/install-app.sh
#
set -euo pipefail

APP_NAME="IRIS"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="${ROOT}/build"
BUILT="${DERIVED}/Build/Products/Release/${APP_NAME}.app"
DEST="/Applications/${APP_NAME}.app"

cd "${ROOT}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found. Install it:  brew install xcodegen" >&2
  exit 1
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "error: Xcode not found. Building from source needs the full Xcode (not just CLT)." >&2
  echo "       Install Xcode from the App Store, then: sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi

echo "==> Generating Xcode project (xcodegen)..."
xcodegen generate >/dev/null

echo "==> Building Release (Xcode needed for this step; running the app later is not)..."
xcodebuild \
  -project "${APP_NAME}.xcodeproj" \
  -scheme "${APP_NAME}" \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "${DERIVED}" \
  build

[ -d "${BUILT}" ] || { echo "error: build succeeded but ${BUILT} not found" >&2; exit 1; }

echo "==> Quitting any running ${APP_NAME}..."
osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true
sleep 1

echo "==> Installing to ${DEST}..."
rm -rf "${DEST}"
cp -R "${BUILT}" "${DEST}"

echo "==> Launching..."
open "${DEST}"

echo ""
echo "Installed ${APP_NAME} to /Applications and launched it."
echo "It runs in the menu bar (the eye icon) -- no dock icon, no Xcode needed to run it."
echo "To start it at login: System Settings > General > Login Items > add IRIS."
