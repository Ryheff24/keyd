#!/bin/zsh
# Search Apple developer documentation through Xcode's MCP DocumentationSearch tool.
# Usage: scripts/xcode-docs.sh "query" [wait_seconds]
# Needs Xcode 27+ and a one-time approval (granted the first time a workspace is opened via mcpbridge).
# Must run outside the Claude Code Bash sandbox.
set -euo pipefail
[[ $# -ge 1 ]] || { echo "usage: $0 \"query\" [wait_seconds]" >&2; exit 2; }
wait=${2:-20}
q=$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")
bridge=$(xcode-select -p)/usr/bin/mcpbridge
{
  print -r -- '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"keyd-xcode-docs","version":"1"}}}'
  sleep 2
  print -r -- '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  print -r -- "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"DocumentationSearch\",\"arguments\":{\"query\":$q}}}"
  sleep "$wait"
} | timeout $(( wait + 5 )) "$bridge" 2>/dev/null | python3 -c '
import sys, json
for line in sys.stdin:
    try: msg = json.loads(line)
    except ValueError: continue
    if msg.get("id") != 2: continue
    if "error" in msg: print(msg["error"]); break
    for c in msg.get("result", {}).get("content", []):
        try: docs = json.loads(c.get("text", "")).get("documents", [])
        except ValueError: print(c.get("text", "")); continue
        for d in docs:
            print("## " + d["title"] + "  (https://developer.apple.com" + d["uri"] + ")")
            print(d["contents"][:1500]); print()
' || true
