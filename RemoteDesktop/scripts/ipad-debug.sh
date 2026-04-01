#!/bin/bash
# Build, install, and launch RemoteDesktopApp on physical iPad with console log capture.
# Usage: ./RemoteDesktop/scripts/ipad-debug.sh [timeout_seconds]
# Default timeout: 60 seconds. Ctrl+C to stop early.
#
# User does: physical actions on iPad only (tap buttons, scan QR codes, etc.)
# This script does: build, install, launch, capture stdout logs, report.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/async-index.sh"

LOCKFILE="/tmp/keyd-ipad-debug.lock"
if [ -f "$LOCKFILE" ]; then
  OLD_PID=$(cat "$LOCKFILE" 2>/dev/null || true)
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Killing previous ipad-debug.sh (PID $OLD_PID)"
    kill "$OLD_PID" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"

LAUNCH_PID=""
cleanup() {
  [ -n "$LAUNCH_PID" ] && kill "$LAUNCH_PID" 2>/dev/null || true
  [ -n "$LAUNCH_PID" ] && wait "$LAUNCH_PID" 2>/dev/null || true
  rm -f "$LOCKFILE"
}
trap cleanup EXIT

WORKSPACE="RemoteDesktop/RemoteDesktop.xcworkspace"
SCHEME="RemoteDesktopApp"
BUNDLE_ID="com.ryheff.keyd.remote.app"
DEVICE_ID="00000000-0000-0000-0000-00000000000A"
CONFIG="Release"
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

start_async_index "ipad-debug.sh"

APP_PATH=$(find "$DERIVED_DATA" -path "*RemoteDesktop*" -name "RemoteDesktopApp.app" -path "*/Release-iphoneos/*" -not -path "*/Index.noindex/*" 2>/dev/null | head -1)
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
LAUNCH_PID=$!

sleep "$TIMEOUT"
# cleanup runs via trap
exit 0
