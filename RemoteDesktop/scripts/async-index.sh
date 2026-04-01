#!/bin/bash
# Launch a non-blocking index refresh after successful builds.
#
# Usage from another script:
#   source "$(dirname "$0")/async-index.sh"
#   start_async_index "run-e2e-tests.sh"

start_async_index() {
  local caller="${1:-unknown}"
  local enable="${KEYD_ASYNC_INDEX:-1}"

  case "$enable" in
    0|false|FALSE|no|NO)
      echo "=== Async index disabled (KEYD_ASYNC_INDEX=$enable) ==="
      return 0
      ;;
  esac

  local repo_root
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

  local index_target="${KEYD_ASYNC_INDEX_TARGET:-index-remote}"
  local log_dir="${KEYD_ASYNC_INDEX_LOG_DIR:-/tmp/keyd-async-index}"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"

  mkdir -p "$log_dir"

  local pid_file="$log_dir/${index_target}.pid"
  if [ -f "$pid_file" ]; then
    local running_pid
    running_pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [ -n "$running_pid" ] && kill -0 "$running_pid" 2>/dev/null; then
      echo "=== Async index already running (PID $running_pid); skipping new launch ==="
      return 0
    fi
  fi

  local log_file="$log_dir/${stamp}-${caller}-${index_target}.log"
  local status_file="$log_dir/${stamp}-${caller}-${index_target}.status"

  nohup bash -c '
set +e
repo_root="$1"
index_target="$2"
caller="$3"
log_file="$4"
status_file="$5"
pid_file="$6"

cd "$repo_root" || exit 1
echo "=== Async index start $(date "+%Y-%m-%d %H:%M:%S") caller=$caller target=$index_target ==="
make "$index_target"
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "ok" > "$status_file"
  echo "=== Async index success $(date "+%Y-%m-%d %H:%M:%S") ==="
else
  {
    echo "failed:$rc"
    echo "log:$log_file"
    echo "errors:"
    grep -E "(^error:|^warning:|BUILD FAILED|Build FAILED)" "$log_file" | tail -60 || true
  } > "$status_file"
  echo "=== Async index failed rc=$rc $(date "+%Y-%m-%d %H:%M:%S") ==="
fi
rm -f "$pid_file"
exit "$rc"
' _ "$repo_root" "$index_target" "$caller" "$log_file" "$status_file" "$pid_file" >"$log_file" 2>&1 &

  local launched_pid=$!
  echo "$launched_pid" > "$pid_file"

  echo "=== Async index launched (PID $launched_pid, target $index_target) ==="
  echo "=== Async index log: $log_file ==="
  echo "=== Async index status: $status_file ==="
}