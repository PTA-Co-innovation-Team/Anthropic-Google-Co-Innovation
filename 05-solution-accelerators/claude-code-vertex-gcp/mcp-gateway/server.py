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
from tools.gateway_traffic_summary import (
    gateway_traffic_summary as _traffic_summary,
)
from tools.gcp_project_info import get_project_info
from tools.list_cloud_run_services import (
    list_cloud_run_services as _list_cloud_run_services,
)
from tools.recent_gateway_errors import (
    recent_gateway_errors as _recent_gateway_errors,
)


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


@mcp.tool()
def list_cloud_run_services(region: str | None = None, max_results: int = 50) -> dict:
    """List Cloud Run services in the current project.

    Use this when the developer asks Claude what's deployed without
    wanting to shell out to ``gcloud`` themselves. Read-only.

    Args:
        region: Cloud Run region (e.g. ``us-central1``). Defaults to the
            gateway's own region. Pass ``"-"`` to list across all regions.
        max_results: Cap on the number of services returned. Default 50.

    Returns:
        Dict with ``services`` (list of {name, region, url, last_revision,
        ready, last_deployed_at}), ``count``, ``truncated``, ``region``.
    """
    log.info("tool_call list_cloud_run_services region=%s", region)
    return _list_cloud_run_services(region=region, max_results=max_results)


@mcp.tool()
def recent_gateway_errors(hours: int = 1, max_results: int = 25) -> dict:
    """Return recent ERROR/WARNING log entries from the gateway services.

    Useful when the developer asks Claude to triage a gateway problem;
    Claude can grab the actual log lines without the user copy-pasting
    from Cloud Logging. Read-only.

    Args:
        hours: Time window. Default 1 hour, max 168 (one week).
        max_results: Cap on entries returned. Default 25, max 200.

    Returns:
        Dict with ``errors`` (list of {timestamp, severity, service,
        summary}), ``count``, ``window_hours``.
    """
    log.info("tool_call recent_gateway_errors hours=%s", hours)
    return _recent_gateway_errors(hours=hours, max_results=max_results)


@mcp.tool()
def gateway_traffic_summary(hours: int = 24) -> dict:
    """Summarize gateway traffic over the last `hours` hours.

    Reads from the BigQuery dataset populated by the observability
    module. Lets a developer ask "how busy was the gateway today?" or
    "who's been the heaviest user this week?" without leaving Claude.

    Args:
        hours: Time window in hours. Default 24, max 720 (30 days).

    Returns:
        Dict with ``window_hours``, ``total_requests``, ``by_model``
        (list of {model, count}), ``by_caller`` (top 10),
        ``error_rate_pct``, and ``latency_ms`` ({p50, p95, p99}).
    """
    log.info("tool_call gateway_traffic_summary hours=%s", hours)
    return _traffic_summary(hours=hours)


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

from contextlib import asynccontextmanager


@asynccontextmanager
async def _lifespan(app: FastAPI):
    """Propagate the FastMCP sub-app lifespan into the parent FastAPI app.

    Starlette does not automatically forward lifespan events to mounted
    sub-applications, so we must do it manually. We look for the
    lifespan handler on the sub-app's router and invoke it ourselves.
    """
    _lc = getattr(getattr(mcp_asgi, "router", None), "lifespan_context", None)
    if _lc is not None:
        async with _lc(mcp_asgi):
            yield
    else:
        yield


app = FastAPI(
    title="Claude Code MCP Gateway",
    version="0.1.0",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
    lifespan=_lifespan,
)

if os.getenv("ENABLE_TOKEN_VALIDATION", "0") == "1":
    from token_validation import validate_token_middleware

    app.middleware("http")(validate_token_middleware)
    log.info("token_validation_enabled")


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
