#!/usr/bin/env bash
#
# loop.sh — sync all mirrored repositories.
#
# Walks every git repo under repositories/ and fast-forward pulls it.
# Skips repos with uncommitted changes (never clobbers local work) and
# repos with no upstream. Prints a per-repo result and a final summary.
#
# Intended to be run on a /loop interval. Safe to run repeatedly.

set -uo pipefail

# Resolve repositories/ relative to this script, so it works from any CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_DIR="$SCRIPT_DIR/repositories"

if [ ! -d "$REPOS_DIR" ]; then
  echo "error: $REPOS_DIR does not exist" >&2
  exit 1
fi

ok=0 skipped=0 failed=0
failed_names=()

# One level deep: repositories/<name>/.git
for repo in "$REPOS_DIR"/*/; do
  [ -d "$repo" ] || continue
  name="$(basename "$repo")"

  if [ ! -d "$repo/.git" ]; then
    echo "skip   $name (not a git repo)"
    skipped=$((skipped + 1))
    continue
  fi

  # Skip if the working tree is dirty — don't risk local changes.
  if [ -n "$(git -C "$repo" status --porcelain)" ]; then
    echo "skip   $name (uncommitted changes)"
    skipped=$((skipped + 1))
    continue
  fi

  # Skip if the current branch has no upstream to pull from.
  if ! git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    echo "skip   $name (no upstream)"
    skipped=$((skipped + 1))
    continue
  fi

  if git -C "$repo" pull --ff-only --quiet; then
    echo "ok     $name"
    ok=$((ok + 1))
  else
    echo "FAIL   $name (pull failed — diverged or network)"
    failed=$((failed + 1))
    failed_names+=("$name")
  fi
done

echo "----"
echo "synced: $ok  skipped: $skipped  failed: $failed"
if [ "$failed" -gt 0 ]; then
  echo "failed repos: ${failed_names[*]}"
  exit 1
fi
