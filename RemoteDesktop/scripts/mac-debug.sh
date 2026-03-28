#!/bin/bash
# Build and run RemoteDesktopAgent on macOS with log streaming.
# Usage: ./RemoteDesktop/scripts/mac-debug.sh [timeout_seconds]
# Default timeout: 60 seconds. Ctrl+C to stop early.

set -euo pipefail

LOCKFILE="/tmp/keyd-mac-debug.lock"
if [ -f "$LOCKFILE" ]; then
  OLD_PID=$(cat "$LOCKFILE" 2>/dev/null || true)
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Killing previous mac-debug.sh (PID $OLD_PID)"
    kill "$OLD_PID" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"

APP_PID=""
LOG_PID=""
cleanup() {
  [ -n "$LOG_PID" ] && kill "$LOG_PID" 2>/dev/null || true
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null || true
  [ -n "$LOG_PID" ] && wait "$LOG_PID" 2>/dev/null || true
  [ -n "$APP_PID" ] && wait "$APP_PID" 2>/dev/null || true
  rm -f "$LOCKFILE"
}
trap cleanup EXIT

PROJECT="RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj"
SCHEME="RemoteDesktopAgent"
CONFIG="Debug"
SUBSYSTEM="com.ryheff.keyd.remote.agent"
TIMEOUT="${1:-60}"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"

cd "$(git rev-parse --show-toplevel)"

echo "=== Building $SCHEME ==="
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "platform=macOS,arch=arm64" \
  -configuration "$CONFIG" \
  build 2>&1 | grep -E "(error:|warning:|BUILD)" | tail -5

APP_PATH=$(find "$DERIVED_DATA" -path "*RemoteDesktopAgent*" -name "RemoteDesktopAgent.app" -path "*/Debug/*" -not -path "*/Index.noindex/*" 2>/dev/null | head -1)
if [ -z "$APP_PATH" ]; then
  echo "ERROR: Could not find built .app bundle"
  exit 1
fi

echo ""
echo "=== Launching $SCHEME ==="

# Kill existing instance
pkill -f "RemoteDesktopAgent" 2>/dev/null || true
sleep 1

# Delete old keydrd TLS items from login keychain to avoid ACL prompts
# (each rebuild changes code signature, old items have stale ACL)
security delete-certificate -c "keydrd-agent" 2>/dev/null || true
security delete-identity -c "keydrd-agent" 2>/dev/null || true

# Launch the app
"$APP_PATH/Contents/MacOS/RemoteDesktopAgent" &
APP_PID=$!

echo "PID: $APP_PID"
echo ""

# Stream logs filtered to our subsystem
echo "=== Streaming logs (${TIMEOUT}s timeout) ==="
log stream --predicate "subsystem == '$SUBSYSTEM'" --style compact &
LOG_PID=$!

sleep "$TIMEOUT"
# cleanup runs via trap
exit 0
