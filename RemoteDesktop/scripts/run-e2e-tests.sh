#!/bin/bash
# End-to-end test harness: builds both Mac + iPad apps, launches them in test mode,
# and captures structured test results from the iPad console.
#
# Usage: ./RemoteDesktop/scripts/run-e2e-tests.sh [timeout_seconds] [options]
#
# Options:
#   --expected-transport TYPE     Assert the initial connected transport type
#                                  TYPE: usb|wifi|awdl
#   --transport-rotation LIST     Comma-separated transport regression set
#                                  (default: usb,wifi,awdl)
#   --transport usb|wifi|awdl     Deprecated alias for --expected-transport
#   --transports LIST             Deprecated alias for --transport-rotation
#   --latency-target-ms N         Latency target for tiered test (median RTT)
#   --expect-resolution WxH       Expected resolution (e.g. 2560x1600)
#   --expect-fps N                Minimum expected FPS (e.g. 60)
#   --notes TEXT                  Required; added to the report commit message and
#                                  metrics changelog
#   --capture-file PATH           Use a file-backed synthetic frame source on Mac
#                                  (default: ./RemoteDesktop/2026-04-02 10-55-42-prores.mov)
#   --stress-capture              Force procedural full-frame stress source on Mac
#   --real-capture                Use live ScreenCaptureKit desktop capture instead
#   --sustained-stream-seconds N  Keep streaming for N seconds after heavy-load
#                                  before security/rotation checks (default: 90, full profile)
#   --profile NAME                full|targeted|connection|security
#                                  full: sustained + perf + rotation + security
#                                  targeted: short playback + rotation + security
#                                  connection: connection + playback + rotation + security
#                                  security: connection + playback + security
#   --video-playback-window-seconds N  Override playback freeze-check window length
#   --video-playback-offset-seconds N  Override playback freeze-check start offset
#   --skip-transport-rotation     Skip reconnect/rotation checks after main stream tests
#   --wired-only                  Shorthand for --transport-rotation usb
#   --full-suite                  Run all test combinations sequentially
#
# Default timeout: 180 seconds (auto-extended for full sustained runs).
# Exit code 0 = all tests passed, 1 = failures.
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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/async-index.sh"

# ---- Parse arguments ----
TIMEOUT="180"
TIMEOUT_SPECIFIED=false
EXPECT_TRANSPORT=""
ROTATION_TRANSPORTS=""
LATENCY_TARGET=""
EXPECT_RESOLUTION=""
EXPECT_FPS=""
CAPTURE_FILE=""
STRESS_CAPTURE=false
REAL_CAPTURE=false
SUSTAINED_STREAM_SECONDS="90"
SKIP_TRANSPORT_ROTATION=false
FULL_SUITE=false
WIRED_ONLY=false
REPORT_NOTES=""
PROFILE="full"
ROTATION_SPECIFIED=false
EXPECT_TRANSPORT_SPECIFIED=false
SUSTAINED_SPECIFIED=false
DEPRECATED_TRANSPORT_FLAG=false
DEPRECATED_TRANSPORTS_FLAG=false
VIDEO_PLAYBACK_WINDOW_SECONDS=""
VIDEO_PLAYBACK_OFFSET_SECONDS=""
VIDEO_WINDOW_SPECIFIED=false
VIDEO_OFFSET_SPECIFIED=false

# First positional arg can be timeout
if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
  TIMEOUT="$1"
  TIMEOUT_SPECIFIED=true
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --expected-transport)
      EXPECT_TRANSPORT="$2"; EXPECT_TRANSPORT_SPECIFIED=true; shift 2 ;;
    --transport)
      EXPECT_TRANSPORT="$2"; EXPECT_TRANSPORT_SPECIFIED=true; DEPRECATED_TRANSPORT_FLAG=true; shift 2 ;;
    --transport-rotation)
      ROTATION_TRANSPORTS="$2"; ROTATION_SPECIFIED=true; shift 2 ;;
    --transports)
      ROTATION_TRANSPORTS="$2"; ROTATION_SPECIFIED=true; DEPRECATED_TRANSPORTS_FLAG=true; shift 2 ;;
    --latency-target-ms)
      LATENCY_TARGET="$2"; shift 2 ;;
    --expect-resolution)
      EXPECT_RESOLUTION="$2"; shift 2 ;;
    --expect-fps)
      EXPECT_FPS="$2"; shift 2 ;;
    --notes)
      REPORT_NOTES="$2"; shift 2 ;;
    --capture-file)
      CAPTURE_FILE="$2"; shift 2 ;;
    --stress-capture)
      STRESS_CAPTURE=true; shift ;;
    --real-capture)
      REAL_CAPTURE=true; shift ;;
    --sustained-stream-seconds)
      SUSTAINED_STREAM_SECONDS="$2"; SUSTAINED_SPECIFIED=true; shift 2 ;;
    --profile)
      PROFILE="$2"; shift 2 ;;
    --video-playback-window-seconds)
      VIDEO_PLAYBACK_WINDOW_SECONDS="$2"; VIDEO_WINDOW_SPECIFIED=true; shift 2 ;;
    --video-playback-offset-seconds)
      VIDEO_PLAYBACK_OFFSET_SECONDS="$2"; VIDEO_OFFSET_SPECIFIED=true; shift 2 ;;
    --skip-transport-rotation)
      SKIP_TRANSPORT_ROTATION=true; shift ;;
    --no-peer-to-peer)
      # Diagnostic: both apps stop including peer-to-peer (AWDL) interfaces.
      NO_PEER_TO_PEER=true; shift ;;
    --full-suite)
      FULL_SUITE=true; shift ;;
    --wired-only)
      WIRED_ONLY=true; ROTATION_SPECIFIED=true; shift ;;
    *)
      # Unknown arg -- treat as timeout if numeric
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        TIMEOUT="$1"
        TIMEOUT_SPECIFIED=true
      else
        echo "Unknown option: $1"
        exit 1
      fi
      shift ;;
  esac
done

if [ -z "$REPORT_NOTES" ]; then
  echo "ERROR: --notes is required"
  exit 1
fi
if [ "$FULL_SUITE" = true ]; then
  echo "ERROR: --full-suite is not compatible with required reporting yet"
  exit 1
fi

if [ "$DEPRECATED_TRANSPORT_FLAG" = true ]; then
  echo "WARNING: --transport is deprecated; use --expected-transport"
fi
if [ "$DEPRECATED_TRANSPORTS_FLAG" = true ]; then
  echo "WARNING: --transports is deprecated; use --transport-rotation"
fi

case "$PROFILE" in
  full|targeted|connection|security) ;;
  *)
    echo "ERROR: invalid --profile '$PROFILE' (expected full|targeted|connection|security)"
    exit 1
    ;;
esac

if [ "$PROFILE" != "full" ] && [ "$SUSTAINED_SPECIFIED" = false ]; then
  SUSTAINED_STREAM_SECONDS="0"
fi

normalize_transport_list() {
  local raw="$1"
  local normalized=()
  local seen_usb=false
  local seen_wifi=false
  local seen_awdl=false
  local item

  IFS=',' read -r -a items <<< "$raw"
  for item in "${items[@]}"; do
    item="$(printf "%s" "$item" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    case "$item" in
      usb)
        if [ "$seen_usb" = false ]; then
          normalized+=("usb")
          seen_usb=true
        fi
        ;;
      wifi)
        if [ "$seen_wifi" = false ]; then
          normalized+=("wifi")
          seen_wifi=true
        fi
        ;;
      awdl)
        if [ "$seen_awdl" = false ]; then
          normalized+=("awdl")
          seen_awdl=true
        fi
        ;;
      "")
        ;;
      *)
        echo "ERROR: invalid transport '$item' in transport rotation set (expected usb,wifi,awdl)"
        return 1
        ;;
    esac
  done

  if [ "${#normalized[@]}" -eq 0 ]; then
    echo "ERROR: transport rotation set must include at least one of usb,wifi,awdl"
    return 1
  fi

  local result=""
  for item in "${normalized[@]}"; do
    if [ -n "$result" ]; then
      result+=","
    fi
    result+="$item"
  done
  printf "%s" "$result"
}

