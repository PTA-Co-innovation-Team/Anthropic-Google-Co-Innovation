"""FastAPI application entrypoint.

This module wires the pieces together:

* Configures JSON logging to stdout (Cloud Logging picks it up).
* Owns the shared ``httpx.AsyncClient`` (one per container instance).
* Defines a catch-all route that forwards every request through the proxy
  logic in :mod:`proxy`.
* Exposes a ``/healthz`` endpoint for Cloud Run's startup/liveness probe.

Why a single catch-all route? Because the gateway is a pass-through. We
don't want to maintain a list of Vertex API paths — Claude Code will use
whichever path is correct for its current code, and we want to forward
anything starting with ``/v1``.
"""

from __future__ import annotations

import os
from contextlib import asynccontextmanager
from typing import AsyncIterator

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from . import __version__
from .logging_config import configure_logging, get_logger
from .proxy import DEFAULT_TIMEOUT, proxy_request


# Configure logging before anything else; the logger is used below.
configure_logging()
log = get_logger(__name__)


# --- Application lifespan ---------------------------------------------------


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Create and dispose the shared httpx client.

    Called once when the container starts, once when it stops. We attach
    the client to ``app.state`` so every request handler can reach it
    without a module-level global that would interfere with testing.
    """
    log.info("gateway_starting")
    # ``http2=False`` keeps things simple. Vertex supports HTTP/2 but
    # enabling it adds a dependency on the ``h2`` package and offers no
    # measurable latency win for this workload.
    async with httpx.AsyncClient(timeout=DEFAULT_TIMEOUT, http2=False) as client:
        app.state.http_client = client
        yield
    log.info("gateway_stopped")


app = FastAPI(
    title="Claude Code → Vertex AI Gateway",
    version="0.1.0",
    # Disable auto-docs in production: this is a pass-through, not a
    # user-facing API. Cuts the attack surface by one endpoint.
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
    lifespan=lifespan,
)


# --- Routes -----------------------------------------------------------------


@app.get("/healthz")
async def healthz() -> JSONResponse:
    """Cloud Run liveness / readiness probe (legacy path).

    Returns a trivial JSON body with 200. We deliberately do not call
    Vertex here — if Vertex is down we still want the gateway marked
    healthy so it can return the real upstream error to callers.
    """
    return JSONResponse({"status": "ok"})


# The richer /health endpoint is what the end-to-end test script and
# in-VPC monitors use. Two-layer auth picture:
#
#   * **App layer (FastAPI)** — unauthenticated. The handler runs no
#     token validation and reveals nothing sensitive (name + version).
#   * **Platform layer (Cloud Run)** — the service is deployed with
#     ``--no-allow-unauthenticated`` + ``ingress=internal-and-cloud-
#     load-balancing``, so Cloud Run rejects callers lacking
#     ``roles/run.invoker`` BEFORE this handler runs. An anonymous
#     external probe therefore cannot reach this endpoint, regardless
#     of what FastAPI does.
#
# For Cloud Monitoring uptime checks: create a service account, grant
# ``roles/run.invoker`` on the gateway, and configure the uptime check
# to sign requests with that SA. See README.md → "External uptime
# probes".
#
# FastAPI routes are matched in declaration order; the catch-all
# ``/{full:path}`` route declared BELOW this one only matches when no
# explicit route matches, so /health does not fall through to the
# proxy.
@app.get("/health")
async def health() -> JSONResponse:
    """Liveness endpoint. Cloud Run IAM gates access; app layer is open."""
    return JSONResponse(
        {
            "status": "ok",
            "component": "llm_gateway",
            # Version comes from the package __init__; overridable via
            # GATEWAY_VERSION env for ops who pin images to a git SHA.
            "version": os.getenv("GATEWAY_VERSION", __version__),
        }
    )


# The catch-all route. FastAPI's path converter ``:path`` means ``full``
# captures everything including slashes. The explicit methods list
# includes POST (predict calls) and GET (rare but possible for discovery).
@app.api_route(
    "/{full:path}",
    methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"],
)
async def proxy(full: str, request: Request):
    """Forward any request to Vertex AI.

    The ``full`` argument is unused directly — we work off
    ``request.url.path`` which is the whole inbound path. We keep ``full``
    in the signature so FastAPI knows this route accepts any path.
    """
    client: httpx.AsyncClient = request.app.state.http_client
    try:
        return await proxy_request(request, client)
    except httpx.HTTPError as exc:
        # Upstream network problem. Log it with caller context and return
        # a 502, which is the semantically correct code for "I am a proxy
        # and my upstream is broken."
        log.exception(
            "upstream_error",
            extra={"path": request.url.path, "error_type": type(exc).__name__},
        )
        return JSONResponse(
            {"error": "upstream_unavailable", "detail": str(exc)},
            status_code=502,
        )
