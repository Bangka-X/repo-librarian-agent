# repos-agent

A terminal-resident **librarian agent** that acts as the single source of truth across
all repositories in the organization. Other software-engineering agents ask it questions
during development — "how does X work?", "where are the docs for Y?", "what's the API for
Z?" — and it finds the answer across every org repo and returns a reasoned, cited
response.

It runs on the **existing Claude subscription in the terminal** (Claude Code), not on
metered API billing. Claude itself is the intelligence: it reads and synthesizes across
the mirrored repos rather than returning raw search hits.

The librarian's operating instructions live in [CLAUDE.md](CLAUDE.md) — that file is the
agent's system prompt, loaded whenever Claude runs in this directory.

## How it works

The system is **two separate processes** — deliberately not the same thing:

### 1. Sync — keep the mirror fresh
[`loop.sh`](loop.sh) walks every repo under `repositories/` and fast-forward pulls it.
It skips repos that are dirty, have no upstream, or aren't git repos, and prints a
per-repo result plus a summary. Run it on a `/loop` interval; it's safe to run
repeatedly.

```bash
bash loop.sh
```

> `/loop` keeps a single session re-running a task on an interval — it is a sync
> mechanism, not a request server. Syncing and answering are different lifecycles, so
> they are different processes.

### 2. Librarian — answer questions
Run a headless Claude Code query against this directory so Claude can grep/read across
`repositories/` and return a synthesized, cited answer:

```bash
claude -p "How does authentication work in the billing service?"
```

Because the answer is a Claude Code turn (not an external API call), the work stays on
the Claude subscription.

## Populating the mirror

`repositories/` is **gitignored** — it holds a local mirror of org source and is never
committed back to this repo. For now, clone the repos you want into it manually:

```bash
git clone <repo-url> repositories/<repo-name>
```

A future `init.sh` will automate discovery + cloning of all org repos via the `gh` CLI
(`gh repo list <org> --limit 1000 ...`). Deferred until the manual flow is proven.

## Layout

```
repos-agent/
├── CLAUDE.md          # librarian agent system prompt
├── README.md          # this file
├── loop.sh            # sync: fast-forward pull every mirrored repo
├── .gitignore         # ignores repositories/
└── repositories/      # local mirror of org repos (gitignored, not committed)
```

## Communication channel — deferred

How other agents reach the librarian is intentionally left open until the sync + mirror
layer is proven. Both candidate paths shell out to the same `claude -p` query:

- **Direct headless call** — other agents run `claude -p "..."` against this directory.
  Simplest; no server to maintain.
- **MCP server** — wrap the query in an MCP tool other agents call. Cleaner integration;
  more setup.

## Known constraints

- **Discovery**: `loop.sh` only syncs already-cloned repos; new org repos must be cloned
  manually (until `init.sh` exists).
- **Scale ceiling**: each synthesized answer costs one Claude Code turn — bounded by
  subscription rate limits. Fine for personal/team use; not high-volume automation.
- **Auth & secrets**: mirroring private repos needs `gh`/SSH auth and puts proprietary
  source on disk. Keep credentials out of this repo; rely on the host's auth.