auto_detect_rotation_transports() {
  local requested="$1"

  if [ "$ROTATION_SPECIFIED" = true ] || [ "$WIRED_ONLY" = true ]; then
    printf "%s" "$requested"
    return
  fi

  # Keep full requested set; DeviceTestRunner skips unavailable transports at runtime.
  printf "%s" "$requested"
}

derive_video_playback_window() {
  if [ -n "$VIDEO_PLAYBACK_WINDOW_SECONDS" ] || [ -n "$VIDEO_PLAYBACK_OFFSET_SECONDS" ]; then
    if [ -z "$VIDEO_PLAYBACK_WINDOW_SECONDS" ]; then
      VIDEO_PLAYBACK_WINDOW_SECONDS="12"
    fi
    if [ -z "$VIDEO_PLAYBACK_OFFSET_SECONDS" ]; then
      VIDEO_PLAYBACK_OFFSET_SECONDS="34"
    fi
    echo "INFO: video playback freeze-check window override offset=${VIDEO_PLAYBACK_OFFSET_SECONDS}s duration=${VIDEO_PLAYBACK_WINDOW_SECONDS}s"
    return
  fi
  local default_window="12"
  local default_offset="34"
  VIDEO_PLAYBACK_WINDOW_SECONDS="$default_window"
  VIDEO_PLAYBACK_OFFSET_SECONDS="$default_offset"
  echo "INFO: video playback freeze-check window offset=${VIDEO_PLAYBACK_OFFSET_SECONDS}s duration=${VIDEO_PLAYBACK_WINDOW_SECONDS}s (deterministic default; refine from future telemetry)"
}

configure_profile_defaults() {
  case "$PROFILE" in
    full)
      ;;
    targeted)
      SKIP_TRANSPORT_ROTATION=false
      if [ "$SUSTAINED_SPECIFIED" = false ]; then
        SUSTAINED_STREAM_SECONDS="0"
      fi
      if [ "$VIDEO_WINDOW_SPECIFIED" = false ]; then
        VIDEO_PLAYBACK_WINDOW_SECONDS="12"
      fi
      if [ "$VIDEO_OFFSET_SPECIFIED" = false ]; then
        VIDEO_PLAYBACK_OFFSET_SECONDS="2"
      fi
      ;;
    connection)
      SKIP_TRANSPORT_ROTATION=false
      if [ "$SUSTAINED_SPECIFIED" = false ]; then
        SUSTAINED_STREAM_SECONDS="0"
      fi
      if [ "$VIDEO_WINDOW_SPECIFIED" = false ]; then
        VIDEO_PLAYBACK_WINDOW_SECONDS="10"
      fi
      if [ "$VIDEO_OFFSET_SPECIFIED" = false ]; then
        VIDEO_PLAYBACK_OFFSET_SECONDS="2"
      fi
      ;;
    security)
      SKIP_TRANSPORT_ROTATION=true
      if [ "$SUSTAINED_SPECIFIED" = false ]; then
        SUSTAINED_STREAM_SECONDS="0"
      fi
      if [ "$VIDEO_WINDOW_SPECIFIED" = false ]; then
        VIDEO_PLAYBACK_WINDOW_SECONDS="10"
      fi
      if [ "$VIDEO_OFFSET_SPECIFIED" = false ]; then
        VIDEO_PLAYBACK_OFFSET_SECONDS="2"
      fi
      ;;
  esac
}

configure_default_timeout() {
  local sustained="${SUSTAINED_STREAM_SECONDS:-0}"
  if ! [[ "$sustained" =~ ^[0-9]+$ ]]; then
    sustained=0
  fi

  if [ "$TIMEOUT_SPECIFIED" = false ] && [ "$PROFILE" = "full" ] && [ "$sustained" -gt 0 ]; then
    # Full profile includes sustained stream + security + rotation, so extend timeout.
    TIMEOUT=$((180 + sustained + 90))
  fi
}

# ---- Configuration ----
IPAD_DEVICE_ID="00000000-0000-0000-0000-00000000000A"
WORKSPACE="RemoteDesktop/RemoteDesktop.xcworkspace"
IPAD_SCHEME="RemoteDesktopApp"
MAC_PROJECT="RemoteDesktop/macOS/RemoteDesktopAgent.xcodeproj"
MAC_SCHEME="RemoteDesktopAgent"
BUNDLE_ID="com.ryheff.keyd.remote.app"
MAC_SUBSYSTEM="com.ryheff.keyd.remote.agent"
METRICS_BRANCH="metrics"
DERIVED_DATA_ROOT="/tmp/keyd-e2e-derived-data"
MAC_DERIVED_DATA="$DERIVED_DATA_ROOT/macos"
IPAD_DERIVED_DATA="$DERIVED_DATA_ROOT/ipados"
LOG_FILE="/tmp/e2e-results.log"
IPAD_LOG_FILE="/tmp/keyd-e2e-ipad.log"
MAC_LOG_FILE="/tmp/keyd-e2e-mac.log"
MAC_BUILD_LOG="/tmp/keyd-e2e-build-mac.log"
IPAD_BUILD_LOG="/tmp/keyd-e2e-build-ipad.log"
IPAD_INSTALL_LOG="/tmp/keyd-e2e-install-ipad.log"
QR_PAYLOAD_FILE="/tmp/keydrd-test-qr.json"
QR_READY_LOG="Test mode: QR payload written to /tmp/keydrd-test-qr.json"
QR_SHOWN_LOG="Test mode: auto-showing QR"
DEFAULT_CAPTURE_FILE="./RemoteDesktop/2026-04-02 10-55-42-prores.mov"
# The .mov stress video produces incompressible frames (~19.7MB) that tank FPS.
# A static desktop screenshot gives realistic LZ4 deltas (~1-50KB per frame),
# representing actual desktop usage (idle, text editing, cursor movement).
LEGACY_CAPTURE_FILE="/tmp/keydrd-capture-mimic.mov"
WIRELESS_ONLY=false

if [ "$WIRED_ONLY" = true ]; then
  ROTATION_TRANSPORTS="usb"
  ROTATION_SPECIFIED=true
fi
if [ -z "$ROTATION_TRANSPORTS" ]; then
  ROTATION_TRANSPORTS="usb,wifi,awdl"
fi
ROTATION_TRANSPORTS="$(normalize_transport_list "$ROTATION_TRANSPORTS")"
ROTATION_TRANSPORTS="$(auto_detect_rotation_transports "$ROTATION_TRANSPORTS")"

case ",$ROTATION_TRANSPORTS," in
  *,usb,*)
    WIRED_ONLY=false
    ;;
  *)
    WIRELESS_ONLY=true
    ;;
esac
if [ "$ROTATION_TRANSPORTS" = "usb" ]; then
  WIRED_ONLY=true
  WIRELESS_ONLY=false
fi

derive_video_playback_window
configure_profile_defaults
configure_default_timeout

if [ -z "$CAPTURE_FILE" ] && [ "$STRESS_CAPTURE" = false ] && [ "$REAL_CAPTURE" = false ]; then
  if [ -f "$DEFAULT_CAPTURE_FILE" ]; then
    CAPTURE_FILE="$DEFAULT_CAPTURE_FILE"
  elif [ -f "$LEGACY_CAPTURE_FILE" ]; then
    CAPTURE_FILE="$LEGACY_CAPTURE_FILE"
  fi
