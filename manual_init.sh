#!/usr/bin/env bash
#
# manual_init.sh — clone a hand-picked list of repos into repositories/.
#
# Edit the REPOS list below, then run:  bash manual_init.sh
#
# Each entry may be:
#   - a full clone URL:   https://github.com/org/repo.git
#                         git@github.com:org/repo.git
#   - GitHub shorthand:   org/repo   (cloned over HTTPS)
#
# Already-cloned repos are fast-forward pulled instead of re-cloned, so this is
# safe to re-run. To keep the mirror fresh afterwards, use loop.sh.

set -uo pipefail

# ---------------------------------------------------------------------------
# Put the repositories you want here, one per line.
# ---------------------------------------------------------------------------
REPOS=(
  # "org/repo"
  # "https://github.com/org/another-repo.git"
  # "git@github.com:org/private-repo.git"
)
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_DIR="$SCRIPT_DIR/repositories"
mkdir -p "$REPOS_DIR"

if [ "${#REPOS[@]}" -eq 0 ]; then
  echo "No repositories listed. Edit the REPOS array in $0 and re-run." >&2
  exit 1
fi

cloned=0 pulled=0 failed=0
failed_names=()

for entry in "${REPOS[@]}"; do
  entry="$(echo "$entry" | xargs)"          # trim whitespace
  [ -z "$entry" ] && continue

  # Normalize shorthand (org/repo) into an HTTPS URL.
  case "$entry" in
    *://*|git@*) url="$entry" ;;            # already a full URL
    */*)         url="https://github.com/$entry.git" ;;
    *)
      echo "FAIL   '$entry' (unrecognized format)"
      failed=$((failed + 1)); failed_names+=("$entry"); continue ;;
  esac

  # Derive the local directory name from the URL's last path segment.
  name="$(basename "$url")"
  name="${name%.git}"
  dest="$REPOS_DIR/$name"

  if [ -d "$dest/.git" ]; then
    if git -C "$dest" pull --ff-only --quiet; then
      echo "pull   $name"
      pulled=$((pulled + 1))
    else
      echo "FAIL   $name (pull failed)"
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
done

echo "----"
echo "cloned: $cloned  pulled: $pulled  failed: $failed"
if [ "$failed" -gt 0 ]; then
  echo "failed: ${failed_names[*]}"
  exit 1
fi
