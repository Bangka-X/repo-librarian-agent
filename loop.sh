#!/usr/bin/env bash
#
# loop.sh — sync every repository listed in .repos.input.
#
# Reads the hidden input file, then for each repo link: clones it into
# .repositories/ if missing, or fast-forward pulls it if already there.
# Skips repos with uncommitted changes (never clobbers local work).
#
# Run init.sh first to create the input file. Safe to run repeatedly — this is
# what the /loop interval calls.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_DIR="$SCRIPT_DIR/.repositories"
INPUT_FILE="$SCRIPT_DIR/.repos.input"

if [ ! -f "$INPUT_FILE" ]; then
  echo "error: $INPUT_FILE not found — run  bash init.sh  first" >&2
  exit 1
fi
mkdir -p "$REPOS_DIR"

cloned=0 pulled=0 skipped=0 failed=0
failed_names=()

while IFS= read -r line || [ -n "$line" ]; do
  entry="$(echo "$line" | xargs)"        # trim whitespace
  [ -z "$entry" ] && continue            # blank line
  case "$entry" in \#*) continue ;; esac # comment

  # Normalize shorthand (org/repo) into an HTTPS URL.
  case "$entry" in
    *://*|git@*) url="$entry" ;;
    */*)         url="https://github.com/$entry.git" ;;
    *)
      echo "FAIL   '$entry' (unrecognized format)"
      failed=$((failed + 1)); failed_names+=("$entry"); continue ;;
  esac

  name="$(basename "$url")"; name="${name%.git}"
  dest="$REPOS_DIR/$name"

  if [ -d "$dest/.git" ]; then
    if [ -n "$(git -C "$dest" status --porcelain)" ]; then
      echo "skip   $name (uncommitted changes)"
      skipped=$((skipped + 1))
    elif git -C "$dest" pull --ff-only --quiet; then
      echo "pull   $name"
      pulled=$((pulled + 1))
    else
      echo "FAIL   $name (pull failed — diverged or network)"
      failed=$((failed + 1)); failed_names+=("$name")
    fi
  else
    if git clone --quiet "$url" "$dest"; then
      echo "clone  $name"
      cloned=$((cloned + 1))
    else
      echo "FAIL   $name (clone failed)"
      failed=$((failed + 1)); failed_names+=("$name")
    fi
  fi
done < "$INPUT_FILE"

echo "----"
echo "cloned: $cloned  pulled: $pulled  skipped: $skipped  failed: $failed"
if [ "$failed" -gt 0 ]; then
  echo "failed: ${failed_names[*]}"
  exit 1
fi