fi

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
rm -f "$LOG_FILE" "$IPAD_LOG_FILE" "$MAC_LOG_FILE" "$MAC_BUILD_LOG" "$IPAD_BUILD_LOG" "$IPAD_INSTALL_LOG" "$QR_PAYLOAD_FILE"
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
  local max_seconds="${4:-0}"
  local stale_seconds="${5:-0}"
  local poll_seconds=5
  local heartbeat_seconds=30
  local start_ts now_ts last_heartbeat_ts elapsed_sec
  local log_size=0
  local last_log_size=0
  local last_log_change_ts=0
  local log_age_sec=0

  WAIT_FOR_JOB_FAIL_REASON=""
  WAIT_FOR_JOB_FAIL_DETAIL=""
  WAIT_FOR_JOB_ELAPSED_SEC=0
  WAIT_FOR_JOB_LOG_AGE_SEC=0

  start_ts=$(date +%s)
  last_heartbeat_ts="$start_ts"
  if [ -f "$log_file" ]; then
    last_log_size=$(stat -f %z "$log_file" 2>/dev/null || echo 0)
  fi
  last_log_change_ts="$start_ts"

  log_progress "[CONSOLE] e2e-wait entry label=$label pid=$pid maxSeconds=$max_seconds staleSeconds=$stale_seconds log=$log_file"

  while kill -0 "$pid" 2>/dev/null; do
    now_ts=$(date +%s)
    elapsed_sec=$((now_ts - start_ts))

    if [ -f "$log_file" ]; then
      log_size=$(stat -f %z "$log_file" 2>/dev/null || echo 0)
      if [ "$log_size" -ne "$last_log_size" ]; then
        last_log_change_ts="$now_ts"
        last_log_size="$log_size"
        log_progress "[CONSOLE] e2e-wait branch label=$label reason=log-progress elapsedSec=$elapsed_sec logSize=$log_size"
      fi
    fi

    log_age_sec=$((now_ts - last_log_change_ts))
    WAIT_FOR_JOB_ELAPSED_SEC="$elapsed_sec"
    WAIT_FOR_JOB_LOG_AGE_SEC="$log_age_sec"

    if [ $((now_ts - last_heartbeat_ts)) -ge "$heartbeat_seconds" ]; then
      log_progress "[CONSOLE] e2e-wait heartbeat label=$label pid=$pid elapsedSec=$elapsed_sec logAgeSec=$log_age_sec logSize=$last_log_size"
      last_heartbeat_ts="$now_ts"
    fi

    if [ "$max_seconds" -gt 0 ] && [ "$elapsed_sec" -ge "$max_seconds" ]; then
      WAIT_FOR_JOB_FAIL_REASON="wall-timeout"
      WAIT_FOR_JOB_FAIL_DETAIL="elapsedSec=$elapsed_sec thresholdSec=$max_seconds"
      log_progress "[CONSOLE] e2e-wait failure label=$label reason=wall-timeout elapsedSec=$elapsed_sec thresholdSec=$max_seconds pid=$pid action=kill"
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      echo "ERROR: $label failed (wall-timeout)"
      echo "--- $label log (last 40 lines) ---"
      tail -40 "$log_file" 2>/dev/null || true
      return 1
    fi

    if [ "$stale_seconds" -gt 0 ] && [ "$log_age_sec" -ge "$stale_seconds" ]; then
      WAIT_FOR_JOB_FAIL_REASON="log-stall-timeout"
      WAIT_FOR_JOB_FAIL_DETAIL="elapsedSec=$elapsed_sec logAgeSec=$log_age_sec thresholdSec=$stale_seconds"
      log_progress "[CONSOLE] e2e-wait failure label=$label reason=log-stall-timeout elapsedSec=$elapsed_sec logAgeSec=$log_age_sec thresholdSec=$stale_seconds pid=$pid action=kill"
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      echo "ERROR: $label failed (log-stall-timeout)"
      echo "--- $label log (last 40 lines) ---"
      tail -40 "$log_file" 2>/dev/null || true
      return 1
    fi

    sleep "$poll_seconds"
  done

  if wait "$pid"; then
    now_ts=$(date +%s)
    elapsed_sec=$((now_ts - start_ts))
    WAIT_FOR_JOB_ELAPSED_SEC="$elapsed_sec"
    WAIT_FOR_JOB_LOG_AGE_SEC=$((now_ts - last_log_change_ts))
    log_progress "[CONSOLE] e2e-wait success label=$label pid=$pid elapsedSec=$elapsed_sec logAgeSec=$WAIT_FOR_JOB_LOG_AGE_SEC"
    return 0
  fi

  now_ts=$(date +%s)
  elapsed_sec=$((now_ts - start_ts))
  WAIT_FOR_JOB_ELAPSED_SEC="$elapsed_sec"
  WAIT_FOR_JOB_LOG_AGE_SEC=$((now_ts - last_log_change_ts))
  WAIT_FOR_JOB_FAIL_REASON="process-exit-nonzero"
  WAIT_FOR_JOB_FAIL_DETAIL="elapsedSec=$elapsed_sec logAgeSec=$WAIT_FOR_JOB_LOG_AGE_SEC"
  log_progress "[CONSOLE] e2e-wait failure label=$label reason=process-exit-nonzero elapsedSec=$elapsed_sec logAgeSec=$WAIT_FOR_JOB_LOG_AGE_SEC"
  echo "ERROR: $label failed"
  echo "--- $label log (last 40 lines) ---"
  tail -40 "$log_file" 2>/dev/null || true
  return 1
}

summarize_frame_checks() {
  local source_tmp
  local converge_tmp
  local matched_tmp
  source_tmp="$(mktemp /tmp/keyd-framecheck-source.XXXXXX)"
  converge_tmp="$(mktemp /tmp/keyd-framecheck-converge.XXXXXX)"
  matched_tmp="$(mktemp /tmp/keyd-framecheck-matched.XXXXXX)"

  awk '
    /FRAME-CHECK source/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^source_crc=/) {
          split($i, a, "=")
          if (a[2] != "00000000") {
            print a[2]
          }
        } else if ($i ~ /^scene_crc=/) {
          split($i, a, "=")
          if (a[2] != "00000000") {
            print a[2]
          }
        }
      }
    }
  ' "$MAC_LOG_FILE" 2>/dev/null | sort -u > "$source_tmp"

  awk '
    /FRAME-CHECK converge/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^raw_crc=/) {
          split($i, a, "=")
          print a[2]
        }
      }
    }
  ' "$MAC_LOG_FILE" 2>/dev/null | sort -u > "$converge_tmp"

  local source_count converge_count matched_count
  source_count=$(wc -l < "$source_tmp" | tr -d ' ')
  converge_count=$(wc -l < "$converge_tmp" | tr -d ' ')

  if [ "$source_count" -eq 0 ] && [ "$converge_count" -eq 0 ]; then
    rm -f "$source_tmp" "$converge_tmp" "$matched_tmp"
    return
  fi

  comm -12 "$source_tmp" "$converge_tmp" > "$matched_tmp"
  matched_count=$(wc -l < "$matched_tmp" | tr -d ' ')

  echo ""
  echo "--- Frame equivalence check ---"
  echo "source scene CRCs:     $source_count unique"
  echo "converged raw CRCs:    $converge_count unique"
  echo "matching raw CRCs:     $matched_count unique"

  if [ "$converge_count" -gt 0 ]; then
    awk -v matched="$matched_count" -v total="$converge_count" 'BEGIN { printf "match rate:            %.1f%%\n", (matched * 100.0) / total }'
  fi

  if [ "$matched_count" -lt "$converge_count" ]; then
    echo "note: mismatches mean the bytes entering compression differ from the stress-scene reference before transport/encode."
  fi

  rm -f "$source_tmp" "$converge_tmp" "$matched_tmp"
}

