#!/bin/bash
# Build and run harness: builds Mac + iPad apps, installs iPad app,
# then launches both runtimes without running E2E tests.
#
# Usage: ./RemoteDesktop/scripts/run-apps.sh [options]
#
# Options:
#   --transport usb|wifi|awdl     Optional transport hint for Mac agent
#   --wired-only                  Disable WiFi/AWDL, USB only
#   --fresh-pairing               Clear pairing state/certs before launch
#   --skip                        Skip build step and reuse existing artifacts
#   --help                        Show usage

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/async-index.sh"

# ---- Parse arguments ----
TRANSPORT=""
WIRED_ONLY=false
FRESH_PAIRING=false
SKIP_BUILD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --transport)
      TRANSPORT="$2"; shift 2 ;;
    --wired-only)
      WIRED_ONLY=true; shift ;;
    --fresh-pairing)
      FRESH_PAIRING=true; shift ;;
    --skip)
      SKIP_BUILD=true; shift ;;
    --help)
      grep '^#' "$0" | sed -e 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "Unknown option: $1"
      exit 1 ;;
  esac
done

# ---- Configuration ----
IPAD_DEVICE_ID="00000000-0000-0000-0000-00000000000A"
WORKSPACE="RemoteDesktop/RemoteDesktop.xcworkspace"
IPAD_SCHEME="RemoteDesktopApp"
MAC_PROJECT="RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj"
MAC_SCHEME="RemoteDesktopAgent"
BUNDLE_ID="com.ryheff.keyd.remote.app"
DERIVED_DATA_ROOT="/tmp/keyd-run-derived-data"
MAC_DERIVED_DATA="$DERIVED_DATA_ROOT/macos"
IPAD_DERIVED_DATA="$DERIVED_DATA_ROOT/ipados"
MAC_BUILD_LOG="/tmp/keyd-run-build-mac.log"
IPAD_BUILD_LOG="/tmp/keyd-run-build-ipad.log"
IPAD_INSTALL_LOG="/tmp/keyd-run-install-ipad.log"
MAC_STDOUT_LOG="/tmp/keyd-run-mac-agent.log"
MAC_LOG_FILE="/tmp/keyd-run-mac-oslog.log"
IPAD_LOG_FILE="/tmp/keyd-run-ipad.log"
MAC_SUBSYSTEM="com.ryheff.keyd.remote.agent"

cd "$(git rev-parse --show-toplevel)"

# ---- Lockfile (prevent concurrent runs) ----
LOCKFILE="/tmp/keyd-run-apps.lock"
if [ -f "$LOCKFILE" ]; then
  OLD_PID=$(cat "$LOCKFILE" 2>/dev/null || true)
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Killing previous run-apps.sh (PID $OLD_PID)"
    kill "$OLD_PID" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"

# ---- Cleanup ----
MAC_BUILD_PID=""
IPAD_BUILD_PID=""
IPAD_INSTALL_PID=""

cleanup() {
  # Stop in-flight worker jobs. Launched apps are intentionally left running.
  for pid in "$IPAD_INSTALL_PID" "$IPAD_BUILD_PID" "$MAC_BUILD_PID"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  rm -f "$LOCKFILE"
}
trap cleanup EXIT

# ---- Clean state ----
rm -f "$MAC_BUILD_LOG" "$IPAD_BUILD_LOG" "$IPAD_INSTALL_LOG"
mkdir -p "$MAC_DERIVED_DATA" "$IPAD_DERIVED_DATA"

summarize_build_log() {
  local log_file="$1"
  grep -E "(error:|warning:|BUILD)" "$log_file" 2>/dev/null | tail -5 || true
}

wait_for_job() {
  local pid="$1"
  local label="$2"
  local log_file="$3"

  if wait "$pid"; then
    return 0
  fi

  echo "ERROR: $label failed"
  echo "--- $label log (last 40 lines) ---"
  tail -40 "$log_file" 2>/dev/null || true
  return 1
}

echo "============================================"
echo "  keyd-rd Build + Run Harness"
echo "============================================"
echo ""

# ---- Step 1: Build Mac agent and iPad app in parallel ----
if [ "$SKIP_BUILD" = true ]; then
  echo "=== [1/5] Skipping build (--skip), reusing existing artifacts ==="
  echo ""
else
  echo "=== [1/5] Building Mac agent + iPad app in parallel ==="
  xcodebuild \
    -project "$MAC_PROJECT" \
    -scheme "$MAC_SCHEME" \
    -destination "platform=macOS,arch=arm64" \
    -configuration Release \
    -derivedDataPath "$MAC_DERIVED_DATA" \
    clean build \
    > "$MAC_BUILD_LOG" 2>&1 &
  MAC_BUILD_PID=$!

  xcodebuild \
    -workspace "$WORKSPACE" \
    -scheme "$IPAD_SCHEME" \
    -destination "id=$IPAD_DEVICE_ID" \
    -configuration Release \
    -derivedDataPath "$IPAD_DERIVED_DATA" \
    clean build \
    > "$IPAD_BUILD_LOG" 2>&1 &
  IPAD_BUILD_PID=$!

  MAC_BUILD_OK=true
  IPAD_BUILD_OK=true

  wait_for_job "$MAC_BUILD_PID" "Mac build" "$MAC_BUILD_LOG" || MAC_BUILD_OK=false
  wait_for_job "$IPAD_BUILD_PID" "iPad build" "$IPAD_BUILD_LOG" || IPAD_BUILD_OK=false

  MAC_BUILD_PID=""
  IPAD_BUILD_PID=""

  echo "$(summarize_build_log "$MAC_BUILD_LOG")"
  echo "$(summarize_build_log "$IPAD_BUILD_LOG")"
  echo ""

  if [ "$MAC_BUILD_OK" != true ] || [ "$IPAD_BUILD_OK" != true ]; then
    exit 1
  fi

  start_async_index "run-apps.sh"
