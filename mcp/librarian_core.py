#!/usr/bin/env python3
"""
librarian_core.py — shared tool logic for the librarian, transport-agnostic.

Imported by both transports:
  - librarian_mcp.py   (stdio, zero-dependency, for local use)
  - librarian_http.py  (Streamable HTTP + bearer token, for VM deployment)

Every call is appended to librarian.log (one line: time, tool, status, duration,
detail) so you can `tail -f librarian.log` to watch all traffic — the same
observability whether the server runs locally or on a VM.
"""

import os
import json
import shutil
import threading
import subprocess
from datetime import datetime
from pathlib import Path


def _find_root(start):
    """Locate the project root (where CLAUDE.md / .repositories live), so this
    works whether the server file sits at the root or in a subdir like utils/."""
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
LOG_DIR = ROOT_DIR / ".logs"
LOG_FILE = LOG_DIR / "librarian.log"          # concise one-line-per-call audit
FEED_FILE = LOG_DIR / "librarian-feed.log"    # live trace of Claude's steps (tail -f in tmux)

ALLOWED_TOOLS = "Read,Grep,Glob,Bash(git log:*),Bash(git show:*),Bash(git blame:*)"
ASK_TIMEOUT = 300                  # seconds for a librarian query
SEARCH_CAP = 50                    # max grep matches returned
LINE_CAP = 300                     # max chars per match line
MAX_LOG_BYTES = 10 * 1024 * 1024   # cap each log file at 10 MB, keep one rollover


def _rotate_if_big(path):
    """Roll a log over to <name>.1 once it hits the size cap, so the active
    file never exceeds MAX_LOG_BYTES. Best-effort; tolerant of concurrent writers."""
    try:
        if path.exists() and path.stat().st_size >= MAX_LOG_BYTES:
            path.replace(path.with_name(path.name + ".1"))
    except Exception:
        pass


def _log(tool, status, dur, detail=""):
    """Append one observability line. Best-effort — never breaks a call."""
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        _rotate_if_big(LOG_FILE)
        ts = datetime.now().astimezone().isoformat(timespec="seconds")
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(f"{ts}\t{tool}\t{status}\t{dur:.1f}s\t{detail}\n")
    except Exception:
        pass


def _now():
    return datetime.now().timestamp()


# --- live feed: render Claude's streamed steps for the tmux watcher ----------

