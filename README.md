# repos-agent

A terminal-resident **librarian agent** that is the single source of truth across all
repositories in your organization. Other engineers and their coding agents ask it
questions during development — "how does X work?", "where are the docs for Y?", "what's
the API for Z?" — and it answers across every mirrored repo with **cited** results.

It runs on your **existing Claude subscription** (Claude Code), not metered API billing:
the librarian is a headless `claude -p` query that reads and synthesizes across the
mirror. The librarian's operating instructions are in [CLAUDE.md](CLAUDE.md) (its system
prompt, auto-loaded whenever Claude runs in this directory).

## How it fits together

```
        .repos.input ──▶ loop.sh ──▶ .repositories/   (local mirror, gitignored)
                          (sync)            │
                                            │ read
                  ┌─────────────────────────┴───────────────────────┐
                  │                                                   │
        mcp/librarian_mcp.py (stdio)                 mcp/librarian_http.py (HTTP+token)
        for THIS machine's Claude                    for OTHER machines / a VM
                  └───────────────────┬───────────────────────────────┘
                                      ▼
                         claude -p over the mirror  ──▶ cited answer
```

Two independent concerns, deliberately split:

- **Sync** keeps `.repositories/` fresh (`loop.sh`).
- **Answering** reads the mirror on demand via an MCP server. The two only share the
  folder on disk; they never talk to each other.

## Quick start

Prerequisites: `claude` (logged in to your subscription), `git`, `tmux`, and `python3`.

```bash
# 1. one-time: list the repos you want, then sync them
bash init.sh                 # creates .repos.input on first run; edit it, then re-run
#    paste org/repo or clone URLs into .repos.input, then:
bash init.sh                 # brings the librarian up (see below)
```

`init.sh` starts **two detached tmux sessions** and prints a status summary:

| tmux session | what it is |
|---|---|
| `librarian` | sync daemon — Claude `/loop` running `loop.sh` every 15 min |
| `librarian-http` | the remote MCP server (Streamable HTTP + bearer token) on `127.0.0.1:8008` |

Manage them:

```bash
tmux ls                      # see both sessions
tmux attach -t librarian     # watch the sync session — detach with Ctrl-b d (don't exit!)
bash mcp/watch.sh            # live view of the librarian answering questions
bash stop.sh                 # stop all librarian services
```

> Tip: re-running `init.sh` is safe — it won't double-start a session that's already up.
> Override the interval/host/port: `bash init.sh 5m`, `LIBRARIAN_PORT=9000 bash init.sh`,
> or skip the HTTP server entirely with `LIBRARIAN_NO_HTTP=1 bash init.sh`.

## Integrate with your Claude

There are two transports. **For local use you're already done** — pick based on where
your Claude runs:

| Your Claude runs… | Use | Setup |
|---|---|---|
| on **this machine** | stdio `librarian` | one-time `claude mcp add` (below) |
| on **another machine / a VM** | HTTP `librarian-http` + token | `claude mcp add --transport http …` (below) |

### Local — stdio (recommended on this machine)

Register the stdio server once, at **user scope** so it's available in *every* project:

```bash
claude mcp add --scope user librarian -- python3 "$(pwd)/mcp/librarian_mcp.py"
claude mcp list              # expect: librarian … ✓ Connected
```

That's it. Open `claude` in **any** repo and the librarian tools are there. Verify and
use:

```
/mcp                         # lists 'librarian' and its 3 tools
```
> "Use the librarian to find how sierra_crawler-tiktok feeds the mlops-service."

Or headless from a script / another agent:

```bash
claude -p "ask the librarian what port the tiktok crawler uses" \
  --allowedTools "mcp__librarian__ask_librarian"
```

The stdio server reads `.repositories/` directly and spawns its own `claude -p`, so it
needs the **`librarian` sync session** running (for freshness) but **not** the HTTP one.

### Remote — HTTP + bearer token (for a VM)

When the mirror lives on another machine, register that machine's HTTP endpoint. The
bearer token is generated once by `init.sh` and stored in `.librarian.token`:

```bash
claude mcp add --transport http librarian-remote http://YOUR_HOST:8008/mcp \
  --header "Authorization: Bearer $(cat .librarian.token)"
```

Notes:
- Register it under a **different name** (`librarian-remote`) so it doesn't collide with
  the stdio `librarian` at user scope.
- On the VM, `ask_librarian` runs `claude -p` *there*, so the VM needs `claude`
  authenticated — run `claude setup-token` on it to use your subscription.
- The token is cleartext over plain HTTP. Bind to `127.0.0.1` and front it with an HTTPS
  reverse proxy (Caddy/nginx), or reach it over an SSH tunnel/VPN.

### The tools

| Tool | What it does | Cost |
|---|---|---|
| `ask_librarian(question, repos?)` | synthesized, cited answer across the mirror | 1 Claude turn |
| `list_repositories()` | mirrored repos + last commit | free (filesystem) |
| `search_code(pattern, repos?)` | raw grep matches (capped at 50) | free (grep) |

Agents are expected to use the two free tools to discover/narrow, then spend a Claude
turn on `ask_librarian` for synthesis.

## Syncing the mirror

`loop.sh` reads `.repos.input` (one repo per line; `#` comments and blanks ignored):

```
org/repo                           # cloned over HTTPS
https://github.com/org/repo.git
git@github.com:org/repo.git        # SSH
```

Per repo it **clones** if missing, **fast-forward pulls** if present, and **skips** repos
with uncommitted local changes. The Claude `/loop` in the `librarian` session runs this
every interval.

## Observability

Every `ask_librarian` call streams Claude's real steps (each grep/read + the answer) to a
live feed. Watch it in tmux:

```bash
bash mcp/watch.sh            # tails .logs/librarian-feed.log in a tmux session
```

- `.logs/librarian-feed.log` — live trace of the librarian working
- `.logs/librarian.log` — one concise line per call (audit)

Both are capped at 10 MB (rolled to `.log.1`) and gitignored.

## Layout

```
repos-agent/
├── CLAUDE.md            # librarian agent system prompt
├── README.md           # this file
├── init.sh             # boot: scaffold + start the two tmux daemons
├── loop.sh             # sync: clone/pull every repo in .repos.input
├── stop.sh             # stop all librarian services
├── mcp/
│   ├── librarian_core.py   # shared tool logic + logging + live feed
│   ├── librarian_mcp.py    # stdio MCP server (local)
│   ├── librarian_http.py   # Streamable HTTP MCP server + bearer (remote/VM)
│   ├── requirements.txt    # deps for the HTTP server (mcp, uvicorn)
│   └── watch.sh            # tmux live viewer of the answer feed
├── utils/
│   └── ask.sh             # ask the librarian from the CLI (claude -p wrapper)
├── .repos.input        # your repo list           (hidden, gitignored)
├── .repositories/      # local mirror of org repos (hidden, gitignored)
├── .librarian.token    # HTTP bearer token         (hidden, gitignored)
└── .logs/              # audit + live feed logs    (gitignored)
```

## Known constraints

- **Discovery is manual** — list repos in `.repos.input` by hand. Auto-discovery via
  `gh repo list <org>` is a possible later addition.
- **Scale ceiling** — each `ask_librarian` answer costs one Claude turn, bounded by your
  subscription rate limits. Great for personal/team use, not high-volume automation.
- **Auth & secrets** — mirroring private repos needs `gh`/SSH auth and puts source on
  disk; the HTTP token and `.repositories/` are gitignored. Keep credentials off the repo.
