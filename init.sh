#!/usr/bin/env bash
#
# init.sh — boot the librarian in a tmux session (Arduino-style setup()).
#
# Runs the one-time scaffold (idempotent), then launches a persistent Claude
# Code session inside a detached tmux session named "librarian" that:
#   1. configures a /loop to run `bash loop.sh` every INTERVAL (sync), then
#   2. stays open as the librarian, answering questions about the mirror.
#
# Because it lives in tmux, the librarian survives closing your terminal.
# Attach to watch/ask:   tmux attach -t librarian
# Detach (leave running): Ctrl-b then d
# Stop it:               tmux kill-session -t librarian
#
# Usage:
#   bash init.sh            # 15-minute sync interval (default)
#   bash init.sh 5m         # custom interval

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_DIR="$SCRIPT_DIR/.repositories"
INPUT_FILE="$SCRIPT_DIR/.repos.input"
INTERVAL="${1:-15m}"
SESSION="librarian"

# --- 1. Scaffold (idempotent) ------------------------------------------------
mkdir -p "$REPOS_DIR"

if [ ! -f "$INPUT_FILE" ]; then
  cat > "$INPUT_FILE" <<'EOF'
# Repositories to sync — one per line.
# Lines starting with # and blank lines are ignored.
#
# Accepted formats:
#   org/repo                                  (cloned over HTTPS)
#   https://github.com/org/repo.git
#   git@github.com:org/repo.git               (SSH)
#
# Paste your repository links below.

EOF
  echo "Created .repos.input — paste your repo links into it, then re-run."
  echo "(No point booting the librarian with an empty mirror.)"
  exit 0
fi

# Warn (but proceed) if no repos are listed yet.
if ! grep -qvE '^\s*(#|$)' "$INPUT_FILE"; then
  echo "warning: .repos.input has no repositories listed yet."
  echo "The librarian will boot, but loop.sh has nothing to sync."
fi

# --- 2. Preconditions --------------------------------------------------------
# Every command the librarian and its sync loop rely on must be installed.
#   claude — the CLI that runs the librarian
#   git    — used by loop.sh to clone/pull the mirrored repositories
#   tmux   — hosts the persistent detached session
missing=()
for cmd in claude git tmux; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "error: required command(s) not found on PATH: ${missing[*]}" >&2
  echo "Install the missing tool(s) and re-run.  For example:" >&2
  for cmd in "${missing[@]}"; do
    case "$cmd" in
      claude) echo "  claude: npm install -g @anthropic-ai/claude-code" >&2 ;;
      git)    echo "  git:    apt install git   (or: brew install git)" >&2 ;;
      tmux)   echo "  tmux:   apt install tmux  (or: brew install tmux)" >&2 ;;
    esac
  done
  exit 1
fi

# If a librarian is already running, don't start a second one.
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "A '$SESSION' tmux session is already running."
  echo "Attach with:  tmux attach -t $SESSION"
  echo "Restart with: tmux kill-session -t $SESSION && bash init.sh $INTERVAL"
  exit 0
fi

# --- 3. Boot the librarian in tmux ------------------------------------------
# NOTE: this prompt is embedded in the tmux command string, so it must contain
# no single/double quotes or backticks (they would break shell parsing).
BOOT_PROMPT="You are the repository librarian for this project — read CLAUDE.md first for your role and rules. Startup task before anything else: use your /loop capability to schedule the shell command bash loop.sh to run every ${INTERVAL}, which keeps the .repositories mirror fresh. Confirm the loop is scheduled, run loop.sh once now for an initial sync, then stay open and answer questions about the mirrored repositories per CLAUDE.md."

# Start detached so it boots in the background, with its CWD set to the project.
tmux new-session -d -s "$SESSION" -c "$SCRIPT_DIR" \
  "claude -n librarian \"$BOOT_PROMPT\""

echo "Librarian booted in tmux session '$SESSION' (sync every ${INTERVAL})."

# Attach if we have a terminal; otherwise just report how to.
if [ -t 1 ]; then
  echo "Attaching… (detach with Ctrl-b then d)"
  exec tmux attach -t "$SESSION"
else
  echo "Attach with:  tmux attach -t $SESSION"
fi
