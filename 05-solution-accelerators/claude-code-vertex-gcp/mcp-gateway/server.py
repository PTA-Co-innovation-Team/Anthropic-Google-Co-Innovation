"""MCP Gateway — FastMCP server over Streamable HTTP, mounted under FastAPI.

Why FastAPI in front of FastMCP?
  * We want a plain unauthenticated ``GET /health`` for load balancers
    and monitoring, which lives alongside the MCP endpoint.
  * FastMCP's HTTP transport is an ASGI app; FastAPI/Starlette can
    mount it cleanly at ``/mcp`` while keeping our own routes at the
    root.

**Transport.** Streamable HTTP (the March 2025 MCP spec standard). SSE
is deprecated and NOT used here.

**Auth.** Cloud Run enforces ``roles/run.invoker`` on the caller for
the /mcp endpoint (the service is deployed with
``--no-allow-unauthenticated``). The /health endpoint is also reached
through Cloud Run's IAM gate — if you need it accessible from an
external uptime monitor, put it behind an IAP-fronted LB or grant
allUsers roles/run.invoker specifically for the health path (not
supported by Cloud Run today; use a separate service in that case).

**Endpoints**:
  * ``GET  /health``  →  unauthenticated liveness check
  * ``POST /mcp``     →  MCP Streamable HTTP endpoint (plus GET/DELETE
                         for session management per the spec)
"""

from __future__ import annotations

import logging
import os
import sys

from fastapi import FastAPI
from fastapi.responses import JSONResponse

# FastMCP is the Python MCP server library we use. It speaks Streamable
# HTTP out of the box and handles all the protocol framing for us.
from fastmcp import FastMCP

# Local tool implementations. Add new imports here when you add new
# files under tools/.
from tools.gcp_project_info import get_project_info


# ----------------------------------------------------------------------------
# Logging — mirror the LLM gateway's "JSON to stdout" pattern so Cloud
# Logging parses structured fields.
# ----------------------------------------------------------------------------

def _configure_logging() -> None:
    """Configure JSON-ish stdout logging for Cloud Run."""
    logging.basicConfig(
        level=logging.INFO,
        stream=sys.stdout,
        format='{"severity":"%(levelname)s","logger":"%(name)s","message":"%(message)s"}',
    )


_configure_logging()
log = logging.getLogger("mcp-gateway")


# ----------------------------------------------------------------------------
# FastMCP server + tool registration
# ----------------------------------------------------------------------------

# Give the server a stable name — Claude Code uses this to label the
# tools it sees in a session.
mcp = FastMCP("claude-code-gcp-mcp-gateway")


@mcp.tool()
def gcp_project_info() -> dict:
    """Return metadata about the GCP project this MCP gateway runs in.

    Useful as a sanity check after deployment: invoke this tool from
    Claude Code and you should see your project ID echoed back.

    Returns:
        A dict with ``project_id``, ``project_number``, ``region``, and
        ``enabled_apis``. Errors surface as ``error`` / ``warning``
        fields rather than raised exceptions.
    """
    log.info("tool_call gcp_project_info")
    return get_project_info()


# ----------------------------------------------------------------------------
# Build the Streamable-HTTP ASGI app from FastMCP.
#
# FastMCP's public API for this changed across versions:
#   * 2.x: mcp.http_app(path="/mcp") — returns a Starlette app
#   * earlier: mcp.streamable_http_app()
# We try the newer method first and fall back. Either way we end up
# with an ASGI app to mount.
# ----------------------------------------------------------------------------

def _build_mcp_asgi():
    """Return a Starlette/ASGI app serving the MCP Streamable HTTP transport."""
    if hasattr(mcp, "http_app"):
        # Newer FastMCP: http_app() accepts a path kwarg and handles
        # lifespan for us. Requesting path="/" so we can mount the
        # result at "/mcp" and get routes at /mcp exactly.
        return mcp.http_app(path="/")
    if hasattr(mcp, "streamable_http_app"):
        return mcp.streamable_http_app()
    raise RuntimeError(
        "This FastMCP version exposes neither http_app() nor "
        "streamable_http_app(); please upgrade fastmcp."
    )


mcp_asgi = _build_mcp_asgi()


# ----------------------------------------------------------------------------
# FastAPI composition.
#
# IMPORTANT: FastMCP relies on an ASGI lifespan to start its internal
# task manager. When we mount FastMCP under FastAPI, we must propagate
# its lifespan context to the parent app — otherwise tool calls will
# fail with "task group not initialized" errors.
# ----------------------------------------------------------------------------

# `lifespan` on the sub-app is what FastMCP exposes. Passing it through
# to FastAPI keeps both apps happy.
_sub_lifespan = getattr(mcp_asgi, "lifespan", None)

app = FastAPI(
    title="Claude Code MCP Gateway",
    version="0.1.0",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
    lifespan=_sub_lifespan,
)


@app.get("/health")
async def health() -> JSONResponse:
    """Liveness probe — app-layer unauth, platform-layer IAM-gated.

    Two-layer auth picture (same as the LLM gateway):

      * **App layer**: this handler does no token validation and
        reveals nothing sensitive.
      * **Platform layer**: Cloud Run enforces ``roles/run.invoker``
        before this handler runs. An anonymous external probe cannot
        reach here. For Cloud Monitoring uptime checks, sign requests
        with a service account that has ``run.invoker`` on this
        service — see README.md → "External uptime probes".

    Returns 200 as long as the process is up; does NOT call into
    FastMCP or any GCP API, so a failing tool does not fail health.
    """
    return JSONResponse({"status": "ok", "component": "mcp_gateway"})


# Mount the FastMCP app at /mcp. Callers POST JSON-RPC payloads here;
# FastMCP handles initialisation handshake, session IDs, and the
# tools/list + tools/call methods.
app.mount("/mcp", mcp_asgi)


# ----------------------------------------------------------------------------
# Local-run entrypoint. On Cloud Run we use uvicorn via CMD in Dockerfile
# so this block only runs when you `python server.py` directly.
# ----------------------------------------------------------------------------

def main() -> None:
    """Start uvicorn serving the composed FastAPI+FastMCP app."""
    import uvicorn

    port = int(os.getenv("PORT", "8080"))
    log.info("mcp_gateway_starting port=%d", port)
    uvicorn.run(app, host="0.0.0.0", port=port)


if __name__ == "__main__":
    main()
