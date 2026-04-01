#!/bin/bash
# Build, install, and launch RemoteDesktopApp on the connected iPad with log capture.
# Usage: ./scripts/build-run-ipad.sh
# Logs are filtered to the app's subsystem and written to stdout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/async-index.sh"

WORKSPACE="RemoteDesktop/RemoteDesktop.xcworkspace"
SCHEME="RemoteDesktopApp"
BUNDLE_ID="com.ryheff.keyd.remote.app"
DEVICE_ID="00000000-00000000000000A1"
CONFIG="Release"
LOG_SUBSYSTEM="com.ryheff.keyd.remote.app"

cd "$(dirname "$0")/.."

echo "=== Building $SCHEME for device ==="
xcodebuild \
  -workspace "$WORKSPACE" \
  -scheme "$SCHEME" \
  -destination "id=$DEVICE_ID" \
  -configuration "$CONFIG" \
  build 2>&1 | tail -5

start_async_index "build-run-ipad.sh"

echo ""
echo "=== Installing on iPad ==="
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -path "*$SCHEME*" -name "*.app" -not -path "*/Intermediates*" 2>/dev/null | head -1)
if [ -z "$APP_PATH" ]; then
  echo "ERROR: Could not find built .app bundle"
  exit 1
fi
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" 2>&1 || true

echo ""
echo "=== Launching $BUNDLE_ID on iPad ==="
xcrun devicectl device process launch --device "$DEVICE_ID" --console "$BUNDLE_ID" 2>&1 &
LAUNCH_PID=$!

echo ""
echo "=== Capturing logs (Ctrl+C to stop) ==="
# Give the app a moment to start
sleep 2

# Stream logs filtered to our subsystem
xcrun devicectl device log stream --device "$DEVICE_ID" --predicate "subsystem == '$LOG_SUBSYSTEM'" 2>&1

wait $LAUNCH_PID 2>/dev/null || true
