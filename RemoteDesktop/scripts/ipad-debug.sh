#!/bin/bash
# Build, install, and launch RemoteDesktopApp on physical iPad with console log capture.
# Usage: ./RemoteDesktop/scripts/ipad-debug.sh [timeout_seconds]
# Default timeout: 60 seconds. Ctrl+C to stop early.
#
# User does: physical actions on iPad only (tap buttons, scan QR codes, etc.)
# This script does: build, install, launch, capture stdout logs, report.

set -euo pipefail

LOCKFILE="/tmp/keyd-ipad-debug.lock"
if [ -f "$LOCKFILE" ]; then
  OLD_PID=$(cat "$LOCKFILE" 2>/dev/null)
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Killing previous ipad-debug.sh (PID $OLD_PID)"
    kill "$OLD_PID" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"; kill $PID 2>/dev/null' EXIT

WORKSPACE="RemoteDesktop/RemoteDesktop.xcworkspace"
SCHEME="RemoteDesktopApp"
BUNDLE_ID="com.ryheff.keyd.remote.app"
DEVICE_ID="00000000-0000-0000-0000-00000000000A"
XCODE_DEVICE_ID="00000000-00000000000000A1"
CONFIG="Debug"
TIMEOUT="${1:-60}"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"

cd "$(git rev-parse --show-toplevel)"

echo "=== Building $SCHEME for iPad ==="
xcodebuild \
  -workspace "$WORKSPACE" \
  -scheme "$SCHEME" \
  -destination "id=$DEVICE_ID" \
  -configuration "$CONFIG" \
  build 2>&1 | grep -E "(error:|warning:|BUILD)" | tail -5

APP_PATH=$(find "$DERIVED_DATA" -path "*RemoteDesktop*" -name "RemoteDesktopApp.app" -path "*/Debug-iphoneos/*" -not -path "*/Index.noindex/*" 2>/dev/null | head -1)
if [ -z "$APP_PATH" ]; then
  echo "ERROR: Could not find built .app bundle"
  exit 1
fi

echo ""
echo "=== Installing on iPad ==="
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" 2>&1 | grep -E "(bundleID|error|ERROR)" || true

echo ""
echo "=== Launching with console (${TIMEOUT}s timeout) ==="
echo "=== Perform actions on iPad now ==="
echo ""

xcrun devicectl device process launch \
  --device "$DEVICE_ID" \
  --terminate-existing \
  --console \
  "$BUNDLE_ID" 2>&1 &
PID=$!

sleep "$TIMEOUT"
kill $PID 2>/dev/null
wait $PID 2>/dev/null

echo ""
echo "=== Done ==="
