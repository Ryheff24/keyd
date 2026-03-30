#!/bin/bash
# End-to-end test harness: builds both Mac + iPad apps, launches them in test mode,
# and captures structured test results from the iPad console.
#
# Usage: ./RemoteDesktop/scripts/run-e2e-tests.sh [timeout_seconds] [options]
#
# Options:
#   --transport usb|wifi|awdl     Assert transport type
#   --latency-target-ms N         Latency target for tiered test (median RTT)
#   --expect-resolution WxH       Expected resolution (e.g. 2560x1600)
#   --expect-fps N                Minimum expected FPS (e.g. 60)
#   --full-suite                  Run all test combinations sequentially
#
# Default timeout: 90 seconds. Exit code 0 = all tests passed, 1 = failures.
#
# Prerequisites:
#   - iPad physically connected via USB or on same Wi-Fi network
#   - Screen Recording and Accessibility permissions granted for RemoteDesktopAgent
#
# What happens:
#   1. Build Mac agent + iPad app in parallel using isolated DerivedData paths
#   2. Install the iPad app before launching either runtime
#   3. Kill existing RemoteDesktopAgent and generate fresh TLS identity (PKCS12)
#   4. Start Mac log capture, then launch Mac agent with --test-mode
#   5. Wait for Mac QR readiness, preferring the payload file over log parsing
#   6. Launch iPad app with --test-mode once the QR payload is ready
#   7. Capture iPad console output, parse [TEST] lines, print summary, and exit

set -euo pipefail

# ---- Parse arguments ----
TIMEOUT="180"
TRANSPORT=""
LATENCY_TARGET=""
EXPECT_RESOLUTION=""
EXPECT_FPS=""
FULL_SUITE=false

# First positional arg can be timeout
if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
  TIMEOUT="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --transport)
      TRANSPORT="$2"; shift 2 ;;
    --latency-target-ms)
      LATENCY_TARGET="$2"; shift 2 ;;
    --expect-resolution)
      EXPECT_RESOLUTION="$2"; shift 2 ;;
    --expect-fps)
      EXPECT_FPS="$2"; shift 2 ;;
    --full-suite)
      FULL_SUITE=true; shift ;;
    *)
      # Unknown arg -- treat as timeout if numeric
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        TIMEOUT="$1"
      else
        echo "Unknown option: $1"
        exit 1
      fi
      shift ;;
  esac
done

# ---- Configuration ----
IPAD_DEVICE_ID="00000000-0000-0000-0000-00000000000A"
WORKSPACE="RemoteDesktop/RemoteDesktop.xcworkspace"
IPAD_SCHEME="RemoteDesktopApp"
MAC_PROJECT="RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj"
MAC_SCHEME="RemoteDesktopAgent"
BUNDLE_ID="com.ryheff.keyd.remote.app"
MAC_SUBSYSTEM="com.ryheff.keyd.remote.agent"
DERIVED_DATA_ROOT="/tmp/keyd-e2e-derived-data"
MAC_DERIVED_DATA="$DERIVED_DATA_ROOT/macos"
IPAD_DERIVED_DATA="$DERIVED_DATA_ROOT/ipados"
LOG_FILE="/tmp/e2e-results.log"
MAC_LOG_FILE="/tmp/keyd-e2e-mac.log"
MAC_BUILD_LOG="/tmp/keyd-e2e-build-mac.log"
IPAD_BUILD_LOG="/tmp/keyd-e2e-build-ipad.log"
IPAD_INSTALL_LOG="/tmp/keyd-e2e-install-ipad.log"
QR_PAYLOAD_FILE="/tmp/keydrd-test-qr.json"
QR_READY_LOG="Test mode: QR payload written to /tmp/keydrd-test-qr.json"
QR_SHOWN_LOG="Test mode: auto-showing QR"

cd "$(git rev-parse --show-toplevel)"

# ---- Lockfile (prevent concurrent runs) ----
LOCKFILE="/tmp/keyd-e2e-test.lock"
if [ -f "$LOCKFILE" ]; then
  OLD_PID=$(cat "$LOCKFILE" 2>/dev/null || true)
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Killing previous run-e2e-tests.sh (PID $OLD_PID)"
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
MAC_PID=""
IPAD_PID=""
MAC_LOG_PID=""