log_progress "============================================"
log_progress "  keyd-rd End-to-End Test Harness"
log_progress "  Timeout: ${TIMEOUT}s"
log_progress "============================================"
log_progress "  Results log:  $LOG_FILE"
log_progress "  iPad log:     $IPAD_LOG_FILE"
log_progress "  Mac log:      $MAC_LOG_FILE"
log_progress "  Build logs:   $MAC_BUILD_LOG, $IPAD_BUILD_LOG"
log_progress "  Transport rotation set: $ROTATION_TRANSPORTS"
log_progress "  Profile: $PROFILE"
log_progress "  Sustained stream seconds: $SUSTAINED_STREAM_SECONDS"
log_progress ""

# ---- Reporting helpers ----
extract_metric_value() {
  local label="$1"
  local value="$2"
  if [ -z "$value" ]; then
    echo "ERROR: could not parse $label from test log"
    return 1
  fi
  printf "%s" "$value"
}

extract_metric_with_patterns() {
  local label="$1"
  local line="$2"
  shift 2
  local pattern value

  for pattern in "$@"; do
    value="$(echo "$line" | sed -nE "$pattern")"
    if [ -n "$value" ]; then
      printf "%s" "$value"
      return 0
    fi
  done

  echo "ERROR: could not parse $label from test log"
  return 1
}

collect_report_metrics() {
  REPORT_RESOLUTION_LINE=$(grep -E '\[TEST\] (PASS|FAIL): resolution \(' "$IPAD_LOG_FILE" 2>/dev/null | tail -1 || true)
  REPORT_FPS_LINE=$(grep -E '\[TEST\] (PASS|FAIL): fps \(' "$IPAD_LOG_FILE" 2>/dev/null | tail -1 || true)
  REPORT_FRAME_PACING_LINE=$(grep -E '\[TEST\] (PASS|FAIL): frame-pacing \(' "$IPAD_LOG_FILE" 2>/dev/null | tail -1 || true)
  REPORT_PIPELINE_LINE=$(grep -E '\[TEST\] (PASS|FAIL): pipeline-latency \(' "$IPAD_LOG_FILE" 2>/dev/null | tail -1 || true)
  REPORT_G2G_LINE=$(grep -E '\[TEST\] (PASS|FAIL): glass-to-glass-latency \(' "$IPAD_LOG_FILE" 2>/dev/null | tail -1 || true)
  REPORT_HEAVY_LOAD_LINE=$(grep -E '\[TEST\] (PASS|FAIL): heavy-load \(' "$IPAD_LOG_FILE" 2>/dev/null | tail -1 || true)
  REPORT_SECURITY_LINE=$(grep -E '\[TEST\] (PASS|FAIL): sec-untrusted-cert \(' "$IPAD_LOG_FILE" 2>/dev/null | tail -1 || true)
  REPORT_COMPLETE_LINE=$(grep -E '\[TEST\] COMPLETE:' "$IPAD_LOG_FILE" 2>/dev/null | tail -1 || true)

  REPORT_VIEWPORT_RESOLUTION=$(extract_metric_value "viewport resolution" "$(echo "$REPORT_RESOLUTION_LINE" | sed -nE 's/.*viewport=([0-9]+x[0-9]+).*/\1/p')")
  REPORT_FRAME_RESOLUTION=$(extract_metric_value "frame resolution" "$(echo "$REPORT_RESOLUTION_LINE" | sed -nE 's/.*frame=([0-9]+x[0-9]+).*/\1/p')")
  REPORT_FPS=$(extract_metric_with_patterns "FPS" "$REPORT_FPS_LINE" \
    's/.*avgFPS=([0-9.]+).*/\1/p' \
    's/.*\(([0-9.]+) fps.*/\1/p')
  REPORT_FRAME_PACING_CV=$(extract_metric_value "frame pacing CV" "$(echo "$REPORT_FRAME_PACING_LINE" | sed -nE 's/.*cv=([0-9]+(\.[0-9]+)?).*/\1/p')")

  read -r REPORT_PIPELINE_MEDIAN REPORT_PIPELINE_P95 REPORT_PIPELINE_AVG <<<"$(extract_metric_with_patterns "pipeline latency" "$REPORT_PIPELINE_LINE" \
    's/.*latency\[min\/med\/avg\/p95\/max\]=([0-9.]+)\/([0-9.]+)\/([0-9.]+)\/([0-9.]+)\/([0-9.]+)ms.*/\2 \4 \3/p' \
    's/.*median=([0-9.]+)ms, p95=([0-9.]+)ms, avg=([0-9.]+)ms.*/\1 \2 \3/p')"
  read -r REPORT_G2G_MEDIAN REPORT_G2G_P95 REPORT_G2G_AVG <<<"$(extract_metric_with_patterns "glass-to-glass latency" "$REPORT_G2G_LINE" \
    's/.*latency\[min\/med\/avg\/p95\/max\]=([0-9.]+)\/([0-9.]+)\/([0-9.]+)\/([0-9.]+)\/([0-9.]+)ms.*/\2 \4 \3/p' \
    's/.*median=([0-9.]+)ms, p95=([0-9.]+)ms, avg=([0-9.]+)ms.*/\1 \2 \3/p')"
  read -r REPORT_HEAVY_LOAD_FPS REPORT_HEAVY_LOAD_MEDIAN REPORT_HEAVY_LOAD_P95 <<<"$(extract_metric_with_patterns "heavy-load metrics" "$REPORT_HEAVY_LOAD_LINE" \
    's/.*fps=([0-9.]+).*pipe\[min\/med\/avg\/p95\/max\]=([0-9.]+)\/([0-9.]+)\/([0-9.]+)\/([0-9.]+)\/([0-9.]+)ms.*/\1 \3 \5/p' \
    's/.*fps=([0-9.]+), pipeline: median=([0-9.]+)ms p95=([0-9.]+)ms.*/\1 \2 \3/p')"
  read -r REPORT_OVERALL_PASSED REPORT_OVERALL_TOTAL <<<"$(extract_metric_value "overall result" "$(echo "$REPORT_COMPLETE_LINE" | sed -nE 's/.*COMPLETE: ([0-9]+)\/([0-9]+) passed.*/\1 \2/p')")"

  if echo "$REPORT_SECURITY_LINE" | grep -q '\[TEST\] PASS:'; then
    REPORT_SECURITY_REJECTION="1"
  elif echo "$REPORT_SECURITY_LINE" | grep -q '\[TEST\] FAIL:'; then
    REPORT_SECURITY_REJECTION="0"
  else
    echo "ERROR: could not parse security rejection result from test log"
    return 1
  fi
}

create_report_commit() {
  local summary subject
  summary="vp ${REPORT_VIEWPORT_RESOLUTION}, frame ${REPORT_FRAME_RESOLUTION}, ${REPORT_FPS}fps, g2g ${REPORT_G2G_MEDIAN}/${REPORT_G2G_P95}/${REPORT_G2G_AVG}ms, overall ${REPORT_OVERALL_PASSED}/${REPORT_OVERALL_TOTAL}"
  subject="test-run: ${summary}"

  # METRICS.md goals are intentionally editable between runs and the file is
  # excluded from the tested code snapshot commit below.
  git add -A -- . ':(exclude).planning/METRICS.md' ':(exclude)scripts/__pycache__'
  git commit --allow-empty -m "$subject" -m "Notes: $REPORT_NOTES" -m "Frame pacing CV: $REPORT_FRAME_PACING_CV
Pipeline latency (median/p95/avg ms): $REPORT_PIPELINE_MEDIAN/$REPORT_PIPELINE_P95/$REPORT_PIPELINE_AVG
Glass-to-glass latency (median/p95/avg ms): $REPORT_G2G_MEDIAN/$REPORT_G2G_P95/$REPORT_G2G_AVG
Heavy-load FPS: $REPORT_HEAVY_LOAD_FPS
Heavy-load pipeline (median/p95 ms): $REPORT_HEAVY_LOAD_MEDIAN/$REPORT_HEAVY_LOAD_P95
Security rejection: $REPORT_SECURITY_REJECTION
Overall: $REPORT_OVERALL_PASSED/$REPORT_OVERALL_TOTAL"
}