fi

MAC_APP="$MAC_DERIVED_DATA/Build/Products/Release/RemoteDesktopAgent.app"
if [ ! -d "$MAC_APP" ]; then
  MAC_APP=$(find "$MAC_DERIVED_DATA" -name "RemoteDesktopAgent.app" -path "*/Release/*" -not -path "*/Index.noindex/*" 2>/dev/null | head -1)
fi
if [ -z "$MAC_APP" ] || [ ! -d "$MAC_APP" ]; then
  echo "ERROR: Could not find built Mac .app bundle"
  exit 1
fi

IPAD_APP="$IPAD_DERIVED_DATA/Build/Products/Release-iphoneos/RemoteDesktopApp.app"
if [ ! -d "$IPAD_APP" ]; then
  IPAD_APP=$(find "$IPAD_DERIVED_DATA" -name "RemoteDesktopApp.app" -path "*/Release-iphoneos/*" -not -path "*/Index.noindex/*" 2>/dev/null | head -1)
fi
if [ -z "$IPAD_APP" ] || [ ! -d "$IPAD_APP" ]; then
  echo "ERROR: Could not find built iPad .app bundle"
  exit 1
fi

# ---- Step 2: Install iPad app ----
echo "=== [2/5] Installing iPad app ==="
xcrun devicectl device install app \
  --device "$IPAD_DEVICE_ID" \
  "$IPAD_APP" \
  > "$IPAD_INSTALL_LOG" 2>&1 &
IPAD_INSTALL_PID=$!

wait_for_job "$IPAD_INSTALL_PID" "iPad install" "$IPAD_INSTALL_LOG"
IPAD_INSTALL_PID=""
grep -E "(bundleID|error|ERROR)" "$IPAD_INSTALL_LOG" 2>/dev/null || true
echo ""

# ---- Step 3: Kill existing agents, generate TLS identity ----
echo "=== [3/5] Preparing Mac agent ==="
pkill -f "RemoteDesktopAgent" 2>/dev/null || true
sleep 1

if [ "$FRESH_PAIRING" = true ]; then
  echo "Fresh pairing requested: clearing keychain pairing identities"
  security delete-certificate -c "keydrd-agent" 2>/dev/null || true
  security delete-identity -c "keydrd-agent" 2>/dev/null || true
else
  echo "Preserving existing pairing identities (default)"
fi

# Reuse existing TLS identity if available (preserves pairing across rebuilds).
CERT_DIR="/tmp/keydrd-tls"
mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"
if [ ! -f "$CERT_DIR/identity.p12" ]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
    -days 3650 -nodes -subj "/CN=keydrd-agent" 2>/dev/null
  openssl pkcs12 -export -out "$CERT_DIR/identity.p12" \
    -inkey "$CERT_DIR/key.pem" -in "$CERT_DIR/cert.pem" -passout pass:keydrd -legacy 2>/dev/null
  chmod 600 "$CERT_DIR/identity.p12"
  rm -f "$CERT_DIR/key.pem" "$CERT_DIR/cert.pem"
  echo "TLS identity generated (new)"
else
  echo "TLS identity reused (existing)"
fi
echo ""

# ---- Step 4: Launch Mac agent ----
echo "=== [4/5] Launching Mac agent ==="
MAC_LAUNCH_ARGS=""
if [ -n "$TRANSPORT" ]; then
  MAC_LAUNCH_ARGS="$MAC_LAUNCH_ARGS --transport $TRANSPORT"
fi
if [ "$WIRED_ONLY" = true ]; then
  MAC_LAUNCH_ARGS="$MAC_LAUNCH_ARGS --wired-only"
fi

# Start Mac os_log capture in background
rm -f "$MAC_LOG_FILE" "$IPAD_LOG_FILE"
log stream --predicate "subsystem == '$MAC_SUBSYSTEM' OR subsystem BEGINSWITH 'com.keydrd'" \
  --style compact > "$MAC_LOG_FILE" 2>&1 &
MAC_LOG_PID=$!

"$MAC_APP/Contents/MacOS/RemoteDesktopAgent" $MAC_LAUNCH_ARGS > "$MAC_STDOUT_LOG" 2>&1 &
MAC_PID=$!
echo "Mac agent PID: $MAC_PID"
echo ""

# ---- Step 5: Launch iPad app ----
echo "=== [5/5] Launching iPad app ==="
xcrun devicectl device process launch \
  --device "$IPAD_DEVICE_ID" \
  --terminate-existing \
  --console \
  "$BUNDLE_ID" > "$IPAD_LOG_FILE" 2>&1 &
IPAD_LOG_PID=$!

echo ""
echo "Both apps launched."
echo "Mac agent PID:  $MAC_PID"
echo ""
echo "=== Log files ==="
echo "  Mac os_log:    $MAC_LOG_FILE"
echo "  Mac stdout:    $MAC_STDOUT_LOG"
echo "  iPad console:  $IPAD_LOG_FILE"
echo ""
echo "Tail logs:"
echo "  tail -f $MAC_LOG_FILE"
echo "  tail -f $IPAD_LOG_FILE"
exit 0
