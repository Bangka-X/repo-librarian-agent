#!/usr/bin/env bash
#
# digest.sh — build/refresh the Claude-managed knowledge base in .knowledge/.
#
# For every mirrored repo it maintains three kinds of curated knowledge:
#
#   .knowledge/<repo>/index.md      structural MAP — purpose, entry points, key
#                                   components, APIs/contracts, docs, gotchas.
#                                   Regenerated when the repo's HEAD changes.
#   .knowledge/<repo>/decisions.md  reverse-chron DECISION LOG mined from git
#                                   history. Each sync APPENDS one entry distilled
#                                   from the commits/diff since the last digest —
#                                   what changed and why.
#   .knowledge/connections.md       cross-repo INTEGRATION GRAPH (who calls whom,
#                                   shared contracts, data flow). Rebuilt from all
#                                   maps whenever anything changed.
#
# The librarian reads these first (cheap, pre-distilled) before diving into the
# raw mirror, then confirms against source before answering.
#
# Incremental: a repo is re-digested only when its HEAD commit changed since the
# last digest (the sha is stamped in the map frontmatter), so steady-state runs
# cost ~zero Claude turns. loop.sh calls this after each sync.
#
# Usage:
#   bash utils/digest.sh                       # refresh repos whose commit changed
#   bash utils/digest.sh --force               # re-digest every repo
#   bash utils/digest.sh sierra_crawler-tiktok # only this repo
#   bash utils/digest.sh --force <repo>        # force just one
#
# Uses the machine's logged-in Claude subscription (no API key, no --bare).

set -uo pipefail

# This script lives in utils/; the project root is one level up.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOS_DIR="$ROOT_DIR/.repositories"
KNOW_DIR="$ROOT_DIR/.knowledge"
DATE="$(date +%F)"

MAP_TOOLS="Read,Grep,Glob,Bash(git log:*),Bash(git show:*),Bash(git diff:*),Write"

FORCE=0
ONLY=""
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -*)      echo "unknown option: $arg" >&2; exit 2 ;;
    *)       ONLY="$arg" ;;
  esac
done

if ! command -v claude >/dev/null 2>&1; then
  echo "error: the 'claude' CLI is not on PATH." >&2
  exit 1
fi

# Force subscription auth (an API key would switch to metered billing).
unset ANTHROPIC_API_KEY
cd "$ROOT_DIR"
mkdir -p "$KNOW_DIR"

digested=0 skipped=0 failed=0
failed_names=()