def _feed(line):
    """Append a line to the live feed (watched via `tail -f` in tmux)."""
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        _rotate_if_big(FEED_FILE)
        with open(FEED_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def _brief(inp, limit=160):
    """One-line summary of a tool_use input."""
    if isinstance(inp, dict):
        parts = []
        for k, v in inp.items():
            vs = str(v).replace("\n", " ")
            if len(vs) > 60:
                vs = vs[:60] + "…"
            parts.append(f"{k}={vs}")
        s = ", ".join(parts)
    else:
        s = str(inp)
    return s[:limit] + ("…" if len(s) > limit else "")


def _preview(content, limit=120):
    """Short preview of a tool_result's content."""
    if isinstance(content, list):
        s = " ".join(b.get("text", "") for b in content
                     if isinstance(b, dict) and b.get("type") == "text")
    else:
        s = str(content)
    s = s.replace("\n", " ").strip()
    return (s[:limit] + "…") if len(s) > limit else s


def _render_event(evt):
    """Turn one stream-json event into a readable feed line (or None to skip)."""
    t = evt.get("type")
    if t == "assistant":
        out = []
        for block in evt.get("message", {}).get("content", []):
            bt = block.get("type")
            if bt == "text":
                txt = block.get("text", "").strip()
                if txt:
                    out.append("  " + txt)
            elif bt == "tool_use":
                out.append(f"  → {block.get('name')}({_brief(block.get('input', {}))})")
        return "\n".join(out) if out else None
    if t == "user":
        for block in evt.get("message", {}).get("content", []):
            if block.get("type") == "tool_result":
                return f"    ✓ {_preview(block.get('content', ''))}"
    return None


# --- tools: each returns a text string --------------------------------------

def list_repositories():
    t0 = _now()
    if not REPOS_DIR.is_dir():
        _log("list_repositories", "error", _now() - t0, "no mirror dir")
        return "error: mirror directory .repositories/ not found."
    repos = sorted(p for p in REPOS_DIR.iterdir() if p.is_dir())
    if not repos:
        _log("list_repositories", "ok", _now() - t0, "empty")
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
    _log("list_repositories", "ok", _now() - t0, f"{len(repos)} repos")
    return f"{len(repos)} repositories in the mirror:\n" + "\n".join(lines)


def search_code(pattern, repos=None):
    t0 = _now()
    pattern = (pattern or "").strip()
    if not pattern:
        return "error: 'pattern' is required."
    repos = repos or []
    if repos:
        targets = [str(REPOS_DIR / r) for r in repos if (REPOS_DIR / r).is_dir()]
        if not targets:
            _log("search_code", "error", _now() - t0, "bad repos")
            return "error: none of the named repos exist in the mirror."
    else:
        targets = [str(REPOS_DIR)]

    cmd = ["grep", "-rnI", "--exclude-dir=.git", "-e", pattern, "--"] + targets
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        _log("search_code", "timeout", _now() - t0, pattern[:80])
        return "error: search timed out."

    lines = res.stdout.splitlines()
    if not lines:
        _log("search_code", "ok", _now() - t0, f"0 matches: {pattern[:80]}")
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
    _log("search_code", "ok", _now() - t0, f"{len(lines)} matches: {pattern[:80]}")
    return f"{len(lines)} match(es) for '{pattern}':\n" + "\n".join(shown) + note


def ask_librarian(question, repos=None):
    t0 = _now()
    question = (question or "").strip()
    if not question:
        return "error: 'question' is required."
    if not shutil.which("claude"):
        _log("ask_librarian", "error", _now() - t0, "no claude CLI")
        return "error: the 'claude' CLI is not on PATH."

    repos = repos or []
    prompt = question
    if repos:
        prompt = f"Limit your search to these repositories: {', '.join(repos)}.\n\n{question}"

    env = dict(os.environ)
    env.pop("ANTHROPIC_API_KEY", None)  # force subscription auth (no metered API)

    detail = f"repos={repos or 'all'} q={question[:120]!r}"
    ts = datetime.now().astimezone().isoformat(timespec="seconds")
    _feed(f"\n┌─ {ts}  ask_librarian  (repos={repos or 'all'})")
    _feed(f"│  Q: {question}")

    # Stream Claude's real steps so a tmux watcher can see the work live, while
    # still capturing the final answer to return to the caller.
    cmd = ["claude", "-p", prompt, "--allowedTools", ALLOWED_TOOLS,
           "--verbose", "--output-format", "stream-json"]
    proc = subprocess.Popen(cmd, cwd=str(ROOT_DIR), env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, bufsize=1)
    timer = threading.Timer(ASK_TIMEOUT, proc.kill)
    timer.start()

    result_text = None
    assistant_texts = []
    try:
        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                evt = json.loads(line)
            except json.JSONDecodeError:
                continue
            if evt.get("type") == "result":
                result_text = evt.get("result")
            elif evt.get("type") == "assistant":
                for b in evt.get("message", {}).get("content", []):
                    if b.get("type") == "text" and b.get("text", "").strip():
                        assistant_texts.append(b["text"].strip())
            rendered = _render_event(evt)
            if rendered:
                _feed(rendered)
        proc.wait()
    finally:
        timer.cancel()

    if proc.returncode and proc.returncode != 0:
        _feed("└─ FAILED")
        _log("ask_librarian", "fail", _now() - t0, detail)
        err = (proc.stderr.read() or "").strip()[:1000] if proc.stderr else ""
        return f"error: librarian query failed.\n{err}"

    answer = (result_text or "\n\n".join(assistant_texts)).strip()
    _feed(f"└─ done in {_now() - t0:.1f}s")
    _log("ask_librarian", "ok", _now() - t0, detail)
    return answer or "(no answer returned)"


# Tool metadata (used by the stdio server's hand-rolled tools/list).
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
