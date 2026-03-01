---
status: resolved
trigger: "Update mac log collection script to include --info level logging"
created: 2026-03-01T00:00:00Z
updated: 2026-03-01T00:00:00Z
---

## Current Focus
Complete. Fixed mac log collection to include info-level logging.

## Symptoms
Mac log stream command in `scripts/deploy-and-run.sh` line 255 was not collecting info-level log messages.

## Resolution
root_cause: |
  The `/usr/bin/log stream` command in `start_mac_log_collector()` function was missing the `--info` flag,
  which caused info-level messages to be filtered out from logs/latest/mac.log
fix: |
  Added `--info` flag to the log stream command at line 255 in scripts/deploy-and-run.sh
verification: |
  Single-line modification verified:
  - Before: /usr/bin/log stream --style compact --predicate "subsystem == \"$log_subsystem\" AND process == \"$mac_process_name\"" 2>&1
  - After: /usr/bin/log stream --info --style compact --predicate "subsystem == \"$log_subsystem\" AND process == \"$mac_process_name\"" 2>&1
  - Change is minimal and targeted, affects only the log collection level
files_changed:
  - ./scripts/deploy-and-run.sh (line 255)
