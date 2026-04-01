#!/bin/bash
# Build and run RemoteDesktopAgent on macOS with log streaming.
# Usage: ./RemoteDesktop/scripts/mac-debug.sh [timeout_seconds]
# Default timeout: 60 seconds. Ctrl+C to stop early.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/async-index.sh"

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
CONFIG="Release"
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

start_async_index "mac-debug.sh"

APP_PATH=$(find "$DERIVED_DATA" -path "*RemoteDesktopAgent*" -name "RemoteDesktopAgent.app" -path "*/Release/*" -not -path "*/Index.noindex/*" 2>/dev/null | head -1)
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
security delete-certificate -c "keydrd-agent" 2>/dev/null || true
security delete-identity -c "keydrd-agent" 2>/dev/null || true

# Generate fresh TLS identity (PKCS12) for the pairing handshake
# Using OpenSSL ensures a properly formatted cert that Network.framework accepts
CERT_DIR="/tmp/keydrd-tls"
mkdir -p "$CERT_DIR"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
  -days 3650 -nodes -subj "/CN=keydrd-agent" 2>/dev/null
openssl pkcs12 -export -out "$CERT_DIR/identity.p12" \
  -inkey "$CERT_DIR/key.pem" -in "$CERT_DIR/cert.pem" -passout pass:keydrd 2>/dev/null
rm -f "$CERT_DIR/key.pem" "$CERT_DIR/cert.pem"

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