cleanup() {
  echo ""
  echo "=== Cleaning up ==="
  # SIGTERM first, then SIGKILL after 2s if still alive
  for pid in "$IPAD_PID" "$MAC_LOG_PID" "$MAC_PID" "$IPAD_INSTALL_PID" "$IPAD_BUILD_PID" "$MAC_BUILD_PID"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  sleep 2
  for pid in "$IPAD_PID" "$MAC_LOG_PID" "$MAC_PID" "$IPAD_INSTALL_PID" "$IPAD_BUILD_PID" "$MAC_BUILD_PID"; do
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  done
  # Don't wait — processes are killed, just proceed
  rm -f "$LOCKFILE"
  rm -f "$QR_PAYLOAD_FILE"
}
trap cleanup EXIT

# ---- Clean state ----
rm -f "$LOG_FILE" "$MAC_LOG_FILE" "$MAC_BUILD_LOG" "$IPAD_BUILD_LOG" "$IPAD_INSTALL_LOG" "$QR_PAYLOAD_FILE"
mkdir -p "$MAC_DERIVED_DATA" "$IPAD_DERIVED_DATA"

# Write progress to log file so user can monitor it
log_progress() { echo "$1"; echo "$1" >> "$LOG_FILE"; }

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

log_progress "============================================"
log_progress "  keyd-rd End-to-End Test Harness"
log_progress "  Timeout: ${TIMEOUT}s"
log_progress "============================================"
log_progress ""

# ---- Step 1: Build Mac agent and iPad app in parallel ----
log_progress "=== [1/6] Building Mac agent + iPad app in parallel ==="
xcodebuild \
  -project "$MAC_PROJECT" \
  -scheme "$MAC_SCHEME" \
  -destination "platform=macOS,arch=arm64" \
  -configuration Debug \
  -derivedDataPath "$MAC_DERIVED_DATA" \
  clean build \
  > "$MAC_BUILD_LOG" 2>&1 &
MAC_BUILD_PID=$!

xcodebuild \
  -workspace "$WORKSPACE" \
  -scheme "$IPAD_SCHEME" \
  -destination "id=$IPAD_DEVICE_ID" \
  -configuration Debug \
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

log_progress "$(summarize_build_log "$MAC_BUILD_LOG")"
log_progress "$(summarize_build_log "$IPAD_BUILD_LOG")"
log_progress ""

if [ "$MAC_BUILD_OK" != true ] || [ "$IPAD_BUILD_OK" != true ]; then
  exit 1
fi

MAC_APP="$MAC_DERIVED_DATA/Build/Products/Debug/RemoteDesktopAgent.app"
if [ ! -d "$MAC_APP" ]; then
  MAC_APP=$(find "$MAC_DERIVED_DATA" -name "RemoteDesktopAgent.app" -path "*/Debug/*" -not -path "*/Index.noindex/*" 2>/dev/null | head -1)
fi
if [ -z "$MAC_APP" ] || [ ! -d "$MAC_APP" ]; then
  echo "ERROR: Could not find built Mac .app bundle"
  exit 1
fi

IPAD_APP="$IPAD_DERIVED_DATA/Build/Products/Debug-iphoneos/RemoteDesktopApp.app"
if [ ! -d "$IPAD_APP" ]; then
  IPAD_APP=$(find "$IPAD_DERIVED_DATA" -name "RemoteDesktopApp.app" -path "*/Debug-iphoneos/*" -not -path "*/Index.noindex/*" 2>/dev/null | head -1)
fi
if [ -z "$IPAD_APP" ] || [ ! -d "$IPAD_APP" ]; then
  echo "ERROR: Could not find built iPad .app bundle"
  exit 1
fi

# ---- Step 2: Install iPad app before runtime launch ----
log_progress "=== [2/6] Installing iPad app ==="
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
log_progress "=== [3/6] Preparing Mac agent ==="
pkill -f "RemoteDesktopAgent" 2>/dev/null || true
sleep 1

# Delete old keydrd TLS items from login keychain to avoid ACL prompts
security delete-certificate -c "keydrd-agent" 2>/dev/null || true
security delete-identity -c "keydrd-agent" 2>/dev/null || true

