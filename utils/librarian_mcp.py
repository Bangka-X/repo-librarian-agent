#!/usr/bin/env python3
"""
librarian_mcp.py — MCP server exposing the repository librarian.

Zero-dependency: speaks MCP over stdio (newline-delimited JSON-RPC 2.0), so a
consuming agent registers it with:

    claude mcp add --scope user librarian -- python3 /ABS/PATH/utils/librarian_mcp.py

Tools (see PRD-librarian-mcp.md):
  - ask_librarian(question, repos?)  -> Claude-synthesized, cited answer (1 turn)
  - list_repositories()              -> mirror contents + last commit (cheap)
  - search_code(pattern, repos?)     -> raw grep matches, capped (cheap)

All diagnostics go to stderr; stdout carries ONLY JSON-RPC messages.
"""

import sys
import os
import json
import shutil
import subprocess
from pathlib import Path

def _find_root(start):
    """Locate the project root (where CLAUDE.md / .repositories live), so this
    file works whether it sits at the root or in a subdir like utils/."""
    d = start
    for _ in range(6):
        if (d / "CLAUDE.md").exists() or (d / ".repositories").is_dir():
            return d
        if d.parent == d:
            break
        d = d.parent
    return start


ROOT_DIR = _find_root(Path(__file__).resolve().parent)
REPOS_DIR = ROOT_DIR / ".repositories"
ALLOWED_TOOLS = "Read,Grep,Glob,Bash(git log:*),Bash(git show:*),Bash(git blame:*)"
ASK_TIMEOUT = 300   # seconds for a librarian query
SEARCH_CAP = 50     # max grep matches returned
LINE_CAP = 300      # max chars per match line


def log(msg):
    print(f"[librarian-mcp] {msg}", file=sys.stderr, flush=True)


def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


# --- tool implementations: each returns a text string -----------------------

def tool_list_repositories(_args):
    if not REPOS_DIR.is_dir():
        return "error: mirror directory .repositories/ not found."
    repos = sorted(p for p in REPOS_DIR.iterdir() if p.is_dir())
    if not repos:
        return "Mirror is empty — no repositories cloned yet."
    lines = []
    for p in repos:
        if (p / ".git").exists():
            try:
                h = subprocess.run(["git", "-C", str(p), "rev-parse", "--short", "HEAD"],
                                   capture_output=True, text=True, timeout=10).stdout.strip()
                d = subprocess.run(["git", "-C", str(p), "log", "-1", "--format=%cI"],
                                   capture_output=True, text=True, timeout=10).stdout.strip()
                lines.append(f"{p.name}  @{h}  (last commit {d})")
            except Exception:
                lines.append(f"{p.name}  (git info unavailable)")
        else:
            lines.append(f"{p.name}  (not a git repo)")
    return f"{len(repos)} repositories in the mirror:\n" + "\n".join(lines)


def tool_search_code(args):
    pattern = (args.get("pattern") or "").strip()
    if not pattern:
        return "error: 'pattern' is required."
    repos = args.get("repos") or []
    if repos:
        targets = [str(REPOS_DIR / r) for r in repos if (REPOS_DIR / r).is_dir()]
        if not targets:
            return "error: none of the named repos exist in the mirror."
    else:
        targets = [str(REPOS_DIR)]

    cmd = ["grep", "-rnI", "--exclude-dir=.git", "-e", pattern, "--"] + targets
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        return "error: search timed out."

    lines = res.stdout.splitlines()
    if not lines:
        return f"No matches for: {pattern}"

    prefix = str(REPOS_DIR) + "/"
    shown = []
    for ln in lines[:SEARCH_CAP]:
        ln = ln.replace(prefix, "")
        if len(ln) > LINE_CAP:
            ln = ln[:LINE_CAP] + " …"
        shown.append(ln)
    note = ("" if len(lines) <= SEARCH_CAP
            else f"\n… {len(lines) - SEARCH_CAP} more (showing first {SEARCH_CAP})")
    return f"{len(lines)} match(es) for '{pattern}':\n" + "\n".join(shown) + note


