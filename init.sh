#!/usr/bin/env bash
#
# init.sh — boot the librarian (Arduino-style setup()).
#
# Runs the one-time scaffold (idempotent), then launches a persistent
# interactive Claude Code session that:
#   1. configures a /loop to run `bash loop.sh` every INTERVAL (sync), then
#   2. stays open as the librarian, answering questions about the mirror.
#
# Usage:
#   bash init.sh            # 15-minute sync interval (default)
#   bash init.sh 5m         # custom interval
#
# Re-running this starts a fresh librarian session with a fresh loop. The
# /loop task is session-scoped, so it must be re-created each boot — which is
# exactly what this script does.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_DIR="$SCRIPT_DIR/.repositories"
INPUT_FILE="$SCRIPT_DIR/.repos.input"
INTERVAL="${1:-15m}"

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

# --- 2. Boot the librarian session ------------------------------------------
if ! command -v claude >/dev/null 2>&1; then
  echo "error: the 'claude' CLI is not on PATH." >&2
  exit 1
fi

BOOT_PROMPT="You are this project's repository librarian — your role and rules are in CLAUDE.md, read it first. Startup task before anything else: use your /loop capability to schedule the shell command \`bash loop.sh\` to run every ${INTERVAL}; this keeps the .repositories/ mirror fresh. Confirm the loop is scheduled, run loop.sh once now for an initial sync, then stay open and answer questions about the mirrored repositories per CLAUDE.md."

echo "Booting librarian (sync every ${INTERVAL})…"
exec claude -n librarian "$BOOT_PROMPT"