# Generate fresh TLS identity (PKCS12) for the pairing handshake
CERT_DIR="/tmp/keydrd-tls"
mkdir -p "$CERT_DIR"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
  -days 3650 -nodes -subj "/CN=keydrd-agent" 2>/dev/null
openssl pkcs12 -export -out "$CERT_DIR/identity.p12" \
  -inkey "$CERT_DIR/key.pem" -in "$CERT_DIR/cert.pem" -passout pass:keydrd 2>/dev/null
rm -f "$CERT_DIR/key.pem" "$CERT_DIR/cert.pem"
log_progress "TLS identity generated"
log_progress ""

# ---- Step 4: Start Mac log capture, then launch Mac agent ----
log_progress "=== [4/6] Launching Mac agent in test mode ==="
MAC_LAUNCH_ARGS="--test-mode"
if [ -n "$TRANSPORT" ]; then
  MAC_LAUNCH_ARGS="$MAC_LAUNCH_ARGS --transport $TRANSPORT"
fi

# Stream Mac logs in background (capture all agent subsystems including ScreenCapture's com.keydrd)
log stream --predicate "subsystem == '$MAC_SUBSYSTEM' OR subsystem BEGINSWITH 'com.keydrd'" --style compact > "$MAC_LOG_FILE" 2>&1 &
MAC_LOG_PID=$!
sleep 1

"$MAC_APP/Contents/MacOS/RemoteDesktopAgent" $MAC_LAUNCH_ARGS &
MAC_PID=$!
echo "Mac agent PID: $MAC_PID"

# ---- Step 5: Wait for Mac to be ready and write the QR payload file ----
log_progress "=== [5/6] Waiting for Mac QR readiness ==="
echo "Waiting for Mac to write QR payload..."
QR_PAYLOAD_B64=""
SAW_QR_SHOWN_LOG=false
SAW_QR_READY_LOG=false
for i in $(seq 1 15); do
  if [ "$SAW_QR_SHOWN_LOG" = false ] && grep -q "$QR_SHOWN_LOG" "$MAC_LOG_FILE" 2>/dev/null; then
    log_progress "Mac log reported QR presentation"
    SAW_QR_SHOWN_LOG=true
  fi
  if [ "$SAW_QR_READY_LOG" = false ] && grep -q "$QR_READY_LOG" "$MAC_LOG_FILE" 2>/dev/null; then
    log_progress "Mac log reported QR payload file write"
    SAW_QR_READY_LOG=true
  fi
  if [ -f "$QR_PAYLOAD_FILE" ]; then
    # Base64-encode the QR payload (single line, no wrapping) to pass to iPad
    QR_PAYLOAD_B64=$(base64 -i "$QR_PAYLOAD_FILE" | tr -d '\n')
    if [ -n "$QR_PAYLOAD_B64" ]; then
      echo "QR payload ready (waited ${i}s, b64 length: ${#QR_PAYLOAD_B64})"
      break
    fi
  fi
  if [ "$i" -eq 15 ]; then
    echo "ERROR: Mac did not write QR payload within 15s"
    if [ "$SAW_QR_SHOWN_LOG" = true ] || [ "$SAW_QR_READY_LOG" = true ]; then
      echo "Mac readiness logs were observed, but the payload file was not usable"
    fi
    echo "--- Mac logs ---"
    tail -20 "$MAC_LOG_FILE" 2>/dev/null
    exit 1
  fi
  sleep 1
done
echo ""

log_progress "=== [6/6] Launching iPad in test mode ==="
# Build launch arguments array
IPAD_LAUNCH_ARGS="--test-mode --qr-payload $QR_PAYLOAD_B64"

# Append optional flags
if [ -n "$TRANSPORT" ]; then
  IPAD_LAUNCH_ARGS="$IPAD_LAUNCH_ARGS --expect-transport $TRANSPORT"
fi
if [ -n "$LATENCY_TARGET" ]; then
  IPAD_LAUNCH_ARGS="$IPAD_LAUNCH_ARGS --latency-target-ms $LATENCY_TARGET"