commit_metrics_to_branch() {
  local tested_commit="$1"
  local worktree_dir status
  worktree_dir="$(mktemp -d /tmp/keyd-metrics-worktree.XXXXXX)"
  status=0

  if ! git show-ref --verify --quiet "refs/heads/$METRICS_BRANCH"; then
    git branch "$METRICS_BRANCH"
  fi

  if ! git worktree add --quiet "$worktree_dir" "$METRICS_BRANCH"; then
    rm -rf "$worktree_dir"
    echo "ERROR: failed to create temporary worktree for metrics branch"
    return 1
  fi

  mkdir -p "$worktree_dir/.planning"
  cp "$PWD/.planning/METRICS.md" "$worktree_dir/.planning/METRICS.md"

  (
    cd "$worktree_dir" || exit 1

    if git diff --quiet HEAD -- .planning/METRICS.md 2>/dev/null; then
      echo "Metrics branch already up to date"
      exit 0
    fi

    git add .planning/METRICS.md
    git commit -m "metrics: record results for $tested_commit" -m "Notes: $REPORT_NOTES"
  ) || status=$?

  git worktree remove --force "$worktree_dir" >/dev/null 2>&1 || rm -rf "$worktree_dir"
  return "$status"
}

run_reporting() {
  log_progress "=== Reporting: parsing test metrics ==="
  if ! collect_report_metrics; then
    log_progress "ERROR: reporting parser could not extract required metrics from test output"
    return 1
  fi

  log_progress "=== Reporting: creating tested snapshot commit ==="
  create_report_commit
  REPORT_COMMIT_ID="$(git rev-parse --short=7 HEAD)"
  log_progress "Report commit created: $REPORT_COMMIT_ID"

  log_progress "=== Reporting: updating METRICS.md ==="
  python3 scripts/update_metrics.py \
    --commit-id "$REPORT_COMMIT_ID" \
    --viewport-resolution "$REPORT_VIEWPORT_RESOLUTION" \
    --frame-resolution "$REPORT_FRAME_RESOLUTION" \
    --fps "$REPORT_FPS" \
    --frame-pacing-cv "$REPORT_FRAME_PACING_CV" \
    --pipeline-median-ms "$REPORT_PIPELINE_MEDIAN" \
    --pipeline-p95-ms "$REPORT_PIPELINE_P95" \
    --pipeline-avg-ms "$REPORT_PIPELINE_AVG" \
    --g2g-median-ms "$REPORT_G2G_MEDIAN" \
    --g2g-p95-ms "$REPORT_G2G_P95" \
    --g2g-avg-ms "$REPORT_G2G_AVG" \
    --heavy-load-fps "$REPORT_HEAVY_LOAD_FPS" \
    --heavy-load-pipeline-median-ms "$REPORT_HEAVY_LOAD_MEDIAN" \
    --heavy-load-pipeline-p95-ms "$REPORT_HEAVY_LOAD_P95" \
    --security-rejection "$REPORT_SECURITY_REJECTION" \
    --overall "$REPORT_OVERALL_PASSED/$REPORT_OVERALL_TOTAL" \
    --notes "$REPORT_NOTES"
  log_progress "METRICS.md updated for commit $REPORT_COMMIT_ID"

  log_progress "=== Reporting: committing METRICS.md to $METRICS_BRANCH branch ==="
  commit_metrics_to_branch "$REPORT_COMMIT_ID"
  log_progress "METRICS.md committed on $METRICS_BRANCH for tested commit $REPORT_COMMIT_ID"
}

# ---- Step 1: Build Mac agent and iPad app in parallel ----
log_progress "=== [1/6] Building Mac agent + iPad app in parallel ==="
xcodebuild \
  -project "$MAC_PROJECT" \
  -allowProvisioningUpdates \
  -scheme "$MAC_SCHEME" \
  -destination "platform=macOS,arch=arm64" \
  -configuration Release \
  -derivedDataPath "$MAC_DERIVED_DATA" \
  clean build \
  > "$MAC_BUILD_LOG" 2>&1 &
MAC_BUILD_PID=$!

log_progress "[CONSOLE] e2e-ipad-build entry attempt=1 device=$IPAD_DEVICE_ID derivedData=$IPAD_DERIVED_DATA"
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
IPAD_BUILD_FAIL_REASON="none"
IPAD_BUILD_FAIL_DETAIL=""
IPAD_BUILD_STALLED=false

wait_for_job "$MAC_BUILD_PID" "Mac build" "$MAC_BUILD_LOG" 900 240 || MAC_BUILD_OK=false
if wait_for_job "$IPAD_BUILD_PID" "iPad build" "$IPAD_BUILD_LOG" 900 120; then
  IPAD_BUILD_OK=true
else
  IPAD_BUILD_OK=false
  IPAD_BUILD_FAIL_REASON="$WAIT_FOR_JOB_FAIL_REASON"
  IPAD_BUILD_FAIL_DETAIL="$WAIT_FOR_JOB_FAIL_DETAIL"
  if [ "$IPAD_BUILD_FAIL_REASON" = "log-stall-timeout" ] || [ "$IPAD_BUILD_FAIL_REASON" = "wall-timeout" ]; then
    IPAD_BUILD_STALLED=true
  fi
fi

MAC_BUILD_PID=""
IPAD_BUILD_PID=""

if [ "$IPAD_BUILD_OK" = true ]; then
  log_progress "[CONSOLE] e2e-ipad-build success attempt=1 device=$IPAD_DEVICE_ID"
