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

## The Arduino model: `init` then `loop`

The sync layer borrows Arduino's two-function shape:

- **`init.sh` runs once** — scaffolds the mirror. It creates the hidden `.repositories/`
  directory and a hidden `.repos.input` file where you paste the repo links you want to
  sync.
- **`loop.sh` runs forever** — reads `.repos.input` and clones/pulls every listed repo
  into `.repositories/`. Run it on a `/loop` interval to keep the mirror fresh.

```bash
bash init.sh        # once — creates .repositories/ and .repos.input
# paste your repo links into .repos.input
bash loop.sh        # clone/sync — or put on a /loop interval
```

### `.repos.input` format

One repository per line. Blank lines and `#` comments are ignored. Accepted forms:

```
org/repo                           # cloned over HTTPS
https://github.com/org/repo.git
git@github.com:org/repo.git        # SSH
```

### What `loop.sh` does per repo

- **Clones** it into `.repositories/<name>` if it isn't there yet
- **Fast-forward pulls** it if it already exists
- **Skips** repos with uncommitted local changes (never clobbers work)
- Prints a per-repo result (`clone`/`pull`/`skip`/`FAIL`) and a summary

> `/loop` keeps a single session re-running a task on an interval — it is a sync
> mechanism, not a request server. Syncing and answering are different lifecycles, so
> they are different processes.

## Asking the librarian

Run a headless Claude Code query against this directory so Claude can grep/read across
`.repositories/` and return a synthesized, cited answer:

```bash
claude -p "How does authentication work in the billing service?"
```

Because the answer is a Claude Code turn (not an external API call), the work stays on
the Claude subscription.

## Layout

```
repos-agent/
├── CLAUDE.md          # librarian agent system prompt
├── README.md          # this file
├── init.sh            # run once: scaffold .repositories/ and .repos.input
├── loop.sh            # run on /loop: clone/pull every repo in .repos.input
├── .gitignore         # ignores .repositories/ and .repos.input
├── .repos.input       # your repo list (hidden, gitignored)
└── .repositories/     # local mirror of org repos (hidden, gitignored)
```

`.repos.input` and `.repositories/` are hidden and gitignored — they hold your repo list
and proprietary org source, and are never committed.

## Communication channel — deferred

How other agents reach the librarian is intentionally left open until the sync + mirror
layer is proven. Both candidate paths shell out to the same `claude -p` query:

- **Direct headless call** — other agents run `claude -p "..."` against this directory.
  Simplest; no server to maintain.
- **MCP server** — wrap the query in an MCP tool other agents call. Cleaner integration;
  more setup.

## Known constraints

- **Discovery is manual** — you list repos in `.repos.input` by hand. Auto-discovering
  every org repo via the `gh` CLI (`gh repo list <org>`) is a possible later addition.
- **Scale ceiling** — each synthesized answer costs one Claude Code turn, bounded by
  subscription rate limits. Fine for personal/team use; not high-volume automation.
- **Auth & secrets** — mirroring private repos needs `gh`/SSH auth and puts proprietary
  source on disk. Keep credentials out of this repo; rely on the host's auth.