fi
if [ -n "$EXPECT_RESOLUTION" ]; then
  IPAD_LAUNCH_ARGS="$IPAD_LAUNCH_ARGS --expect-resolution $EXPECT_RESOLUTION"
fi
if [ -n "$EXPECT_FPS" ]; then
  IPAD_LAUNCH_ARGS="$IPAD_LAUNCH_ARGS --expect-fps $EXPECT_FPS"
fi

log_progress "iPad launch args: $IPAD_LAUNCH_ARGS"

# Pass the QR payload as a launch argument (--qr-payload <base64>)
# iPad reads this instead of scanning a physical QR code
xcrun devicectl device process launch \
  --device "$IPAD_DEVICE_ID" \
  --terminate-existing \
  --console \
  "$BUNDLE_ID" \
  -- $IPAD_LAUNCH_ARGS \
  2>&1 | tee -a "$LOG_FILE" &
IPAD_PID=$!

# ---- Wait for test results ----
wait_and_parse_results() {
  local run_label="${1:-}"
  echo ""
  if [ -n "$run_label" ]; then
    log_progress "=== Waiting for results: $run_label (timeout: ${TIMEOUT}s) ==="
  else
    log_progress "=== Waiting for test results (timeout: ${TIMEOUT}s) ==="
  fi
  START=$(date +%s)
  while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START))

    if [ $ELAPSED -ge "$TIMEOUT" ]; then
      echo ""
      echo "TIMEOUT after ${TIMEOUT}s -- killing test"
      break
    fi

    if grep -q "\[TEST\] COMPLETE:" "$LOG_FILE" 2>/dev/null; then
      # Give a moment for any remaining output
      sleep 1
      break
    fi

    sleep 1
  done

  # ---- Parse and display results ----
  echo ""
  echo "============================================"
  if [ -n "$run_label" ]; then
    echo "  TEST RESULTS: $run_label"
  else
    echo "  TEST RESULTS"
  fi
  echo "============================================"
  echo ""

  if [ -f "$LOG_FILE" ]; then
    # Extract [TEST] lines
    grep "\[TEST\]" "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
      # Transport-specific colors: USB=green, WiFi=yellow, AWDL=cyan
      # Applied on top of pass/fail/info colors for transport-related lines
      local color=""
      local reset="\033[0m"

      if echo "$line" | grep -qi "usb\|USB/TCP\|wired"; then
        color="\033[32m"  # green = USB
      elif echo "$line" | grep -qi "awdl\|AWDL"; then
        color="\033[36m"  # cyan = AWDL
      elif echo "$line" | grep -qi "wifi\|Wi-Fi"; then
        color="\033[33m"  # yellow = WiFi
      fi

      if echo "$line" | grep -q "\[TEST\] PASS:"; then
        if [ -n "$color" ]; then
          printf "${color}%s${reset}\n" "$line"
        else
          printf "\033[32m%s\033[0m\n" "$line"
        fi
      elif echo "$line" | grep -q "\[TEST\] FAIL:"; then
        printf "\033[31m%s\033[0m\n" "$line"
      elif echo "$line" | grep -q "\[TEST\] INFO:"; then
        if [ -n "$color" ]; then
          printf "${color}%s${reset}\n" "$line"
        else
          printf "\033[34m%s\033[0m\n" "$line"
        fi
      elif echo "$line" | grep -q "\[TEST\] COMPLETE:"; then
        printf "\033[1m%s\033[0m\n" "$line"
      else
        echo "$line"
      fi
    done

    PASSED=$(grep -c "\[TEST\] PASS:" "$LOG_FILE" 2>/dev/null) || PASSED=0
    FAILED=$(grep -c "\[TEST\] FAIL:" "$LOG_FILE" 2>/dev/null) || FAILED=0
    TOTAL=$((PASSED + FAILED))

    echo ""
    echo "--------------------------------------------"
    printf "  Passed: \033[32m%s\033[0m\n" "$PASSED"
    printf "  Failed: \033[31m%s\033[0m\n" "$FAILED"
    echo "  Total:  $TOTAL"
    echo "--------------------------------------------"

    if [ "$FAILED" -gt 0 ]; then
      echo ""
      echo "--- Mac agent logs (capture + transport + streaming) ---"
      grep -i "capture\|HEVC\|onPixelBuffer\|onEncoded\|sendMedia\|sendInput.*sent\|STREAMING\|CONNECTING\|media.*ready\|media.*fail\|DTLS" "$MAC_LOG_FILE" 2>/dev/null | tail -30 || echo "(no relevant Mac logs)"
      echo ""
      echo "--- Mac agent logs (last 30 lines) ---"
      tail -30 "$MAC_LOG_FILE" 2>/dev/null || echo "(no Mac logs)"
      echo ""
      return 1
    fi

    if [ "$TOTAL" -eq 0 ]; then
      echo ""
      echo "WARNING: No test output found"
      echo ""
      echo "--- iPad console (last 50 lines) ---"
      tail -50 "$LOG_FILE" 2>/dev/null || echo "(no output)"
      echo ""
      echo "--- Mac agent logs (last 30 lines) ---"
      tail -30 "$MAC_LOG_FILE" 2>/dev/null || echo "(no Mac logs)"
      return 1
    fi
  else
    echo "ERROR: No iPad log output captured"
    return 1
  fi

  return 0
}