else
  ipad_destination_timeout=false
  if grep -q "Timed out waiting for all destinations matching the provided destination specifier to become available" "$IPAD_BUILD_LOG" 2>/dev/null; then
    ipad_destination_timeout=true
  fi
  log_progress "[CONSOLE] e2e-ipad-build failure attempt=1 device=$IPAD_DEVICE_ID destinationTimeout=$ipad_destination_timeout waitFailReason=$IPAD_BUILD_FAIL_REASON waitFailDetail=$IPAD_BUILD_FAIL_DETAIL stalled=$IPAD_BUILD_STALLED"

  if [ "$ipad_destination_timeout" = true ] || [ "$IPAD_BUILD_STALLED" = true ]; then
    retry_decision_reason="destination-timeout"
    if [ "$IPAD_BUILD_STALLED" = true ]; then
      retry_decision_reason="watchdog-$IPAD_BUILD_FAIL_REASON"
    fi
    log_progress "[CONSOLE] e2e-ipad-build decision attempt=1 reason=$retry_decision_reason action=retry waitSeconds=10"
    sleep 10

    {
      echo ""
      echo "=== RETRY ATTEMPT 2 ($(date '+%Y-%m-%d %H:%M:%S')) ==="
    } >> "$IPAD_BUILD_LOG"

    log_progress "[CONSOLE] e2e-ipad-build entry attempt=2 device=$IPAD_DEVICE_ID derivedData=$IPAD_DERIVED_DATA"
    xcodebuild \
      -workspace "$WORKSPACE" \
      -scheme "$IPAD_SCHEME" \
      -destination "id=$IPAD_DEVICE_ID" \
      -configuration Release \
      -derivedDataPath "$IPAD_DERIVED_DATA" \
      clean build \
      >> "$IPAD_BUILD_LOG" 2>&1 &
    IPAD_BUILD_PID=$!

    if wait_for_job "$IPAD_BUILD_PID" "iPad build retry" "$IPAD_BUILD_LOG" 900 120; then
      IPAD_BUILD_OK=true
      log_progress "[CONSOLE] e2e-ipad-build success attempt=2 device=$IPAD_DEVICE_ID"
    else
      IPAD_BUILD_OK=false
      retry_wait_fail_reason="$WAIT_FOR_JOB_FAIL_REASON"
      retry_wait_fail_detail="$WAIT_FOR_JOB_FAIL_DETAIL"
      retry_destination_timeout=false
      if grep -q "Timed out waiting for all destinations matching the provided destination specifier to become available" "$IPAD_BUILD_LOG" 2>/dev/null; then
        retry_destination_timeout=true
      fi
      retry_stalled=false
      if [ "$retry_wait_fail_reason" = "log-stall-timeout" ] || [ "$retry_wait_fail_reason" = "wall-timeout" ]; then
        retry_stalled=true
      fi
      log_progress "[CONSOLE] e2e-ipad-build failure attempt=2 device=$IPAD_DEVICE_ID destinationTimeout=$retry_destination_timeout waitFailReason=$retry_wait_fail_reason waitFailDetail=$retry_wait_fail_detail stalled=$retry_stalled"
      log_progress "[CONSOLE] e2e-ipad-build exit status=failed reason=retry-exhausted"
    fi
    IPAD_BUILD_PID=""
  else
    log_progress "[CONSOLE] e2e-ipad-build decision attempt=1 reason=non-timeout action=no-retry"
    log_progress "[CONSOLE] e2e-ipad-build exit status=failed reason=non-timeout-build-error"
  fi
fi

log_progress "$(summarize_build_log "$MAC_BUILD_LOG")"
log_progress "$(summarize_build_log "$IPAD_BUILD_LOG")"
log_progress ""

if [ "$MAC_BUILD_OK" != true ] || [ "$IPAD_BUILD_OK" != true ]; then
  exit 1
fi

start_async_index "run-e2e-tests.sh"

MAC_APP="$MAC_DERIVED_DATA/Build/Products/Release/RemoteDesktopAgent.app"
if [ ! -d "$MAC_APP" ]; then
  MAC_APP=$(find "$MAC_DERIVED_DATA" -name "RemoteDesktopAgent.app" -path "*/Release/*" -not -path "*/Index.noindex/*" 2>/dev/null | head -1)
fi
if [ -z "$MAC_APP" ] || [ ! -d "$MAC_APP" ]; then
  echo "ERROR: Could not find built Mac .app bundle"
  exit 1
fi

# Secure Enclave identity self-test (fail closed): key in the SE, export refused, TLS 1.3
# loopback with that identity. The fingerprint goes to the iPad, which checks it against the
# certificate it pinned over the real connection (sec-identity-secure-enclave).
IDENTITY_SELFTEST_OUT=$("$MAC_APP/Contents/MacOS/RemoteDesktopAgent" --identity-selftest 2>&1)
IDENTITY_SELFTEST_RC=$?
echo "$IDENTITY_SELFTEST_OUT" | sed 's/^/[identity] /'
if [ "$IDENTITY_SELFTEST_RC" -ne 0 ]; then
  echo "ERROR: Secure Enclave identity self-test failed (rc=$IDENTITY_SELFTEST_RC); the agent cannot serve. Check signing (keychain-access-groups + provisioning profile)."
  exit 1
fi
MAC_IDENTITY_FP=$(echo "$IDENTITY_SELFTEST_OUT" | sed -n 's/.*identity ok fingerprint=\([0-9a-f]*\).*/\1/p' | head -1)
MAC_IDENTITY_TOKEN=$(echo "$IDENTITY_SELFTEST_OUT" | sed -n 's/.*export=refused token=\([^ ]*\).*/\1/p' | head -1)
MAC_IDENTITY_ARG="fp=${MAC_IDENTITY_FP};export=refused;token=${MAC_IDENTITY_TOKEN};tls13=ok"

IPAD_APP="$IPAD_DERIVED_DATA/Build/Products/Release-iphoneos/RemoteDesktopApp.app"
if [ ! -d "$IPAD_APP" ]; then
  IPAD_APP=$(find "$IPAD_DERIVED_DATA" -name "RemoteDesktopApp.app" -path "*/Release-iphoneos/*" -not -path "*/Index.noindex/*" 2>/dev/null | head -1)
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

# The agent's TLS identity is a Secure Enclave key in the data-protection keychain
# (PairingManager.m, tla/KeyCustody.tla). No key file, no fallback.
rm -rf /tmp/keydrd-tls 2>/dev/null || true
log_progress ""

# ---- Step 4: Start Mac log capture, then launch Mac agent ----
log_progress "=== [4/6] Launching Mac agent in test mode ==="
if [ -n "$CAPTURE_FILE" ] && [ ! -f "$CAPTURE_FILE" ]; then
  echo "ERROR: capture file does not exist: $CAPTURE_FILE"
  exit 1
fi
if [ "$REAL_CAPTURE" = true ] && [ "$STRESS_CAPTURE" = true ]; then
  echo "ERROR: --real-capture and --stress-capture are mutually exclusive"
  exit 1
fi
if [ -n "$CAPTURE_FILE" ] && [ "$STRESS_CAPTURE" = true ]; then
  echo "ERROR: --capture-file and --stress-capture are mutually exclusive"
  exit 1
fi
if [ -n "$CAPTURE_FILE" ] && [ "$REAL_CAPTURE" = true ]; then
  echo "ERROR: --capture-file and --real-capture are mutually exclusive"
  exit 1
fi

MAC_LAUNCH_ARGS=(--test-mode --automation-mode)
if [ "${NO_PEER_TO_PEER:-false}" = true ]; then
  MAC_LAUNCH_ARGS+=(--no-peer-to-peer)
fi
if [ "$WIRED_ONLY" = true ]; then
  MAC_LAUNCH_ARGS+=(--wired-only)
elif [ "$WIRELESS_ONLY" = true ]; then
  MAC_LAUNCH_ARGS+=(--wireless-only)
