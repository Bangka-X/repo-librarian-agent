#!/usr/bin/env python3
"""
librarian_http.py — remote librarian MCP server over Streamable HTTP, secured
with a static bearer token. For deploying on a VM.

Tool logic is shared with the stdio server via librarian_core.py, so this gets
the same live feed (.logs/librarian-feed.log) and audit log.

Run:
    export LIBRARIAN_TOKEN="<long-random-secret>"
    python3 mcp/librarian_http.py            # binds 127.0.0.1:8008 by default
    # override: LIBRARIAN_HOST=0.0.0.0 LIBRARIAN_PORT=8008 python3 mcp/librarian_http.py

Register from a client:
    claude mcp add --transport http librarian https://HOST/mcp \
      --header "Authorization: Bearer <same-token>"

SECURITY:
  - Refuses to start without LIBRARIAN_TOKEN (fail closed).
  - A bearer token over plain HTTP travels in cleartext. Bind to 127.0.0.1 and
    put an HTTPS reverse proxy (Caddy/nginx) in front, or use an SSH tunnel/VPN.
"""

import os
import sys
import hmac
from pathlib import Path

import uvicorn
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import JSONResponse
from mcp.server.fastmcp import FastMCP

sys.path.insert(0, str(Path(__file__).resolve().parent))
import librarian_core as core  # noqa: E402

TOKEN = os.environ.get("LIBRARIAN_TOKEN", "").strip()
HOST = os.environ.get("LIBRARIAN_HOST", "127.0.0.1")
PORT = int(os.environ.get("LIBRARIAN_PORT", "8008"))

if not TOKEN:
    print("FATAL: set LIBRARIAN_TOKEN to a long random secret before starting.",
          file=sys.stderr)
    sys.exit(1)

mcp = FastMCP("librarian", host=HOST, port=PORT)


@mcp.tool()
def ask_librarian(question: str, repos: list[str] | None = None) -> str:
    """Ask a natural-language question about the organization's repositories and get a
    synthesized answer with citations (repo/path/file:line). Use for explanations, an
    API/contract, how something works, or anything spanning repos. Costs a Claude turn;
    to just locate code, prefer search_code."""
    return core.ask_librarian(question, repos)


@mcp.tool()
def list_repositories() -> str:
    """List the repositories currently in the mirror, each with its last commit. Cheap
    (no Claude turn). Use to discover coverage before asking."""
    return core.list_repositories()


@mcp.tool()
def search_code(pattern: str, repos: list[str] | None = None) -> str:
    """Raw grep across the mirrored repos. Returns matching repo/path:line locations with
    snippets (capped at 50). Cheap (no Claude turn). Use to find where something lives when
    you'll read it yourself; use ask_librarian for synthesis."""
    return core.search_code(pattern, repos)


class BearerAuthMiddleware(BaseHTTPMiddleware):
    """Reject any request without a matching `Authorization: Bearer <token>`."""

    def __init__(self, app, token):
        super().__init__(app)
        self._token = token

    async def dispatch(self, request, call_next):
        if request.url.path == "/healthz":
            return JSONResponse({"status": "ok"})
        auth = request.headers.get("authorization", "")
        presented = auth[7:] if auth.startswith("Bearer ") else ""
        if not presented or not hmac.compare_digest(presented, self._token):
            return JSONResponse({"error": "unauthorized"}, status_code=401)
        return await call_next(request)


app = mcp.streamable_http_app()
app.add_middleware(BearerAuthMiddleware, token=TOKEN)


if __name__ == "__main__":
    print(f"[librarian-http] serving MCP on http://{HOST}:{PORT}/mcp "
          f"(mirror={core.REPOS_DIR})", file=sys.stderr)
    uvicorn.run(app, host=HOST, port=PORT, log_level="warning")
