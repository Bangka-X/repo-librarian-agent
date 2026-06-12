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
KNOW_DIR="$SCRIPT_DIR/.knowledge"
LOGS_DIR="$SCRIPT_DIR/.logs"
INPUT_FILE="$SCRIPT_DIR/.repos.input"
INTERVAL="${1:-15m}"
SESSION="librarian"

# Central settings (model selection, etc.) live in librarian.conf at the repo
# root; an env var of the same name still wins. Sourced so the booted librarian
# and every script it spawns run on the configured model.
[ -f "$SCRIPT_DIR/librarian.conf" ] && . "$SCRIPT_DIR/librarian.conf"
MODEL="${LIBRARIAN_MODEL:-sonnet}"

# --- 1. Scaffold (idempotent) ------------------------------------------------
# Create every runtime directory the librarian depends on up front, so nothing
# downstream has to assume it exists. All three are gitignored, derived state:
#   .repositories  the read-only mirror loop.sh clones/pulls into
#   .knowledge     the curated maps digest.sh builds (overviews, decisions, …)
#   .logs          the MCP server's audit + live-feed logs
mkdir -p "$REPOS_DIR" "$KNOW_DIR" "$LOGS_DIR"

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

# --- 2.5 Cold-start backfill -------------------------------------------------
# Build the knowledge base for the mirror. We do NOT skip this just because some
# maps already exist — backfill runs whenever repos are listed and keeps going
# until every repo is deep-mapped. It is idempotent and cheap when complete: per
# repo it skips work already finished and only fills what's missing or still
# provisional. We (1) fetch every repo to completion FIRST — so the backfill sees
# the whole mirror — then (2) launch the staged, parallel build in its own tmux
# session, which holds .knowledge/.backfill.lock so the sync loop defers its
# digest while it runs. Disable entirely with LIBRARIAN_NO_BACKFILL=1.
BACKFILL_SESSION="librarian-backfill"
has_repos_listed="$(grep -cvE '^\s*(#|$)' "$INPUT_FILE" 2>/dev/null || true)"
has_repos_listed="${has_repos_listed:-0}"

if [ "$has_repos_listed" -gt 0 ] && [ -z "${LIBRARIAN_NO_BACKFILL:-}" ]; then
  if tmux has-session -t "=$BACKFILL_SESSION" 2>/dev/null; then
    echo "Knowledge backfill already running (tmux '$BACKFILL_SESSION')."
  else
    echo "Ensuring full knowledge coverage — fetching all repos, then backfilling…"
    # Synchronous full fetch (digest disabled here; the backfill owns indexing).
    LIBRARIAN_NO_DIGEST=1 bash "$SCRIPT_DIR/loop.sh" || \
      echo "warning: some repos failed to fetch; backfilling whatever landed." >&2

    echo "Launching staged backfill in tmux '$BACKFILL_SESSION'…"
    tmux new-session -d -s "$BACKFILL_SESSION" -c "$SCRIPT_DIR" \
      "bash '$SCRIPT_DIR/utils/backfill.sh'; echo; echo '[backfill finished — press a key to close]'; read -n 1"
    echo "  watch it:  tail -f .logs/backfill.log     (or: tmux attach -t $BACKFILL_SESSION)"
  fi
fi