# ---- Full Suite Mode ----
if [ "$FULL_SUITE" = true ]; then
  # In full-suite mode, the single run already includes all extended tests
  # (resolution, fps, latency-tiered, throughput). We run a progressive latency
  # tier sweep to find the minimum achievable latency target.

  # First run: basic suite (all 14 tests, no latency target constraint)
  wait_and_parse_results "basic + extended (no latency target)"
  BASIC_RESULT=$?

  if [ "$BASIC_RESULT" -ne 0 ]; then
    echo ""
    echo "FULL SUITE: basic tests FAILED -- aborting suite"
    exit 1
  fi

  echo ""
  echo "============================================"
  echo "  FULL SUITE: Latency Tier Sweep"
  echo "============================================"
  echo ""

  # Progressive latency targets (stop at first failure)
  LATENCY_TIERS=(1000 500 250 100 50 20 10)
  LAST_PASSING_TIER=""

  for TIER in "${LATENCY_TIERS[@]}"; do
    echo ""
    log_progress "--- Latency tier: ${TIER}ms ---"

    # Kill and re-launch iPad with this latency target
    kill "$IPAD_PID" 2>/dev/null || true
    sleep 2
    rm -f "$LOG_FILE"

    TIER_ARGS="--test-mode --qr-payload $QR_PAYLOAD_B64 --latency-target-ms $TIER"
    if [ -n "$TRANSPORT" ]; then
      TIER_ARGS="$TIER_ARGS --expect-transport $TRANSPORT"
    fi

    xcrun devicectl device process launch \
      --device "$IPAD_DEVICE_ID" \
      --terminate-existing \
      --console \
      "$BUNDLE_ID" \
      -- $TIER_ARGS \
      2>&1 | tee -a "$LOG_FILE" &
    IPAD_PID=$!

    wait_and_parse_results "latency-tier=${TIER}ms"
    TIER_RESULT=$?

    if [ "$TIER_RESULT" -ne 0 ]; then
      echo ""
      printf "\033[33mLatency tier ${TIER}ms FAILED -- stopping sweep\033[0m\n"
      if [ -n "$LAST_PASSING_TIER" ]; then
        printf "\033[32mBest passing latency tier: ${LAST_PASSING_TIER}ms\033[0m\n"
      fi
      break
    fi

    LAST_PASSING_TIER="$TIER"
    printf "\033[32mLatency tier ${TIER}ms PASSED\033[0m\n"
  done

  echo ""
  echo "============================================"
  echo "  FULL SUITE COMPLETE"
  echo "============================================"
  if [ -n "$LAST_PASSING_TIER" ]; then
    printf "  Best latency tier: \033[32m${LAST_PASSING_TIER}ms\033[0m\n"
  else
    printf "  \033[31mNo latency tiers passed\033[0m\n"
  fi
  echo "============================================"
  exit 0
fi

# ---- Single run mode ----
wait_and_parse_results ""
RESULT=$?

if [ "$RESULT" -ne 0 ]; then
  exit 1
fi

echo ""
echo "All tests passed."
exit 0
