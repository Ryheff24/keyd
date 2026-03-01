#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"

if [[ "$mode" != "deploy" && "$mode" != "run" && "$mode" != "stop" && "$mode" != "run-mac" && "$mode" != "run-ios" && "$mode" != "attach" && "$mode" != "attach-mac" && "$mode" != "attach-ios" ]]; then
  echo "Usage: $0 [deploy|run|stop|run-mac|run-ios|attach|attach-mac|attach-ios]" >&2
  exit 1
fi

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

workspace_path="${WORKSPACE_PATH:-keyd.xcworkspace}"
derived_data="${DERIVED_DATA:-.build/DerivedData}"
log_root="${LOG_ROOT:-logs}"
configuration="${CONFIGURATION:-Debug}"

ios_scheme="${IOS_SCHEME:-KeydApp}"
ios_app_name="${IOS_APP_NAME:-KeydApp}"
ios_bundle_id="${IOS_BUNDLE_ID:-com.ryheff.keyd}"
ios_labels_csv="${IOS_LABELS:-}"

mac_scheme="${MAC_SCHEME:-KeydAgent}"
mac_app_name="${MAC_APP_NAME:-KeydAgent}"
mac_process_name="${MAC_PROCESS_NAME:-KeydAgent}"
log_subsystem="${LOG_SUBSYSTEM:-com.ryheff.keyd}"

resolve_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf "%s\n" "$path"
  else
    printf "%s/%s\n" "$root_dir" "$path"
  fi
}