for repo_path in "$REPOS_DIR"/*/; do
  [ -d "${repo_path}.git" ] || continue
  name="$(basename "$repo_path")"
  [ -n "$ONLY" ] && [ "$name" != "$ONLY" ] && continue

  sha="$(git -C "$repo_path" rev-parse --short HEAD 2>/dev/null)" || sha="unknown"
  kdir="$KNOW_DIR/$name"
  kfile="$kdir/index.md"
  decisions="$kdir/decisions.md"
  pending="$kdir/.pending-entry.md"

  # Skip only when the map is current AND a decision log already exists. (A repo
  # mapped before this feature lands has no log yet, so it re-runs once to seed.)
  if [ "$FORCE" -eq 0 ] && [ -f "$kfile" ] && grep -q "^commit: $sha$" "$kfile" \
       && [ -f "$decisions" ]; then
    echo "skip    $name (up to date @ $sha)"
    skipped=$((skipped + 1))
    continue
  fi

  echo "digest  $name @ $sha ..."
  mkdir -p "$kdir"

  # Previously indexed sha (if any) drives the decision-log delta.
  old_sha=""
  [ -f "$kfile" ] && old_sha="$(sed -n 's/^commit: //p' "$kfile" | head -n1)"

  if [ -n "$old_sha" ] && [ "$old_sha" != "$sha" ] \
       && git -C "$repo_path" cat-file -e "${old_sha}^{commit}" 2>/dev/null; then
    # Incremental update: log the commits/diff since the last digest.
    commits="$(git -C "$repo_path" log --no-merges --date=short \
                 --pretty='- %h %s (%an, %ad)' "${old_sha}..HEAD" 2>/dev/null | head -n 80)"
    diffstat="$(git -C "$repo_path" diff --stat "${old_sha}" HEAD 2>/dev/null | tail -n 50)"
    decision_block="These commits landed since the previously indexed commit ${old_sha} (range ${old_sha}..${sha}):
${commits}

Files changed (git diff --stat):
${diffstat}

You may run git show/git diff on specific hashes to understand a change before writing."
    entry_head="## ${DATE} — ${sha} (updated from ${old_sha})"
  else
    # First-time seed: distil the repo's history into an initial entry.
    commits="$(git -C "$repo_path" log --no-merges --date=short \
                 --pretty='- %h %s (%ad)' 2>/dev/null | head -n 50)"
    decision_block="This is the FIRST time this repo is indexed. Summarize its history as initial context — the major milestones and turning points, NOT every commit. Recent/representative commits (newest first):
${commits}"
    entry_head="## ${DATE} — ${sha} (initial history)"
  fi

  PROMPT="You are maintaining a knowledge base for a code librarian, indexing the repository at .repositories/${name} (READ-ONLY: never modify, commit, or run it).

TASK 1 — Repository map. Write .knowledge/${name}/index.md. It MUST begin with this exact YAML frontmatter, filling in the summary:
---
repo: ${name}
commit: ${sha}
indexed: ${DATE}
summary: ONE sentence (max 120 chars) describing what this repo is and does
---
Then a markdown body with these sections, in order:
## Purpose - one short paragraph.
## Stack - languages, frameworks, notable dependencies.
## Entry points - the files you would open first, each cited as ${name}/path/to/file.ext:line.
## Key components - 5 to 12 bullets; each names a component, cites its location as ${name}/path:line, one line on what it does.
## APIs and contracts - endpoints, message schemas, public interfaces, env/config that OTHER repos would call or depend on, each cited.
## Where docs live - READMEs, docs/, notable comments or config, cited.
## Gotchas - non-obvious behavior, footguns, surprising defaults.
Every concrete claim cites a real ${name}/path:line. Be dense - a map, not a transcript.

TASK 2 — Decision-log entry. Write .knowledge/${name}/.pending-entry.md with ONE new entry (it will be prepended to the existing log; do NOT include older entries). ${decision_block}
Format the entry exactly as:
${entry_head}
Then 2-6 bullets capturing the MEANINGFUL changes and the decision/rationale behind them — new features, refactors, migrations, breaking API/schema changes, notable dependency or infra changes — explaining the *why* where the commits or diff reveal it. Cite commit hashes as ${name}@<hash> and source as ${name}/path:line. Skip pure trivia (formatting, typos, lockfile noise); if everything is trivial, write a single bullet saying so. Terse and high-signal.

Write ONLY these two files (.knowledge/${name}/index.md and .knowledge/${name}/.pending-entry.md)."

  if claude -p "$PROMPT" --allowedTools "$MAP_TOOLS" >/dev/null 2>&1 && [ -f "$kfile" ]; then
    # Prepend the new entry to the decision log (newest first), then clean up.
    if [ -s "$pending" ]; then
      if [ -f "$decisions" ]; then
        { cat "$pending"; printf '\n'; cat "$decisions"; } > "${decisions}.tmp" \
          && mv "${decisions}.tmp" "$decisions"
      else
        cp "$pending" "$decisions"
      fi
    fi
    rm -f "$pending"
    echo "  ok    $name"
    digested=$((digested + 1))
  else
    rm -f "$pending"
    echo "  FAIL  $name (no map written)"
    failed=$((failed + 1)); failed_names+=("$name")
  fi
done

# --- Cross-repo connections graph (second pass) -----------------------------
# Synthesize how the repos integrate, from the per-repo maps. Rebuilt only when
# something changed (or it's missing), and only if there are >=2 maps to relate.
conn="$KNOW_DIR/connections.md"
map_count="$(find "$KNOW_DIR" -mindepth 2 -name index.md 2>/dev/null | wc -l | tr -d ' ')"
if { [ "$digested" -gt 0 ] || [ ! -f "$conn" ]; } && [ "$map_count" -ge 2 ]; then
  echo "connect  synthesizing cross-repo graph from $map_count maps ..."
  CPROMPT="You are mapping how an organization's repositories connect, for a code librarian. Read every map under .knowledge/*/index.md (rely on these curated maps and their cited pointers; you need not open .repositories). Write .knowledge/connections.md describing the cross-repo integration graph. Cover: (1) which repo calls/triggers/depends on which, with direction and mechanism (HTTP endpoint, shared DB/schema, queue, model artifact, file or wire contract); (2) the shared contracts/schemas and where each side lives, cited as repo/path:line from the maps; (3) the end-to-end data flow across the pipeline, start to finish. Use short bullets and simple arrows like 'A -> B: mechanism'. This is the whiteboard diagram a senior dev draws to explain the system. Cite repo/path:line. If a link is inferred rather than explicit in the maps, mark it (inferred). Begin the file with '# Cross-repo connections', a blank line, then '_Last built: ${DATE}_'. Write ONLY .knowledge/connections.md."
  if claude -p "$CPROMPT" --allowedTools "Read,Grep,Glob,Write" >/dev/null 2>&1 \
       && [ -f "$conn" ]; then
    echo "  ok    connections.md"
  else
    echo "  FAIL  connections.md"
  fi
fi

# --- Rebuild the top-level index from each map's frontmatter -----------------
# Mechanical (grep), so it never costs a Claude turn and can't drift from facts.
index="$KNOW_DIR/index.md"
{
  echo "# Knowledge Base"
  echo
  echo "Curated, Claude-generated knowledge for each mirrored repo. Start here to"
  echo "locate components, open the per-repo map or decision log, then CONFIRM in"
  echo ".repositories/ and cite the real source line. These are derived, not truth."
  echo
  echo "_Last built: ${DATE}_"
  echo
  [ -f "$conn" ] && echo "**Cross-repo integration graph:** [connections.md](connections.md)" && echo
  echo "| Repo | Summary | Map | History |"
  echo "|---|---|---|---|"
  for f in "$KNOW_DIR"/*/index.md; do
    [ -f "$f" ] || continue
    rname="$(basename "$(dirname "$f")")"
    rsum="$(sed -n 's/^summary: //p' "$f" | head -n1)"
    [ -z "$rsum" ] && rsum="(no summary)"
    if [ -f "$KNOW_DIR/$rname/decisions.md" ]; then
      hist="[history]($rname/decisions.md)"
    else
      hist="—"
    fi
    echo "| $rname | $rsum | [map]($rname/index.md) | $hist |"
  done
} > "$index"

echo "----"
echo "digested: $digested  skipped: $skipped  failed: $failed"
echo "index: $index"
if [ "$failed" -gt 0 ]; then
  echo "failed: ${failed_names[*]}"
  exit 1
fi