fi
if [ -n "$CAPTURE_FILE" ]; then
  # The agent runs as its own app (LaunchServices launch below), so a file under
  # ~/Documents would need its own Documents-folder permission: the open blocks on that
  # consent and stalls the agent's transport queue (seen: 28 s, input replies starved).
  # Hand it an APFS clone in /tmp instead: instant, no extra space. No full-copy fallback
  # (the file is ~20 GB); if cloning fails, use the original path and say so.
  AGENT_CAPTURE_FILE="$CAPTURE_FILE"
  case "$CAPTURE_FILE" in
    "$HOME"/Documents/*|"$HOME"/Desktop/*|"$HOME"/Downloads/*)
      CLONE_PATH="/tmp/keyd-e2e-capture.${CAPTURE_FILE##*.}"
      rm -f "$CLONE_PATH"
      if cp -c "$CAPTURE_FILE" "$CLONE_PATH" 2>/dev/null; then
        AGENT_CAPTURE_FILE="$CLONE_PATH"
        log_progress "Mac capture file cloned outside protected folders: $CLONE_PATH"
      else
        log_progress "WARNING: could not APFS-clone capture file; agent may block on Documents access"
      fi
      ;;
  esac
  MAC_LAUNCH_ARGS+=(--test-capture-file "$AGENT_CAPTURE_FILE")
  if [ "$CAPTURE_FILE" = "$DEFAULT_CAPTURE_FILE" ]; then
    log_progress "Mac synthetic capture file: $CAPTURE_FILE (default auto-selected)"
  else
    log_progress "Mac synthetic capture file: $CAPTURE_FILE"
  fi
  log_progress "Mac synthetic capture mode: file-backed playback"
elif [ "$STRESS_CAPTURE" = true ]; then
  MAC_LAUNCH_ARGS+=(--stress-capture)
  log_progress "Mac synthetic capture mode: procedural full-frame stress"
elif [ "$REAL_CAPTURE" = true ]; then
  MAC_LAUNCH_ARGS+=(--real-capture)
  log_progress "Mac capture mode: live ScreenCaptureKit desktop capture"
else
  log_progress "Mac synthetic capture mode: procedural full-frame stress (default)"
fi

# Stream Mac logs in background (capture all agent subsystems including ScreenCapture's com.keydrd)
log stream --predicate "subsystem == '$MAC_SUBSYSTEM' OR subsystem BEGINSWITH 'com.keydrd'" --style compact > "$MAC_LOG_FILE" 2>&1 &
MAC_LOG_PID=$!
sleep 1

# Launch through LaunchServices, not by exec'ing the binary: TCC attributes a binary started
# from a shell to the shell's responsible app (Terminal, Claude, ...), so the agent's own
# Accessibility grant would not apply and CGEventPost would drop every input event.
MAC_STDOUT_LOG="/tmp/keyd-e2e-mac-stdout.log"
open -n -g -a "$MAC_APP" --stdout "$MAC_STDOUT_LOG" --stderr "$MAC_STDOUT_LOG" --args "${MAC_LAUNCH_ARGS[@]}"
for i in $(seq 1 50); do
  MAC_PID=$(pgrep -n -f "$MAC_APP/Contents/MacOS/RemoteDesktopAgent" || true)
  [ -n "$MAC_PID" ] && break
  sleep 0.1
done
if [ -z "$MAC_PID" ]; then
  echo "ERROR: Mac agent did not start via open -a $MAC_APP"
  cat "$MAC_STDOUT_LOG" 2>/dev/null | tail -20
  exit 1
fi
echo "Mac agent PID: $MAC_PID (launched via LaunchServices; stdout: $MAC_STDOUT_LOG)"

# ---- Step 5: Wait for Mac to be ready and write the QR payload file ----
log_progress "=== [5/6] Waiting for Mac QR readiness ==="
echo "Waiting for Mac to write QR payload..."
QR_PAYLOAD_B64=""
SAW_QR_SHOWN_LOG=false
SAW_QR_READY_LOG=false
for i in $(seq 1 15); do
  if [ "$SAW_QR_SHOWN_LOG" = false ] && grep -q "$QR_SHOWN_LOG" "$MAC_LOG_FILE" 2>/dev/null; then
    log_progress "Mac log reported QR pairing setup"
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
launch_ipad_for_tests() {
  local launch_args=("$@")
  local max_attempts=2
  local attempt=1
  local launch_probe_seconds=12
  local retry_wait_seconds=6

  while [ "$attempt" -le "$max_attempts" ]; do
    if [ "$attempt" -gt 1 ]; then
      {
        echo ""
        echo "=== LAUNCH RETRY ATTEMPT $attempt ($(date '+%Y-%m-%d %H:%M:%S')) ==="
      } >> "$IPAD_LOG_FILE"
    fi

    log_progress "[CONSOLE] e2e-ipad-launch entry attempt=$attempt device=$IPAD_DEVICE_ID profile=$PROFILE transportRotation=$ROTATION_TRANSPORTS"

    xcrun devicectl device process launch \
      --device "$IPAD_DEVICE_ID" \
      --terminate-existing \
      --console \
      "$BUNDLE_ID" \
      -- "${launch_args[@]}" \
      2>&1 | tee -a "$IPAD_LOG_FILE" | awk -v results_log="$LOG_FILE" '
        /\[TEST\]/ {
          print
          print >> results_log
          fflush()
          fflush(results_log)
        }
      ' &
    IPAD_PID=$!

    local probe_elapsed=0
    while [ "$probe_elapsed" -lt "$launch_probe_seconds" ]; do
      if ! kill -0 "$IPAD_PID" 2>/dev/null; then
        break
      fi
      if grep -q "\[TEST\] RUNNING:" "$IPAD_LOG_FILE" 2>/dev/null; then
        break
      fi
      sleep 1
      probe_elapsed=$((probe_elapsed + 1))
    done

    if kill -0 "$IPAD_PID" 2>/dev/null; then
      log_progress "[CONSOLE] e2e-ipad-launch success attempt=$attempt pid=$IPAD_PID probeSec=$probe_elapsed"
      return 0
    fi

    local launch_reason="process-exit-early"
    if grep -q "Broken pipe" "$IPAD_LOG_FILE" 2>/dev/null; then
      launch_reason="broken-pipe"
    elif grep -q "No provider was found" "$IPAD_LOG_FILE" 2>/dev/null; then
      launch_reason="no-provider"
    elif grep -q "timed out" "$IPAD_LOG_FILE" 2>/dev/null; then
      launch_reason="devicectl-timeout"
    fi

    log_progress "[CONSOLE] e2e-ipad-launch failure attempt=$attempt reason=$launch_reason probeSec=$probe_elapsed"

    if [ "$attempt" -lt "$max_attempts" ] && { [ "$launch_reason" = "broken-pipe" ] || [ "$launch_reason" = "no-provider" ]; }; then
      log_progress "[CONSOLE] e2e-ipad-launch decision attempt=$attempt reason=$launch_reason action=retry waitSeconds=$retry_wait_seconds"
      # Nudge CoreDevice to refresh tunnel/provider state before retry.
      xcrun devicectl list devices >/dev/null 2>&1 || true
      sleep "$retry_wait_seconds"
      attempt=$((attempt + 1))
      continue
    fi

    log_progress "[CONSOLE] e2e-ipad-launch exit status=failed attempt=$attempt reason=$launch_reason"
    return 1
  done

  log_progress "[CONSOLE] e2e-ipad-launch exit status=failed reason=retry-exhausted maxAttempts=$max_attempts"
  return 1
}

# Build launch arguments array
IPAD_LAUNCH_ARGS=(--test-mode --qr-payload "$QR_PAYLOAD_B64")
IPAD_LAUNCH_ARGS+=(--mac-identity "$MAC_IDENTITY_ARG")
IPAD_LAUNCH_ARGS+=(--transport-rotation "$ROTATION_TRANSPORTS")
IPAD_LAUNCH_ARGS+=(--transports "$ROTATION_TRANSPORTS")
IPAD_LAUNCH_ARGS+=(--profile "$PROFILE")
if [ -n "$VIDEO_PLAYBACK_WINDOW_SECONDS" ]; then
  IPAD_LAUNCH_ARGS+=(--video-playback-window-seconds "$VIDEO_PLAYBACK_WINDOW_SECONDS")
fi
if [ -n "$VIDEO_PLAYBACK_OFFSET_SECONDS" ]; then
  IPAD_LAUNCH_ARGS+=(--video-playback-offset-seconds "$VIDEO_PLAYBACK_OFFSET_SECONDS")
fi
# Append optional flags
if [ -n "$EXPECT_TRANSPORT" ]; then
  IPAD_LAUNCH_ARGS+=(--expected-transport "$EXPECT_TRANSPORT")
  IPAD_LAUNCH_ARGS+=(--expect-transport "$EXPECT_TRANSPORT")
fi
if [ -n "$LATENCY_TARGET" ]; then
  IPAD_LAUNCH_ARGS+=(--latency-target-ms "$LATENCY_TARGET")
fi
if [ -n "$EXPECT_RESOLUTION" ]; then
  IPAD_LAUNCH_ARGS+=(--expect-resolution "$EXPECT_RESOLUTION")
fi
if [ -n "$EXPECT_FPS" ]; then
  IPAD_LAUNCH_ARGS+=(--expect-fps "$EXPECT_FPS")
fi
if [ -n "$SUSTAINED_STREAM_SECONDS" ]; then
  IPAD_LAUNCH_ARGS+=(--sustained-stream-seconds "$SUSTAINED_STREAM_SECONDS")
fi
if [ "$SKIP_TRANSPORT_ROTATION" = true ]; then
  IPAD_LAUNCH_ARGS+=(--skip-transport-rotation)
fi
if [ "${NO_PEER_TO_PEER:-false}" = true ]; then
  IPAD_LAUNCH_ARGS+=(--no-peer-to-peer)
fi
if [ "$WIRED_ONLY" = true ]; then
  IPAD_LAUNCH_ARGS+=(--wired-only)
elif [ "$WIRELESS_ONLY" = true ]; then
  IPAD_LAUNCH_ARGS+=(--wireless-only)
fi

log_progress "iPad launch args: ${IPAD_LAUNCH_ARGS[*]}"

# Pass the QR payload as a launch argument (--qr-payload <base64>)
# iPad reads this instead of scanning a physical QR code
if ! launch_ipad_for_tests "${IPAD_LAUNCH_ARGS[@]}"; then
  echo "ERROR: iPad launch failed before test execution"
  echo "--- Last 40 iPad launch lines ---"
  tail -n 40 "$IPAD_LOG_FILE" 2>/dev/null
  exit 1
fi

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

    if grep -q "\[TEST\] COMPLETE:" "$IPAD_LOG_FILE" 2>/dev/null; then
      # Give a moment for any remaining output
      sleep 1
      break
    fi

    if [ -n "$IPAD_PID" ] && ! kill -0 "$IPAD_PID" 2>/dev/null; then
      if ! grep -q "\[TEST\] COMPLETE:" "$IPAD_LOG_FILE" 2>/dev/null; then
        ipad_launch_drop_reason="process-exit"
        if grep -q "Broken pipe" "$IPAD_LOG_FILE" 2>/dev/null; then
          ipad_launch_drop_reason="broken-pipe"
        elif grep -q "No provider was found" "$IPAD_LOG_FILE" 2>/dev/null; then
          ipad_launch_drop_reason="no-provider"
        fi
        log_progress "[CONSOLE] e2e-ipad-launch failure attempt=active reason=$ipad_launch_drop_reason action=abort-wait elapsedSec=$ELAPSED"
        echo ""
        echo "ERROR: iPad launch stream exited early (reason=$ipad_launch_drop_reason)"
        echo "--- Last 20 iPad launch lines ---"
        tail -n 20 "$IPAD_LOG_FILE" 2>/dev/null
        break
      fi
    fi

    # Detect app crash (signal termination)
    if grep -q "terminated due to signal" "$IPAD_LOG_FILE" 2>/dev/null; then
      echo ""
      echo "CRASH DETECTED: iPad app terminated by signal"
      grep "signal" "$IPAD_LOG_FILE" 2>/dev/null | tail -1
      echo "--- Last 20 iPad console lines ---"
      grep "\[CONSOLE\]" "$IPAD_LOG_FILE" 2>/dev/null | tail -20
      echo "--- Last 20 Mac agent lines ---"
      tail -20 "$MAC_LOG_FILE" 2>/dev/null
      break
    fi

    # Detect Mac agent crash
    if [ -n "$MAC_PID" ] && ! kill -0 "$MAC_PID" 2>/dev/null; then
      echo ""
      echo "CRASH DETECTED: Mac agent (PID $MAC_PID) no longer running"
      echo "--- Last 20 Mac agent lines ---"
      tail -20 "$MAC_LOG_FILE" 2>/dev/null
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

  is_high_signal_test_line() {
    case "$1" in
      *"[TEST] PASS:"*|*"[TEST] FAIL:"*|*"[TEST] COMPLETE:"*|*"[TEST] START:"*|*"[TEST] RUNNING:"*) return 0 ;;
    esac

    case "$1" in
      *"latency-probe"*|*"clock-sync"*|*"pipeline-latency"*|*"glass-to-glass-latency"*|*"latency-tiered"*|*"throughput"*|*"fps"*|*"frame-pacing"*|*"frame-loss"*|*"resolution"*|*"heavy-load"*|*"transport-detected"*|*"session-handshake"*|*"keepalive"*|*"multi-transport"*|*"transport-assertion"*|*"wifi-"*|*"transport-usb"*|*"transport-wifi"*|*"transport-awdl"*) return 0 ;;
      *"video-playback"*) return 0 ;;
    esac

    return 1
  }

  if [ -f "$IPAD_LOG_FILE" ]; then
    # Extract [TEST] lines
    grep "\[TEST\]" "$IPAD_LOG_FILE" 2>/dev/null | while IFS= read -r line; do
      if ! is_high_signal_test_line "$line"; then
        continue
      fi

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

    PASSED=$(grep -c "\[TEST\] PASS:" "$IPAD_LOG_FILE" 2>/dev/null) || PASSED=0
    FAILED=$(grep -c "\[TEST\] FAIL:" "$IPAD_LOG_FILE" 2>/dev/null) || FAILED=0
    TOTAL=$((PASSED + FAILED))

    echo ""
    echo "--------------------------------------------"
    printf "  Passed: \033[32m%s\033[0m\n" "$PASSED"
    printf "  Failed: \033[31m%s\033[0m\n" "$FAILED"
    echo "  Total:  $TOTAL"
    echo "--------------------------------------------"
    {
      echo "--------------------------------------------"
      echo "Passed: $PASSED"
      echo "Failed: $FAILED"
      echo "Total: $TOTAL"
      echo "--------------------------------------------"
    } >> "$LOG_FILE"
    summarize_frame_checks

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
      tail -50 "$IPAD_LOG_FILE" 2>/dev/null || echo "(no output)"
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
  set +e
  wait_and_parse_results "basic + extended (no latency target)"
  BASIC_RESULT=$?
  set -e

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
    rm -f "$LOG_FILE" "$IPAD_LOG_FILE"

    TIER_ARGS=(--test-mode --qr-payload "$QR_PAYLOAD_B64" --latency-target-ms "$TIER")
    if [ -n "$EXPECT_TRANSPORT" ]; then
      TIER_ARGS+=(--expected-transport "$EXPECT_TRANSPORT")
      TIER_ARGS+=(--expect-transport "$EXPECT_TRANSPORT")
    fi

    xcrun devicectl device process launch \
      --device "$IPAD_DEVICE_ID" \
      --terminate-existing \
      --console \
      "$BUNDLE_ID" \
      -- "${TIER_ARGS[@]}" \
      > "$IPAD_LOG_FILE" 2>&1 &
    IPAD_PID=$!

    set +e
    wait_and_parse_results "latency-tier=${TIER}ms"
    TIER_RESULT=$?
    set -e

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
set +e
wait_and_parse_results ""
RESULT=$?
set -e

set +e
run_reporting
REPORT_RESULT=$?
set -e

echo ""
if [ "$REPORT_RESULT" -ne 0 ]; then
  log_progress "Reporting failed before commit/metrics update."
  exit 1
fi

if [ "$RESULT" -ne 0 ]; then
  echo "Test run completed with failures."
  exit 1
fi

echo "All tests passed."
exit 0