trim() {
  printf "%s" "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

slugify() {
  printf "%s" "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-'
}

log_step() {
  printf "==> %s\n" "$1"
}

workspace_abs="$(resolve_path "$workspace_path")"
derived_data_abs="$(resolve_path "$derived_data")"
log_root_abs="$(resolve_path "$log_root")"

declare -a ios_devices=()
declare -a ios_labels=()

append_device() {
  local device="$1"
  local label="$2"
  if [[ -n "$device" ]]; then
    ios_devices+=("$device")
    ios_labels+=("$label")
  fi
}

load_devices() {
  local device_csv="${IOS_DEVICES:-}"
  local label_csv="${ios_labels_csv:-}"
  local raw_devices
  local raw_device
  local device
  local raw_labels
  local label=""
  local index=0

  ios_devices=()
  ios_labels=()

  if [[ -n "$device_csv" ]]; then
    IFS=',' read -r -a raw_devices <<< "$device_csv"
    if [[ -n "$label_csv" ]]; then
      IFS=',' read -r -a raw_labels <<< "$label_csv"
    else
      raw_labels=()
    fi
    for raw_device in "${raw_devices[@]}"; do
      device="$(trim "$raw_device")"
      if [[ -n "$device" ]]; then
        if [[ ${#raw_labels[@]} -gt $index ]]; then
          label="$(trim "${raw_labels[$index]}")"
        else
          label=""
        fi
        if [[ -z "$label" ]]; then
          label="$(slugify "$device")"
        fi
        append_device "$device" "$label"
        index=$((index + 1))
      fi
    done
  else
    append_device "${IPAD_DEVICE:-}" "iPad"
    append_device "${IPHONE_DEVICE:-}" "iPhone"
  fi

  if [[ ${#ios_devices[@]} -eq 0 ]]; then
    echo "Set IOS_DEVICES (comma-separated) or IPAD_DEVICE/IPHONE_DEVICE before running make $mode." >&2
    exit 1
  fi
}

stop_active_run() {
  local latest_link="$log_root_abs/latest"
  local active_dir=""
  local meta_dir=""
  local pid_file=""
  local pid=""

  if [[ -L "$latest_link" ]]; then
    active_dir="$(cd "$log_root_abs" && cd "$(readlink "$latest_link")" && pwd)"
  elif [[ -d "$latest_link" ]]; then
    active_dir="$latest_link"
  fi

  if [[ -z "$active_dir" || ! -d "$active_dir" ]]; then
    echo "No active log session found at $latest_link" >&2
    exit 0
  fi

  meta_dir="$active_dir/meta"
  if [[ -d "$meta_dir" ]]; then
    for pid_file in "$meta_dir"/*.pid; do
      [[ -e "$pid_file" ]] || continue
      pid="$(tr -d '[:space:]' < "$pid_file")"
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
      fi
    done
  fi

  pkill -x "$mac_process_name" 2>/dev/null || true

  printf "Stopped local run processes from %s\n" "$active_dir"
}

if [[ "$mode" == "stop" ]]; then
  stop_active_run
  exit 0
fi

mkdir -p "$log_root_abs"
session_dir="$log_root_abs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$session_dir"
meta_dir="$session_dir/meta"
mkdir -p "$meta_dir"
latest_dir="$log_root_abs/latest"
if [[ -L "$latest_dir" ]]; then
  rm -f "$latest_dir"
fi
mkdir -p "$latest_dir"
latest_meta_dir="$latest_dir/meta"
mkdir -p "$latest_meta_dir"

if [[ "$mode" == "deploy" || "$mode" == "run" || "$mode" == "run-ios" || "$mode" == "attach-ios" ]]; then
  load_devices
fi

mac_app_bundle="$derived_data_abs/Build/Products/$configuration/$mac_app_name.app"
mac_binary="$mac_app_bundle/Contents/MacOS/$mac_app_name"
ios_app_bundle="$derived_data_abs/Build/Products/${configuration}-iphoneos/$ios_app_name.app"

build_mac() {
  log_step "Building $mac_scheme"
  xcodebuild \
    -workspace "$workspace_abs" \
    -scheme "$mac_scheme" \
    -configuration "$configuration" \
    -derivedDataPath "$derived_data_abs" \
    build \
    > "$meta_dir/build-macos.log" 2>&1
  cp "$meta_dir/build-macos.log" "$latest_meta_dir/build-macos.log"

  if [[ ! -d "$mac_app_bundle" ]]; then
    echo "Expected macOS app bundle was not produced: $mac_app_bundle" >&2
    exit 1
  fi

  if [[ ! -x "$mac_binary" ]]; then
    echo "Expected macOS binary was not produced: $mac_binary" >&2
    exit 1
  fi
}

build_ios() {
  log_step "Building $ios_scheme for physical devices"
  xcodebuild \
    -workspace "$workspace_abs" \
    -scheme "$ios_scheme" \
    -configuration "$configuration" \
    -destination "generic/platform=iOS" \
    -derivedDataPath "$derived_data_abs" \
    build \
    > "$meta_dir/build-ios.log" 2>&1
  cp "$meta_dir/build-ios.log" "$latest_meta_dir/build-ios.log"

  if [[ ! -d "$ios_app_bundle" ]]; then
    echo "Expected iOS app bundle was not produced: $ios_app_bundle" >&2
    exit 1
  fi
}

install_ios_builds() {
  local index
  local device
  local label

  for index in "${!ios_devices[@]}"; do
    device="${ios_devices[$index]}"
    label="${ios_labels[$index]}"
    log_step "Installing on $device"
    xcrun devicectl device install app \
      --device "$device" \
      "$ios_app_bundle" \
      --log-output "$meta_dir/${label}-install.log" \
      > /dev/null
    cp "$meta_dir/${label}-install.log" "$latest_meta_dir/${label}-install.log"
  done
}

start_mac_log_collector() {
  if [[ -f "$meta_dir/mac-log.pid" ]]; then
    local existing_pid
    existing_pid="$(tr -d '[:space:]' < "$meta_dir/mac-log.pid")"
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      kill "$existing_pid" 2>/dev/null || true
    fi
  fi

  log_step "Starting macOS log stream"
  : > "$latest_dir/mac.log"
  /usr/bin/log stream \
    --style compact \
    --predicate "subsystem == \"$log_subsystem\" AND process == \"$mac_process_name\"" \
    2>&1 | tee "$session_dir/mac.log" > "$latest_dir/mac.log" &
  printf '%s\n' "$!" > "$meta_dir/mac-log.pid"
  cp "$meta_dir/mac-log.pid" "$latest_meta_dir/mac-log.pid"
}

launch_mac_app() {
  if pgrep -x "$mac_process_name" > /dev/null 2>&1; then
    pkill -x "$mac_process_name" || true
    sleep 1
  fi

  log_step "Launching $mac_app_name"
  /usr/bin/open -n "$mac_app_bundle" > /dev/null 2>&1
}

connect_ios_consoles() {
  local relaunch_existing="$1"
  local index
  local device
  local label
  local -a launch_args

  for index in "${!ios_devices[@]}"; do
    device="${ios_devices[$index]}"
    label="${ios_labels[$index]}"
    log_step "Launching on $device"
    launch_args=(
      xcrun devicectl device process launch
      --device "$device"
    )
    if [[ "$relaunch_existing" == "true" ]]; then
      launch_args+=(--terminate-existing)
    fi
    launch_args+=(
      --console
      "$ios_bundle_id"
    )

    : > "$latest_dir/${label}.log"
    "${launch_args[@]}" 2>&1 | tee "$session_dir/${label}.log" > "$latest_dir/${label}.log" &
    printf '%s\n' "$!" > "$meta_dir/${label}.pid"
    cp "$meta_dir/${label}.pid" "$latest_meta_dir/${label}.pid"
  done
}

case "$mode" in
  deploy)
    build_mac
    build_ios
    install_ios_builds
    ;;
  run)
    build_mac
    build_ios
    install_ios_builds
    start_mac_log_collector
    launch_mac_app
    connect_ios_consoles true
    ;;
  run-mac)
    build_mac
    start_mac_log_collector
    launch_mac_app
    ;;
  run-ios)
    build_ios
    install_ios_builds
    connect_ios_consoles true
    ;;
  attach)
    echo "attach relaunches the mac app and selected iOS app(s) and reattaches logs without building or reinstalling." >&2
    start_mac_log_collector
    launch_mac_app
    connect_ios_consoles true
    ;;
  attach-mac)
    echo "attach-mac relaunches the mac app and reattaches logs without building." >&2
    start_mac_log_collector
    launch_mac_app
    ;;
  attach-ios)
    echo "attach-ios relaunches the selected app(s) and reattaches logs without building or reinstalling." >&2
    connect_ios_consoles true
    ;;
esac

printf "\nLogs: %s\n" "$session_dir"
printf "Latest dir: %s\n" "$latest_dir"
printf "Metadata dir: %s\n" "$meta_dir"
if [[ "$mode" == "run" || "$mode" == "run-mac" || "$mode" == "attach" || "$mode" == "attach-mac" ]]; then
  printf "macOS runtime log: %s\n" "$session_dir/mac.log"
fi
if [[ "$mode" == "run" || "$mode" == "run-ios" || "$mode" == "attach" || "$mode" == "attach-ios" ]]; then
  for index in "${!ios_devices[@]}"; do
    label="${ios_labels[$index]}"
    printf "%s runtime log: %s\n" "$label" "$session_dir/${label}.log"
  done
fi
