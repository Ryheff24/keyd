#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_PATH="${1:-/tmp/keydrd-capture-mimic.mov}"
DURATION="${2:-20}"

swift "$SCRIPT_DIR/generate-stress-video.swift" \
  --output "$OUTPUT_PATH" \
  --duration "$DURATION"