def tool_ask_librarian(args):
    question = (args.get("question") or "").strip()
    if not question:
        return "error: 'question' is required."
    if not shutil.which("claude"):
        return "error: the 'claude' CLI is not on PATH."

    repos = args.get("repos") or []
    prompt = question
    if repos:
        prompt = f"Limit your search to these repositories: {', '.join(repos)}.\n\n{question}"

    env = dict(os.environ)
    env.pop("ANTHROPIC_API_KEY", None)  # force subscription auth (no metered API)

    cmd = ["claude", "-p", prompt, "--allowedTools", ALLOWED_TOOLS]
    try:
        res = subprocess.run(cmd, cwd=str(ROOT_DIR), env=env,
                             capture_output=True, text=True, timeout=ASK_TIMEOUT)
    except subprocess.TimeoutExpired:
        return f"error: librarian query timed out after {ASK_TIMEOUT}s."
    if res.returncode != 0:
        return f"error: librarian query failed.\n{res.stderr.strip()[:1000]}"
    return res.stdout.strip() or "(no answer returned)"


TOOLS = [
    {
        "name": "ask_librarian",
        "description": (
            "Ask a natural-language question about the organization's repositories and get a "
            "synthesized answer with citations (repo/path/file:line). Use for explanations, an "
            "API/contract, how something works, or anything spanning repos. Costs a Claude turn; "
            "to just locate code, prefer search_code."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "question": {"type": "string", "description": "The question to answer."},
                "repos": {"type": "array", "items": {"type": "string"},
                          "description": "Optional: limit to these repo names (see list_repositories)."},
            },
            "required": ["question"],
        },
    },
    {
        "name": "list_repositories",
        "description": (
            "List the repositories currently in the mirror, each with its last commit. Cheap "
            "(no Claude turn). Use to discover coverage before asking."
        ),
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "search_code",
        "description": (
            "Raw grep across the mirrored repos. Returns matching repo/path:line locations with "
            "snippets (capped at 50). Cheap (no Claude turn). Use to find where something lives "
            "when you'll read it yourself; use ask_librarian for synthesis."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "pattern": {"type": "string", "description": "Text or basic-regex pattern."},
                "repos": {"type": "array", "items": {"type": "string"},
                          "description": "Optional: limit to these repo names."},
            },
            "required": ["pattern"],
        },
    },
]

DISPATCH = {
    "ask_librarian": tool_ask_librarian,
    "list_repositories": tool_list_repositories,
    "search_code": tool_search_code,
}


def handle(req):
    method = req.get("method")
    rid = req.get("id")

    if method == "initialize":
        params = req.get("params") or {}
        return {"jsonrpc": "2.0", "id": rid, "result": {
            "protocolVersion": params.get("protocolVersion", "2024-11-05"),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "librarian", "version": "0.1.0"},
        }}

    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": rid, "result": {"tools": TOOLS}}

    if method == "tools/call":
        params = req.get("params") or {}
        name = params.get("name")
        args = params.get("arguments") or {}
        fn = DISPATCH.get(name)
        if not fn:
            return {"jsonrpc": "2.0", "id": rid,
                    "error": {"code": -32602, "message": f"unknown tool: {name}"}}
        try:
            text = fn(args)
        except Exception as e:  # never crash the server on a tool error
            text = f"error: {e}"
        is_err = isinstance(text, str) and text.startswith("error:")
        return {"jsonrpc": "2.0", "id": rid,
                "result": {"content": [{"type": "text", "text": text}], "isError": is_err}}

    if method == "ping":
        return {"jsonrpc": "2.0", "id": rid, "result": {}}

    # Notifications (no id) need no response.
    if rid is None:
        return None
    return {"jsonrpc": "2.0", "id": rid,
            "error": {"code": -32601, "message": f"method not found: {method}"}}


def main():
    log(f"started; mirror={REPOS_DIR}")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            log("skipping non-JSON line")
            continue
        resp = handle(req)
        if resp is not None:
            send(resp)
    log("stdin closed, exiting")


if __name__ == "__main__":
    main()
