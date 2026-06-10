#!/usr/bin/env bash
#
# init.sh — one-time scaffold for the mirror.
#
# Creates the hidden mirror directory and a hidden input file where you paste
# the repositories you want to sync (one link per line). Run this once, edit
# the input file, then use loop.sh to clone/pull everything.
#
# Both .repositories/ and .repos.input are gitignored — they hold your repo
# list and proprietary source, and are never committed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_DIR="$SCRIPT_DIR/.repositories"
INPUT_FILE="$SCRIPT_DIR/.repos.input"

# 1. Hidden mirror directory.
mkdir -p "$REPOS_DIR"
echo "ok  .repositories/ ready"

# 2. Hidden input file — don't clobber an existing list.
if [ -f "$INPUT_FILE" ]; then
  echo "ok  .repos.input already exists (left untouched)"
else
  cat > "$INPUT_FILE" <<'EOF'
# Repositories to sync — one per line.
# Lines starting with # and blank lines are ignored.
#
# Accepted formats:
#   org/repo                                  (cloned over HTTPS)
#   https://github.com/org/repo.git
#   git@github.com:org/repo.git               (SSH)
#
# Paste your repository links below, then run:  bash loop.sh

EOF
  echo "ok  .repos.input created — paste your repo links into it"
fi

echo "----"
echo "Next: edit .repos.input, then run  bash loop.sh"