# --- 3. Start the remote MCP server (Streamable HTTP + bearer token) ---------
# Runs in its own tmux session, independent of the sync session. Skip entirely
# with LIBRARIAN_NO_HTTP=1. Host/port override via LIBRARIAN_HOST / LIBRARIAN_PORT.
if [ -z "${LIBRARIAN_NO_HTTP:-}" ]; then
  HTTP_SESSION="librarian-http"
  TOKEN_FILE="$SCRIPT_DIR/.librarian.token"
  VENV_PY="$SCRIPT_DIR/mcp/.venv/bin/python"
  HTTP_HOST="${LIBRARIAN_HOST:-127.0.0.1}"
  HTTP_PORT="${LIBRARIAN_PORT:-8008}"

  # Generate the bearer token once (gitignored), reused on every boot.
  if [ ! -f "$TOKEN_FILE" ]; then
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    echo "Generated a bearer token at .librarian.token"
  fi
  TOKEN="$(cat "$TOKEN_FILE")"

  # Ensure the Python venv with MCP deps exists (one-time setup).
  if [ ! -x "$VENV_PY" ]; then
    echo "Setting up the HTTP server venv (one-time)…"
    if command -v uv >/dev/null 2>&1; then
      uv venv "$SCRIPT_DIR/mcp/.venv" >/dev/null 2>&1 &&
        uv pip install --python "$VENV_PY" -r "$SCRIPT_DIR/mcp/requirements.txt" >/dev/null 2>&1
    else
      python3 -m venv "$SCRIPT_DIR/mcp/.venv" >/dev/null 2>&1 &&
        "$VENV_PY" -m pip install -q -r "$SCRIPT_DIR/mcp/requirements.txt" >/dev/null 2>&1
    fi
  fi

  if [ ! -x "$VENV_PY" ]; then
    echo "warning: could not set up mcp/.venv — skipping HTTP server." >&2
  elif tmux has-session -t "=$HTTP_SESSION" 2>/dev/null; then
    echo "HTTP MCP server already running (tmux '$HTTP_SESSION')."
  else
    tmux new-session -d -s "$HTTP_SESSION" -c "$SCRIPT_DIR" \
      "LIBRARIAN_TOKEN='$TOKEN' LIBRARIAN_HOST='$HTTP_HOST' LIBRARIAN_PORT='$HTTP_PORT' '$VENV_PY' '$SCRIPT_DIR/mcp/librarian_http.py'"
    echo "HTTP MCP server started in tmux '$HTTP_SESSION' → http://$HTTP_HOST:$HTTP_PORT/mcp"
    echo "Register a client with:"
    echo "  claude mcp add --transport http librarian http://$HTTP_HOST:$HTTP_PORT/mcp --header \"Authorization: Bearer $TOKEN\""
  fi
fi

# --- 4. Boot the librarian sync session in tmux -----------------------------
# NOTE: this prompt is embedded in the tmux command string, so it must contain
# no single/double quotes or backticks (they would break shell parsing).
BOOT_PROMPT="You are the repository librarian for this project — read CLAUDE.md first for your role and rules. Startup task before anything else: use your /loop capability to schedule the shell command bash loop.sh to run every ${INTERVAL}, which keeps the .repositories mirror fresh. Confirm the loop is scheduled, run loop.sh once now for an initial sync, then stay open and answer questions about the mirrored repositories per CLAUDE.md."

if tmux has-session -t "=$SESSION" 2>/dev/null; then
  echo "Librarian sync session already running (tmux '$SESSION')."
else
  tmux new-session -d -s "$SESSION" -c "$SCRIPT_DIR" \
    "claude -n librarian --model $MODEL \"$BOOT_PROMPT\""
  echo "Librarian booted in tmux session '$SESSION' (sync every ${INTERVAL})."
fi

# Both sessions run DETACHED as background daemons. We deliberately do NOT
# auto-attach: attaching would drop you into the sync session's interactive
# Claude, where an accidental Ctrl-C/exit kills it (leaving only the HTTP one).
echo
echo "Librarian is up. Background tmux sessions:"
echo "  $SESSION  — sync daemon (Claude /loop → loop.sh)"
if [ -n "${HTTP_SESSION:-}" ] && tmux has-session -t "=$HTTP_SESSION" 2>/dev/null; then
  echo "  $HTTP_SESSION  — HTTP MCP server (http://${HTTP_HOST}:${HTTP_PORT}/mcp)"
fi
if tmux has-session -t "=$BACKFILL_SESSION" 2>/dev/null; then
  echo "  $BACKFILL_SESSION  — cold-start knowledge build (one-time; exits when done)"
fi
echo
echo "  List:   tmux ls"
echo "  Attach: tmux attach -t $SESSION        (detach again with Ctrl-b d)"
echo "  Watch:  bash mcp/watch.sh              (live view of answers)"
echo "  Stop:   tmux kill-session -t $SESSION${HTTP_SESSION:+; tmux kill-session -t $HTTP_SESSION}"
