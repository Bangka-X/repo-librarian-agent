#!/usr/bin/env bash
#
# stop.sh — stop all librarian background services.
#
# Kills the tmux sessions started by init.sh:
#   librarian       — Claude /loop sync daemon
#   librarian-http  — Streamable HTTP MCP server
#   librarian-feed  — the watch.sh live viewer
#
# Killing a tmux session also kills the process running inside it (claude /
# uvicorn), so the HTTP port is freed. Safe to run anytime; idempotent.
#
#   bash stop.sh
#
set -uo pipefail

SESSIONS=(librarian librarian-http librarian-feed)

stopped=0
for s in "${SESSIONS[@]}"; do
  if tmux has-session -t "=$s" 2>/dev/null; then
    tmux kill-session -t "=$s" 2>/dev/null && { echo "stopped  $s"; stopped=$((stopped + 1)); }
  else
    echo "skip     $s (not running)"
  fi
done

# Belt-and-suspenders: reap any HTTP server left running outside tmux
# (e.g. started by hand), so the port is always freed.
if pgrep -f "mcp/librarian_http.py" >/dev/null 2>&1; then
  pkill -f "mcp/librarian_http.py" 2>/dev/null && echo "stopped  stray librarian_http.py process(es)"
fi

echo "----"
if [ "$stopped" -eq 0 ]; then
  echo "Nothing was running."
else
  echo "All librarian services stopped."
fi
